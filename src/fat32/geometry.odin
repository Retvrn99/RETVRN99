// SPDX-License-Identifier: GPL-3.0-only
package fat32

import disk "../disk"

SECTOR :: 512
SECTORS_PER_CLUSTER :: 8 // 4K clusters
DISK_HEADS :: disk.IDE_CHS_HEADS
SECTORS_PER_TRACK :: disk.IDE_CHS_SECTORS_PER_TRACK
PART_START_LBA :: SECTORS_PER_TRACK
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

@(private = "file")
put_chs :: proc(b: []u8, off: int, lba: u64) {
	max_lba := u64(1024 * DISK_HEADS * SECTORS_PER_TRACK - 1)
	address := min(lba, max_lba)
	cylinder := address / (DISK_HEADS * SECTORS_PER_TRACK)
	remainder := address % (DISK_HEADS * SECTORS_PER_TRACK)
	head := remainder / SECTORS_PER_TRACK
	sector := remainder % SECTORS_PER_TRACK + 1
	b[off] = u8(head)
	b[off + 1] = u8(sector) | u8(cylinder >> 2) & 0xC0
	b[off + 2] = u8(cylinder)
}

// clean-room boot code assembled from assets/vbr/*.asm
MBR_BIN :: #load("../../assets/vbr/mbr.bin")
VBR_BIN :: #load("../../assets/vbr/vbr.bin")
VBR_LBA_OFFSET :: 0x1F0 // qword: absolute LBA of IO.SYS first sector
VBR_DATA_LBA_OFFSET :: 0x1E0 // dword: absolute LBA of the first data sector
VBR_CLUSTER_OFFSET :: 0x1E4 // dword: first cluster of IO.SYS

// MBR: one bootable 0x0C partition at PART_START_LBA
make_mbr :: proc(total_sectors: u32) -> (mbr: [512]u8) {
	copy(mbr[:446], MBR_BIN)
	e := mbr[446:]
	e[0] = 0x80 // bootable
	put_chs(e, 1, PART_START_LBA)
	e[4] = 0x0C // FAT32 LBA
	put_chs(e, 5, u64(PART_START_LBA) + u64(total_sectors) - 1)
	put32(e, 8, PART_START_LBA)
	put32(e, 12, total_sectors)
	mbr[510] = 0x55
	mbr[511] = 0xAA
	return
}

// VBR: jump + FAT32 BPB; boot code loads IO.SYS when its LBA is known,
// otherwise an int 18h stub remains
make_vbr :: proc(g: ^Geometry, total: u32, io_sys_lba: u64 = 0, io_sys_cluster: u32 = 0) -> (vbr: [512]u8) {
	if io_sys_lba != 0 {
		copy(vbr[:], VBR_BIN)
		put32(vbr[:], VBR_LBA_OFFSET, u32(io_sys_lba))
		put32(vbr[:], VBR_LBA_OFFSET + 4, u32(io_sys_lba >> 32))
		// MS-DOS 7 MSLOAD handoff inputs (see assets/vbr/vbr.asm)
		put32(vbr[:], VBR_DATA_LBA_OFFSET, PART_START_LBA + g.data_start)
		put32(vbr[:], VBR_CLUSTER_OFFSET, io_sys_cluster)
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
	put16(vbr[:], 24, SECTORS_PER_TRACK)
	put16(vbr[:], 26, DISK_HEADS)
	put32(vbr[:], 28, PART_START_LBA) // hidden
	put32(vbr[:], 32, total)
	put32(vbr[:], 36, g.sectors_per_fat)
	put32(vbr[:], 44, 2) // root cluster
	put16(vbr[:], 48, 1) // fsinfo sector
	put16(vbr[:], 50, 6) // boot backup
	vbr[64] = 0x80 // drive
	vbr[66] = 0x29 // ext signature
	put32(vbr[:], 67, 0x19980625) // serial
	copy(vbr[71:82], "RETVRN99   ")
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
