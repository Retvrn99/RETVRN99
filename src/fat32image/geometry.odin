// SPDX-License-Identifier: GPL-3.0-only
package fat32image

PARTITION_LBA :: u32(63)
BIOS_LOGICAL_HEADS :: u32(128)
SECTORS_PER_TRACK :: u32(63)
RESERVED_SECTORS :: u16(32)
FAT_COUNT :: u8(2)
ROOT_CLUSTER :: u32(2)
FSINFO_SECTOR :: u16(1)
BACKUP_VBR_SECTOR :: u16(6)
MARKER_RELATIVE_SECTOR :: u16(31)

Geometry :: struct {
	disk_sectors:        u64,
	partition_lba:       u32,
	partition_sectors:   u32,
	sectors_per_cluster: u8,
	reserved_sectors:    u16,
	fat_count:           u8,
	sectors_per_fat:     u32,
	data_start:          u32,
	cluster_count:       u32,
	fsinfo_sector:       u16,
	backup_vbr_sector:   u16,
	marker_sector:       u32,
}

@(private = "package")
sectors_per_cluster_for_capacity :: proc(capacity_gib: u32) -> u8 {
	switch {
	case capacity_gib < 8:
		return 8
	case capacity_gib < 16:
		return 16
	case capacity_gib < 32:
		return 32
	case:
		return 64
	}
}

@(private = "package")
geometry_for_capacity :: proc(capacity_gib: u32) -> (Geometry, Image_Error) {
	if capacity_gib < MIN_CAPACITY_GIB || capacity_gib > MAX_CAPACITY_GIB {
		return {}, error_make(.Capacity_Out_Of_Range, false, "hard-drive capacity must be between 1 and 127 GiB")
	}
	disk_sectors := u64(capacity_gib) * (u64(1) << 30) / SECTOR_BYTES
	if disk_sectors <= u64(PARTITION_LBA) || disk_sectors > LBA28_SECTOR_LIMIT {
		return {}, error_make(.Capacity_Out_Of_Range, false, "hard-drive capacity is outside the LBA28 range")
	}
	partition_sectors := u32(disk_sectors - u64(PARTITION_LBA))
	spc := sectors_per_cluster_for_capacity(capacity_gib)
	spf: u32
	for {
		if partition_sectors <= u32(RESERVED_SECTORS) + u32(FAT_COUNT) * spf {
			return {}, error_make(.Invalid_FAT32, false, "hard-drive capacity cannot hold the FAT32 layout")
		}
		data_sectors := partition_sectors - u32(RESERVED_SECTORS) - u32(FAT_COUNT) * spf
		clusters := data_sectors / u32(spc)
		needed := u32((u64(clusters + 2) * 4 + SECTOR_BYTES - 1) / SECTOR_BYTES)
		if needed <= spf {break}
		spf = needed
	}
	data_start := u32(RESERVED_SECTORS) + u32(FAT_COUNT) * spf
	cluster_count := (partition_sectors - data_start) / u32(spc)
	if cluster_count < 65_525 || cluster_count > 0x0FFF_FFF5 {
		return {}, error_make(.Invalid_FAT32, false, "hard-drive geometry is outside the FAT32 cluster range")
	}
	return Geometry {
		disk_sectors = disk_sectors,
		partition_lba = PARTITION_LBA,
		partition_sectors = partition_sectors,
		sectors_per_cluster = spc,
		reserved_sectors = RESERVED_SECTORS,
		fat_count = FAT_COUNT,
		sectors_per_fat = spf,
		data_start = data_start,
		cluster_count = cluster_count,
		fsinfo_sector = FSINFO_SECTOR,
		backup_vbr_sector = BACKUP_VBR_SECTOR,
		marker_sector = PARTITION_LBA + u32(MARKER_RELATIVE_SECTOR),
	}, {}
}

@(private = "file")
bios_cylinder_count :: proc(disk_sectors: u64) -> u64 {
	return clamp(disk_sectors / u64(BIOS_LOGICAL_HEADS * SECTORS_PER_TRACK), u64(1), u64(1024))
}

@(private = "file")
put_chs :: proc(data: []u8, offset: int, lba, cylinder_count: u64) {
	max_lba := cylinder_count * u64(BIOS_LOGICAL_HEADS) * u64(SECTORS_PER_TRACK) - 1
	address := min(lba, max_lba)
	cylinder := address / u64(BIOS_LOGICAL_HEADS * SECTORS_PER_TRACK)
	remainder := address % u64(BIOS_LOGICAL_HEADS * SECTORS_PER_TRACK)
	head := remainder / u64(SECTORS_PER_TRACK)
	sector := remainder % u64(SECTORS_PER_TRACK) + 1
	data[offset] = u8(head)
	data[offset + 1] = u8(sector) | u8(cylinder >> 2) & 0xC0
	data[offset + 2] = u8(cylinder)
}

MBR_BIN :: #load("../../assets/vbr/mbr.bin")
VBR_BIN :: #load("../../assets/vbr/vbr.bin")

@(private = "package")
make_mbr :: proc(geometry: ^Geometry) -> (mbr: [SECTOR_BYTES]u8) {
	copy(mbr[:446], MBR_BIN)
	entry := mbr[446:462]
	entry[0] = 0x80
	cylinders := bios_cylinder_count(geometry.disk_sectors)
	put_chs(entry, 1, u64(geometry.partition_lba), cylinders)
	entry[4] = 0x0C
	put_chs(entry, 5, u64(geometry.partition_lba) + u64(geometry.partition_sectors) - 1, cylinders)
	put_u32le(entry, 8, geometry.partition_lba)
	put_u32le(entry, 12, geometry.partition_sectors)
	mbr[510] = 0x55
	mbr[511] = 0xAA
	return
}

@(private = "package")
make_vbr :: proc(geometry: ^Geometry, image_id: Image_Id) -> (vbr: [SECTOR_BYTES]u8) {
	vbr[0] = 0xEB
	vbr[1] = 0x58
	vbr[2] = 0x90
	copy(vbr[3:11], "MSWIN4.1")
	put_u16le(vbr[:], 11, SECTOR_BYTES)
	vbr[13] = geometry.sectors_per_cluster
	put_u16le(vbr[:], 14, geometry.reserved_sectors)
	vbr[16] = geometry.fat_count
	vbr[21] = 0xF8
	put_u16le(vbr[:], 24, u16(SECTORS_PER_TRACK))
	put_u16le(vbr[:], 26, u16(BIOS_LOGICAL_HEADS))
	put_u32le(vbr[:], 28, geometry.partition_lba)
	put_u32le(vbr[:], 32, geometry.partition_sectors)
	put_u32le(vbr[:], 36, geometry.sectors_per_fat)
	put_u32le(vbr[:], 44, ROOT_CLUSTER)
	put_u16le(vbr[:], 48, FSINFO_SECTOR)
	put_u16le(vbr[:], 50, BACKUP_VBR_SECTOR)
	vbr[64] = 0x80
	vbr[66] = 0x29
	serial :=
		u32(image_id[0]) | u32(image_id[1]) << 8 | u32(image_id[2]) << 16 | u32(image_id[3]) << 24
	put_u32le(vbr[:], 67, serial)
	copy(vbr[71:82], "RETVRN99   ")
	copy(vbr[82:90], "FAT32   ")
	vbr[90] = 0xCD
	vbr[91] = 0x18
	vbr[510] = 0x55
	vbr[511] = 0xAA
	return
}

@(private = "package")
make_fsinfo :: proc(geometry: ^Geometry) -> (fsinfo: [SECTOR_BYTES]u8) {
	put_u32le(fsinfo[:], 0, 0x41615252)
	put_u32le(fsinfo[:], 484, 0x61417272)
	put_u32le(fsinfo[:], 488, geometry.cluster_count - 1)
	put_u32le(fsinfo[:], 492, 3)
	fsinfo[510] = 0x55
	fsinfo[511] = 0xAA
	return
}

@(private = "package")
make_initial_fat_sector :: proc() -> (fat: [SECTOR_BYTES]u8) {
	put_u32le(fat[:], 0, 0x0FFF_FFF8)
	put_u32le(fat[:], 4, 0x0FFF_FFFF)
	put_u32le(fat[:], 8, 0x0FFF_FFFF)
	return
}
