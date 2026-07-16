// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32edit "../fat32edit"
import fat32image "../fat32image"
import "base:runtime"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

EDIT_OWNER_MAGIC :: "R99EDOWN"
EDIT_OWNER_VERSION :: u16(4)
EDIT_OWNER_BYTES :: 64
EDIT_OWNER_CRC_OFFSET :: 56

Edit_Owner_Phase :: enum u8 {
	Open = 1,
	Applying,
	Clean_Pending,
	Completed,
	Prepared,
}

Edit_Owner :: struct {
	valid:              bool,
	restore_unenrolled: bool,
	adopt_requested:    bool,
	phase:              Edit_Owner_Phase,
	epoch:              u64,
	transaction:        u64,
	sector_count:       u64,
	image_id:           fat32image.Image_Id,
}

Edit_In_Process_Implementation :: struct {
	allocator:              runtime.Allocator,
	image_path:             string,
	session_id:             string,
	state_root:             string,
	boundary:               Companion_Boundary,
	image:                  ^fat32image.Image,
	edit:                   fat32edit.Edit_Session,
	job:                    ^fat32edit.Step_Job,
	apply_job:              fat32edit.Apply_Job,
	apply_progress:         fat32edit.Apply_Progress,
	apply_active:           bool,
	apply_finishing:        bool,
	apply_evidence_retired: bool,
	owner:                  Edit_Owner,
	adoption:               Edit_Adoption_Evidence,
	unenrolled_marker:      fat32image.Unenrolled_Marker_Snapshot,
	closed:                 bool,
	frozen:                 bool,
	last_error:             Session_Error,
}

@(private = "file")
edit_owner_encode :: proc(owner: Edit_Owner) -> (data: [EDIT_OWNER_BYTES]u8) {
	copy(data[:8], EDIT_OWNER_MAGIC)
	put_u16le(data[:], 8, EDIT_OWNER_VERSION)
	data[10] = u8(owner.phase)
	if owner.restore_unenrolled {data[11] = 1}
	if owner.adopt_requested {data[11] |= 2}
	put_u64le(data[:], 16, owner.transaction)
	put_u64le(data[:], 24, owner.sector_count)
	image_id := owner.image_id
	copy(data[32:48], image_id[:])
	put_u64le(data[:], 48, owner.epoch)
	put_u32le(data[:], EDIT_OWNER_CRC_OFFSET, hash.crc32(data[:]))
	return
}

@(private = "file")
edit_owner_decode :: proc(data: []u8) -> Edit_Owner {
	version := get_u16le(data, 8)
	if len(data) != EDIT_OWNER_BYTES ||
	   string(data[:8]) != EDIT_OWNER_MAGIC ||
	   (version != 3 && version != EDIT_OWNER_VERSION) ||
	   data[11] & (version == 3 ? u8(0xfe) : u8(0xfc)) != 0 ||
	   (data[10] != u8(Edit_Owner_Phase.Open) &&
			   data[10] != u8(Edit_Owner_Phase.Applying) &&
			   data[10] != u8(Edit_Owner_Phase.Clean_Pending) &&
			   data[10] != u8(Edit_Owner_Phase.Completed) &&
			   data[10] != u8(Edit_Owner_Phase.Prepared)) {
		return {}
	}
	want := get_u32le(data, EDIT_OWNER_CRC_OFFSET)
	copy_data: [EDIT_OWNER_BYTES]u8
	copy(copy_data[:], data)
	put_u32le(copy_data[:], EDIT_OWNER_CRC_OFFSET, 0)
	if hash.crc32(copy_data[:]) != want {return {}}
	owner := Edit_Owner {
		valid              = true,
		restore_unenrolled = data[11] & 1 != 0,
		adopt_requested    = version >= 4 && data[11] & 2 != 0,
		phase              = Edit_Owner_Phase(data[10]),
		epoch              = get_u64le(data, 48),
		transaction        = get_u64le(data, 16),
		sector_count       = get_u64le(data, 24),
	}
	copy(owner.image_id[:], data[32:48])
	if owner.epoch == 0 || owner.transaction == 0 || owner.sector_count == 0 {return {}}
	return owner
}

@(private = "file")
edit_unenrolled_snapshot_from_info :: proc(
	info: ^fat32image.Image_Info,
) -> fat32image.Unenrolled_Marker_Snapshot {
	if info == nil {return {}}
	return {
		valid = true,
		marker_sector = info.marker_sector,
		sector_count = info.sector_count,
		partition_lba = info.partition_lba,
		partition_sectors = info.partition_sectors,
		reserved_sectors = info.reserved_sectors,
		sectors_per_cluster = info.sectors_per_cluster,
	}
}

@(private = "file")
edit_owner_path :: proc(
	root: string,
	slot: int,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	name := slot == 0 ? "edit-owner.a" : "edit-owner.b"
	path, path_error := filepath.join({root, name}, allocator)
	return path, path_error == nil
}

@(private = "file")
edit_owner_read_slot_boundary :: proc(
	directory: ^Companion_Boundary,
	slot: int,
) -> (
	Edit_Owner,
	bool,
) {
	name := slot == 0 ? "edit-owner.a" : "edit-owner.b"
	exists, safe, _ := companion_boundary_file_probe(directory, name)
	if !safe {return {}, false}
	if !exists {return {}, true}
	file, opened := companion_boundary_file_open(directory, name, {.Read})
	if !opened {return {}, false}
	defer os.close(file)
	data: [EDIT_OWNER_BYTES]u8
	size, size_error := os.file_size(file)
	if size_error != nil || size != EDIT_OWNER_BYTES ||
	   !file_read_exact_at(file, data[:], 0) {
		return {}, true
	}
	return edit_owner_decode(data[:]), true
}

@(private = "package")
edit_owner_load_boundary :: proc(directory: ^Companion_Boundary) -> (Edit_Owner, bool) {
	first, first_safe := edit_owner_read_slot_boundary(directory, 0)
	second, second_safe := edit_owner_read_slot_boundary(directory, 1)
	if !first_safe || !second_safe {return {}, false}
	if !first.valid && !second.valid {return {}, false}
	if !first.valid {return second, true}
	if !second.valid {return first, true}
	return first.epoch >= second.epoch ? first : second, true
}

@(private = "package")
edit_owner_load :: proc(root: string) -> (Edit_Owner, bool) {
	directory, opened := companion_boundary_open(root, context.temp_allocator)
	if !opened {return {}, false}
	defer companion_boundary_close(&directory, context.temp_allocator)
	return edit_owner_load_boundary(&directory)
}

@(private = "file")
edit_owner_save_boundary :: proc(
	directory: ^Companion_Boundary,
	owner: ^Edit_Owner,
	phase: Edit_Owner_Phase,
) -> Session_Error {
	if directory == nil || !directory.open || owner == nil {
		return error_make(
			.Wal_IO,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit ownership state is unavailable",
		)
	}
	next := owner^
	next.epoch += 1
	next.phase = phase
	next.valid = true
	name := next.epoch & 1 == 0 ? "edit-owner.a" : "edit-owner.b"
	data := edit_owner_encode(next)
	file, opened := companion_boundary_file_open(
		directory,
		name,
		{.Read, .Write, .Create, .Sync},
	)
	if !opened {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			0,
			0,
			"cannot open FAT32 Edit ownership state",
		)
	}
	ok :=
		os.truncate(file, 0) == nil &&
		file_write_exact_at(file, data[:], 0) &&
		os.sync(file) == nil
	close_error := os.close(file)
	if !ok || close_error != nil || !companion_boundary_sync(directory) {
		return error_make(
			.Wal_IO,
			false,
			.Uncertain,
			0,
			0,
			"cannot durably save FAT32 Edit ownership state",
		)
	}
	owner^ = next
	return {}
}

@(private = "file")
edit_owner_save :: proc(
	root: string,
	owner: ^Edit_Owner,
	phase: Edit_Owner_Phase,
) -> Session_Error {
	directory, opened := companion_boundary_open(root, context.temp_allocator)
	if !opened {
		return error_make(.Wal_IO, false, .Retained, 0, 0, "cannot bind FAT32 Edit ownership state")
	}
	defer companion_boundary_close(&directory, context.temp_allocator)
	return edit_owner_save_boundary(&directory, owner, phase)
}

@(private = "file")
edit_restore_unenrolled_image :: proc(
	info: ^fat32image.Image_Info,
	owner: ^Edit_Owner,
) -> Session_Error {
	if info == nil || owner == nil || !owner.restore_unenrolled {return {}}
	if !info.enrolled {
		info.dirty = false
		return {}
	}
	image, open_error := fat32image.open(info.path, .Read_Write)
	if open_error.code != .None {return image_error_map(open_error, 0, 0)}
	if image.info.image_id != owner.image_id || image.info.sector_count != owner.sector_count {
		_ = fat32image.close(image, .Retain)
		return error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image changed while restoring its pre-Edit enrollment state",
		)
	}
	snapshot := edit_unenrolled_snapshot_from_info(&image.info)
	restore_error := fat32image.restore_unenrolled_marker(image, &snapshot, owner.image_id)
	if restore_error.code != .None {
		_ = fat32image.close(image, .Retain)
		return image_error_map(restore_error, 0, 0)
	}
	close_error := fat32image.close(image, .Retain)
	if close_error.code != .None {return image_error_map(close_error, 0, 0)}
	info.enrolled = false
	info.dirty = false
	info.image_id = {}
	return {}
}

@(private = "package")
edit_completion_preflight :: proc(info: ^fat32image.Image_Info) -> (bool, Session_Error) {
	if info == nil || info.path == "" {return false, {}}
	root, root_ok := companion_path(info.path, context.temp_allocator)
	if !root_ok {return false, {}}
	root_exists, root_safe := companion_directory_probe(root)
	if !root_exists {return false, {}}
	if !root_safe || !companion_directory_prepare(root, false) {
		return true, error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 Edit companion state is not a safe local directory",
		)
	}
	owner, owner_ok := edit_owner_load(root)
	if !owner_ok {return false, {}}
	identity_matches :=
		owner.sector_count == info.sector_count &&
		(info.enrolled && owner.image_id == info.image_id ||
				owner.restore_unenrolled &&
					!info.enrolled &&
					(owner.phase == .Prepared ||
							owner.phase == .Clean_Pending ||
							owner.phase == .Completed))
	if !identity_matches {
		return true, error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image does not match its completed FAT32 Edit state",
		)
	}
	#partial switch owner.phase {
	case .Clean_Pending:
		if owner.restore_unenrolled {
			restore_error := edit_restore_unenrolled_image(info, &owner)
			if restore_error.code != .None {return true, restore_error}
		} else if info.dirty {
			image, open_error := fat32image.open(info.path, .Read_Write)
			if open_error.code != .None {return true, image_error_map(open_error, 0, 0)}
			if image.info.image_id != owner.image_id ||
			   image.info.sector_count != owner.sector_count {
				_ = fat32image.close(image, .Retain)
				return true, error_make(
					.State_Mismatch,
					false,
					.Retained,
					0,
					0,
					"hard-drive image changed while retiring FAT32 Edit state",
				)
			}
			if owner.adopt_requested {
				evidence, evidence_ok := edit_adoption_load(root)
				if !evidence_ok {
					_ = fat32image.close(image, .Retain)
					return true, error_make(
						.State_Mismatch,
						false,
						.Retained,
						0,
						0,
						"completed FAT32 adoption has no original boot-sector evidence",
					)
				}
				if evidence_error := edit_adoption_validate(&evidence, &owner, image);
				   evidence_error.code != .None {
					_ = fat32image.close(image, .Retain)
					return true, evidence_error
				}
				image.info.retvrn99_format = true
			}
			filesystem_error := fat32image.check_filesystem(image)
			if filesystem_error.code != .None {
				_ = fat32image.close(image, .Retain)
				return true, error_make(
					.FAT_Invalid,
					false,
					.Retained,
					0,
					0,
					fat32image.error_text(&filesystem_error),
				)
			}
			close_error := fat32image.close(image, .Clean)
			if close_error.code != .None {return true, image_error_map(close_error, 0, 0)}
			info.dirty = false
		}
		owner_error := edit_owner_save(root, &owner, .Completed)
		if owner_error.code != .None {return true, owner_error}
	case .Completed:
		if owner.restore_unenrolled {
			restore_error := edit_restore_unenrolled_image(info, &owner)
			if restore_error.code != .None {return true, restore_error}
		} else if info.dirty {
			return true, error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"dirty image disagrees with completed FAT32 Edit state",
			)
		}
	case:
		return false, {}
	}
	if !companion_directory_remove(root) {
		return true, error_make(
			.Wal_IO,
			true,
			.Completed,
			0,
			0,
			"cannot retire completed FAT32 Edit companion state",
		)
	}
	return true, {}
}

@(private = "file")
edit_error_map :: proc(err: fat32edit.Edit_Error) -> Session_Error {
	if err.code == .None {return {}}
	code := Error_Code.Image_IO
	#partial switch err.code {
	case .Invalid_Argument, .Invalid_Path, .Host_Path_Unsafe:
		code = .Invalid_Argument
	case .Name_Collision:
		code = .Name_Collision
	case .Invalid_State:
		code = .Invalid_State
	case .Not_Found:
		code = .Image_Missing
	case .State_Corrupt:
		code = .State_Mismatch
	case .Fat32:
		code = .FAT_Invalid
	case .Cancelled:
		return {}
	}
	value := err
	outcome := Operation_Outcome.Not_Started
	#partial switch err.outcome {
	case .Applied:
		outcome = .Completed
	case .Preserved:
		outcome = .Retained
	case .Uncertain:
		outcome = .Uncertain
	}
	return error_make(code, err.retryable, outcome, 0, 0, fat32edit.error_text(&value))
}

@(private = "file")
edit_apply_sink :: proc(image: ^fat32image.Image) -> fat32edit.Apply_Sink {
	return {ctx = image, write = proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
			return fat32image.edit_block_write((^fat32image.Image)(ctx), lba, data).code == .None
		}, flush = proc(ctx: rawptr) -> bool {
			return fat32image.sync((^fat32image.Image)(ctx)).code == .None
		}, phase = proc(_: rawptr, phase: fat32edit.Apply_Phase) {
			switch phase {
			case .Intent_Durable:
				return
			case .Image_Applied:
				crash_point(.Edit_Image_Applied)
			case .Image_Synced:
				crash_point(.Edit_Image_Synced)
			}
		}}
}

@(private = "file")
edit_apply_intent_present :: proc(
	directory: ^Companion_Boundary,
) -> (bool, Session_Error) {
	exists, safe := companion_boundary_child_file_probe(directory, "edit", "apply.intent")
	if !safe {
		return false, error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"FAT32 Apply intent is not a safe companion child",
		)
	}
	return exists, {}
}

@(private = "file")
edit_commit_apply_owner :: proc(impl: ^Edit_In_Process_Implementation) -> Session_Error {
	if impl == nil || !impl.owner.restore_unenrolled {return {}}
	impl.owner.restore_unenrolled = false
	owner_error := edit_owner_save_boundary(&impl.boundary, &impl.owner, .Applying)
	if owner_error.code != .None {impl.owner.restore_unenrolled = true}
	return owner_error
}

@(private = "file")
edit_recover_machine_for_open :: proc(
	image_path, session_id: string,
	info: ^fat32image.Image_Info,
) -> (
	bool,
	Session_Error,
) {
	if info == nil || !info.dirty {return false, {}}
	state_error := companion_state_validate(info)
	if state_error.code != .None {return false, state_error}
	root, root_ok := companion_path(image_path, context.temp_allocator)
	if !root_ok {
		return false, error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"cannot resolve FAT32 Machine recovery state",
		)
	}
	_, has_edit_owner := edit_owner_load(root)
	if has_edit_owner {return false, {}}
	machine, open_error := open_in_process(image_path, session_id)
	if open_error.code != .None {return false, open_error}
	close_error := close(machine, .Commit)
	if close_error.code != .None {
		if close_error.outcome != .Completed {_ = close(machine, .Retain)}
		return false, close_error
	}
	return true, {}
}

open_edit_in_process :: proc(
	image_path, session_id: string,
	requested_transaction: u64 = 0,
) -> (
	^Edit_Session,
	Session_Error,
) {
	if image_path == "" || session_id == "" {
		return nil, error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"image path and Edit session id are required",
		)
	}
	validated, recovery_grade, validation_error := validate_image_for_session(image_path)
	if validation_error.code != .None {return nil, image_error_map(validation_error, 0, 0)}
	defer fat32image.info_destroy(&validated)
	_, completion_error := edit_completion_preflight(&validated)
	if completion_error.code != .None {return nil, completion_error}
	previous_id := validated.image_id
	previous_sector_count := validated.sector_count
	recovered_machine, recovery_error := edit_recover_machine_for_open(
		image_path,
		session_id,
		&validated,
	)
	if recovery_error.code != .None {return nil, recovery_error}
	if recovered_machine {
		fat32image.info_destroy(&validated)
		validated, validation_error = fat32image.validate(image_path)
		if validation_error.code != .None {
			return nil, image_error_map(validation_error, 0, 0)
		}
		if validated.dirty ||
		   validated.image_id != previous_id ||
		   validated.sector_count != previous_sector_count {
			return nil, error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"FAT32 Machine recovery did not produce the same clean image",
			)
		}
	}
	root, root_ok := companion_path(image_path)
	if !root_ok {return nil, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "cannot resolve FAT32 Edit companion state")}
	boundary: Companion_Boundary
	defer companion_boundary_close(&boundary)
	owner: Edit_Owner
	if validated.dirty {
		if !companion_directory_prepare(root, false) {
			delete(root)
			return nil, error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"cannot secure the FAT32 Edit companion state directory",
			)
		}
		boundary, root_ok = companion_boundary_open(root)
		if root_ok {owner, root_ok = edit_owner_load_boundary(&boundary)}
		if !root_ok ||
		   owner.image_id != validated.image_id ||
		   owner.sector_count != validated.sector_count ||
		   requested_transaction != 0 && requested_transaction != owner.transaction {
			delete(root)
			return nil, error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"dirty image does not match its FAT32 Edit state",
			)
		}
	} else {
		preflight_error := wal_preflight(&validated)
		if preflight_error.code != .None {delete(root); return nil, preflight_error}
		if root_exists, root_safe := companion_directory_probe(root);
		   root_exists && (!root_safe || !companion_directory_remove(root)) {
			delete(root)
			return nil, error_make(
				.Wal_IO,
				true,
				.Not_Started,
				0,
				0,
				"cannot retire completed FAT32 companion state",
			)
		}
	}
	unenrolled_marker: fat32image.Unenrolled_Marker_Snapshot
	if !validated.enrolled {
		unenrolled_marker, validation_error = fat32image.capture_unenrolled_marker(&validated)
		if validation_error.code != .None {
			delete(root)
			return nil, image_error_map(validation_error, 0, 0)
		}
	}
	image, image_open_error := fat32image.open_staged(image_path, recovery_grade)
	if image_open_error.code != .None {
		delete(root)
		return nil, image_error_map(image_open_error, 0, 0)
	}
	impl := new(Edit_In_Process_Implementation)
	impl.allocator = context.allocator
	impl.image_path = strings.clone(image_path)
	impl.session_id = strings.clone(session_id)
	impl.state_root = root
	impl.boundary = boundary
	boundary = {}
	impl.image = image
	impl.unenrolled_marker = unenrolled_marker
	if image.info.dirty != validated.dirty ||
	   validated.enrolled && image.info.image_id != validated.image_id {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		edit_in_process_destroy(impl)
		return nil, error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image changed between validation and Edit lock acquisition",
		)
	}
	if validated.dirty {
		impl.owner = owner
		if owner.restore_unenrolled {
			impl.unenrolled_marker = edit_unenrolled_snapshot_from_info(&image.info)
		}
	} else {
		if !companion_directory_prepare(root, true) {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"cannot create or secure the FAT32 Edit companion state directory",
			)
		}
		impl.boundary, root_ok = companion_boundary_open(root)
		if !root_ok {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"cannot bind the new FAT32 Edit companion directory",
			)
		}
		transaction := requested_transaction
		if transaction == 0 {
			transaction = u64(time.now()._nsec) ~ u64(os.get_pid()) << 32
			if transaction == 0 {transaction = 1}
		}
		impl.owner = Edit_Owner {
			valid              = true,
			restore_unenrolled = unenrolled_marker.valid,
			phase              = .Open,
			transaction        = transaction,
			sector_count       = image.info.sector_count,
			image_id           = image.info.image_id,
		}
		owner_error := edit_owner_save_boundary(&impl.boundary, &impl.owner, .Prepared)
		if owner_error.code != .None {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, owner_error
		}
		crash_point(.Edit_Owner_Prepared)
	}
	if impl.owner.adopt_requested {
		evidence, evidence_ok := edit_adoption_load_boundary(&impl.boundary)
		if !evidence_ok {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, error_make(
				.State_Mismatch,
				false,
				.Retained,
				0,
				0,
				"pending FAT32 adoption has no original boot-sector evidence",
			)
		}
		if evidence_error := edit_adoption_validate(&evidence, &impl.owner, image);
		   evidence_error.code != .None {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, evidence_error
		}
		impl.adoption = evidence
		image.info.retvrn99_format = true
	}
	activation_error := fat32image.activate(image)
	if activation_error.code != .None {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		edit_in_process_destroy(impl)
		return nil, image_error_map(activation_error, 0, 0)
	}
	if !validated.dirty {crash_point(.Edit_Marker_Dirty)}
	apply_intent_present := false
	if impl.owner.phase == .Applying {
		intent_error: Session_Error
		apply_intent_present, intent_error = edit_apply_intent_present(&impl.boundary)
		if intent_error.code != .None {
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, intent_error
		}
		if apply_intent_present && impl.owner.restore_unenrolled {
			owner_error := edit_commit_apply_owner(impl)
			if owner_error.code != .None {
				_ = fat32image.close(image, .Retain)
				impl.image = nil
				edit_in_process_destroy(impl)
				return nil, owner_error
			}
		}
	}
	low_edit, low_error := fat32edit.open(
		fat32image.edit_block_device(image),
		root,
		impl.owner.transaction,
		edit_apply_sink(image),
	)
	if low_error.code != .None {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		edit_in_process_destroy(impl)
		return nil, edit_error_map(low_error)
	}
	impl.edit = low_edit
	allow_external_boot_layout := impl.owner.adopt_requested && !apply_intent_present
	filesystem_error := fat32image.complete_edit_recovery(image, allow_external_boot_layout)
	if apply_intent_present {
		filesystem_error = fat32image.complete_recovery(image, allow_external_boot_layout)
	}
	if filesystem_error.code != .None {
		_ = fat32edit.close_retain(&impl.edit)
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		edit_in_process_destroy(impl)
		return nil, error_make(
			.FAT_Invalid,
			false,
			.Retained,
			0,
			0,
			fat32image.error_text(&filesystem_error),
		)
	}
	if impl.owner.phase == .Prepared || impl.owner.phase == .Applying {
		owner_error := edit_owner_save_boundary(&impl.boundary, &impl.owner, .Open)
		if owner_error.code != .None {
			_ = fat32edit.close_retain(&impl.edit)
			_ = fat32image.close(image, .Retain)
			impl.image = nil
			edit_in_process_destroy(impl)
			return nil, owner_error
		}
	}
	session := new(Edit_Session)
	session.ctx = impl
	session.adapter = .In_Process
	session.operations = edit_in_process_operations()
	return session, {}
}

@(private = "file")
edit_in_process_operations :: proc() -> Edit_Operations {
	return {
		ready = edit_in_process_ready,
		transaction_id = proc(ctx: rawptr) -> u64 {return(
				(^Edit_In_Process_Implementation)(ctx).owner.transaction \
			)},
		changed_sector_count = proc(ctx: rawptr) -> u64 {return fat32edit.changed_sector_count(
				&(^Edit_In_Process_Implementation)(ctx).edit,
			)},
		list = edit_in_process_list,
		stat = edit_in_process_stat,
		read = edit_in_process_read,
		mkdir = edit_in_process_mkdir,
		rename = edit_in_process_rename,
		remove_recursive = edit_in_process_remove,
		begin_remove_recursive = edit_in_process_begin_remove,
		begin_import_file = edit_in_process_begin_import_file,
		begin_import_tree = edit_in_process_begin_import_tree,
		begin_export_file = edit_in_process_begin_export_file,
		job_step = edit_in_process_job_step,
		job_cancel = edit_in_process_job_cancel,
		adopt_image = edit_in_process_adopt_image,
		patch_boot_loader = edit_in_process_patch_boot_loader,
		restore_boot_loader = edit_in_process_restore_boot_loader,
		begin_apply = edit_in_process_begin_apply,
		step_apply = edit_in_process_step_apply,
		cancel_apply = edit_in_process_cancel_apply,
		apply = edit_in_process_apply,
		discard = edit_in_process_discard,
		close_retain = edit_in_process_close_retain,
		destroy = proc(ctx: rawptr) {edit_in_process_destroy(
				(^Edit_In_Process_Implementation)(ctx),
			)},
	}
}

edit_in_process_ready :: proc(ctx: rawptr) -> bool {
	impl := (^Edit_In_Process_Implementation)(ctx)
	return(
		impl != nil &&
		!impl.closed &&
		!impl.frozen &&
		!impl.apply_active &&
		impl.image != nil &&
		impl.edit.impl != nil \
	)
}

edit_in_process_list :: proc(
	ctx: rawptr,
	path: string,
	cursor: u64,
	limit: int,
	allocator: runtime.Allocator,
) -> (
	Edit_Page,
	Session_Error,
) {
	page, err := fat32edit.list(
		&(^Edit_In_Process_Implementation)(ctx).edit,
		path,
		cursor,
		limit,
		allocator,
	)
	return page, edit_error_map(err)
}

edit_in_process_stat :: proc(ctx: rawptr, path: string) -> (Edit_Stat, Session_Error) {
	info, err := fat32edit.stat(&(^Edit_In_Process_Implementation)(ctx).edit, path)
	return info, edit_error_map(err)
}

edit_in_process_read :: proc(
	ctx: rawptr,
	path: string,
	offset, length: u64,
	allocator: runtime.Allocator,
) -> (
	Edit_Read_Result,
	Session_Error,
) {
	result, err := fat32edit.read_range(
		&(^Edit_In_Process_Implementation)(ctx).edit,
		path,
		offset,
		length,
		allocator,
	)
	return result, edit_error_map(err)
}

edit_in_process_mkdir :: proc(ctx: rawptr, path: string) -> Session_Error {
	return edit_error_map(fat32edit.mkdir(&(^Edit_In_Process_Implementation)(ctx).edit, path))
}

edit_in_process_rename :: proc(ctx: rawptr, source, destination: string) -> Session_Error {
	return edit_error_map(
		fat32edit.rename(&(^Edit_In_Process_Implementation)(ctx).edit, source, destination),
	)
}

edit_in_process_remove :: proc(ctx: rawptr, path: string) -> Session_Error {
	return edit_error_map(
		fat32edit.remove_recursive(&(^Edit_In_Process_Implementation)(ctx).edit, path),
	)
}

@(private = "file")
edit_in_process_job_begin :: proc(
	impl: ^Edit_In_Process_Implementation,
	job: fat32edit.Step_Job,
	err: fat32edit.Edit_Error,
) -> Session_Error {
	if err.code != .None {return edit_error_map(err)}
	if impl.job != nil {
		unused_job := job
		fat32edit.job_destroy(&unused_job)
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"another FAT32 Edit job is active",
		)
	}
	impl.job = new(fat32edit.Step_Job)
	impl.job^ = job
	return {}
}

edit_in_process_begin_import_file :: proc(
	ctx: rawptr,
	host_source, guest_destination: string,
	replace: bool,
) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	job, err := fat32edit.begin_import_file(&impl.edit, host_source, guest_destination, replace)
	return edit_in_process_job_begin(impl, job, err)
}

edit_in_process_begin_import_tree :: proc(
	ctx: rawptr,
	host_source, guest_destination: string,
	replace: bool,
) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	job, err := fat32edit.begin_import_tree(&impl.edit, host_source, guest_destination, replace)
	return edit_in_process_job_begin(impl, job, err)
}

edit_in_process_begin_export_file :: proc(
	ctx: rawptr,
	guest_source, host_destination: string,
) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	job, err := fat32edit.begin_export_file(&impl.edit, guest_source, host_destination)
	return edit_in_process_job_begin(impl, job, err)
}

edit_in_process_job_step :: proc(ctx: rawptr) -> (Edit_Job_Progress, Session_Error) {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil ||
	   impl.job ==
		   nil {return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "no FAT32 Edit job is active")}
	progress := fat32edit.job_step(impl.job)
	if progress.state == .Failed {return progress, edit_error_map(fat32edit.job_error(impl.job))}
	if progress.state == .Complete || progress.state == .Cancelled {
		fat32edit.job_destroy(impl.job)
		free(impl.job)
		impl.job = nil
	}
	return progress, {}
}

edit_in_process_job_cancel :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.job == nil {return {}}
	err := fat32edit.job_cancel(impl.job)
	fat32edit.job_destroy(impl.job)
	free(impl.job)
	impl.job = nil
	if err.code == .Cancelled {return {}}
	return edit_error_map(err)
}

edit_in_process_adopt_image :: proc(ctx: rawptr) -> (Edit_Adoption_Result, Session_Error) {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.image == nil || impl.job != nil || impl.apply_active {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit job must finish before image adoption",
		)
	}
	if impl.image.info.retvrn99_format && !impl.owner.adopt_requested {
		return Edit_Adoption_Result{image_identity = impl.image.info.image_id}, {}
	}
	if !impl.owner.adopt_requested {
		pair, pair_error := fat32image.prepare_adoption_boot_pair(impl.image)
		if pair_error.code != .None {return {}, image_error_map(pair_error, 0, 0)}
		if evidence_error := edit_adoption_save_boundary(&impl.boundary, &impl.owner, &pair);
		   evidence_error.code != .None {
			return {}, evidence_error
		}
		crash_point(.Edit_Adoption_Evidence)
		evidence, evidence_ok := edit_adoption_load_boundary(&impl.boundary)
		if !evidence_ok {
			return {}, error_make(
				.State_Mismatch,
				false,
				.Uncertain,
				0,
				0,
				"durable FAT32 adoption evidence cannot be reloaded",
			)
		}
		impl.adoption = evidence
		impl.owner.adopt_requested = true
		owner_error := edit_owner_save_boundary(&impl.boundary, &impl.owner, .Open)
		if owner_error.code != .None {
			impl.owner.adopt_requested = false
			return {}, owner_error
		}
		crash_point(.Edit_Adoption_Owner)
	}
	if evidence_error := edit_adoption_validate(&impl.adoption, &impl.owner, impl.image);
	   evidence_error.code != .None {
		return {}, evidence_error
	}
	impl.image.info.retvrn99_format = true
	primary_lba, backup_lba, primary, backup, patch_error :=
		fat32image.prepare_adoption_boot_loader_patch(
			impl.image,
			impl.adoption.original_primary[:],
			0,
			0,
		)
	if patch_error.code != .None {return {}, image_error_map(patch_error, 0, 0)}
	stage_error := fat32edit.stage_boot_loader_pair(
		&impl.edit,
		primary_lba,
		backup_lba,
		primary[:],
		backup[:],
	)
	if stage_error.code != .None {return {}, edit_error_map(stage_error)}
	crash_point(.Edit_Adoption_Staged)
	return Edit_Adoption_Result {
		image_identity = impl.image.info.image_id,
		staged         = true,
	}, {}
}

edit_in_process_patch_boot_loader :: proc(
	ctx: rawptr,
	io_sys_cluster: u32,
) -> (
	Boot_Target,
	Session_Error,
) {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.image == nil || impl.job != nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit job must finish before boot-loader patching")
	}
	geometry := &impl.image.geometry
	if io_sys_cluster < 2 || io_sys_cluster >= geometry.cluster_count + 2 {
		return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "IO.SYS cluster is outside the FAT32 image")
	}
	io_short := [11]u8{'I', 'O', ' ', ' ', ' ', ' ', ' ', ' ', 'S', 'Y', 'S'}
	in_first_root, root_error := fat32edit.boot_entry_in_first_root_cluster(
		&impl.edit,
		io_short,
		io_sys_cluster,
	)
	if root_error.code != .None {return {}, edit_error_map(root_error)}
	if !in_first_root {
		return {}, error_make(
			.FAT_Invalid,
			false,
			.Not_Started,
			0,
			0,
			"IO.SYS is not addressable from the bounded first root-directory cluster",
		)
	}
	lba :=
		u64(geometry.partition_lba) +
		u64(geometry.data_start) +
		u64(io_sys_cluster - 2) * u64(geometry.sectors_per_cluster)
	primary_lba, backup_lba: u64
	primary, backup: [fat32image.SECTOR_BYTES]u8
	patch_error: fat32image.Image_Error
	if impl.owner.adopt_requested {
		primary_lba, backup_lba, primary, backup, patch_error =
			fat32image.prepare_adoption_boot_loader_patch(
				impl.image,
				impl.adoption.original_primary[:],
				lba,
				io_sys_cluster,
			)
	} else {
		primary_lba, backup_lba, primary, backup, patch_error =
			fat32image.prepare_boot_loader_patch(
				impl.image,
				lba,
				io_sys_cluster,
			)
	}
	if patch_error.code != .None {return {}, image_error_map(patch_error, 0, 0)}
	stage_error := fat32edit.stage_boot_loader_pair(
		&impl.edit,
		primary_lba,
		backup_lba,
		primary[:],
		backup[:],
	)
	if stage_error.code != .None {return {}, edit_error_map(stage_error)}
	return Boot_Target{first_cluster = io_sys_cluster, lba = lba}, {}
}

edit_in_process_restore_boot_loader :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.image == nil || impl.job != nil {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit job must finish before boot-loader restoration",
		)
	}
	primary_lba, backup_lba, primary, backup, restore_error :=
		fat32image.prepare_boot_stub_restore(impl.image)
	if restore_error.code != .None {return image_error_map(restore_error, 0, 0)}
	return edit_error_map(
		fat32edit.stage_boot_loader_pair(
			&impl.edit,
			primary_lba,
			backup_lba,
			primary[:],
			backup[:],
		),
	)
}

@(private = "file")
edit_in_process_finish_image :: proc(
	impl: ^Edit_In_Process_Implementation,
	retire_apply_evidence: bool,
) -> Session_Error {
	filesystem_error := fat32image.check_filesystem_compatible(impl.image)
	if retire_apply_evidence {filesystem_error = fat32image.check_filesystem(impl.image)}
	if filesystem_error.code != .None {
		return error_make(
			.FAT_Invalid,
			false,
			.Retained,
			0,
			0,
			fat32image.error_text(&filesystem_error),
		)
	}
	owner_error: Session_Error
	if impl.owner.phase != .Clean_Pending {
		owner_error = edit_owner_save_boundary(&impl.boundary, &impl.owner, .Clean_Pending)
		if owner_error.code != .None {return owner_error}
	}
	crash_point(.Edit_Clean_Pending)
	if retire_apply_evidence && !impl.apply_evidence_retired {
		retire_error := fat32edit.retire_applied(impl.state_root, impl.owner.transaction)
		if retire_error.code != .None {return edit_error_map(retire_error)}
		impl.apply_evidence_retired = true
		crash_point(.Edit_Evidence_Retired)
	}
	close_mode := fat32image.Close_Mode.Clean_Compatible
	if retire_apply_evidence {close_mode = .Clean}
	if impl.owner.restore_unenrolled {
		restore_error := fat32image.restore_unenrolled_marker(
			impl.image,
			&impl.unenrolled_marker,
			impl.owner.image_id,
		)
		if restore_error.code != .None {return image_error_map(restore_error, 0, 0)}
		close_mode = .Retain
	}
	close_error := fat32image.close(impl.image, close_mode)
	if close_error.code != .None {return image_error_map(close_error, 0, 0)}
	impl.image = nil
	crash_point(.Edit_Marker_Clean)
	owner_error = edit_owner_save_boundary(&impl.boundary, &impl.owner, .Completed)
	if owner_error.code != .None {return owner_error}
	impl.closed = true
	crash_point(.Edit_Completed)
	crash_point(.Edit_Cleanup)
	companion_boundary_close(&impl.boundary)
	if !companion_directory_remove(impl.state_root) {
		return error_make(
			.Wal_IO,
			true,
			.Completed,
			0,
			0,
			"FAT32 Edit completed but its companion state could not be retired",
		)
	}
	return {}
}

edit_in_process_apply :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.job != nil || impl.apply_active {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit job must finish before Apply",
		)
	}
	_, begin_error := edit_in_process_begin_apply(ctx)
	if begin_error.code != .None {return begin_error}
	for impl.apply_active {
		progress, step_error := edit_in_process_step_apply(ctx)
		if step_error.code != .None {return step_error}
		if progress.state == .Complete {break}
	}
	return {}
}

edit_in_process_begin_remove :: proc(ctx: rawptr, path: string) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	job, err := fat32edit.begin_remove_recursive(&impl.edit, path)
	return edit_in_process_job_begin(impl, job, err)
}

edit_in_process_begin_apply :: proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error) {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || impl.job != nil || impl.apply_active {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "another FAT32 Edit job is active")
	}
	primary_lba, backup_lba, primary, backup, fsinfo_changed, fsinfo_error :=
		fat32image.prepare_fsinfo_mirror(impl.image)
	if fsinfo_error.code != .None {return {}, image_error_map(fsinfo_error, 0, 0)}
	if fsinfo_changed {
		stage_error := fat32edit.stage_fsinfo_pair(
			&impl.edit,
			primary_lba,
			backup_lba,
			primary[:],
			backup[:],
		)
		if stage_error.code != .None {return {}, edit_error_map(stage_error)}
	}
	job, begin_error := fat32edit.begin_apply(&impl.edit)
	if begin_error.code != .None {return {}, edit_error_map(begin_error)}
	impl.apply_job = job
	impl.apply_progress = fat32edit.apply_progress(&impl.apply_job)
	impl.apply_active = true
	return impl.apply_progress, {}
}

edit_in_process_step_apply :: proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error) {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || !impl.apply_active {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit Apply is not active")
	}
	if impl.apply_finishing {
		finish_error := edit_in_process_finish_image(impl, true)
		if finish_error.code != .None {return impl.apply_progress, finish_error}
		impl.apply_active = false
		impl.apply_finishing = false
		return impl.apply_progress, {}
	}
	was_ready := impl.apply_job.state == .Ready
	if was_ready {
		owner_error := edit_owner_save_boundary(&impl.boundary, &impl.owner, .Applying)
		if owner_error.code != .None {return impl.apply_progress, owner_error}
		crash_point(.Edit_Owner_Applying)
	} else if impl.apply_job.irreversible && impl.owner.restore_unenrolled {
		owner_error := edit_commit_apply_owner(impl)
		if owner_error.code != .None {return impl.apply_progress, owner_error}
	}
	progress, step_error := fat32edit.apply_step(&impl.apply_job)
	impl.apply_progress = progress
	if step_error.code != .None {return progress, edit_error_map(step_error)}
	if was_ready {
		owner_error := edit_commit_apply_owner(impl)
		if owner_error.code != .None {return progress, owner_error}
		crash_point(.Edit_Intent_Durable)
	}
	if progress.state != .Complete {return progress, {}}
	fat32edit.apply_job_destroy(&impl.apply_job)
	impl.apply_finishing = true
	crash_point(.Edit_Apply_Ready)
	finish_error := edit_in_process_finish_image(impl, true)
	if finish_error.code != .None {return progress, finish_error}
	impl.apply_active = false
	impl.apply_finishing = false
	return progress, {}
}

edit_in_process_cancel_apply :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil || !impl.apply_active || impl.apply_finishing {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply is not cancellable",
		)
	}
	cancel_error := fat32edit.apply_cancel(&impl.apply_job)
	if cancel_error.code != .Cancelled {return edit_error_map(cancel_error)}
	fat32edit.apply_job_destroy(&impl.apply_job)
	impl.apply_active = false
	impl.apply_progress = {}
	return {}
}

edit_in_process_discard :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil ||
	   impl.apply_active ||
	   impl.job !=
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit job must finish before Discard")}
	discard_error := fat32edit.discard(&impl.edit)
	if discard_error.code != .None {return edit_error_map(discard_error)}
	if impl.owner.adopt_requested {
		impl.owner.adopt_requested = false
		impl.image.info.retvrn99_format = false
		impl.adoption = {}
	}
	crash_point(.Edit_Discarded)
	return edit_in_process_finish_image(impl, false)
}

edit_in_process_close_retain :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_In_Process_Implementation)(ctx)
	if impl == nil {return {}}
	if impl.image == nil {
		impl.closed = true
		return {}
	}
	if impl.job != nil {_ = edit_in_process_job_cancel(impl)}
	if impl.apply_active {
		fat32edit.apply_job_destroy(&impl.apply_job)
		impl.apply_active = false
	}
	edit_error := fat32edit.close_retain(&impl.edit)
	if edit_error.code != .None {return edit_error_map(edit_error)}
	image_error := fat32image.close(impl.image, .Retain)
	impl.image = nil
	impl.closed = true
	return image_error_map(image_error, 0, 0)
}

edit_in_process_destroy :: proc(impl: ^Edit_In_Process_Implementation) {
	if impl == nil {return}
	if impl.job != nil {
		_ = fat32edit.job_cancel(impl.job)
		fat32edit.job_destroy(impl.job)
		free(impl.job)
	}
	if impl.apply_active {fat32edit.apply_job_destroy(&impl.apply_job)}
	if impl.edit.impl != nil {_ = fat32edit.close_retain(&impl.edit)}
	if impl.image != nil {_ = fat32image.close(impl.image, .Retain)}
	delete(impl.image_path)
	delete(impl.session_id)
	companion_boundary_close(&impl.boundary)
	delete(impl.state_root)
	free(impl)
}
