// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:slice"

Adoption_Boot_Pair :: struct {
	primary_lba:      u64,
	backup_lba:       u64,
	original_primary: [SECTOR_BYTES]u8,
	original_backup:  [SECTOR_BYTES]u8,
	adopted_primary:  [SECTOR_BYTES]u8,
	adopted_backup:   [SECTOR_BYTES]u8,
}

@(private = "file")
adoption_source_matches_image :: proc(image: ^Image, source: []u8) -> bool {
	if image == nil || len(source) != SECTOR_BYTES || source[510] != 0x55 || source[511] != 0xAA {
		return false
	}
	return(
		get_u16le(source, 11) == SECTOR_BYTES &&
		source[13] == image.geometry.sectors_per_cluster &&
		get_u16le(source, 14) == image.geometry.reserved_sectors &&
		source[16] == image.geometry.fat_count &&
		get_u32le(source, 28) == image.geometry.partition_lba &&
		get_u32le(source, 32) == image.geometry.partition_sectors &&
		get_u32le(source, 36) == image.geometry.sectors_per_fat &&
		get_u32le(source, 44) >= 2 &&
		get_u32le(source, 44) < image.geometry.cluster_count + 2 &&
		get_u16le(source, 48) == image.geometry.fsinfo_sector &&
		get_u16le(source, 50) == image.geometry.backup_vbr_sector \
	)
}

@(private = "file")
adoption_build_boot_sector :: proc(
	image: ^Image,
	source: []u8,
	io_sys_lba: u64,
	io_sys_cluster: u32,
) -> (
	sector: [SECTOR_BYTES]u8,
	err: Image_Error,
) {
	if image == nil || image.closed || image.file == nil {
		err = error_make(.Closed, false, "hard-drive image is closed")
		return
	}
	if image.mode != .Read_Write {
		err = error_make(.Read_Only, false, "hard-drive image is read-only")
		return
	}
	if !image.info.enrolled || !adoption_source_matches_image(image, source) {
		err = error_make(.Invalid_FAT32, false, "compatible FAT32 boot geometry is unavailable for adoption")
		return
	}
	if image.geometry.sectors_per_cluster < 4 {
		err = error_make(
			.Boot_Code_Unsupported,
			false,
			"RETVRN99 boot adoption requires FAT32 clusters of at least four sectors",
		)
		return
	}
	if io_sys_cluster == 0 {
		if io_sys_lba != 0 {
			err = error_make(.Invalid_Boot_Target, false, "an empty adoption boot target must have a zero LBA")
			return
		}
	} else {
		if io_sys_cluster < 2 || io_sys_cluster >= image.geometry.cluster_count + 2 {
			err = error_make(.Invalid_Boot_Target, false, "IO.SYS cluster is outside the FAT32 data area")
			return
		}
		expected_lba :=
			u64(image.geometry.partition_lba) +
			u64(image.geometry.data_start) +
			u64(io_sys_cluster - 2) * u64(image.geometry.sectors_per_cluster)
		partition_end := u64(image.geometry.partition_lba) + u64(image.geometry.partition_sectors)
		if io_sys_lba != expected_lba || io_sys_lba > partition_end || 4 > partition_end - io_sys_lba {
			err = error_make(.Invalid_Boot_Target, false, "IO.SYS LBA does not match its FAT32 cluster")
			return
		}
	}
	copy(sector[:], VBR_BIN)
	copy(sector[11:67], source[11:67])
	copy(sector[3:11], "MSWIN4.1")
	serial :=
		u32(image.info.image_id[0]) |
		u32(image.info.image_id[1]) << 8 |
		u32(image.info.image_id[2]) << 16 |
		u32(image.info.image_id[3]) << 24
	put_u32le(sector[:], 67, serial)
	copy(sector[71:82], "RETVRN99   ")
	copy(sector[82:90], "FAT32   ")
	put_u32le(
		sector[:],
		VBR_DATA_LBA_OFFSET,
		image.geometry.partition_lba + image.geometry.data_start,
	)
	put_u32le(sector[:], VBR_CLUSTER_OFFSET, io_sys_cluster)
	put_u64le(sector[:], VBR_IO_SYS_LBA_OFFSET, io_sys_lba)
	return
}

prepare_adoption_boot_pair :: proc(image: ^Image) -> (pair: Adoption_Boot_Pair, err: Image_Error) {
	if image == nil || image.closed || image.file == nil {
		err = error_make(.Closed, false, "hard-drive image is closed")
		return
	}
	if image.info.retvrn99_format {
		err = error_make(.Invalid_Argument, false, "hard-drive image already uses the RETVRN99 boot layout")
		return
	}
	pair.primary_lba = u64(image.geometry.partition_lba)
	pair.backup_lba = pair.primary_lba + u64(image.geometry.backup_vbr_sector)
	primary_offset, primary_ok := sector_offset(pair.primary_lba)
	backup_offset, backup_ok := sector_offset(pair.backup_lba)
	if !primary_ok ||
	   !backup_ok ||
	   !read_exact_at(image.file, pair.original_primary[:], primary_offset) ||
	   !read_exact_at(image.file, pair.original_backup[:], backup_offset) {
		err = error_make(.IO, false, "cannot preserve both compatible FAT32 boot sectors")
		return
	}
	if !slice.equal(pair.original_primary[11:90], pair.original_backup[11:90]) {
		err = error_make(.Invalid_FAT32, false, "compatible FAT32 boot-sector mirrors disagree")
		return
	}
	pair.adopted_primary, err = adoption_build_boot_sector(
		image,
		pair.original_primary[:],
		0,
		0,
	)
	if err.code != .None {return}
	copy(pair.adopted_backup[:], pair.adopted_primary[:])
	return
}

prepare_adoption_boot_loader_patch :: proc(
	image: ^Image,
	original_primary: []u8,
	io_sys_lba: u64,
	io_sys_cluster: u32,
) -> (
	primary_lba, backup_lba: u64,
	primary_patch, backup_patch: [SECTOR_BYTES]u8,
	err: Image_Error,
) {
	primary_lba = u64(image.geometry.partition_lba)
	backup_lba = primary_lba + u64(image.geometry.backup_vbr_sector)
	primary_patch, err = adoption_build_boot_sector(
		image,
		original_primary,
		io_sys_lba,
		io_sys_cluster,
	)
	if err.code != .None {return}
	copy(backup_patch[:], primary_patch[:])
	return
}

@(private = "package")
adoption_boot_sector_write_valid :: proc(image: ^Image, lba: u64, data: []u8) -> bool {
	if image == nil || !image.info.retvrn99_format || len(data) != SECTOR_BYTES {
		return false
	}
	primary_lba := u64(image.geometry.partition_lba)
	backup_lba := primary_lba + u64(image.geometry.backup_vbr_sector)
	if lba != primary_lba && lba != backup_lba {return false}
	current: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !read_exact_at(image.file, current[:], offset) ||
	   !slice.equal(data[11:67], current[11:67]) ||
	   !adoption_source_matches_image(image, data) ||
	   string(data[3:11]) != "MSWIN4.1" ||
	   string(data[71:82]) != "RETVRN99   " ||
	   string(data[82:90]) != "FAT32   " ||
	   !boot_loader_valid_for_geometry(data, &image.geometry) {
		return false
	}
	serial :=
		u32(image.info.image_id[0]) |
		u32(image.info.image_id[1]) << 8 |
		u32(image.info.image_id[2]) << 16 |
		u32(image.info.image_id[3]) << 24
	if get_u32le(data, 67) != serial {
		return false
	}
	return true
}
