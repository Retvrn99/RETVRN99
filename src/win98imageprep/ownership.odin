// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32image "../fat32image"
import fat32session "../fat32session"
import "core:hash"

OWNER_MAGIC :: "R99PRP01"
OWNER_VERSION :: u16(1)
OWNER_BYTES :: 112
OWNER_CRC_OFFSET :: 12
OWNER_FLAG_SYSTEM_IO :: u16(1 << 0)
OWNER_FLAG_SYSTEM_MSDOS :: u16(1 << 1)
OWNER_FLAG_SYSTEM_COMMAND :: u16(1 << 2)
OWNER_FLAG_AUTOEXEC_BACKUP :: u16(1 << 3)
FINGERPRINT_BYTES :: 16
FINGERPRINT_OFFSET :: 56

File_Fingerprint :: struct {
	size: u64,
	crc:  u32,
}

Preparation_Owner :: struct {
	valid:               bool,
	system_owned:        [3]bool,
	autoexec_backup:     bool,
	transaction_id:      u64,
	image_identity:      fat32image.Image_Id,
	boot_target:         Boot_Target,
	system_fingerprints: [3]File_Fingerprint,
}

owner_put_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

owner_put_u32 :: proc(data: []u8, offset: int, value: u32) {
	for index in 0 ..< 4 {data[offset + index] = u8(value >> u32(index * 8))}
}

owner_put_u64 :: proc(data: []u8, offset: int, value: u64) {
	for index in 0 ..< 8 {data[offset + index] = u8(value >> u64(index * 8))}
}

owner_get_u16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

owner_get_u32 :: proc(data: []u8, offset: int) -> u32 {
	value: u32
	for index in 0 ..< 4 {value |= u32(data[offset + index]) << u32(index * 8)}
	return value
}

owner_get_u64 :: proc(data: []u8, offset: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {value |= u64(data[offset + index]) << u64(index * 8)}
	return value
}

owner_encode :: proc(owner: Preparation_Owner) -> (data: [OWNER_BYTES]u8) {
	copy(data[:8], OWNER_MAGIC)
	owner_put_u16(data[:], 8, OWNER_VERSION)
	flags: u16
	if owner.system_owned[0] {flags |= OWNER_FLAG_SYSTEM_IO}
	if owner.system_owned[1] {flags |= OWNER_FLAG_SYSTEM_MSDOS}
	if owner.system_owned[2] {flags |= OWNER_FLAG_SYSTEM_COMMAND}
	if owner.autoexec_backup {flags |= OWNER_FLAG_AUTOEXEC_BACKUP}
	owner_put_u16(data[:], 10, flags)
	owner_put_u64(data[:], 16, owner.transaction_id)
	owner_put_u64(data[:], 24, owner.boot_target.lba)
	owner_put_u32(data[:], 32, owner.boot_target.first_cluster)
	identity := owner.image_identity
	copy(data[40:56], identity[:])
	for fingerprint, index in owner.system_fingerprints {
		offset := FINGERPRINT_OFFSET + index * FINGERPRINT_BYTES
		owner_put_u64(data[:], offset, fingerprint.size)
		owner_put_u32(data[:], offset + 8, fingerprint.crc)
	}
	owner_put_u32(data[:], OWNER_CRC_OFFSET, hash.crc32(data[:]))
	return
}

owner_decode :: proc(data: []u8) -> Preparation_Owner {
	if len(data) != OWNER_BYTES ||
	   string(data[:8]) != OWNER_MAGIC ||
	   owner_get_u16(data, 8) != OWNER_VERSION {
		return {}
	}
	want := owner_get_u32(data, OWNER_CRC_OFFSET)
	copy_data: [OWNER_BYTES]u8
	copy(copy_data[:], data)
	owner_put_u32(copy_data[:], OWNER_CRC_OFFSET, 0)
	if hash.crc32(copy_data[:]) != want {return {}}
	flags := owner_get_u16(data, 10)
	known_flags :=
		OWNER_FLAG_SYSTEM_IO |
		OWNER_FLAG_SYSTEM_MSDOS |
		OWNER_FLAG_SYSTEM_COMMAND |
		OWNER_FLAG_AUTOEXEC_BACKUP
	if flags & ~known_flags != 0 {return {}}
	owner := Preparation_Owner {
		valid = true,
		system_owned = {
			flags & OWNER_FLAG_SYSTEM_IO != 0,
			flags & OWNER_FLAG_SYSTEM_MSDOS != 0,
			flags & OWNER_FLAG_SYSTEM_COMMAND != 0,
		},
		autoexec_backup = flags & OWNER_FLAG_AUTOEXEC_BACKUP != 0,
		transaction_id = owner_get_u64(data, 16),
		boot_target = {first_cluster = owner_get_u32(data, 32), lba = owner_get_u64(data, 24)},
	}
	copy(owner.image_identity[:], data[40:56])
	for &fingerprint, index in owner.system_fingerprints {
		offset := FINGERPRINT_OFFSET + index * FINGERPRINT_BYTES
		fingerprint.size = owner_get_u64(data, offset)
		fingerprint.crc = owner_get_u32(data, offset + 8)
	}
	identity_valid := false
	for octet in owner.image_identity {if octet != 0 {identity_valid = true; break}}
	if owner.transaction_id == 0 ||
	   owner.boot_target.first_cluster < 2 ||
	   owner.boot_target.lba == 0 ||
	   !identity_valid {
		return {}
	}
	for owned, index in owner.system_owned {
		if owned && owner.system_fingerprints[index].size == 0 {
			return {}
		}
	}
	return owner
}

fingerprint_bytes :: proc(data: []u8) -> File_Fingerprint {
	return {size = u64(len(data)), crc = hash.crc32(data)}
}

edit_read_small :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	limit: u64,
) -> (
	[]u8,
	bool,
	Error,
) {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code != .None {
		err := error_make(.Edit_Failed, "cannot inspect a prepared FAT file")
		err.session_error = stat_error
		return nil, false, err
	}
	if !stat.exists {return nil, false, {}}
	if stat.is_directory || stat.size > limit {
		return nil, true, error_make(
			.Ownership_Mismatch,
			"prepared FAT file has an unexpected type or size",
		)
	}
	result, read_error := fat32session.edit_read(session, path, 0, stat.size)
	if read_error.code != .None {
		err := error_make(.Edit_Failed, "cannot read a prepared FAT file")
		err.session_error = read_error
		return nil, true, err
	}
	data := result.data
	result.data = nil
	fat32session.edit_read_destroy(&result)
	return data, true, {}
}

edit_file_equals :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	expected: []u8,
) -> (
	exists, matches: bool,
	err: Error,
) {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code != .None {
		err = error_make(.Edit_Failed, "cannot inspect an owned FAT file")
		err.session_error = stat_error
		return
	}
	if !stat.exists {return false, false, {}}
	if stat.is_directory || stat.size != u64(len(expected)) {return true, false, {}}
	data, found, read_error := edit_read_small(session, path, u64(len(expected)))
	if read_error.code != .None || !found {return found, false, read_error}
	defer delete(data)
	return true, string(data) == string(expected), {}
}

edit_file_has_prefix :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	prefix: string,
) -> (
	exists, matches: bool,
	err: Error,
) {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code != .None {
		err = error_make(.Edit_Failed, "cannot inspect an owned FAT file")
		err.session_error = stat_error
		return
	}
	if !stat.exists {return false, false, {}}
	if stat.is_directory || stat.size < u64(len(prefix)) {
		return true, false, {}
	}
	result, read_error := fat32session.edit_read(session, path, 0, u64(len(prefix)))
	if read_error.code != .None {
		err = error_make(.Edit_Failed, "cannot read an owned FAT file")
		err.session_error = read_error
		return
	}
	defer fat32session.edit_read_destroy(&result)
	return true, string(result.data) == prefix, {}
}

edit_file_fingerprint :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	maximum_size: u64,
) -> (
	File_Fingerprint,
	bool,
	Error,
) {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code != .None {
		err := error_make(.Edit_Failed, "cannot inspect an owned FAT file")
		err.session_error = stat_error
		return {}, false, err
	}
	if !stat.exists {return {}, false, {}}
	if stat.is_directory || stat.size == 0 || stat.size > maximum_size {
		return {}, true, error_make(.Ownership_Mismatch, "owned FAT file has an unexpected type or size")
	}
	fingerprint := File_Fingerprint {
		size = stat.size,
	}
	offset: u64
	for offset < stat.size {
		length := min(u64(128 * 1024), stat.size - offset)
		result, read_error := fat32session.edit_read(session, path, offset, length)
		if read_error.code != .None || u64(len(result.data)) != length {
			fat32session.edit_read_destroy(&result)
			err := error_make(.Edit_Failed, "cannot fingerprint an owned FAT file")
			err.session_error = read_error
			return {}, true, err
		}
		fingerprint.crc = hash.crc32(result.data, fingerprint.crc)
		offset += length
		fat32session.edit_read_destroy(&result)
	}
	return fingerprint, true, {}
}

owner_read :: proc(session: ^fat32session.Edit_Session) -> (Preparation_Owner, bool, Error) {
	data, exists, read_error := edit_read_small(session, OWNER_FILE_NAME, OWNER_BYTES)
	if read_error.code != .None || !exists {return {}, exists, read_error}
	defer delete(data)
	owner := owner_decode(data)
	if !owner.valid {
		return {}, true, error_make(.Ownership_Mismatch, "Windows 98 preparation ownership marker is invalid")
	}
	return owner, true, {}
}
