// SPDX-License-Identifier: GPL-3.0-only
package fat32

SECTOR :: 512
SECTORS_PER_CLUSTER :: 8 // 4K clusters
PART_START_LBA :: 2048
RESERVED_SECTORS :: 32
NUM_FATS :: 2

Geometry :: struct {
	total_sectors:   u32, // of the partition
	sectors_per_fat: u32,
	fat_start:       u32, // relative to partition
	data_start:      u32,
	cluster_count:   u32,
}

geometry_make :: proc(volume_mb: u32) -> Geometry {
	total := volume_mb * 2048 // sectors
	// iterate: clusters ≈ (total - reserved - 2*fat) / spc
	spf := u32(0)
	for {
		data := total - RESERVED_SECTORS - NUM_FATS * spf
		clusters := data / SECTORS_PER_CLUSTER
		need := (clusters + 2) * 4 // 4 bytes per entry
		need_sectors := (need + SECTOR - 1) / SECTOR
		if need_sectors <= spf { break }
		spf = need_sectors
	}
	g := Geometry{total_sectors = total, sectors_per_fat = spf}
	g.fat_start = RESERVED_SECTORS
	g.data_start = RESERVED_SECTORS + NUM_FATS * spf
	g.cluster_count = (total - g.data_start) / SECTORS_PER_CLUSTER
	return g
}

cluster_to_lba :: proc(g: ^Geometry, cluster: u32) -> u32 {
	return g.data_start + (cluster - 2) * SECTORS_PER_CLUSTER
}

@(private = "file")
put16 :: proc(b: []u8, off: int, v: u16) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
}

@(private = "file")
put32 :: proc(b: []u8, off: int, v: u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

// clean-room boot code assembled from assets/vbr/*.asm
MBR_BIN :: #load("../../assets/vbr/mbr.bin")
VBR_BIN :: #load("../../assets/vbr/vbr.bin")
VBR_LBA_OFFSET :: 0x1F0 // qword: absolute LBA of IO.SYS first sector

// MBR: one bootable 0x0C partition at PART_START_LBA
make_mbr :: proc(total_sectors: u32) -> (mbr: [512]u8) {
	copy(mbr[:446], MBR_BIN)
	e := mbr[446:]
	e[0] = 0x80 // bootable
	e[1] = 0xFE // dummy CHS (LBA only)
	e[2] = 0xFF
	e[3] = 0xFF
	e[4] = 0x0C // FAT32 LBA
	e[5] = 0xFE
	e[6] = 0xFF
	e[7] = 0xFF
	put32(e, 8, PART_START_LBA)
	put32(e, 12, total_sectors)
	mbr[510] = 0x55
	mbr[511] = 0xAA
	return
}

// VBR: jump + FAT32 BPB; boot code loads IO.SYS when its LBA is known,
// otherwise an int 18h stub remains
make_vbr :: proc(g: ^Geometry, total: u32, io_sys_lba: u64 = 0) -> (vbr: [512]u8) {
	if io_sys_lba != 0 {
		copy(vbr[:], VBR_BIN)
		put32(vbr[:], VBR_LBA_OFFSET, u32(io_sys_lba))
		put32(vbr[:], VBR_LBA_OFFSET + 4, u32(io_sys_lba >> 32))
	} else {
		vbr[90] = 0xCD // int 18h
		vbr[91] = 0x18
	}
	vbr[0] = 0xEB
	vbr[1] = 0x58
	vbr[2] = 0x90
	copy(vbr[3:11], "MSWIN4.1")
	put16(vbr[:], 11, SECTOR)
	vbr[13] = SECTORS_PER_CLUSTER
	put16(vbr[:], 14, RESERVED_SECTORS)
	vbr[16] = NUM_FATS
	vbr[21] = 0xF8 // media
	put16(vbr[:], 24, 63) // sectors/track
	put16(vbr[:], 26, 16) // heads
	put32(vbr[:], 28, PART_START_LBA) // hidden
	put32(vbr[:], 32, total)
	put32(vbr[:], 36, g.sectors_per_fat)
	put32(vbr[:], 44, 2) // root cluster
	put16(vbr[:], 48, 1) // fsinfo sector
	put16(vbr[:], 50, 6) // boot backup
	vbr[64] = 0x80 // drive
	vbr[66] = 0x29 // ext signature
	put32(vbr[:], 67, 0x19980625) // serial
	copy(vbr[71:82], "MATE98     ")
	copy(vbr[82:90], "FAT32   ")
	vbr[510] = 0x55
	vbr[511] = 0xAA
	return
}

make_fsinfo :: proc() -> (fi: [512]u8) {
	put32(fi[:], 0, 0x41615252)
	put32(fi[:], 484, 0x61417272)
	put32(fi[:], 488, 0xFFFFFFFF) // free count unknown
	put32(fi[:], 492, 0xFFFFFFFF) // next free unknown
	fi[510] = 0x55
	fi[511] = 0xAA
	return
}
