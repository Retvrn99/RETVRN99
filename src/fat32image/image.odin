// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:fmt"
import "core:os"

open_staged :: proc(
	path: string,
	recovery_grade: bool = false,
	allocator := context.allocator,
) -> (
	^Image,
	Image_Error,
) {
	if len(path) ==
	   0 {return nil, error_make(.Invalid_Argument, false, "hard-drive image path is empty")}
	path_info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
	if stat_error == .Not_Exist {
		return nil, error_make(.Not_Found, false, "hard-drive image does not exist")
	}
	if stat_error != nil ||
	   path_info.type != .Regular ||
	   !platform_image_path_is_safe_regular(path) {
		if stat_error == nil {os.file_info_delete(path_info, context.temp_allocator)}
		return nil, error_make(
			.Path_Unsupported,
			false,
			"hard-drive image must be a regular file, not a link or special file",
		)
	}
	os.file_info_delete(path_info, context.temp_allocator)
	flags := os.File_Flags{.Read, .Write}
	file, open_error := os.open(path, flags)
	if open_error !=
	   nil {return nil, error_make(.Open_Failed, false, "cannot open the hard-drive image")}
	if !platform_image_lock(file) {
		_ = os.close(file)
		return nil, error_make(.Locked, true, "hard-drive image is owned by another session")
	}
	info, geometry, validation_error := validate_file(file, path, allocator, recovery_grade)
	if validation_error.code != .None {
		platform_image_unlock(file)
		_ = os.close(file)
		return nil, validation_error
	}
	image := new(Image, allocator)
	image^ = Image {
		allocator      = allocator,
		file           = file,
		info           = info,
		geometry       = geometry,
		mode           = .Read_Write,
		recovery_grade = recovery_grade,
		locked         = true,
	}
	if !image.info.enrolled {
		image.info.image_id = new_image_id()
		image.info.enrolled = true
	}
	return image, {}
}

activate :: proc(image: ^Image) -> Image_Error {
	if image == nil || image.closed || image.file == nil {
		return error_make(.Closed, false, "hard-drive image is closed")
	}
	if image.mode != .Read_Write {
		return error_make(.Read_Only, false, "hard-drive image is read-only")
	}
	if image.write_started {return {}}
	if image.info.dirty {
		image.write_started = true
		return {}
	}
	marker_error := write_marker(image.file, &image.info, true)
	if marker_error.code != .None {return marker_error}
	image.write_started = true
	if os.sync(image.file) != nil {
		return error_make(.Sync_Failed, false, "cannot durably mark the hard-drive image dirty")
	}
	return {}
}

open :: proc(
	path: string,
	mode: Open_Mode,
	allocator := context.allocator,
) -> (
	^Image,
	Image_Error,
) {
	if mode == .Read_Only {
		if len(path) == 0 {
			return nil, error_make(.Invalid_Argument, false, "hard-drive image path is empty")
		}
		path_info, stat_error := os.stat_do_not_follow_links(path, context.temp_allocator)
		if stat_error == .Not_Exist {
			return nil, error_make(.Not_Found, false, "hard-drive image does not exist")
		}
		if stat_error != nil ||
		   path_info.type != .Regular ||
		   !platform_image_path_is_safe_regular(path) {
			if stat_error == nil {os.file_info_delete(path_info, context.temp_allocator)}
			return nil, error_make(
				.Path_Unsupported,
				false,
				"hard-drive image must be a regular file, not a link or special file",
			)
		}
		os.file_info_delete(path_info, context.temp_allocator)
		file, open_error := os.open(path, {.Read})
		if open_error != nil {
			return nil, error_make(.Open_Failed, false, "cannot open the hard-drive image")
		}
		if !platform_image_lock(file) {
			_ = os.close(file)
			return nil, error_make(.Locked, true, "hard-drive image is owned by another session")
		}
		info, geometry, validation_error := validate_file(file, path, allocator)
		if validation_error.code != .None {
			platform_image_unlock(file)
			_ = os.close(file)
			return nil, validation_error
		}
		image := new(Image, allocator)
		image^ = Image {
			allocator = allocator,
			file      = file,
			info      = info,
			geometry  = geometry,
			mode      = mode,
			locked    = true,
		}
		return image, {}
	}
	image, staged_error := open_staged(path, false, allocator)
	if staged_error.code != .None {return nil, staged_error}
	activate_error := activate(image)
	if activate_error.code != .None {
		_ = close(image, .Retain)
		return nil, activate_error
	}
	fsinfo_error := recover_fsinfo_mirror(image)
	if fsinfo_error.code != .None {
		_ = close(image, .Retain)
		return nil, fsinfo_error
	}
	return image, {}
}

@(private = "file")
validate_io_range :: proc(image: ^Image, lba: u64, byte_count: int) -> (u64, Image_Error) {
	if image == nil ||
	   image.closed ||
	   image.file == nil {return 0, error_make(.Closed, false, "hard-drive image is closed")}
	if byte_count <= 0 || byte_count > MAX_BLOCK_BYTES || byte_count % SECTOR_BYTES != 0 {
		return 0, error_make(
			.Invalid_Argument,
			false,
			"block transfer must be 1 to 128 KiB and 512-byte aligned",
		)
	}
	sector_count := u64(byte_count / SECTOR_BYTES)
	if lba >= image.info.sector_count || sector_count > image.info.sector_count - lba {
		return 0, error_make(.Out_Of_Range, false, "block transfer exceeds the hard-drive image")
	}
	return sector_count, {}
}

@(private = "file")
protected_sector_matches :: proc(
	image: ^Image,
	lba: u64,
	data: []u8,
	first_compared_byte: int,
	last_compared_byte: int,
) -> bool {
	if image == nil ||
	   len(data) != SECTOR_BYTES ||
	   first_compared_byte < 0 ||
	   last_compared_byte > SECTOR_BYTES ||
	   first_compared_byte >= last_compared_byte {
		return false
	}
	current: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !read_exact_at(image.file, current[:], offset) {return false}
	for index in first_compared_byte ..< last_compared_byte {
		if current[index] != data[index] {return false}
	}
	return true
}

@(private = "file")
validate_reserved_sector :: proc(
	image: ^Image,
	lba: u64,
	data: []u8,
) -> (
	ignore: bool,
	err: Image_Error,
) {
	partition_start := u64(image.info.partition_lba)
	relative := lba - partition_start
	backup_vbr := u64(image.geometry.backup_vbr_sector)
	if relative == 0 || relative == backup_vbr {
		if data[510] == 0x55 &&
		   data[511] == 0xAA &&
		   protected_sector_matches(image, lba, data, 11, 64) {
			return true, {}
		}
		return false, error_make(
			.Protected_Write,
			false,
			fmt.tprintf("write at LBA %d would replace the protected FAT32 VBR geometry", lba),
		)
	}
	if relative == 2 || relative == backup_vbr + 2 {return true, {}}
	if is_fsinfo_write(image, lba, len(data)) {
		if validate_fsinfo_update(image, lba, data) {return false, {}}
		return false, error_make(
			.Protected_Write,
			false,
			fmt.tprintf(
				"write at LBA %d would replace the protected FAT32 FSInfo layout " +
				"(lead=%08x struct=%08x free=%d next=%d trail=%08x immutable-byte=%d)",
				lba,
				get_u32le(data, 0),
				get_u32le(data, 484),
				get_u32le(data, 488),
				get_u32le(data, 492),
				get_u32le(data, 508),
				fsinfo_first_immutable_mismatch(image, lba, data),
			),
		)
	}
	return false, error_make(
		.Protected_Write,
		false,
		fmt.tprintf("write at LBA %d targets the protected FAT32 reserved layout", lba),
	)
}

validate_write :: proc(image: ^Image, lba: u64, data: []u8) -> (ignore: bool, err: Image_Error) {
	sector_count, range_error := validate_io_range(image, lba, len(data))
	if range_error.code != .None {return false, range_error}
	if image.mode !=
	   .Read_Write {return false, error_make(.Read_Only, false, "hard-drive image is read-only")}
	if !image.write_started {
		return false, error_make(.Read_Only, false, "hard-drive image writes are not activated")
	}
	partition_start := u64(image.info.partition_lba)
	partition_end := partition_start + u64(image.info.partition_sectors)
	normal_start := partition_start + u64(image.info.reserved_sectors)
	transfer_end := lba + sector_count
	if lba == 0 && sector_count == 1 {
		if protected_sector_matches(image, lba, data, 446, SECTOR_BYTES) {return true, {}}
		return false, error_make(
			.Protected_Write,
			false,
			"write would replace the protected MBR or partition table",
		)
	}
	if lba < partition_start || transfer_end > partition_end {
		return false, error_make(
			.Protected_Write,
			false,
			fmt.tprintf(
				"write at LBA %d (%d sectors) crosses the protected partition exterior",
				lba,
				sector_count,
			),
		)
	}
	if lba < normal_start {
		all_ignored := true
		for sector_index in 0 ..< int(sector_count) {
			sector_lba := lba + u64(sector_index)
			sector_start := sector_index * SECTOR_BYTES
			sector := data[sector_start:sector_start + SECTOR_BYTES]
			if sector_lba < normal_start {
				sector_ignored, sector_error := validate_reserved_sector(image, sector_lba, sector)
				if sector_error.code != .None {return false, sector_error}
				all_ignored = all_ignored && sector_ignored
			} else {
				if !validate_fat_header_updates(image, sector_lba, sector) {
					return false, error_make(
						.Protected_Write,
						false,
						fmt.tprintf(
							"write at LBA %d would replace the protected FAT32 allocation roots",
							sector_lba,
						),
					)
				}
				all_ignored = false
			}
		}
		return all_ignored, {}
	}
	if !validate_fat_header_updates(image, lba, data) {
		return false, error_make(
			.Protected_Write,
			false,
			fmt.tprintf("write at LBA %d would replace the protected FAT32 allocation roots", lba),
		)
	}
	return false, {}
}

@(private = "file")
is_fsinfo_write :: proc(image: ^Image, lba: u64, byte_count: int) -> bool {
	if image == nil || byte_count != SECTOR_BYTES {return false}
	partition_start := u64(image.info.partition_lba)
	return(
		lba == partition_start + u64(image.geometry.fsinfo_sector) ||
		lba ==
			partition_start +
				u64(image.geometry.backup_vbr_sector) +
				u64(image.geometry.fsinfo_sector) \
	)
}

@(private = "file")
fsinfo_first_immutable_mismatch :: proc(image: ^Image, lba: u64, data: []u8) -> int {
	if !is_fsinfo_write(image, lba, len(data)) {return -1}
	current: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !read_exact_at(image.file, current[:], offset) {return -1}
	for index in 0 ..< SECTOR_BYTES {
		if index >= 488 && index < 496 {continue}
		if current[index] != data[index] {return index}
	}
	return -1
}

@(private = "file")
validate_fsinfo_update :: proc(image: ^Image, lba: u64, data: []u8) -> bool {
	if !is_fsinfo_write(image, lba, len(data)) ||
	   get_u32le(data, 0) != 0x41615252 ||
	   get_u32le(data, 484) != 0x61417272 ||
	   data[510] != 0x55 ||
	   data[511] != 0xAA {
		return false
	}
	if image.recovery_grade {
		return validate_fsinfo_sector(data, &image.geometry)
	}
	current: [SECTOR_BYTES]u8
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !read_exact_at(image.file, current[:], offset) {return false}
	for index in 0 ..< SECTOR_BYTES {
		if index >= 488 && index < 496 {continue}
		if current[index] != data[index] {return false}
	}
	free_count := get_u32le(data, 488)
	next_free := get_u32le(data, 492)
	return(
		(free_count == 0xFFFF_FFFF || free_count <= image.geometry.cluster_count) &&
		fsinfo_next_free_valid(next_free, &image.geometry) \
	)
}

@(private = "file")
fat_link_valid :: proc(image: ^Image, value: u32) -> bool {
	link := value & 0x0FFF_FFFF
	return link >= 0x0FFF_FFF8 || link >= 2 && link < image.geometry.cluster_count + 2
}

@(private = "file")
validate_fat_header_updates :: proc(image: ^Image, lba: u64, data: []u8) -> bool {
	sector_count := u64(len(data) / SECTOR_BYTES)
	transfer_end := lba + sector_count
	first_fat := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
	for fat_index in u64(0) ..< u64(image.geometry.fat_count) {
		fat_header_lba := first_fat + fat_index * u64(image.geometry.sectors_per_fat)
		if fat_header_lba < lba || fat_header_lba >= transfer_end {continue}
		offset := int(fat_header_lba - lba) * SECTOR_BYTES
		sector := data[offset:offset + SECTOR_BYTES]
		media := get_u32le(sector, 0) & 0x0FFF_FFFF
		status := get_u32le(sector, 4) & 0x0FFF_FFFF
		root := get_u32le(sector, 8)
		if media != 0x0FFF_FFF8 ||
		   status & 0x03FF_FFFF != 0x03FF_FFFF ||
		   !fat_link_valid(image, root) {
			return false
		}
	}
	return true
}

block_read :: proc(image: ^Image, lba: u64, data: []u8) -> Image_Error {
	_, range_error := validate_io_range(image, lba, len(data))
	if range_error.code != .None {return range_error}
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !read_exact_at(image.file, data, offset) {
		return error_make(.IO, false, "cannot read the hard-drive image")
	}
	return {}
}

block_write :: proc(image: ^Image, lba: u64, data: []u8) -> Image_Error {
	ignored, write_error := validate_write(image, lba, data)
	if write_error.code != .None {return write_error}
	if ignored {
		return error_make(
			.Protected_Write,
			false,
			fmt.tprintf("write at LBA %d targets protected system-disk bytes", lba),
		)
	}
	normal_start := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
	if lba >= normal_start {
		offset, offset_ok := sector_offset(lba)
		if !offset_ok || !write_exact_at(image.file, data, offset) {
			return error_make(.IO, false, "cannot write the hard-drive image")
		}
		return {}
	}
	for sector_index in 0 ..< len(data) / SECTOR_BYTES {
		sector_lba := lba + u64(sector_index)
		sector_start := sector_index * SECTOR_BYTES
		sector := data[sector_start:sector_start + SECTOR_BYTES]
		sector_ignored, sector_error := validate_write(image, sector_lba, sector)
		if sector_error.code != .None {return sector_error}
		if sector_ignored {continue}
		offset, offset_ok := sector_offset(sector_lba)
		if !offset_ok || !write_exact_at(image.file, sector, offset) {
			return error_make(.IO, false, "cannot write the hard-drive image")
		}
	}
	return {}
}

edit_block_write :: proc(image: ^Image, lba: u64, data: []u8) -> Image_Error {
	normal_start := u64(image.info.partition_lba) + u64(image.info.reserved_sectors)
	if len(data) > SECTOR_BYTES && lba < normal_start {
		for sector_index in 0 ..< len(data) / SECTOR_BYTES {
			sector_start := sector_index * SECTOR_BYTES
			sector_error := edit_block_write(
				image,
				lba + u64(sector_index),
				data[sector_start:sector_start + SECTOR_BYTES],
			)
			if sector_error.code != .None {return sector_error}
		}
		return {}
	}
	write_error := block_write(image, lba, data)
	if write_error.code != .Protected_Write {return write_error}
	if !edit_boot_sector_write_valid(image, lba, data) {
		return write_error
	}
	offset, offset_ok := sector_offset(lba)
	if !offset_ok || !write_exact_at(image.file, data, offset) {
		return error_make(.IO, false, "cannot write the staged RETVRN99 boot-loader sector")
	}
	return {}
}

sync :: proc(image: ^Image) -> Image_Error {
	if image == nil ||
	   image.closed ||
	   image.file == nil {return error_make(.Closed, false, "hard-drive image is closed")}
	if image.mode == .Read_Only {return {}}
	if os.sync(image.file) !=
	   nil {return error_make(.Sync_Failed, false, "cannot durably synchronize the hard-drive image")}
	return {}
}

backing_identity_matches :: proc(image: ^Image) -> bool {
	if image == nil || image.closed || image.file == nil {return false}
	path_info, path_error := os.stat_do_not_follow_links(image.info.path, context.temp_allocator)
	handle_info, handle_error := os.fstat(image.file, context.temp_allocator)
	expected_size, expected_size_ok := sector_offset(image.info.sector_count)
	matches :=
		path_error == nil &&
		handle_error == nil &&
		path_info.type == .Regular &&
		platform_image_path_is_safe_regular(image.info.path) &&
		os.same_file(path_info, handle_info) &&
		expected_size_ok &&
		handle_info.size == expected_size
	if path_error == nil {os.file_info_delete(path_info, context.temp_allocator)}
	if handle_error == nil {os.file_info_delete(handle_info, context.temp_allocator)}
	return matches
}

close :: proc(image: ^Image, mode: Close_Mode) -> Image_Error {
	if image == nil {return {}}
	if image.closed ||
	   image.file == nil {return error_make(.Closed, false, "hard-drive image is already closed")}
	if (mode == .Clean || mode == .Clean_Compatible) &&
	   image.mode == .Read_Write &&
	   image.write_started {
		if mode == .Clean {
			fsinfo_error := recover_fsinfo_mirror(image)
			if fsinfo_error.code != .None {return fsinfo_error}
		}
		filesystem_error := check_filesystem_compatible(image)
		if mode == .Clean {filesystem_error = check_filesystem(image)}
		if filesystem_error.code != .None {return filesystem_error}
		sync_error := sync(image)
		if sync_error.code != .None {return sync_error}
		marker_error := write_marker(image.file, &image.info, false)
		if marker_error.code != .None {return marker_error}
		if os.sync(image.file) != nil {
			return error_make(
				.Sync_Failed,
				false,
				"cannot durably mark the hard-drive image clean",
			)
		}
	}
	result: Image_Error
	if mode == .Retain && image.mode == .Read_Write && os.sync(image.file) != nil {
		result = error_make(.Sync_Failed, false, "cannot durably retain the hard-drive image")
	}
	if image.locked {
		platform_image_unlock(image.file)
		image.locked = false
	}
	if os.close(image.file) != nil && result.code == .None {
		result = error_make(.IO, false, "cannot close the hard-drive image")
	}
	image.file = nil
	image.closed = true
	allocator := image.allocator
	info_destroy(&image.info, allocator)
	free(image, allocator)
	return result
}

@(private = "package")
image_device_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	image := (^Image)(ctx)
	return block_read(image, lba, data).code == .None
}

@(private = "package")
image_device_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	image := (^Image)(ctx)
	return block_write(image, lba, data).code == .None
}

@(private = "package")
image_edit_device_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	image := (^Image)(ctx)
	return edit_block_write(image, lba, data).code == .None
}

@(private = "package")
image_device_flush :: proc(ctx: rawptr) -> bool {
	image := (^Image)(ctx)
	return sync(image).code == .None
}
