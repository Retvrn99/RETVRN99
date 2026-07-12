// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:testing"

// little-endian reads local to the test
fat32_rd16le :: proc(b: []u8, off: int) -> u16 {
	return u16(b[off]) | u16(b[off + 1]) << 8
}

fat32_rd32le :: proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

@(test)
fat32_test_geometry_2048mb :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	testing.expect(t, g.total_sectors == 2048 * 2048)
	testing.expect(t, g.cluster_count >= 65525) // FAT32 mandatory minimum
	testing.expect(t, g.fat_start == RESERVED_SECTORS)
	testing.expect(t, g.data_start == RESERVED_SECTORS + 2 * g.sectors_per_fat)
	testing.expect(t, cluster_to_lba(&g, 2) == g.data_start)
	testing.expect(t, cluster_to_lba(&g, 3) == g.data_start + SECTORS_PER_CLUSTER)
}

@(test)
fat32_test_mbr :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	mbr := make_mbr(g.total_sectors)
	testing.expect(t, mbr[510] == 0x55)
	testing.expect(t, mbr[511] == 0xAA)
	testing.expect(t, mbr[446] == 0x80)
	testing.expect(t, mbr[450] == 0x0C)
	testing.expect(t, fat32_rd32le(mbr[:], 454) == PART_START_LBA)
	testing.expect(t, fat32_rd32le(mbr[:], 458) == g.total_sectors)
}

@(test)
fat32_test_vbr :: proc(t: ^testing.T) {
	g := geometry_make(2048)
	vbr := make_vbr(&g, g.total_sectors)
	testing.expect(t, fat32_rd16le(vbr[:], 11) == SECTOR)          // bytes/sector
	testing.expect(t, vbr[13] == SECTORS_PER_CLUSTER)              // sectors/cluster
	testing.expect(t, fat32_rd16le(vbr[:], 14) == RESERVED_SECTORS)
	testing.expect(t, vbr[16] == NUM_FATS)
	testing.expect(t, vbr[21] == 0xF8)                             // media
	testing.expect(t, fat32_rd32le(vbr[:], 28) == PART_START_LBA)  // hidden
	testing.expect(t, fat32_rd32le(vbr[:], 32) == g.total_sectors)
	testing.expect(t, fat32_rd32le(vbr[:], 36) == g.sectors_per_fat)
	testing.expect(t, fat32_rd32le(vbr[:], 44) == 2)               // root cluster
	testing.expect(t, fat32_rd16le(vbr[:], 48) == 1)               // fsinfo sector
	testing.expect(t, fat32_rd16le(vbr[:], 50) == 6)               // boot backup
	testing.expect(t, vbr[66] == 0x29)                             // ext signature
	testing.expect(t, string(vbr[71:82]) == "RETVRN99   ")
	testing.expect(t, string(vbr[82:90]) == "FAT32   ")
	testing.expect(t, vbr[510] == 0x55)
	testing.expect(t, vbr[511] == 0xAA)
}

@(test)
fat32_test_fsinfo :: proc(t: ^testing.T) {
	fi := make_fsinfo()
	testing.expect(t, fat32_rd32le(fi[:], 0) == 0x41615252)
	testing.expect(t, fat32_rd32le(fi[:], 484) == 0x61417272)
	testing.expect(t, fat32_rd32le(fi[:], 488) == 0xFFFFFFFF) // free count unknown
	testing.expect(t, fi[510] == 0x55)
	testing.expect(t, fi[511] == 0xAA)
}
