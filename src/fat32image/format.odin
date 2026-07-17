// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

@(private = "file")
write_sector :: proc(file: ^os.File, lba: u64, data: []u8) -> bool {
	if len(data) != SECTOR_BYTES {return false}
	offset, ok := sector_offset(lba)
	return ok && write_exact_at(file, data, offset)
}

@(private = "file")
format_file :: proc(file: ^os.File, geometry: ^Geometry, image_id: Image_Id) -> Image_Error {
	mbr := make_mbr(geometry)
	vbr := make_vbr(geometry, image_id)
	fsinfo := make_fsinfo(geometry)
	fat := make_initial_fat_sector()
	marker_info := Image_Info {
		image_id            = image_id,
		sector_count        = geometry.disk_sectors,
		partition_lba       = geometry.partition_lba,
		partition_sectors   = geometry.partition_sectors,
		sectors_per_cluster = geometry.sectors_per_cluster,
		reserved_sectors    = geometry.reserved_sectors,
		marker_sector       = geometry.marker_sector,
		enrolled            = true,
		retvrn99_format     = true,
	}
	marker := marker_encode(&marker_info, false)
	first_fat := u64(geometry.partition_lba) + u64(geometry.reserved_sectors)
	second_fat := first_fat + u64(geometry.sectors_per_fat)
	if !write_sector(file, 0, mbr[:]) ||
	   !write_sector(file, u64(geometry.partition_lba), vbr[:]) ||
	   !write_sector(file, u64(geometry.partition_lba) + u64(geometry.fsinfo_sector), fsinfo[:]) ||
	   !write_sector(
			   file,
			   u64(geometry.partition_lba) + u64(geometry.backup_vbr_sector),
			   vbr[:],
		   ) ||
	   !write_sector(
			   file,
			   u64(geometry.partition_lba) +
			   u64(geometry.backup_vbr_sector) +
			   u64(geometry.fsinfo_sector),
			   fsinfo[:],
		   ) ||
	   !write_sector(file, u64(geometry.marker_sector), marker[:]) ||
	   !write_sector(file, first_fat, fat[:]) ||
	   !write_sector(file, second_fat, fat[:]) {
		return error_make(.IO, false, "cannot write the initial FAT32 layout")
	}
	return {}
}

create :: proc(
	request: Create_Request,
	allocator := context.allocator,
) -> (
	Image_Info,
	Image_Error,
) {
	if len(request.path) ==
	   0 {return {}, error_make(.Invalid_Argument, false, "hard-drive image path is empty")}
	geometry, geometry_error := geometry_for_capacity(request.capacity_gib)
	if geometry_error.code != .None {return {}, geometry_error}
	if existing, stat_error := os.stat_do_not_follow_links(request.path, context.temp_allocator);
	   stat_error == nil {
		os.file_info_delete(existing, context.temp_allocator)
		return {}, error_make(.Already_Exists, false, "hard-drive image already exists")
	} else if stat_error != .Not_Exist {
		return {}, error_make(.Path_Unsupported, false, "hard-drive image path cannot be inspected")
	}
	parent := filepath.dir(request.path)
	parent_info, parent_error := os.stat_do_not_follow_links(parent, context.temp_allocator)
	if parent_error != nil || parent_info.type != .Directory {
		if parent_error == nil {os.file_info_delete(parent_info, context.temp_allocator)}
		return {}, error_make(.Path_Unsupported, false, "hard-drive image directory does not exist")
	}
	os.file_info_delete(parent_info, context.temp_allocator)
	pattern := fmt.tprintf(".%s.tmp-*", filepath.base(request.path))
	file, create_error := os.create_temp_file(parent, pattern)
	if create_error !=
	   nil {return {}, error_make(.Open_Failed, false, "cannot create a temporary hard-drive image")}
	temporary := strings.clone(os.name(file), context.allocator)
	published := false
	defer {
		if file != nil {_ = os.close(file)}
		if !published {_ = os.remove(temporary)}
		delete(temporary)
	}
	sparse := platform_prepare_sparse(file)
	if !sparse && !request.allow_full_allocation {
		return {}, error_make(.Sparse_Unsupported, false, "this location cannot create sparse files without full-allocation confirmation")
	}
	logical_bytes := geometry.disk_sectors * SECTOR_BYTES
	if logical_bytes > u64(max(i64)) || os.truncate(file, i64(logical_bytes)) != nil {
		return {}, error_make(.Resize_Failed, false, "cannot set the hard-drive image capacity")
	}
	image_id := new_image_id()
	format_error := format_file(file, &geometry, image_id)
	if format_error.code != .None {return {}, format_error}
	if os.sync(file) !=
	   nil {return {}, error_make(.Sync_Failed, false, "cannot durably synchronize the new hard-drive image")}
	if os.close(file) != nil {
		file = nil
		return {}, error_make(.Sync_Failed, false, "cannot close the new hard-drive image")
	}
	file = nil
	if !platform_publish_no_replace(temporary, request.path) {
		if os.exists(
			request.path,
		) {return {}, error_make(.Already_Exists, false, "hard-drive image already exists")}
		return {}, error_make(.Publish_Failed, false, "cannot atomically publish the new hard-drive image")
	}
	_ = os.remove(temporary)
	published = true
	if !platform_sync_published_parent(request.path) {
		return {}, error_make(.Sync_Failed, false, "new hard-drive image was published but its directory could not be durably synchronized")
	}
	info, validation_error := validate(request.path, allocator)
	if validation_error.code != .None {return {}, validation_error}
	return info, {}
}
