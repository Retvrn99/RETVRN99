// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

WAL_FILE :: "active.wal"
WAL_MAGIC :: u32(0x57393952)
WAL_VERSION :: u16(2)
WAL_HEADER_BYTES :: 40
WAL_CHECKPOINT_MAX_BYTES :: i64(16 * 1024 * 1024)
WAL_CHECKPOINT_MAX_SEQUENCES :: u64(2048)
STATE_MAGIC :: "R99STATE"
STATE_VERSION :: u16(1)
STATE_BYTES :: 64
STATE_CRC_OFFSET :: 56

Wal_State_Phase :: enum u8 {
	Open = 1,
	Clean,
	Clean_Pending,
	Prepared,
}

Wal_State :: struct {
	valid:      bool,
	epoch:      u64,
	checkpoint: u64,
	image_id:   fat32image.Image_Id,
	phase:      Wal_State_Phase,
}

Wal :: struct {
	file:               ^os.File,
	path:               string,
	state_root:         string,
	boundary:           Companion_Boundary,
	created_state_root: bool,
	offset:             i64,
	state:              Wal_State,
}

companion_path :: proc(image_path: string, allocator := context.allocator) -> (string, bool) {
	if image_path == "" {return "", false}
	name := strings.concatenate(
		{".", filepath.base(image_path), ".retvrn99-fat32"},
		context.temp_allocator,
	)
	path, path_error := filepath.join({filepath.dir(image_path), name}, allocator)
	return path, path_error == nil
}

@(private = "package")
state_encode :: proc(state: Wal_State) -> (data: [STATE_BYTES]u8) {
	copy(data[:8], STATE_MAGIC)
	put_u16le(data[:], 8, STATE_VERSION)
	data[10] = u8(state.phase)
	put_u64le(data[:], 16, state.epoch)
	put_u64le(data[:], 24, state.checkpoint)
	image_id := state.image_id
	copy(data[32:48], image_id[:])
	put_u32le(data[:], STATE_CRC_OFFSET, hash.crc32(data[:]))
	return
}

@(private = "package")
state_decode :: proc(data: []u8) -> Wal_State {
	if len(data) != STATE_BYTES ||
	   string(data[:8]) != STATE_MAGIC ||
	   get_u16le(data, 8) != STATE_VERSION ||
	   (data[10] != u8(Wal_State_Phase.Open) &&
			   data[10] != u8(Wal_State_Phase.Clean) &&
			   data[10] != u8(Wal_State_Phase.Clean_Pending) &&
			   data[10] != u8(Wal_State_Phase.Prepared)) {
		return {}
	}
	want := get_u32le(data, STATE_CRC_OFFSET)
	copy_data: [STATE_BYTES]u8
	copy(copy_data[:], data)
	put_u32le(copy_data[:], STATE_CRC_OFFSET, 0)
	if hash.crc32(copy_data[:]) != want {return {}}
	state := Wal_State {
		valid      = true,
		epoch      = get_u64le(data, 16),
		checkpoint = get_u64le(data, 24),
		phase      = Wal_State_Phase(data[10]),
	}
	copy(state.image_id[:], data[32:48])
	return state
}

@(private = "file")
state_path :: proc(root: string, slot: int, allocator := context.allocator) -> (string, bool) {
	name := slot == 0 ? "state.a" : "state.b"
	path, path_error := filepath.join({root, name}, allocator)
	return path, path_error == nil
}

@(private = "file")
state_read_slot_boundary :: proc(
	directory: ^Companion_Boundary,
	slot: int,
) -> (
	Wal_State,
	bool,
) {
	name := slot == 0 ? "state.a" : "state.b"
	exists, safe, _ := companion_boundary_file_probe(directory, name)
	if !safe {return {}, false}
	if !exists {return {}, true}
	file, opened := companion_boundary_file_open(directory, name, {.Read})
	if !opened {return {}, false}
	defer os.close(file)
	data: [STATE_BYTES]u8
	size, size_error := os.file_size(file)
	if size_error != nil || size != STATE_BYTES ||
	   !file_read_exact_at(file, data[:], 0) {
		return {}, true
	}
	return state_decode(data[:]), true
}

@(private = "file")
state_load_boundary :: proc(directory: ^Companion_Boundary) -> (Wal_State, bool) {
	first, first_safe := state_read_slot_boundary(directory, 0)
	second, second_safe := state_read_slot_boundary(directory, 1)
	if !first_safe || !second_safe {return {}, false}
	if !first.valid && !second.valid {return {}, false}
	if !first.valid {return second, true}
	if !second.valid {return first, true}
	return first.epoch >= second.epoch ? first : second, true
}

@(private = "file")
state_load :: proc(root: string) -> (Wal_State, bool) {
	directory, opened := companion_boundary_open(root, context.temp_allocator)
	if !opened {return {}, false}
	defer companion_boundary_close(&directory, context.temp_allocator)
	return state_load_boundary(&directory)
}

@(private = "package")
state_save :: proc(wal: ^Wal, phase: Wal_State_Phase, checkpoint: u64) -> Session_Error {
	if wal == nil || wal.state_root == "" {
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			checkpoint,
			checkpoint,
			"FAT32 checkpoint state is unavailable",
		)
	}
	state := wal.state
	state.valid = true
	state.epoch += 1
	state.phase = phase
	state.checkpoint = checkpoint
	name := state.epoch & 1 == 0 ? "state.a" : "state.b"
	file, opened := companion_boundary_file_open(
		&wal.boundary,
		name,
		{.Read, .Write, .Create, .Sync},
	)
	if !opened {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			checkpoint,
			wal.state.checkpoint,
			"cannot open FAT32 checkpoint state",
		)
	}
	defer os.close(file)
	data := state_encode(state)
	if os.truncate(file, 0) != nil ||
	   !file_write_exact_at(file, data[:], 0) ||
	   os.sync(file) != nil ||
	   !companion_boundary_sync(&wal.boundary) {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			checkpoint,
			wal.state.checkpoint,
			"cannot durably save FAT32 checkpoint state",
		)
	}
	wal.state = state
	return {}
}

wal_prepare :: proc(
	wal: ^Wal,
	image_path: string,
	image_id: fat32image.Image_Id,
	was_dirty: bool,
) -> Session_Error {
	root, root_ok := companion_path(image_path)
	if !root_ok {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"cannot resolve FAT32 companion state",
		)
	}
	wal.state_root = root
	root_exists, root_safe := companion_directory_probe(root)
	if root_exists && (!root_safe || !companion_directory_prepare(root, false)) {
		return error_make(
			.Wal_IO,
			false,
			.Retained,
			0,
			0,
			"cannot secure the FAT32 companion state directory",
		)
	}
	loaded: Wal_State
	has_state := false
	if root_exists {
		boundary, boundary_ok := companion_boundary_open(root)
		if !boundary_ok {
			return error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"cannot bind the FAT32 companion directory",
			)
		}
		wal.boundary = boundary
		loaded, has_state = state_load_boundary(&wal.boundary)
	}
	if was_dirty {
		if !root_exists ||
		   !has_state ||
		   (loaded.phase != .Prepared &&
				   loaded.phase != .Open &&
				   loaded.phase != .Clean_Pending) ||
		   loaded.image_id != image_id {
			return error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"dirty image does not match its FAT32 recovery state",
			)
		}
		wal.state = loaded
	} else {
		if root_exists {
			if !has_state ||
			   loaded.image_id != image_id ||
			   (loaded.phase != .Prepared &&
					   loaded.phase != .Clean &&
					   loaded.phase != .Clean_Pending) {
				return error_make(
					.State_Mismatch,
					false,
					.Retained,
					0,
					0,
					"clean image disagrees with preserved FAT32 recovery state",
				)
			}
			companion_boundary_close(&wal.boundary)
			if !companion_directory_remove(root) {
				return error_make(
					.Wal_IO,
					true,
					.Not_Started,
					0,
					0,
					"cannot retire completed FAT32 recovery state",
				)
			}
		}
		if !companion_directory_prepare(root, true) {
			wal.created_state_root = os.exists(root)
			return error_make(
				.Wal_IO,
				false,
				.Not_Started,
				0,
				0,
				"cannot create or secure the FAT32 companion state directory",
			)
		}
		wal.created_state_root = true
		boundary, boundary_ok := companion_boundary_open(root)
		if !boundary_ok {
			return error_make(
				.Wal_IO,
				false,
				.Not_Started,
				0,
				0,
				"cannot bind the new FAT32 companion directory",
			)
		}
		wal.boundary = boundary
		wal.state = Wal_State {
			valid    = true,
			image_id = image_id,
		}
		state_error := state_save(wal, .Prepared, 0)
		if state_error.code != .None {return state_error}
	}
	path, path_error := filepath.join({root, WAL_FILE}, context.allocator)
	if path_error != nil {
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			0,
			wal.state.checkpoint,
			"cannot resolve the FAT32 redo log",
		)
	}
	if was_dirty {
		exists, safe, _ := companion_boundary_file_probe(&wal.boundary, WAL_FILE)
		if !exists || !safe {
			delete(path)
			return error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				wal.state.checkpoint,
				"dirty image has no intact FAT32 redo log",
			)
		}
	}
	flags := os.File_Flags{.Read, .Write, .Sync}
	if !was_dirty {flags += {.Create}}
	file, opened := companion_boundary_file_open(&wal.boundary, WAL_FILE, flags)
	if !opened {
		delete(path)
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			0,
			wal.state.checkpoint,
			"cannot open the FAT32 redo log",
		)
	}
	if !was_dirty && (os.sync(file) != nil || !companion_boundary_sync(&wal.boundary)) {
		_ = os.close(file)
		delete(path)
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			0,
			wal.state.checkpoint,
			"cannot durably create the FAT32 redo log",
		)
	}
	size, size_error := os.file_size(file)
	if size_error != nil {
		_ = os.close(file)
		delete(path)
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			0,
			wal.state.checkpoint,
			"cannot inspect the FAT32 redo log",
		)
	}
	wal.file = file
	wal.path = path
	wal.offset = size
	return {}
}

wal_preflight :: proc(info: ^fat32image.Image_Info) -> Session_Error {
	validation_error := companion_state_validate(info)
	if validation_error.code != .None {return validation_error}
	root, _ := companion_path(info.path, context.temp_allocator)
	root_exists, root_safe := companion_directory_probe(root)
	if !root_exists {return {}}
	if !root_safe {return error_make(
		.State_Mismatch,
		false,
		.Retained,
		0,
		0,
		"FAT32 companion state changed during validation",
	)}
	retired_edit, edit_error := edit_completion_preflight(info)
	if edit_error.code != .None {return edit_error}
	if retired_edit {return {}}
	return {}
}

@(private = "package")
companion_state_validate :: proc(info: ^fat32image.Image_Info) -> Session_Error {
	if info == nil || info.path == "" {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"hard-drive image information is unavailable",
		)
	}
	root, root_ok := companion_path(info.path, context.temp_allocator)
	if !root_ok {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"cannot resolve FAT32 companion state",
		)
	}
	root_exists, root_safe := companion_directory_probe(root)
	if !root_exists {
		if info.dirty {
			return error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"dirty image has no FAT32 recovery state",
			)
		}
		return {}
	}
	if !root_safe || !companion_directory_prepare(root, false) {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 companion state is not a safe local directory",
		)
	}
	boundary, boundary_ok := companion_boundary_open(root, context.temp_allocator)
	if !boundary_ok {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 companion state cannot be identity-bound",
		)
	}
	defer companion_boundary_close(&boundary, context.temp_allocator)
	owner, owner_valid := edit_owner_load_boundary(&boundary)
	state, state_valid := state_load_boundary(&boundary)
	if owner_valid && state_valid {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image has ambiguous FAT32 companion state",
		)
	}
	if owner_valid {
		identity_matches :=
			owner.sector_count == info.sector_count &&
			(info.enrolled && owner.image_id == info.image_id ||
					owner.restore_unenrolled &&
						!info.enrolled &&
						(owner.phase == .Prepared ||
								owner.phase == .Clean_Pending ||
								owner.phase == .Completed))
		if !identity_matches {
			return error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"hard-drive image does not match its FAT32 Edit state",
			)
		}
		valid_phase :=
			info.dirty &&
				(owner.phase == .Prepared ||
						owner.phase == .Open ||
						owner.phase == .Applying ||
						owner.phase == .Clean_Pending) ||
			!info.dirty &&
				info.enrolled &&
				(owner.phase == .Prepared ||
						owner.phase == .Clean_Pending ||
						owner.phase == .Completed) ||
			!info.enrolled &&
				owner.restore_unenrolled &&
				(owner.phase == .Prepared ||
						owner.phase == .Clean_Pending ||
						owner.phase == .Completed)
		if valid_phase {return {}}
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image dirty marker disagrees with FAT32 Edit state",
		)
	}
	if !state_valid || !info.enrolled || state.image_id != info.image_id {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image does not match its FAT32 companion state",
		)
	}
	if info.dirty {
		exists, safe, _ := companion_boundary_file_probe(&boundary, WAL_FILE)
		if !exists || !safe {
			return error_make(
				.State_Mismatch,
				false,
				.Retained,
				state.checkpoint,
				state.checkpoint,
				"dirty image has no intact FAT32 redo log",
			)
		}
	}
	valid_phase :=
		info.dirty &&
			(state.phase == .Prepared || state.phase == .Open || state.phase == .Clean_Pending) ||
		!info.dirty &&
			(state.phase == .Prepared || state.phase == .Clean || state.phase == .Clean_Pending)
	if !valid_phase {
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			state.checkpoint,
			state.checkpoint,
			"hard-drive image dirty marker disagrees with FAT32 companion state",
		)
	}
	return {}
}

wal_close :: proc(wal: ^Wal) {
	if wal == nil {return}
	if wal.file != nil {_ = os.close(wal.file)}
	companion_boundary_close(&wal.boundary)
	delete(wal.path)
	delete(wal.state_root)
	wal^ = {}
}

@(private = "file")
wal_checksum :: proc(header, payload: []u8) -> u32 {
	checksum := hash.crc32(header)
	if len(payload) > 0 {checksum = hash.crc32(payload, checksum)}
	return checksum
}

@(private = "file")
wal_header :: proc(sequence, lba: u64, payload: []u8) -> [WAL_HEADER_BYTES]u8 {
	header: [WAL_HEADER_BYTES]u8
	put_u32le(header[:], 0, WAL_MAGIC)
	put_u16le(header[:], 4, WAL_VERSION)
	put_u32le(header[:], 8, u32(len(payload)))
	put_u64le(header[:], 16, sequence)
	put_u64le(header[:], 24, lba)
	put_u32le(header[:], 12, wal_checksum(header[:], payload))
	return header
}

wal_append :: proc(wal: ^Wal, sequence, lba: u64, payload: []u8) -> Session_Error {
	if wal == nil || wal.file == nil || len(payload) <= 0 || len(payload) > MAX_BLOCK_BYTES {
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			sequence,
			0,
			"FAT32 redo log is unavailable",
		)
	}
	header := wal_header(sequence, lba, payload)
	if !file_write_exact_at(wal.file, header[:], wal.offset) ||
	   !file_write_exact_at(wal.file, payload, wal.offset + WAL_HEADER_BYTES) ||
	   os.sync(wal.file) != nil {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			sequence,
			wal.state.checkpoint,
			"FAT32 redo record could not be made durable",
		)
	}
	wal.offset += WAL_HEADER_BYTES + i64(len(payload))
	crash_point(.Wal_Appended)
	return {}
}

wal_checkpoint_due :: proc(wal: ^Wal, sequence: u64) -> bool {
	if wal == nil {return false}
	if wal.offset >= WAL_CHECKPOINT_MAX_BYTES {return true}
	return(
		sequence >= wal.state.checkpoint &&
		sequence - wal.state.checkpoint >= WAL_CHECKPOINT_MAX_SEQUENCES \
	)
}

@(private = "file")
wal_record_sequence_valid :: proc(checkpoint, previous, sequence: u64) -> bool {
	if sequence == 0 {return false}
	if previous == 0 {
		return sequence <= checkpoint ||
		       checkpoint != max(u64) && sequence == checkpoint + 1
	}
	return previous != max(u64) && sequence == previous + 1
}

wal_recover :: proc(wal: ^Wal, image: ^fat32image.Image) -> (u64, Session_Error) {
	if wal == nil || wal.file == nil || image == nil {
		return 0, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 recovery has no image or redo log",
		)
	}
	offset: i64
	last_sequence := wal.state.checkpoint
	last_record_sequence: u64
	buffer: [MAX_BLOCK_BYTES]u8
	for offset < wal.offset {
		remaining := wal.offset - offset
		if remaining < WAL_HEADER_BYTES {
			if os.truncate(wal.file, offset) != nil || os.sync(wal.file) != nil {
				return 0, error_make(
					.Wal_IO,
					false,
					.Uncertain,
					last_sequence,
					wal.state.checkpoint,
					"torn FAT32 redo tail cannot be discarded",
				)
			}
			wal.offset = offset
			break
		}
		header: [WAL_HEADER_BYTES]u8
		if !file_read_exact_at(wal.file, header[:], offset) {
			return 0, error_make(
				.Wal_IO,
				false,
				.Uncertain,
				last_sequence,
				wal.state.checkpoint,
				"FAT32 redo header cannot be read",
			)
		}
		if get_u32le(header[:], 0) != WAL_MAGIC || get_u16le(header[:], 4) != WAL_VERSION {
			return 0, error_make(
				.Recovery_Failed,
				false,
				.Retained,
				last_sequence,
				wal.state.checkpoint,
				"FAT32 redo log is incompatible",
			)
		}
		length := int(get_u32le(header[:], 8))
		sequence := get_u64le(header[:], 16)
		lba := get_u64le(header[:], 24)
		record_bytes := i64(WAL_HEADER_BYTES + length)
		if length <= 0 ||
		   length > MAX_BLOCK_BYTES ||
		   length % fat32image.SECTOR_BYTES != 0 {
			return 0, error_make(
				.Recovery_Failed,
				false,
				.Retained,
				sequence,
				wal.state.checkpoint,
				"FAT32 redo record is malformed or out of order",
			)
		}
		if remaining < record_bytes {
			if os.truncate(wal.file, offset) != nil || os.sync(wal.file) != nil {
				return 0, error_make(
					.Wal_IO,
					false,
					.Uncertain,
					last_sequence,
					wal.state.checkpoint,
					"torn FAT32 redo record cannot be discarded",
				)
			}
			wal.offset = offset
			break
		}
		payload := buffer[:length]
		if !file_read_exact_at(wal.file, payload, offset + WAL_HEADER_BYTES) {
			return 0, error_make(
				.Wal_IO,
				false,
				.Uncertain,
				sequence,
				wal.state.checkpoint,
				"FAT32 redo payload cannot be read",
			)
		}
		want := get_u32le(header[:], 12)
		put_u32le(header[:], 12, 0)
		if wal_checksum(header[:], payload) != want {
			if offset + record_bytes == wal.offset {
				if os.truncate(wal.file, offset) != nil || os.sync(wal.file) != nil {
					return 0, error_make(
						.Wal_IO,
						false,
						.Uncertain,
						last_sequence,
						wal.state.checkpoint,
						"torn FAT32 redo tail cannot be discarded",
					)
				}
				wal.offset = offset
				break
			}
			return 0, error_make(
				.Recovery_Failed,
				false,
				.Retained,
				sequence,
				wal.state.checkpoint,
				"FAT32 redo checksum failed before the log tail",
			)
		}
		if !wal_record_sequence_valid(wal.state.checkpoint, last_record_sequence, sequence) {
			return 0, error_make(
				.Recovery_Failed,
				false,
				.Retained,
				sequence,
				wal.state.checkpoint,
				"FAT32 redo record sequence is missing, duplicated, or out of order",
			)
		}
		if sequence > wal.state.checkpoint {
			write_error := fat32image.block_write(image, lba, payload)
			if write_error.code != .None {
				return 0, image_error_map(write_error, sequence, wal.state.checkpoint)
			}
		}
		last_record_sequence = sequence
		last_sequence = max(last_sequence, sequence)
		offset += record_bytes
	}
	if last_sequence > wal.state.checkpoint {
		sync_error := fat32image.sync(image)
		if sync_error.code !=
		   .None {return 0, image_error_map(sync_error, last_sequence, wal.state.checkpoint)}
	}
	return last_sequence, {}
}

wal_checkpoint :: proc(wal: ^Wal, image: ^fat32image.Image, sequence: u64) -> Session_Error {
	if wal == nil || image == nil {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			sequence,
			0,
			"FAT32 checkpoint has no open image",
		)
	}
	sync_error := fat32image.sync(image)
	if sync_error.code !=
	   .None {return image_error_map(sync_error, sequence, wal.state.checkpoint)}
	crash_point(.Image_Synced)
	state_error := state_save(wal, .Open, sequence)
	if state_error.code != .None {return state_error}
	crash_point(.Checkpoint_Saved)
	if os.truncate(wal.file, 0) != nil || os.sync(wal.file) != nil {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			sequence,
			wal.state.checkpoint,
			"FAT32 redo log could not be retired",
		)
	}
	wal.offset = 0
	crash_point(.Wal_Truncated)
	return {}
}

wal_mark_clean :: proc(wal: ^Wal, sequence: u64) -> Session_Error {
	err := state_save(wal, .Clean_Pending, sequence)
	if err.code == .None {crash_point(.State_Clean)}
	return err
}

wal_finalize_clean :: proc(wal: ^Wal, sequence: u64) -> Session_Error {
	return state_save(wal, .Clean, sequence)
}

wal_resume_open :: proc(wal: ^Wal, sequence: u64) -> Session_Error {
	if wal == nil ||
	   (wal.state.phase != .Prepared && wal.state.phase != .Clean_Pending) {return {}}
	return state_save(wal, .Open, sequence)
}

wal_cleanup_root :: proc(wal: ^Wal) {
	if wal == nil || wal.state_root == "" {return}
	_ = companion_directory_remove(wal.state_root)
}
