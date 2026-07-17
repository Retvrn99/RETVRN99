// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:hash"
import "core:os"
import "core:path/filepath"

EDIT_ADOPTION_MAGIC :: "R99ADV01"
EDIT_ADOPTION_VERSION :: u16(1)
EDIT_ADOPTION_HEADER_BYTES :: 128
EDIT_ADOPTION_BYTES :: EDIT_ADOPTION_HEADER_BYTES + fat32image.SECTOR_BYTES * 2
EDIT_ADOPTION_CRC_OFFSET :: 12

Edit_Adoption_Evidence :: struct {
	valid:             bool,
	transaction:       u64,
	sector_count:      u64,
	primary_lba:       u64,
	backup_lba:        u64,
	image_id:          fat32image.Image_Id,
	original_primary:  [fat32image.SECTOR_BYTES]u8,
	original_backup:   [fat32image.SECTOR_BYTES]u8,
}

@(private = "file")
edit_adoption_path :: proc(root: string, allocator := context.allocator) -> (string, bool) {
	path, path_error := filepath.join({root, "adoption-vbr.evidence"}, allocator)
	return path, path_error == nil
}

@(private = "file")
edit_adoption_encode :: proc(evidence: ^Edit_Adoption_Evidence) -> (data: [EDIT_ADOPTION_BYTES]u8) {
	copy(data[:8], EDIT_ADOPTION_MAGIC)
	put_u16le(data[:], 8, EDIT_ADOPTION_VERSION)
	put_u16le(data[:], 10, EDIT_ADOPTION_HEADER_BYTES)
	put_u64le(data[:], 16, evidence.transaction)
	put_u64le(data[:], 24, evidence.sector_count)
	put_u64le(data[:], 32, evidence.primary_lba)
	put_u64le(data[:], 40, evidence.backup_lba)
	copy(data[48:64], evidence.image_id[:])
	copy(
		data[EDIT_ADOPTION_HEADER_BYTES:EDIT_ADOPTION_HEADER_BYTES + fat32image.SECTOR_BYTES],
		evidence.original_primary[:],
	)
	copy(
		data[EDIT_ADOPTION_HEADER_BYTES + fat32image.SECTOR_BYTES:],
		evidence.original_backup[:],
	)
	put_u32le(data[:], EDIT_ADOPTION_CRC_OFFSET, hash.crc32(data[:]))
	return
}

@(private = "file")
edit_adoption_decode :: proc(data: []u8) -> Edit_Adoption_Evidence {
	if len(data) != EDIT_ADOPTION_BYTES ||
	   string(data[:8]) != EDIT_ADOPTION_MAGIC ||
	   get_u16le(data, 8) != EDIT_ADOPTION_VERSION ||
	   get_u16le(data, 10) != EDIT_ADOPTION_HEADER_BYTES {
		return {}
	}
	want := get_u32le(data, EDIT_ADOPTION_CRC_OFFSET)
	copy_data: [EDIT_ADOPTION_BYTES]u8
	copy(copy_data[:], data)
	put_u32le(copy_data[:], EDIT_ADOPTION_CRC_OFFSET, 0)
	if hash.crc32(copy_data[:]) != want {return {}}
	evidence := Edit_Adoption_Evidence {
		valid        = true,
		transaction  = get_u64le(data, 16),
		sector_count = get_u64le(data, 24),
		primary_lba  = get_u64le(data, 32),
		backup_lba   = get_u64le(data, 40),
	}
	copy(evidence.image_id[:], data[48:64])
	copy(
		evidence.original_primary[:],
		data[EDIT_ADOPTION_HEADER_BYTES:EDIT_ADOPTION_HEADER_BYTES + fat32image.SECTOR_BYTES],
	)
	copy(
		evidence.original_backup[:],
		data[EDIT_ADOPTION_HEADER_BYTES + fat32image.SECTOR_BYTES:],
	)
	if evidence.transaction == 0 ||
	   evidence.sector_count == 0 ||
	   evidence.primary_lba == evidence.backup_lba {
		return {}
	}
	return evidence
}

@(private = "package")
edit_adoption_load_boundary :: proc(
	directory: ^Companion_Boundary,
) -> (Edit_Adoption_Evidence, bool) {
	file, opened := companion_boundary_file_open(directory, "adoption-vbr.evidence", {.Read})
	if !opened {return {}, false}
	defer os.close(file)
	data: [EDIT_ADOPTION_BYTES]u8
	size, size_error := os.file_size(file)
	if size_error != nil || size != EDIT_ADOPTION_BYTES ||
	   !file_read_exact_at(file, data[:], 0) {
		return {}, false
	}
	evidence := edit_adoption_decode(data[:])
	return evidence, evidence.valid
}

@(private = "package")
edit_adoption_load :: proc(root: string) -> (Edit_Adoption_Evidence, bool) {
	directory, opened := companion_boundary_open(root, context.temp_allocator)
	if !opened {return {}, false}
	defer companion_boundary_close(&directory, context.temp_allocator)
	return edit_adoption_load_boundary(&directory)
}

@(private = "package")
edit_adoption_save_boundary :: proc(
	directory: ^Companion_Boundary,
	owner: ^Edit_Owner,
	pair: ^fat32image.Adoption_Boot_Pair,
) -> Session_Error {
	if directory == nil || !directory.open || owner == nil || pair == nil {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 adoption recovery evidence is unavailable",
		)
	}
	evidence := Edit_Adoption_Evidence {
		valid            = true,
		transaction      = owner.transaction,
		sector_count     = owner.sector_count,
		primary_lba      = pair.primary_lba,
		backup_lba       = pair.backup_lba,
		image_id         = owner.image_id,
		original_primary = pair.original_primary,
		original_backup  = pair.original_backup,
	}
	exists, safe, _ := companion_boundary_file_probe(directory, "adoption-vbr.evidence")
	if exists {
		if !safe {
			return error_make(.State_Mismatch, false, .Retained, 0, 0, "FAT32 adoption evidence is not a safe regular file")
		}
		current, current_ok := edit_adoption_load_boundary(directory)
		if current_ok &&
		   current.transaction == evidence.transaction &&
		   current.sector_count == evidence.sector_count &&
		   current.primary_lba == evidence.primary_lba &&
		   current.backup_lba == evidence.backup_lba &&
		   current.image_id == evidence.image_id &&
		   current.original_primary == evidence.original_primary &&
		   current.original_backup == evidence.original_backup {
			return {}
		}
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 adoption evidence disagrees with the active Edit owner",
		)
	}
	data := edit_adoption_encode(&evidence)
	file, opened := companion_boundary_file_open(
		directory,
		"adoption-vbr.evidence",
		{.Write, .Create, .Excl, .Sync},
	)
	if !opened {
		return error_make(.Wal_IO, false, .Retained, 0, 0, "cannot create FAT32 adoption evidence")
	}
	ok := file_write_exact_at(file, data[:], 0) && os.sync(file) == nil
	close_error := os.close(file)
	if !ok || close_error != nil || !companion_boundary_sync(directory) {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			0,
			0,
			"cannot durably preserve the original FAT32 boot sectors",
		)
	}
	return {}
}

@(private = "package")
edit_adoption_save :: proc(
	root: string,
	owner: ^Edit_Owner,
	pair: ^fat32image.Adoption_Boot_Pair,
) -> Session_Error {
	directory, opened := companion_boundary_open(root, context.temp_allocator)
	if !opened {
		return error_make(.Wal_IO, false, .Retained, 0, 0, "cannot bind FAT32 adoption evidence")
	}
	defer companion_boundary_close(&directory, context.temp_allocator)
	return edit_adoption_save_boundary(&directory, owner, pair)
}

@(private = "package")
edit_adoption_validate :: proc(
	evidence: ^Edit_Adoption_Evidence,
	owner: ^Edit_Owner,
	image: ^fat32image.Image,
) -> Session_Error {
	if evidence == nil ||
	   !evidence.valid ||
	   owner == nil ||
	   image == nil ||
	   evidence.transaction != owner.transaction ||
	   evidence.sector_count != owner.sector_count ||
	   evidence.image_id != owner.image_id ||
	   evidence.sector_count != image.info.sector_count ||
	   evidence.image_id != image.info.image_id ||
	   evidence.primary_lba != u64(image.info.partition_lba) ||
	   evidence.backup_lba !=
		   u64(image.info.partition_lba) + u64(image.geometry.backup_vbr_sector) {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 adoption evidence does not match its image and Edit transaction",
		)
	}
	return {}
}
