// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:path/filepath"
import "core:testing"
import disk "../disk"

// independent single-sector read through the public API only
read_test_sector :: proc(t: ^testing.T, v: ^Volume, lba: u64, loc := #caller_location) -> [SECTOR]u8 {
	buf: [SECTOR]u8
	testing.expect(t, volume_read(v, lba, buf[:]), loc = loc)
	return buf
}

read_test_all_zero :: proc(b: []u8) -> bool {
	for x in b {
		if x != 0 {
			return false
		}
	}
	return true
}

// follow a FAT chain with reads through volume_read only
read_test_chain :: proc(t: ^testing.T, v: ^Volume, fat_start: u64, first: u32) -> [dynamic]u32 {
	chain := make([dynamic]u32)
	c := first
	for {
		append(&chain, c)
		sec := read_test_sector(t, v, fat_start + u64(c / 128))
		next := synth_rd32(sec[:], int(c % 128) * 4) & 0x0FFFFFFF
		if next >= 0x0FFFFFF8 {
			break
		}
		testing.expect(t, next >= 2)
		c = next
		if len(chain) > 1024 {
			testing.fail_now(t, "FAT chain does not terminate")
		}
	}
	return chain
}

@(test)
read_test_volume_end_to_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}

	// MBR: signature and one bootable FAT32 LBA partition
	mbr := read_test_sector(t, v, 0)
	testing.expect_value(t, mbr[510], u8(0x55))
	testing.expect_value(t, mbr[511], u8(0xAA))
	testing.expect_value(t, mbr[446], u8(0x80))
	testing.expect_value(t, mbr[446 + 4], u8(0x0C))
	part := u64(synth_rd32(mbr[:], 446 + 8))
	testing.expect_value(t, part, u64(PART_START_LBA))

	// gap before the partition reads as zeros
	gap := read_test_sector(t, v, 1)
	testing.expect(t, read_test_all_zero(gap[:]))

	// VBR: parse the BPB independently
	vbr := read_test_sector(t, v, part)
	testing.expect_value(t, vbr[510], u8(0x55))
	testing.expect_value(t, vbr[511], u8(0xAA))
	testing.expect_value(t, synth_rd16(vbr[:], 11), u16(SECTOR))
	testing.expect_value(t, vbr[13], u8(SECTORS_PER_CLUSTER))
	reserved := synth_rd16(vbr[:], 14)
	testing.expect_value(t, reserved, u16(RESERVED_SECTORS))
	nfats := vbr[16]
	testing.expect_value(t, nfats, u8(NUM_FATS))
	spf := synth_rd32(vbr[:], 36)
	testing.expect(t, spf > 0)
	root_cluster := synth_rd32(vbr[:], 44)
	testing.expect_value(t, root_cluster, u32(2))

	// FSInfo and backups
	fsi := read_test_sector(t, v, part + 1)
	testing.expect_value(t, synth_rd32(fsi[:], 0), u32(0x41615252))
	bak := read_test_sector(t, v, part + 6)
	testing.expect(t, bak == vbr)
	bak_fsi := read_test_sector(t, v, part + 7)
	testing.expect(t, bak_fsi == fsi)

	fat_start := part + u64(reserved)
	data_start := fat_start + u64(nfats) * u64(spf)

	// both FAT copies agree; entry 0 is the media descriptor
	f0 := read_test_sector(t, v, fat_start)
	f1 := read_test_sector(t, v, fat_start + u64(spf))
	testing.expect(t, f0 == f1)
	testing.expect_value(t, synth_rd32(f0[:], 0), u32(0x0FFFFFF8))

	// walk the root directory and find IO.SYS
	io_cluster, io_size := u32(0), u32(0)
	found := false
	root_lba := data_start + u64(root_cluster - 2) * SECTORS_PER_CLUSTER
	scan: for s in u64(0) ..< SECTORS_PER_CLUSTER {
		sec := read_test_sector(t, v, root_lba + s)
		for off := 0; off < SECTOR; off += 32 {
			e := sec[off:][:32]
			if e[0] == 0 {
				break scan
			}
			if e[11] == 0x0F {
				continue // LFN
			}
			if string(e[0:11]) == "IO      SYS" {
				io_cluster = u32(synth_rd16(e, 20)) << 16 | u32(synth_rd16(e, 26))
				io_size = synth_rd32(e, 28)
				found = true
			}
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, io_size, u32(5000))
	testing.expect(t, io_cluster >= 2)
	if !found {
		return
	}

	// follow the FAT chain and compare content with the host file
	chain := read_test_chain(t, v, fat_start, io_cluster)
	testing.expect_value(t, len(chain), 2)
	content := make([dynamic]u8)
	for c in chain {
		lba := data_start + u64(c - 2) * SECTORS_PER_CLUSTER
		for s in u64(0) ..< SECTORS_PER_CLUSTER {
			sec := read_test_sector(t, v, lba + s)
			append(&content, ..sec[:])
		}
	}
	testing.expect(t, len(content) >= int(io_size))
	host_path, _ := filepath.join({dir, "IO.SYS"})
	host, herr := os.read_entire_file(host_path, context.allocator)
	testing.expect(t, herr == nil)
	testing.expect(t, string(content[:io_size]) == string(host))
	// slack after EOF inside the last cluster is zero padded
	testing.expect(t, read_test_all_zero(content[io_size:]))

	// free clusters read as zeros
	free := read_test_sector(t, v, data_start + u64(v.alloc.next_free - 2) * SECTORS_PER_CLUSTER)
	testing.expect(t, read_test_all_zero(free[:]))
}

@(test)
read_test_block_device_glue :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := fat32_test_fixture(t)
	defer os.remove_all(dir)

	v := volume_open(dir, 2048)
	testing.expect(t, v != nil)
	if v == nil {
		return
	}
	bd: disk.Block_Device = volume_block_device(v)
	testing.expect(t, bd.ctx == rawptr(v))
	testing.expect_value(t, bd.sector_count, u64(PART_START_LBA) + u64(v.alloc.geo.total_sectors))

	// multi-sector read matches two single-sector reads
	part := u64(PART_START_LBA)
	two: [2 * SECTOR]u8
	testing.expect(t, bd.read(bd.ctx, part, two[:]))
	vbr := read_test_sector(t, v, part)
	fsi := read_test_sector(t, v, part + 1)
	testing.expect(t, string(two[:SECTOR]) == string(vbr[:]))
	testing.expect(t, string(two[SECTOR:]) == string(fsi[:]))

	// writes are rejected until the Task 19 journal lands
	sec: [SECTOR]u8
	testing.expect(t, !bd.write(bd.ctx, part, sec[:]))
}
