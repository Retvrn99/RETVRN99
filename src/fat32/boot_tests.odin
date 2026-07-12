// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

@(test)
boot_test_mbr_code :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	mbr := make_mbr(g.total_sectors)
	// boot code area populated, partition table and signature intact
	nonzero := 0
	for b in mbr[:446] {
		if b != 0 {
			nonzero += 1
		}
	}
	testing.expect(t, nonzero > 32)
	testing.expect_value(t, mbr[0], u8(0xFA)) // cli
	testing.expect_value(t, mbr[446], u8(0x80))
	testing.expect_value(t, mbr[450], u8(0x0C))
	testing.expect_value(t, fat32_rd32le(mbr[:], 454), u32(PART_START_LBA))
	testing.expect_value(t, mbr[510], u8(0x55))
	testing.expect_value(t, mbr[511], u8(0xAA))
}

@(test)
boot_test_vbr_patched :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	lba := u64(0x1_0002_3456)
	vbr := make_vbr(&g, g.total_sectors, lba)
	// IO.SYS LBA qword at the patch offset
	lo := u64(fat32_rd32le(vbr[:], VBR_LBA_OFFSET))
	hi := u64(fat32_rd32le(vbr[:], VBR_LBA_OFFSET + 4))
	testing.expect_value(t, hi << 32 | lo, lba)
	// DAP right before it: size 0x10, 4 sectors, buffer 0000:0700
	testing.expect_value(t, vbr[VBR_LBA_OFFSET - 8], u8(0x10))
	testing.expect_value(t, fat32_rd16le(vbr[:], VBR_LBA_OFFSET - 6), u16(4))
	testing.expect_value(t, fat32_rd16le(vbr[:], VBR_LBA_OFFSET - 4), u16(0x0700))
	testing.expect_value(t, fat32_rd16le(vbr[:], VBR_LBA_OFFSET - 2), u16(0))
	// boot code non-zero and the BPB still parses
	testing.expect(t, vbr[0x5A] != 0)
	testing.expect_value(t, fat32_rd16le(vbr[:], 11), u16(SECTOR))
	testing.expect_value(t, vbr[13], u8(SECTORS_PER_CLUSTER))
	testing.expect_value(t, fat32_rd16le(vbr[:], 14), u16(RESERVED_SECTORS))
	testing.expect_value(t, fat32_rd32le(vbr[:], 28), u32(PART_START_LBA))
	testing.expect_value(t, fat32_rd32le(vbr[:], 36), g.sectors_per_fat)
	testing.expect_value(t, fat32_rd32le(vbr[:], 44), u32(2))
	testing.expect_value(t, vbr[510], u8(0x55))
	testing.expect_value(t, vbr[511], u8(0xAA))
}

// MS-DOS 7 MSLOAD handoff: the VBR must know the absolute LBA of the first
// data sector (pushed at 0:7BFC) and IO.SYS's first cluster (passed in SI:DI)
@(test)
boot_test_vbr_msload_handoff_fields :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	lba := u64(10464)
	cluster := u32(26)
	vbr := make_vbr(&g, g.total_sectors, lba, cluster)
	testing.expect_value(t, fat32_rd32le(vbr[:], VBR_DATA_LBA_OFFSET),
		u32(PART_START_LBA) + g.data_start)
	testing.expect_value(t, fat32_rd32le(vbr[:], VBR_CLUSTER_OFFSET), cluster)
	// consistency: data start + (cluster-2)*spc must equal the IO.SYS LBA
	got := u64(fat32_rd32le(vbr[:], VBR_DATA_LBA_OFFSET)) +
		u64((fat32_rd32le(vbr[:], VBR_CLUSTER_OFFSET) - 2) * SECTORS_PER_CLUSTER)
	testing.expect_value(t, got, lba)
}

@(test)
boot_test_vbr_stub_without_lba :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	vbr := make_vbr(&g, g.total_sectors)
	testing.expect_value(t, vbr[90], u8(0xCD)) // int 18h stub
	testing.expect_value(t, vbr[91], u8(0x18))
	testing.expect_value(t, fat32_rd32le(vbr[:], VBR_LBA_OFFSET), u32(0))
	testing.expect_value(t, vbr[510], u8(0x55))
	testing.expect_value(t, vbr[511], u8(0xAA))
}

@(test)
boot_test_volume_vbr :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	// fixture has IO.SYS: patched VBR with its absolute LBA
	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	io := v.alloc.root.children[2]
	testing.expect(t, io.name == "IO.SYS")
	expected := u64(PART_START_LBA) + u64(cluster_to_lba(&v.alloc.geo, io.first_cluster))
	testing.expect_value(t, v.io_sys_lba, expected)
	vbr := read_test_sector(t, v, PART_START_LBA)
	testing.expect_value(t, u64(fat32_rd32le(vbr[:], VBR_LBA_OFFSET)), expected)
	testing.expect(t, vbr[0x5A] != 0)
	// MSLOAD handoff fields, also present in the backup VBR at rel sector 6
	testing.expect_value(t, fat32_rd32le(vbr[:], VBR_DATA_LBA_OFFSET),
		u32(PART_START_LBA) + v.alloc.geo.data_start)
	testing.expect_value(t, fat32_rd32le(vbr[:], VBR_CLUSTER_OFFSET), io.first_cluster)
	bak := read_test_sector(t, v, PART_START_LBA + 6)
	testing.expect_value(t, fat32_rd32le(bak[:], VBR_CLUSTER_OFFSET), io.first_cluster)

	// without IO.SYS the int 18h stub stays
	base, _ := os.temp_directory(context.allocator)
	dir2, _ := filepath.join({base, fmt.tprintf("retvrn99_noio_%d", time.now()._nsec)})
	testing.expect(t, os.make_directory_all(dir2) == nil)
	defer os.remove_all(dir2)
	p, _ := filepath.join({dir2, "COMMAND.COM"})
	testing.expect(t, os.write_entire_file(p, make([]u8, 100)) == nil)
	// the missing-IO.SYS error line is expected here
	quiet := context
	quiet.logger = log.nil_logger()
	v2: ^Volume
	{
		context = quiet
		v2 = volume_open(dir2, 2048)
	}
	testing.expect(t, v2 != nil)
	if v2 == nil {
		return
	}
	testing.expect_value(t, v2.io_sys_lba, u64(0))
	vbr2 := read_test_sector(t, v2, PART_START_LBA)
	testing.expect_value(t, vbr2[90], u8(0xCD))
	testing.expect_value(t, vbr2[91], u8(0x18))
}
