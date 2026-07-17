// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:crypto"
import "core:hash"
import "core:os"

MARKER_MAGIC :: "RETVR99I"
MARKER_VERSION :: u16(1)
MARKER_HEADER_BYTES :: u16(64)
MARKER_DIRTY :: u32(1)
MARKER_RETVRN99_FORMAT :: u32(2)
MARKER_CRC_OFFSET :: 56

@(private = "package")
new_image_id :: proc() -> Image_Id {
	image_id: Image_Id
	crypto.rand_bytes(image_id[:])
	image_id[6] = image_id[6] & 0x0F | 0x40
	image_id[8] = image_id[8] & 0x3F | 0x80
	return image_id
}

@(private = "package")
marker_encode :: proc(info: ^Image_Info, dirty: bool) -> (data: [SECTOR_BYTES]u8) {
	copy(data[:8], MARKER_MAGIC)
	put_u16le(data[:], 8, MARKER_VERSION)
	put_u16le(data[:], 10, MARKER_HEADER_BYTES)
	flags := dirty ? MARKER_DIRTY : 0
	if info.retvrn99_format {flags |= MARKER_RETVRN99_FORMAT}
	put_u32le(data[:], 12, flags)
	put_u32le(data[:], 16, info.marker_sector)
	put_u32le(data[:], 20, info.partition_lba)
	put_u32le(data[:], 24, info.partition_sectors)
	copy(data[32:48], info.image_id[:])
	put_u64le(data[:], 48, info.sector_count)
	put_u32le(data[:], MARKER_CRC_OFFSET, hash.crc32(data[:]))
	return
}

@(private = "package")
marker_decode :: proc(
	data: []u8,
	sector: u32,
	geometry: ^Geometry,
) -> (
	image_id: Image_Id,
	dirty, retvrn99_format, matched, valid: bool,
) {
	if len(data) != SECTOR_BYTES ||
	   string(data[:8]) != MARKER_MAGIC {return {}, false, false, false, false}
	matched = true
	if get_u16le(data, 8) != MARKER_VERSION ||
	   get_u16le(data, 10) != MARKER_HEADER_BYTES ||
	   get_u32le(data, 12) & ~(MARKER_DIRTY | MARKER_RETVRN99_FORMAT) != 0 ||
	   get_u32le(data, 16) != sector ||
	   sector == geometry.partition_lba + u32(geometry.fsinfo_sector) ||
	   sector == geometry.partition_lba + u32(geometry.backup_vbr_sector) ||
	   sector ==
		   geometry.partition_lba +
			   u32(geometry.backup_vbr_sector) +
			   u32(geometry.fsinfo_sector) ||
	   get_u32le(data, 20) != geometry.partition_lba ||
	   get_u32le(data, 24) != geometry.partition_sectors ||
	   get_u64le(data, 48) != geometry.disk_sectors {
		return {}, false, false, true, false
	}
	want := get_u32le(data, MARKER_CRC_OFFSET)
	copy_data: [SECTOR_BYTES]u8
	copy(copy_data[:], data)
	put_u32le(copy_data[:], MARKER_CRC_OFFSET, 0)
	if hash.crc32(copy_data[:]) != want {return {}, false, false, true, false}
	copy(image_id[:], data[32:48])
	nonzero := false
	for octet in image_id {nonzero = nonzero || octet != 0}
	if !nonzero {return {}, false, false, true, false}
	flags := get_u32le(data, 12)
	return image_id, flags & MARKER_DIRTY != 0, flags & MARKER_RETVRN99_FORMAT != 0, true, true
}

@(private = "package")
sector_is_zero :: proc(data: []u8) -> bool {
	for octet in data {if octet != 0 {return false}}
	return true
}

@(private = "package")
discover_marker :: proc(
	file: ^os.File,
	geometry: ^Geometry,
) -> (
	Image_Id,
	u32,
	bool,
	bool,
	bool,
	Image_Error,
) {
	sector: [SECTOR_BYTES]u8
	zero_candidate: u32
	found_zero := false
	found_marker := false
	marker_id: Image_Id
	marker_sector: u32
	marker_dirty := false
	marker_retvrn99_format := false
	fsinfo := u32(geometry.fsinfo_sector)
	backup := u32(geometry.backup_vbr_sector)
	for relative in u32(1) ..< u32(geometry.reserved_sectors) {
		absolute := geometry.partition_lba + relative
		offset, offset_ok := sector_offset(u64(absolute))
		if !offset_ok || !read_exact_at(file, sector[:], offset) {
			return {}, 0, false, false, false, error_make(.IO, false, "cannot inspect the FAT32 reserved area")
		}
		image_id, dirty, retvrn99_format, matched, valid := marker_decode(
			sector[:],
			absolute,
			geometry,
		)
		if matched {
			if !valid || found_marker {
				return {}, 0, false, false, false, error_make(.Marker_Invalid, false, "the RETVRN99 image marker is invalid or duplicated")
			}
			found_marker = true
			marker_id = image_id
			marker_sector = absolute
			marker_dirty = dirty
			marker_retvrn99_format = retvrn99_format
			continue
		}
		if relative != fsinfo &&
		   relative != backup &&
		   relative != backup + fsinfo &&
		   sector_is_zero(sector[:]) {
			zero_candidate = absolute
			found_zero = true
		}
	}
	if found_marker {return marker_id, marker_sector, true, marker_dirty, marker_retvrn99_format, {}}
	if !found_zero {
		return {}, 0, false, false, false, error_make(.Marker_Unavailable, false, "the FAT32 reserved area has no safe sector for an image marker")
	}
	return {}, zero_candidate, false, false, false, {}
}

@(private = "package")
write_marker :: proc(file: ^os.File, info: ^Image_Info, dirty: bool) -> Image_Error {
	if file == nil || info == nil || !info.enrolled {
		return error_make(.Marker_Invalid, false, "the RETVRN99 image marker is unavailable")
	}
	data := marker_encode(info, dirty)
	offset, offset_ok := sector_offset(u64(info.marker_sector))
	if !offset_ok || !write_exact_at(file, data[:], offset) {
		return error_make(.IO, false, "cannot write the RETVRN99 image marker")
	}
	return {}
}
