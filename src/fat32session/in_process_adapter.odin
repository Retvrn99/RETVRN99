// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import disk "../disk"
import fat32fs "../fat32fs"
import fat32image "../fat32image"
import "base:runtime"
import "core:fmt"
import "core:strings"

In_Process_Implementation :: struct {
	allocator:          runtime.Allocator,
	image_path:         string,
	machine_session_id: string,
	image:              ^fat32image.Image,
	wal:                Wal,
	sequence:           u64,
	durable_sequence:   u64,
	closed:             bool,
	frozen:             bool,
	last_error:         Session_Error,
}

open_in_process :: proc(
	image_path, machine_session_id: string,
) -> (
	^Machine_Session,
	Session_Error,
) {
	if image_path == "" || machine_session_id == "" {
		return nil, error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"image path and Machine session id are required",
		)
	}
	preflight, recovery_grade, validation_error := validate_image_for_session(image_path)
	if validation_error.code != .None {return nil, image_error_map(validation_error, 0, 0)}
	defer fat32image.info_destroy(&preflight)
	preflight_error := wal_preflight(&preflight)
	if preflight_error.code != .None {return nil, preflight_error}
	image, open_error := fat32image.open_staged(image_path, recovery_grade)
	if open_error.code != .None {return nil, image_error_map(open_error, 0, 0)}
	impl := new(In_Process_Implementation)
	impl.allocator = context.allocator
	impl.image_path = strings.clone(image_path)
	impl.machine_session_id = strings.clone(machine_session_id)
	impl.image = image
	if image.info.dirty != preflight.dirty ||
	   preflight.enrolled && image.info.image_id != preflight.image_id {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		in_process_destroy(impl)
		return nil, error_make(
			.State_Mismatch,
			false,
			.Retained,
			0,
			0,
			"hard-drive image changed between validation and lock acquisition",
		)
	}
	wal_error := wal_prepare(&impl.wal, image_path, image.info.image_id, image.info.dirty)
	if wal_error.code != .None {
		wal_error = in_process_wal_open_failure(impl, preflight.dirty, wal_error)
		in_process_destroy(impl)
		return nil, wal_error
	}
	if !preflight.dirty {crash_point(.Machine_State_Prepared)}
	activation_error := fat32image.activate(image)
	if activation_error.code != .None {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		in_process_destroy(impl)
		return nil, image_error_map(activation_error, 0, 0)
	}
	if !preflight.dirty {crash_point(.Machine_Marker_Dirty)}
	sequence, recovery_error := wal_recover(&impl.wal, image)
	if recovery_error.code != .None {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		in_process_destroy(impl)
		return nil, recovery_error
	}
	filesystem_error := fat32image.complete_recovery(image)
	if filesystem_error.code != .None {
		checkpoint := impl.wal.state.checkpoint
		diagnostic := strings.clone(
			fat32image.error_text(&filesystem_error),
			context.temp_allocator,
		)
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		in_process_destroy(impl)
		return nil, error_make(.FAT_Invalid, false, .Retained, sequence, checkpoint, diagnostic)
	}
	resume_error := wal_resume_open(&impl.wal, sequence)
	if resume_error.code != .None {
		_ = fat32image.close(image, .Retain)
		impl.image = nil
		in_process_destroy(impl)
		return nil, resume_error
	}
	impl.sequence = sequence
	impl.durable_sequence = impl.wal.state.checkpoint
	session := new(Machine_Session)
	session.ctx = impl
	session.adapter = .In_Process
	session.device = disk.Block_Device {
		ctx          = impl,
		sector_count = image.info.sector_count,
		read         = in_process_block_read,
		write        = in_process_block_write,
		flush        = in_process_block_flush,
	}
	session.operations = Machine_Operations {
		ready = in_process_ready,
		terminal_error = in_process_terminal_error,
		barrier = in_process_barrier,
		observe = in_process_observe,
		close = in_process_close,
		destroy = proc(ctx: rawptr) {in_process_destroy((^In_Process_Implementation)(ctx))},
	}
	return session, {}
}

@(private = "package")
in_process_wal_open_failure :: proc(
	impl: ^In_Process_Implementation,
	image_was_dirty: bool,
	wal_error: Session_Error,
) -> Session_Error {
	if impl == nil || impl.image == nil {return wal_error}
	if image_was_dirty {
		_ = fat32image.close(impl.image, .Retain)
		impl.image = nil
		return wal_error
	}
	restore_error := fat32image.close(impl.image, .Clean)
	if restore_error.code == .None {
		impl.image = nil
		if impl.wal.created_state_root {wal_cleanup_root(&impl.wal)}
		return wal_error
	}
	_ = fat32image.close(impl.image, .Retain)
	impl.image = nil
	value := wal_error
	return error_make(
		wal_error.code,
		false,
		.Uncertain,
		wal_error.sequence,
		wal_error.durable_sequence,
		fmt.tprintf(
			"%s; the original clean image marker could not be restored: %s",
			error_text(&value),
			fat32image.error_text(&restore_error),
		),
	)
}

@(private = "package")
in_process_freeze :: proc(impl: ^In_Process_Implementation, err: Session_Error) -> Session_Error {
	if impl == nil {return err}
	impl.frozen = true
	result := err
	if result.sequence == 0 {result.sequence = impl.sequence}
	if result.durable_sequence == 0 {result.durable_sequence = impl.durable_sequence}
	impl.last_error = result
	return result
}

in_process_ready :: proc(ctx: rawptr) -> bool {
	impl := (^In_Process_Implementation)(ctx)
	return impl != nil && !impl.closed && !impl.frozen && impl.image != nil
}

in_process_terminal_error :: proc(ctx: rawptr) -> (Session_Error, bool) {
	impl := (^In_Process_Implementation)(ctx)
	if impl == nil || !impl.frozen || impl.last_error.code == .None {return {}, false}
	return impl.last_error, true
}

@(private = "file")
in_process_backing_valid :: proc(impl: ^In_Process_Implementation) -> bool {
	if !in_process_ready(impl) {return false}
	if fat32image.backing_identity_matches(impl.image) {return true}
	_ = in_process_freeze(
		impl,
		error_make(
			.State_Mismatch,
			false,
			.Retained,
			impl.sequence,
			impl.durable_sequence,
			"hard-drive image backing file changed while locked",
		),
	)
	return false
}

in_process_block_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^In_Process_Implementation)(ctx)
	if !in_process_backing_valid(impl) {return false}
	read_error := fat32image.block_read(impl.image, lba, data)
	if read_error.code == .None {return true}
	_ = in_process_freeze(impl, image_error_map(read_error, impl.sequence, impl.durable_sequence))
	return false
}

in_process_block_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^In_Process_Implementation)(ctx)
	if !in_process_backing_valid(impl) {return false}
	ignored, validation_error := fat32image.validate_write(impl.image, lba, data)
	if validation_error.code != .None {
		_ = in_process_freeze(
			impl,
			image_error_map(validation_error, impl.sequence, impl.durable_sequence),
		)
		return false
	}
	if ignored {return true}
	sequence := impl.sequence + 1
	wal_error := wal_append(&impl.wal, sequence, lba, data)
	if wal_error.code != .None {
		_ = in_process_freeze(impl, wal_error)
		return false
	}
	write_error := fat32image.block_write(impl.image, lba, data)
	if write_error.code != .None {
		_ = in_process_freeze(impl, image_error_map(write_error, sequence, impl.durable_sequence))
		return false
	}
	impl.sequence = sequence
	crash_point(.Image_Applied)
	if wal_checkpoint_due(&impl.wal, impl.sequence) {
		checkpoint_error := wal_checkpoint(&impl.wal, impl.image, impl.sequence)
		if checkpoint_error.code != .None {
			_ = in_process_freeze(impl, checkpoint_error)
			return false
		}
		impl.durable_sequence = impl.sequence
	}
	return true
}

in_process_block_flush :: proc(ctx: rawptr) -> bool {
	_, err := in_process_barrier(ctx, .Block_Flush)
	return err.code == .None
}

in_process_barrier :: proc(
	ctx: rawptr,
	reason: Barrier_Reason,
) -> (
	Barrier_Result,
	Session_Error,
) {
	impl := (^In_Process_Implementation)(ctx)
	if impl == nil || impl.closed {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is closed")
	}
	if impl.frozen {return {}, impl.last_error}
	if !in_process_backing_valid(impl) {return {}, impl.last_error}
	checkpoint_error := wal_checkpoint(&impl.wal, impl.image, impl.sequence)
	if checkpoint_error.code != .None {
		return {}, in_process_freeze(impl, checkpoint_error)
	}
	impl.durable_sequence = impl.sequence
	result := Barrier_Result {
		sequence         = impl.sequence,
		durable_sequence = impl.durable_sequence,
		materialization  = .Pending,
	}
	if reason == .Block_Flush {return result, {}}
	filesystem_error := fat32image.materialize_filesystem(impl.image)
	if filesystem_error.code == .None {
		result.materialization = .Materialized
		return result, {}
	}
	if filesystem_error.code != .Invalid_FAT32 {
		return result, in_process_freeze(
			impl,
			image_error_map(filesystem_error, impl.sequence, impl.durable_sequence),
		)
	}
	if reason == .Observation {return result, {}}
	return result, error_make(
		.Observation_Pending,
		true,
		.Retained,
		impl.sequence,
		impl.durable_sequence,
		"FAT32 mirrors or recovery sectors do not yet form a coherent transaction",
	)
}

@(private = "file")
observation_error_map :: proc(
	err: fat32fs.Error,
	impl: ^In_Process_Implementation,
) -> Session_Error {
	code := Error_Code.Observation_IO
	retryable := false
	if err.code == .Invalid_FAT || err.code == .IO {
		code = .Observation_Pending
		retryable = true
	} else if err.code == .Invalid_Path {
		code = .Invalid_Argument
	}
	value := err
	return error_make(
		code,
		retryable,
		.Not_Started,
		impl.sequence,
		impl.durable_sequence,
		fat32fs.error_text(&value),
	)
}

in_process_observe :: proc(
	ctx: rawptr,
	probes: []Probe,
	allocator: runtime.Allocator,
) -> (
	Observation_Batch,
	Session_Error,
) {
	impl := (^In_Process_Implementation)(ctx)
	if impl == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is closed")
	}
	validation_error := observation_probes_validate(probes, impl.sequence, impl.durable_sequence)
	if validation_error.code != .None {return {}, validation_error}
	barrier_result, barrier_error := in_process_barrier(impl, .Observation)
	if barrier_error.code != .None {return {}, barrier_error}
	if barrier_result.materialization == .Pending {
		return Observation_Batch{barrier = barrier_result, pending = true}, {}
	}
	volume, fs_open_error := fat32fs.open(fat32image.block_device(impl.image))
	if fs_open_error.code != .None {
		err := observation_error_map(fs_open_error, impl)
		return Observation_Batch {
				barrier = barrier_result,
				pending = err.code == .Observation_Pending,
			},
			err
	}
	batch := Observation_Batch {
		barrier = barrier_result,
		items   = make([]Observation, len(probes), allocator),
	}
	for probe, index in probes {
		item := &batch.items[index]
		item.path = strings.clone(probe.path, allocator)
		file_stat, stat_error := fat32fs.stat(&volume, probe.path)
		if stat_error.code != .None {
			observation_batch_destroy(&batch, allocator)
			err := observation_error_map(stat_error, impl)
			return Observation_Batch {
					barrier = barrier_result,
					pending = err.code == .Observation_Pending,
				},
				err
		}
		if !file_stat.exists {
			item.type = .Missing
			continue
		}
		item.type = file_stat.is_directory ? .Directory : .Regular
		item.size = file_stat.size
		if probe.kind == .Stat || file_stat.is_directory {continue}
		read_result: fat32fs.Read_Result
		read_error: fat32fs.Error
		if probe.kind == .Read_Tail {
			read_result, read_error = fat32fs.read_tail(
				&volume,
				probe.path,
				probe.length,
				allocator,
			)
		} else {
			read_result, read_error = fat32fs.read_range(
				&volume,
				probe.path,
				probe.offset,
				probe.length,
				allocator,
			)
		}
		if read_error.code != .None {
			observation_batch_destroy(&batch, allocator)
			err := observation_error_map(read_error, impl)
			return Observation_Batch {
					barrier = barrier_result,
					pending = err.code == .Observation_Pending,
				},
				err
		}
		item.offset = read_result.offset
		item.data = read_result.data
		read_result.data = nil
	}
	return batch, {}
}

in_process_close :: proc(ctx: rawptr, mode: Close_Mode) -> Session_Error {
	impl := (^In_Process_Implementation)(ctx)
	if impl == nil ||
	   impl.closed {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is already closed")}
	if mode == .Retain {
		result: fat32image.Image_Error
		if impl.image != nil {
			result = fat32image.close(impl.image, .Retain)
			impl.image = nil
		}
		impl.closed = true
		return image_error_map(result, impl.sequence, impl.durable_sequence)
	}
	if impl.frozen {return impl.last_error}
	_, barrier_error := in_process_barrier(impl, .Clean_Close)
	if barrier_error.code != .None {return barrier_error}
	state_error := wal_mark_clean(&impl.wal, impl.sequence)
	if state_error.code != .None {return in_process_freeze(impl, state_error)}
	close_error := fat32image.close(impl.image, .Clean)
	if close_error.code != .None {
		return in_process_freeze(
			impl,
			image_error_map(close_error, impl.sequence, impl.durable_sequence),
		)
	}
	impl.image = nil
	finalize_error := wal_finalize_clean(&impl.wal, impl.sequence)
	if finalize_error.code != .None {
		return in_process_freeze(impl, finalize_error)
	}
	root := strings.clone(impl.wal.state_root, context.temp_allocator)
	wal_close(&impl.wal)
	impl.closed = true
	if !companion_directory_remove(root) {
		return error_make(
			.Wal_IO,
			true,
			.Completed,
			impl.sequence,
			impl.durable_sequence,
			"FAT32 Machine completed but its companion state could not be retired",
		)
	}
	return {}
}

in_process_destroy :: proc(impl: ^In_Process_Implementation) {
	if impl == nil {return}
	if impl.image != nil {_ = fat32image.close(impl.image, .Retain)}
	wal_close(&impl.wal)
	delete(impl.image_path, impl.allocator)
	delete(impl.machine_session_id, impl.allocator)
	free(impl, impl.allocator)
}

in_process_runtime_error :: proc(
	impl: ^In_Process_Implementation,
	diagnostic: string,
) -> Session_Error {
	if impl != nil && impl.last_error.code != .None {return impl.last_error}
	if impl == nil {return error_make(.Internal, false, .Uncertain, 0, 0, diagnostic)}
	return error_make(
		.Internal,
		false,
		.Uncertain,
		impl.sequence,
		impl.durable_sequence,
		fmt.tprintf("%s", diagnostic),
	)
}
