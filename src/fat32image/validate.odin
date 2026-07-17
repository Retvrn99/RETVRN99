// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "base:runtime"
import "core:os"
import "core:slice"
import "core:strings"

@(private = "file")
is_power_of_two_u8 :: proc(value: u8) -> bool {
	return value != 0 && value & (value - 1) == 0
}

@(private = "package")
fsinfo_next_free_valid :: proc(next_free: u32, geometry: ^Geometry) -> bool {
	if geometry == nil {return false}
	// Windows 98 ScanDisk uses zero as an unknown next-free hint.
	return(
		next_free == 0 ||
		next_free == 0xFFFF_FFFF ||
		next_free >= 2 && next_free < geometry.cluster_count + 2 \
	)
}

@(private = "package")
validate_fsinfo_sector :: proc(sector: []u8, geometry: ^Geometry) -> bool {
	if len(sector) != SECTOR_BYTES || geometry == nil {return false}
	free_count := get_u32le(sector, 488)
	next_free := get_u32le(sector, 492)
	return(
		get_u32le(sector, 0) == 0x41615252 &&
		get_u32le(sector, 484) == 0x61417272 &&
		sector[510] == 0x55 &&
		sector[511] == 0xAA &&
		(free_count == 0xFFFF_FFFF || free_count <= geometry.cluster_count) &&
		fsinfo_next_free_valid(next_free, geometry) \
	)
}

@(private = "package")
read_fsinfo_pair :: proc(file: ^os.File, geometry: ^Geometry, primary, backup: []u8) -> bool {
	if len(primary) != SECTOR_BYTES || len(backup) != SECTOR_BYTES {return false}
	primary_lba := u64(geometry.partition_lba) + u64(geometry.fsinfo_sector)
	backup_lba :=
		u64(geometry.partition_lba) + u64(geometry.backup_vbr_sector) + u64(geometry.fsinfo_sector)
	primary_offset, primary_ok := sector_offset(primary_lba)
	backup_offset, backup_ok := sector_offset(backup_lba)
	return(
		primary_ok &&
		backup_ok &&
		read_exact_at(file, primary[:], primary_offset) &&
		read_exact_at(file, backup[:], backup_offset) \
	)
}

@(private = "file")
validate_fsinfo :: proc(file: ^os.File, geometry: ^Geometry, require_mirror: bool = true) -> bool {
	primary, backup: [SECTOR_BYTES]u8
	return(
		read_fsinfo_pair(file, geometry, primary[:], backup[:]) &&
		validate_fsinfo_sector(primary[:], geometry) &&
		validate_fsinfo_sector(backup[:], geometry) &&
		(!require_mirror || slice.equal(primary[:], backup[:])) \
	)
}

prepare_fsinfo_mirror :: proc(
	image: ^Image,
) -> (
	primary_lba, backup_lba: u64,
	primary, backup: [SECTOR_BYTES]u8,
	changed: bool,
	err: Image_Error,
) {
	if image == nil || image.closed || image.file == nil {
		err = error_make(.Closed, false, "hard-drive image is closed")
		return
	}
	if !read_fsinfo_pair(image.file, &image.geometry, primary[:], backup[:]) ||
	   !validate_fsinfo_sector(primary[:], &image.geometry) ||
	   !validate_fsinfo_sector(backup[:], &image.geometry) {
		err = error_make(.Invalid_FAT32, false, "FAT32 FSInfo recovery sectors are invalid")
		return
	}
	changed = !slice.equal(primary[:], backup[:])
	if !changed {return}
	put_u32le(primary[:], 488, 0xFFFF_FFFF)
	put_u32le(primary[:], 492, 0xFFFF_FFFF)
	copy(backup[:], primary[:])
	primary_lba = u64(image.geometry.partition_lba) + u64(image.geometry.fsinfo_sector)
	backup_lba =
		u64(image.geometry.partition_lba) +
		u64(image.geometry.backup_vbr_sector) +
		u64(image.geometry.fsinfo_sector)
	return
}

recover_fsinfo_mirror :: proc(image: ^Image) -> Image_Error {
	primary_lba, backup_lba, primary, backup, changed, prepare_error := prepare_fsinfo_mirror(
		image,
	)
	if prepare_error.code != .None {return prepare_error}
	if !changed {return {}}
	if write_error := block_write(image, primary_lba, primary[:]); write_error.code != .None {
		return write_error
	}
	if write_error := block_write(image, backup_lba, backup[:]); write_error.code != .None {
		return write_error
	}
	return sync(image)
}

@(private = "file")
validate_backup_vbr :: proc(
	file: ^os.File,
	geometry: ^Geometry,
	primary: []u8,
	require_full_parity: bool = false,
) -> bool {
	sector: [SECTOR_BYTES]u8
	lba := u64(geometry.partition_lba) + u64(geometry.backup_vbr_sector)
	offset, ok := sector_offset(lba)
	if !ok ||
	   !read_exact_at(file, sector[:], offset) ||
	   sector[510] != 0x55 ||
	   sector[511] != 0xAA {
		return false
	}
	if require_full_parity {return slice.equal(primary, sector[:])}
	return slice.equal(primary[11:90], sector[11:90])
}

@(private = "file")
validate_fat_headers :: proc(file: ^os.File, geometry: ^Geometry, root_cluster: u32) -> bool {
	FAT_SCAN_BUFFER_BYTES :: MAX_BLOCK_BYTES / 2
	FAT_SCAN_BUFFER_SECTORS :: FAT_SCAN_BUFFER_BYTES / SECTOR_BYTES
	first, second: [FAT_SCAN_BUFFER_BYTES]u8
	first_lba := u64(geometry.partition_lba) + u64(geometry.reserved_sectors)
	second_lba := first_lba + u64(geometry.sectors_per_fat)
	sector_index: u64
	for sector_index < u64(geometry.sectors_per_fat) {
		sector_count := min(
			u64(FAT_SCAN_BUFFER_SECTORS),
			u64(geometry.sectors_per_fat) - sector_index,
		)
		byte_count := int(sector_count * SECTOR_BYTES)
		first_offset, first_ok := sector_offset(first_lba + sector_index)
		second_offset, second_ok := sector_offset(second_lba + sector_index)
		if !first_ok ||
		   !second_ok ||
		   !read_exact_at(file, first[:byte_count], first_offset) ||
		   !read_exact_at(file, second[:byte_count], second_offset) ||
		   !slice.equal(first[:byte_count], second[:byte_count]) {
			return false
		}
		sector_index += sector_count
	}
	header: [SECTOR_BYTES]u8
	header_offset, header_ok := sector_offset(first_lba)
	if !header_ok || !read_exact_at(file, header[:], header_offset) {return false}
	entry0 := get_u32le(header[:], 0) & 0x0FFF_FFFF
	entry1 := get_u32le(header[:], 4) & 0x0FFF_FFFF
	if entry0 & 0x0FFF_FFF8 != 0x0FFF_FFF8 || entry1 & 0x03FF_FFFF != 0x03FF_FFFF {
		return false
	}
	entry_byte := u64(root_cluster) * 4
	entry_sector := entry_byte / SECTOR_BYTES
	entry_offset := int(entry_byte % SECTOR_BYTES)
	if entry_sector >= u64(geometry.sectors_per_fat) {return false}
	root_sector: [SECTOR_BYTES]u8
	root_offset, root_ok := sector_offset(first_lba + entry_sector)
	if !root_ok || !read_exact_at(file, root_sector[:], root_offset) {return false}
	root_entry := get_u32le(root_sector[:], entry_offset) & 0x0FFF_FFFF
	return(
		root_entry >= 2 &&
		root_entry != 0x0FFF_FFF7 &&
		(root_entry < geometry.cluster_count + 2 || root_entry >= 0x0FFF_FFF8) \
	)
}

@(private = "package")
validate_file :: proc(
	file: ^os.File,
	path: string,
	allocator: runtime.Allocator,
	recovery_grade: bool = false,
) -> (
	Image_Info,
	Geometry,
	Image_Error,
) {
	if file ==
	   nil {return {}, {}, error_make(.Open_Failed, false, "hard-drive image is unavailable")}
	size, size_error := os.file_size(file)
	if size_error != nil || size <= 0 || size % SECTOR_BYTES != 0 {
		return {}, {}, error_make(.Invalid_Size, false, "hard-drive image size is not a positive multiple of 512 bytes")
	}
	sector_count := u64(size / SECTOR_BYTES)
	if sector_count > LBA28_SECTOR_LIMIT {
		return {}, {}, error_make(.Invalid_Size, false, "hard-drive image exceeds the LBA28 capacity")
	}
	mbr: [SECTOR_BYTES]u8
	if !read_exact_at(file, mbr[:], 0) || mbr[510] != 0x55 || mbr[511] != 0xAA {
		return {}, {}, error_make(.Invalid_MBR, false, "hard-drive image has no valid MBR")
	}
	partition_lba, partition_sectors: u32
	found := false
	for index in 0 ..< 4 {
		entry := mbr[446 + index * 16:462 + index * 16]
		partition_type := entry[4]
		if partition_type != 0x0B && partition_type != 0x0C {continue}
		if found {
			return {}, {}, error_make(.Partition_Unsupported, false, "hard-drive image has more than one FAT32 partition")
		}
		partition_lba = get_u32le(entry, 8)
		partition_sectors = get_u32le(entry, 12)
		found = true
	}
	partition_end := u64(partition_lba) + u64(partition_sectors)
	if !found ||
	   partition_lba == 0 ||
	   partition_sectors == 0 ||
	   partition_end < u64(partition_lba) ||
	   partition_end > sector_count {
		return {}, {}, error_make(.Partition_Unsupported, false, "hard-drive image has no compatible MBR FAT32 partition")
	}
	vbr: [SECTOR_BYTES]u8
	vbr_offset, offset_ok := sector_offset(u64(partition_lba))
	if !offset_ok ||
	   !read_exact_at(file, vbr[:], vbr_offset) ||
	   vbr[510] != 0x55 ||
	   vbr[511] != 0xAA {
		return {}, {}, error_make(.Invalid_VBR, false, "FAT32 partition has no valid boot sector")
	}
	bytes_per_sector := get_u16le(vbr[:], 11)
	spc := vbr[13]
	reserved := get_u16le(vbr[:], 14)
	fat_count := vbr[16]
	root_entries := get_u16le(vbr[:], 17)
	total16 := get_u16le(vbr[:], 19)
	fat16 := get_u16le(vbr[:], 22)
	hidden := get_u32le(vbr[:], 28)
	total32 := get_u32le(vbr[:], 32)
	spf := get_u32le(vbr[:], 36)
	extended_flags := get_u16le(vbr[:], 40)
	fs_version := get_u16le(vbr[:], 42)
	root_cluster := get_u32le(vbr[:], 44)
	fsinfo := get_u16le(vbr[:], 48)
	backup := get_u16le(vbr[:], 50)
	if bytes_per_sector != SECTOR_BYTES ||
	   !is_power_of_two_u8(spc) ||
	   spc > 64 ||
	   reserved < 8 ||
	   fat_count != 2 ||
	   root_entries != 0 ||
	   total16 != 0 ||
	   fat16 != 0 ||
	   hidden != partition_lba ||
	   total32 != partition_sectors ||
	   spf == 0 ||
	   extended_flags & 0x80 != 0 ||
	   fs_version != 0 ||
	   root_cluster < 2 ||
	   fsinfo == 0 ||
	   fsinfo >= reserved ||
	   backup == 0 ||
	   u32(backup) + u32(fsinfo) >= u32(reserved) {
		return {}, {}, error_make(.Invalid_FAT32, false, "FAT32 boot parameters are incompatible with RETVRN99")
	}
	fat_sectors := u64(fat_count) * u64(spf)
	if u64(reserved) + fat_sectors >= u64(total32) {
		return {}, {}, error_make(.Invalid_FAT32, false, "FAT32 data area is missing")
	}
	data_start := u32(u64(reserved) + fat_sectors)
	cluster_count := (total32 - data_start) / u32(spc)
	if cluster_count < 65_525 ||
	   cluster_count > 0x0FFF_FFF5 ||
	   u64(spf) * SECTOR_BYTES / 4 < u64(cluster_count) + 2 ||
	   root_cluster >= cluster_count + 2 {
		return {}, {}, error_make(.Invalid_FAT32, false, "FAT32 cluster geometry is invalid")
	}
	geometry := Geometry {
		disk_sectors        = sector_count,
		partition_lba       = partition_lba,
		partition_sectors   = partition_sectors,
		sectors_per_cluster = spc,
		reserved_sectors    = reserved,
		fat_count           = fat_count,
		sectors_per_fat     = spf,
		data_start          = data_start,
		cluster_count       = cluster_count,
		fsinfo_sector       = fsinfo,
		backup_vbr_sector   = backup,
	}
	image_id, marker_sector, enrolled, dirty, retvrn99_format, marker_error := discover_marker(
		file,
		&geometry,
	)
	if marker_error.code != .None {return {}, {}, marker_error}
	if recovery_grade && (!enrolled || !dirty) {
		return {}, {}, error_make(.Invalid_FAT32, false, "recovery-grade validation requires an enrolled dirty image")
	}
	if !recovery_grade &&
	   (!validate_fsinfo(file, &geometry, false) ||
			   !validate_backup_vbr(file, &geometry, vbr[:], retvrn99_format)) {
		return {}, {}, error_make(.Invalid_FAT32, false, "FAT32 recovery sectors are invalid")
	}
	if !dirty && !validate_fat_headers(file, &geometry, root_cluster) {
		return {}, {}, error_make(.Invalid_FAT32, false, "FAT32 mirrors or root allocation are invalid")
	}
	if retvrn99_format {
		serial :=
			u32(image_id[0]) |
			u32(image_id[1]) << 8 |
			u32(image_id[2]) << 16 |
			u32(image_id[3]) << 24
		if get_u32le(vbr[:], 67) != serial ||
		   string(vbr[3:11]) != "MSWIN4.1" ||
		   string(vbr[71:82]) != "RETVRN99   " ||
		   !boot_sector_valid_for_geometry(vbr[:], &geometry) {
			return {}, {}, error_make(.Marker_Invalid, false, "RETVRN99 image identity does not match its FAT32 boot sector")
		}
	}
	geometry.marker_sector = marker_sector
	return Image_Info {
		path = strings.clone(path, allocator),
		image_id = image_id,
		sector_count = sector_count,
		partition_lba = partition_lba,
		partition_sectors = partition_sectors,
		sectors_per_cluster = spc,
		reserved_sectors = reserved,
		marker_sector = marker_sector,
		sparse = platform_image_is_sparse(file),
		enrolled = enrolled,
		retvrn99_format = retvrn99_format,
		dirty = dirty,
	}, geometry, {}
}

check_filesystem :: proc(image: ^Image, allow_external_boot_layout: bool = false) -> Image_Error {
	if image == nil || image.closed || image.file == nil {
		return error_make(.Closed, false, "hard-drive image is closed")
	}
	vbr: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(u64(image.info.partition_lba))
	if !offset_ok || !read_exact_at(image.file, vbr[:], offset) {
		return error_make(.IO, false, "cannot inspect the FAT32 filesystem")
	}
	root_cluster := get_u32le(vbr[:], 44)
	require_retvrn_boot :=
		image.info.retvrn99_format &&
		(!allow_external_boot_layout || string(vbr[71:82]) == "RETVRN99   ")
	if !validate_fsinfo(image.file, &image.geometry, true) ||
	   !validate_backup_vbr(image.file, &image.geometry, vbr[:], require_retvrn_boot) ||
	   require_retvrn_boot && !boot_sector_valid_for_geometry(vbr[:], &image.geometry) ||
	   !validate_fat_headers(image.file, &image.geometry, root_cluster) {
		return error_make(
			.Invalid_FAT32,
			false,
			"FAT32 mirrors, root allocation, or recovery sectors are invalid",
		)
	}
	return {}
}

materialize_filesystem :: proc(
	image: ^Image,
	allow_external_boot_layout: bool = false,
) -> Image_Error {
	if image == nil || image.closed || image.file == nil {
		return error_make(.Closed, false, "hard-drive image is closed")
	}
	vbr: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(u64(image.info.partition_lba))
	if !offset_ok || !read_exact_at(image.file, vbr[:], offset) {
		return error_make(.IO, false, "cannot inspect the FAT32 filesystem")
	}
	root_cluster := get_u32le(vbr[:], 44)
	require_retvrn_boot :=
		image.info.retvrn99_format &&
		(!allow_external_boot_layout || string(vbr[71:82]) == "RETVRN99   ")
	if !validate_backup_vbr(image.file, &image.geometry, vbr[:], require_retvrn_boot) ||
	   require_retvrn_boot && !boot_sector_valid_for_geometry(vbr[:], &image.geometry) ||
	   !validate_fat_headers(image.file, &image.geometry, root_cluster) {
		return error_make(.Invalid_FAT32, false, "FAT32 mirrors or root allocation are invalid")
	}
	fsinfo_error := recover_fsinfo_mirror(image)
	if fsinfo_error.code != .None {return fsinfo_error}
	return check_filesystem(image, allow_external_boot_layout)
}

check_filesystem_compatible :: proc(
	image: ^Image,
	allow_external_boot_layout: bool = false,
) -> Image_Error {
	if image == nil || image.closed || image.file == nil {
		return error_make(.Closed, false, "hard-drive image is closed")
	}
	vbr: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(u64(image.info.partition_lba))
	if !offset_ok || !read_exact_at(image.file, vbr[:], offset) {
		return error_make(.IO, false, "cannot inspect the FAT32 filesystem")
	}
	root_cluster := get_u32le(vbr[:], 44)
	require_retvrn_boot :=
		image.info.retvrn99_format &&
		(!allow_external_boot_layout || string(vbr[71:82]) == "RETVRN99   ")
	if !validate_fsinfo(image.file, &image.geometry, false) ||
	   !validate_backup_vbr(image.file, &image.geometry, vbr[:], require_retvrn_boot) ||
	   require_retvrn_boot && !boot_sector_valid_for_geometry(vbr[:], &image.geometry) ||
	   !validate_fat_headers(image.file, &image.geometry, root_cluster) {
		return error_make(
			.Invalid_FAT32,
			false,
			"FAT32 mirrors, root allocation, or recovery sectors are invalid",
		)
	}
	return {}
}

complete_recovery :: proc(image: ^Image, allow_external_boot_layout: bool = false) -> Image_Error {
	err := materialize_filesystem(image, allow_external_boot_layout)
	if err.code == .None {image.recovery_grade = false}
	return err
}

complete_edit_recovery :: proc(
	image: ^Image,
	allow_external_boot_layout: bool = false,
) -> Image_Error {
	err := check_filesystem_compatible(image, allow_external_boot_layout)
	if err.code == .None {image.recovery_grade = false}
	return err
}

validate :: proc(path: string, allocator := context.allocator) -> (Image_Info, Image_Error) {
	if len(path) ==
	   0 {return {}, error_make(.Invalid_Argument, false, "hard-drive image path is empty")}
	path_info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
	if stat_error == .Not_Exist {
		return {}, error_make(.Not_Found, false, "hard-drive image does not exist")
	}
	if stat_error != nil ||
	   path_info.type != .Regular ||
	   !platform_image_path_is_safe_regular(path) {
		if stat_error == nil {os.file_info_delete(path_info, context.temp_allocator)}
		return {}, error_make(.Path_Unsupported, false, "hard-drive image must be a regular file, not a link or special file")
	}
	os.file_info_delete(path_info, context.temp_allocator)
	file, open_error := os.open(path, {.Read})
	if open_error !=
	   nil {return {}, error_make(.Open_Failed, false, "cannot open the hard-drive image")}
	defer os.close(file)
	if !platform_image_lock(file) {
		return {}, error_make(.Locked, true, "hard-drive image is owned by another session")
	}
	defer platform_image_unlock(file)
	info, _, validation_error := validate_file(file, path, allocator)
	return info, validation_error
}

validate_recovery :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	Image_Info,
	Image_Error,
) {
	if len(path) == 0 {
		return {}, error_make(.Invalid_Argument, false, "hard-drive image path is empty")
	}
	path_info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
	if stat_error == .Not_Exist {
		return {}, error_make(.Not_Found, false, "hard-drive image does not exist")
	}
	if stat_error != nil ||
	   path_info.type != .Regular ||
	   !platform_image_path_is_safe_regular(path) {
		if stat_error == nil {os.file_info_delete(path_info, context.temp_allocator)}
		return {}, error_make(.Path_Unsupported, false, "hard-drive image must be a regular file, not a link or special file")
	}
	os.file_info_delete(path_info, context.temp_allocator)
	file, open_error := os.open(path, {.Read})
	if open_error != nil {
		return {}, error_make(.Open_Failed, false, "cannot open the hard-drive image")
	}
	defer os.close(file)
	if !platform_image_lock(file) {
		return {}, error_make(.Locked, true, "hard-drive image is owned by another session")
	}
	defer platform_image_unlock(file)
	info, _, validation_error := validate_file(file, path, allocator, true)
	return info, validation_error
}
