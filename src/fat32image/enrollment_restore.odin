// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"

Unenrolled_Marker_Snapshot :: struct {
	valid:               bool,
	marker_sector:       u32,
	sector_count:        u64,
	partition_lba:       u32,
	partition_sectors:   u32,
	reserved_sectors:    u16,
	sectors_per_cluster: u8,
	original:            [SECTOR_BYTES]u8,
}

capture_unenrolled_marker :: proc(info: ^Image_Info) -> (Unenrolled_Marker_Snapshot, Image_Error) {
	if info == nil || info.path == "" || info.enrolled || info.marker_sector == 0 {
		return {}, error_make(.Invalid_Argument, false, "unenrolled image marker information is unavailable")
	}
	file, open_error := os.open(info.path, {.Read})
	if open_error != nil {
		return {}, error_make(.Open_Failed, false, "cannot capture the unenrolled image marker sector")
	}
	defer os.close(file)
	offset, offset_ok := sector_offset(u64(info.marker_sector))
	snapshot := Unenrolled_Marker_Snapshot {
		marker_sector       = info.marker_sector,
		sector_count        = info.sector_count,
		partition_lba       = info.partition_lba,
		partition_sectors   = info.partition_sectors,
		reserved_sectors    = info.reserved_sectors,
		sectors_per_cluster = info.sectors_per_cluster,
	}
	if !offset_ok ||
	   !read_exact_at(file, snapshot.original[:], offset) ||
	   !sector_is_zero(snapshot.original[:]) {
		return {}, error_make(.Marker_Invalid, false, "the compatible image no longer has its captured safe marker sector")
	}
	snapshot.valid = true
	return snapshot, {}
}

restore_unenrolled_marker :: proc(
	image: ^Image,
	snapshot: ^Unenrolled_Marker_Snapshot,
	expected_image_id: Image_Id,
) -> Image_Error {
	if image == nil ||
	   image.closed ||
	   image.file == nil ||
	   image.mode != .Read_Write ||
	   snapshot == nil ||
	   !snapshot.valid ||
	   !sector_is_zero(snapshot.original[:]) ||
	   image.info.image_id != expected_image_id ||
	   image.info.retvrn99_format ||
	   image.info.marker_sector != snapshot.marker_sector ||
	   image.info.sector_count != snapshot.sector_count ||
	   image.info.partition_lba != snapshot.partition_lba ||
	   image.info.partition_sectors != snapshot.partition_sectors ||
	   image.info.reserved_sectors != snapshot.reserved_sectors ||
	   image.info.sectors_per_cluster != snapshot.sectors_per_cluster ||
	   !backing_identity_matches(image) {
		return error_make(
			.Marker_Invalid,
			false,
			"cannot restore an unenrolled marker after the image identity or layout changed",
		)
	}
	offset, offset_ok := sector_offset(u64(snapshot.marker_sector))
	current: [SECTOR_BYTES]u8
	if !offset_ok || !read_exact_at(image.file, current[:], offset) {
		return error_make(.IO, false, "cannot verify the temporary image enrollment marker")
	}
	image_id, dirty, retvrn99_format, matched, valid := marker_decode(
		current[:],
		snapshot.marker_sector,
		&image.geometry,
	)
	if !matched || !valid || !dirty || retvrn99_format || image_id != expected_image_id {
		return error_make(
			.Marker_Invalid,
			false,
			"temporary image enrollment marker does not match the active Edit owner",
		)
	}
	if !write_exact_at(image.file, snapshot.original[:], offset) || os.sync(image.file) != nil {
		return error_make(
			.Sync_Failed,
			false,
			"cannot durably restore the unenrolled marker sector",
		)
	}
	image.info.enrolled = false
	image.info.dirty = false
	image.info.image_id = {}
	return {}
}
