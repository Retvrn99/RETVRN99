// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import companionio "../companionio"
import disk "../disk"
import "core:hash"
import "core:os"

EDIT_META_BYTES :: 48
APPLY_INTENT_BYTES :: 56
TRANSACTION_VERSION :: u16(1)
EDIT_META_MAGIC :: "R99EDT01"
APPLY_INTENT_MAGIC :: "R99APY01"

@(private = "package")
open_edit_meta :: proc(impl: ^Edit_Impl, requested, generated: u64) -> Edit_Error {
	if impl == nil ||
	   impl.meta_path == "" {return error_make(.Internal, "edit metadata path is unavailable")}
	meta_exists, meta_safe, _ := companionio.probe_file(&impl.edit_boundary, "edit.meta")
	if !meta_safe {
		return error_make(.State_Corrupt, "FAT32 edit metadata is not a safe regular file")
	}
	if meta_exists {
		file, _, status := companionio.open_file(&impl.edit_boundary, "edit.meta", {.Read})
		if status != .None {return error_make(.State_Corrupt, "cannot open FAT32 edit metadata")}
		data: [EDIT_META_BYTES]u8
		ok := read_exact_at(file, data[:], 0)
		_ = os.close(file)
		if !ok ||
		   !validate_transaction_header(data[:], EDIT_META_MAGIC, EDIT_META_BYTES) ||
		   get_u64le(data[:], 24) != impl.base.sector_count ||
		   get_u64le(data[:], 32) != impl.bitmap_bytes {
			return error_make(
				.State_Corrupt,
				"FAT32 edit metadata is invalid or belongs to another image size",
			)
		}
		impl.transaction_id = get_u64le(data[:], 16)
		if impl.transaction_id == 0 || requested != 0 && requested != impl.transaction_id {
			return error_make(.Invalid_State, "FAT32 edit transaction identity does not match")
		}
		return {}
	}
	transaction := requested
	if transaction == 0 {transaction = generated}
	if transaction == 0 {transaction = 1}
	data: [EDIT_META_BYTES]u8
	copy(data[:8], EDIT_META_MAGIC)
	put_u16le(data[:], 8, TRANSACTION_VERSION)
	put_u16le(data[:], 10, EDIT_META_BYTES)
	put_u64le(data[:], 16, transaction)
	put_u64le(data[:], 24, impl.base.sector_count)
	put_u64le(data[:], 32, impl.bitmap_bytes)
	put_u32le(data[:], 12, hash.crc32(data[:]))
	file, _, status := companionio.open_file(
		&impl.edit_boundary,
		"edit.meta",
		{.Write, .Create, .Excl, .Sync},
	)
	if status != .None {return error_make(.Open_Failed, "cannot create FAT32 edit metadata")}
	ok := write_exact_at(file, data[:], 0) && os.sync(file) == nil
	close_error := os.close(file)
	if !ok || close_error != nil || !companionio.sync_directory(&impl.edit_boundary) {
		return error_make(.Sync_Failed, "cannot durably create FAT32 edit metadata")
	}
	impl.transaction_id = transaction
	return {}
}

@(private = "package")
validate_transaction_header :: proc(data: []u8, magic: string, expected_size: int) -> bool {
	if len(data) != expected_size ||
	   len(magic) != 8 ||
	   string(data[:8]) != magic ||
	   get_u16le(data, 8) != TRANSACTION_VERSION ||
	   int(get_u16le(data, 10)) != expected_size {
		return false
	}
	want := get_u32le(data, 12)
	copy_data: [APPLY_INTENT_BYTES]u8
	copy(copy_data[:expected_size], data)
	put_u32le(copy_data[:], 12, 0)
	return hash.crc32(copy_data[:expected_size]) == want
}

@(private = "package")
write_apply_intent :: proc(impl: ^Edit_Impl) -> Edit_Error {
	data: [APPLY_INTENT_BYTES]u8
	copy(data[:8], APPLY_INTENT_MAGIC)
	put_u16le(data[:], 8, TRANSACTION_VERSION)
	put_u16le(data[:], 10, APPLY_INTENT_BYTES)
	put_u64le(data[:], 16, impl.transaction_id)
	put_u64le(data[:], 24, impl.base.sector_count)
	put_u64le(data[:], 32, impl.bitmap_bytes)
	put_u64le(data[:], 40, impl.dirty_sectors)
	put_u32le(data[:], 12, hash.crc32(data[:]))
	file, _, status := companionio.open_file(
		&impl.edit_boundary,
		"apply.intent",
		{.Write, .Create, .Excl, .Sync},
	)
	if status !=
	   .None {return error_make(.State_Corrupt, "FAT32 Apply intent already exists or cannot be created")}
	ok := write_exact_at(file, data[:], 0) && os.sync(file) == nil
	close_error := os.close(file)
	if !ok || close_error != nil || !companionio.sync_directory(&impl.edit_boundary) {
		return error_make(
			.Sync_Failed,
			"cannot durably persist the FAT32 Apply intent",
			false,
			.Uncertain,
		)
	}
	return {}
}

@(private = "package")
flush_apply_run :: proc(
	sink: Apply_Sink,
	overlay_file: ^os.File,
	start_lba: u64,
	sector_count: int,
	buffer: []u8,
) -> bool {
	if sector_count == 0 {return true}
	bytes := sector_count * SECTOR_BYTES
	return(
		read_exact_at(overlay_file, buffer[:bytes], i64(start_lba * SECTOR_BYTES)) &&
		sink.write(sink.ctx, start_lba, buffer[:bytes]) \
	)
}

@(private = "package")
apply_overlay_files :: proc(
	sink: Apply_Sink,
	overlay_file, bitmap_file: ^os.File,
	sector_count, bitmap_bytes, expected_dirty: u64,
) -> Edit_Error {
	if sink.ctx == nil ||
	   sink.write == nil ||
	   sink.flush == nil ||
	   overlay_file == nil ||
	   bitmap_file == nil {
		return error_make(.Invalid_Argument, "FAT32 Apply storage is unavailable")
	}
	bitmap: [BITMAP_CACHE_BYTES]u8
	data: [MAX_TRANSFER_BYTES]u8
	run_start: u64
	run_count := 0
	found: u64
	for bitmap_offset := u64(0);
	    bitmap_offset < bitmap_bytes;
	    bitmap_offset += BITMAP_CACHE_BYTES {
		used := int(min(u64(BITMAP_CACHE_BYTES), bitmap_bytes - bitmap_offset))
		if !read_exact_at(bitmap_file, bitmap[:used], i64(bitmap_offset)) {
			return error_make(
				.State_Corrupt,
				"cannot read the FAT32 Apply presence bitmap",
				false,
				.Uncertain,
			)
		}
		for byte_value, byte_index in bitmap[:used] {
			if byte_value == 0 {continue}
			for bit in 0 ..< 8 {
				if byte_value & (u8(1) << u8(bit)) == 0 {continue}
				lba := (bitmap_offset + u64(byte_index)) * 8 + u64(bit)
				if lba >= sector_count {
					return error_make(
						.State_Corrupt,
						"FAT32 Apply bitmap references a sector outside the image",
						false,
						.Uncertain,
					)
				}
				found += 1
				if run_count == 0 {
					run_start = lba
					run_count = 1
				} else if lba == run_start + u64(run_count) &&
				   run_count < MAX_TRANSFER_BYTES / SECTOR_BYTES {
					run_count += 1
				} else {
					if !flush_apply_run(sink, overlay_file, run_start, run_count, data[:]) {
						return error_make(
							.IO,
							"cannot apply a FAT32 overlay sector run",
							false,
							.Uncertain,
						)
					}
					run_start = lba
					run_count = 1
				}
			}
		}
	}
	if found != expected_dirty {
		return error_make(
			.State_Corrupt,
			"FAT32 Apply bitmap count disagrees with the durable intent",
			false,
			.Uncertain,
		)
	}
	if !flush_apply_run(sink, overlay_file, run_start, run_count, data[:]) {
		return error_make(
			.IO,
			"cannot apply the final FAT32 overlay sector run",
			false,
			.Uncertain,
		)
	}
	if sink.phase != nil {sink.phase(sink.ctx, .Image_Applied)}
	if !sink.flush(sink.ctx) {
		return error_make(
			.Sync_Failed,
			"cannot durably synchronize the applied FAT32 image",
			false,
			.Uncertain,
		)
	}
	if sink.phase != nil {sink.phase(sink.ctx, .Image_Synced)}
	return {}
}

apply :: proc(session: ^Edit_Session) -> Edit_Error {
	job, begin_error := begin_apply(session)
	if begin_error.code != .None {return begin_error}
	defer apply_job_destroy(&job)
	for job.state != .Complete {
		_, step_error := apply_step(&job)
		if step_error.code != .None {return step_error}
	}
	return Edit_Error{outcome = .Applied}
}

apply_progress :: proc(job: ^Apply_Job) -> Apply_Progress {
	if job == nil {return {state = .Failed}}
	total_units := job.scan_lba
	if job.session != nil && job.session.impl != nil {
		total_units = job.session.impl.base.sector_count
	}
	return {
		state = job.state,
		completed_units = job.scan_lba,
		total_units = total_units,
		applied_sectors = job.applied_sectors,
		total_sectors = job.expected_sectors,
		cancellable = job.state == .Ready && !job.irreversible,
	}
}

begin_apply :: proc(session: ^Edit_Session) -> (Apply_Job, Edit_Error) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if session.impl.active_job {
		return {}, error_make(.Invalid_State, "another FAT32 edit job is already active")
	}
	session.impl.active_job = true
	return Apply_Job {
		session = session,
		state = .Ready,
		expected_sectors = session.impl.dirty_sectors,
		scan_buffer = make([]u8, MAX_TRANSFER_BYTES),
		data_buffer = make([]u8, MAX_TRANSFER_BYTES),
		owns_job_slot = true,
	}, {}
}

@(private = "file")
apply_job_fail :: proc(job: ^Apply_Job, err: Edit_Error) -> (Apply_Progress, Edit_Error) {
	job.state = .Failed
	job.error = err
	return apply_progress(job), err
}

@(private = "file")
apply_step_run :: proc(job: ^Apply_Job) -> Edit_Error {
	impl := job.session.impl
	if job.scan_lba >= impl.base.sector_count {return {}}
	byte_offset := job.scan_lba / 8
	bit_offset := int(job.scan_lba & 7)
	used := int(min(u64(len(job.scan_buffer)), impl.bitmap_bytes - byte_offset))
	if used <= 0 || !read_exact_at(impl.bitmap_file, job.scan_buffer[:used], i64(byte_offset)) {
		return error_make(
			.State_Corrupt,
			"cannot scan the FAT32 Apply presence bitmap",
			false,
			.Uncertain,
		)
	}
	run_start: u64
	run_count := 0
	bits := used * 8 - bit_offset
	for index in 0 ..< bits {
		if job.scan_lba >= impl.base.sector_count {break}
		absolute_bit := bit_offset + index
		present := job.scan_buffer[absolute_bit / 8] & (u8(1) << u8(absolute_bit & 7)) != 0
		if present {
			if run_count == 0 {run_start = job.scan_lba}
			run_count += 1
			job.scan_lba += 1
			if run_count == MAX_TRANSFER_BYTES / SECTOR_BYTES {break}
			continue
		}
		job.scan_lba += 1
		if run_count > 0 {break}
	}
	if run_count == 0 {return {}}
	if !flush_apply_run(
		impl.apply_sink,
		impl.overlay_file,
		run_start,
		run_count,
		job.data_buffer,
	) {
		return error_make(.IO, "cannot apply a FAT32 overlay sector run", false, .Uncertain)
	}
	job.applied_sectors += u64(run_count)
	return {}
}

apply_step :: proc(job: ^Apply_Job) -> (Apply_Progress, Edit_Error) {
	if job == nil ||
	   job.session == nil ||
	   job.session.impl == nil ||
	   job.state == .Cancelled ||
	   job.state == .Complete ||
	   job.state == .Failed {
		return {}, error_make(.Invalid_State, "FAT32 Apply job is unavailable")
	}
	impl := job.session.impl
	if job.state == .Ready {
		if !overlay_flush(impl) {
			return apply_job_fail(
				job,
				error_make(
					.Sync_Failed,
					"cannot synchronize the FAT32 edit overlay before Apply",
					false,
					.Uncertain,
				),
			)
		}
		job.irreversible = true
		intent_error := write_apply_intent(impl)
		if intent_error.code != .None {return apply_job_fail(job, intent_error)}
		if impl.apply_sink.phase != nil {
			impl.apply_sink.phase(impl.apply_sink.ctx, .Intent_Durable)
		}
		job.state = .Applying
		return apply_progress(job), {}
	}
	if job.scan_lba < impl.base.sector_count {
		step_error := apply_step_run(job)
		if step_error.code != .None {return apply_job_fail(job, step_error)}
		return apply_progress(job), {}
	}
	if job.applied_sectors != job.expected_sectors {
		return apply_job_fail(
			job,
			error_make(
				.State_Corrupt,
				"FAT32 Apply bitmap count disagrees with the durable intent",
				false,
				.Uncertain,
			),
		)
	}
	if impl.apply_sink.phase != nil {impl.apply_sink.phase(impl.apply_sink.ctx, .Image_Applied)}
	if !impl.apply_sink.flush(impl.apply_sink.ctx) {
		return apply_job_fail(
			job,
			error_make(
				.Sync_Failed,
				"cannot durably synchronize the applied FAT32 image",
				false,
				.Uncertain,
			),
		)
	}
	if impl.apply_sink.phase != nil {impl.apply_sink.phase(impl.apply_sink.ctx, .Image_Synced)}
	job.state = .Complete
	job.scan_lba = impl.base.sector_count
	impl.active_job = false
	job.owns_job_slot = false
	close_impl(impl, false)
	job.session.impl = nil
	return apply_progress(job), {}
}

apply_cancel :: proc(job: ^Apply_Job) -> Edit_Error {
	if job == nil || job.state != .Ready || job.irreversible {
		return error_make(
			.Invalid_State,
			"FAT32 Apply cannot be cancelled after its durable intent",
		)
	}
	job.state = .Cancelled
	if job.owns_job_slot && job.session != nil && job.session.impl != nil {
		job.session.impl.active_job = false
		job.owns_job_slot = false
	}
	return Edit_Error{code = .Cancelled, outcome = .Preserved}
}

apply_job_destroy :: proc(job: ^Apply_Job) {
	if job == nil {return}
	if job.owns_job_slot && job.session != nil && job.session.impl != nil {
		job.session.impl.active_job = false
	}
	delete(job.scan_buffer)
	delete(job.data_buffer)
	job^ = {}
}

retire_applied :: proc(state_directory: string, expected_transaction: u64) -> Edit_Error {
	if state_directory == "" || expected_transaction == 0 {
		return error_make(.Invalid_Argument, "applied FAT32 Edit identity is unavailable")
	}
	state, state_status := companionio.open_path(state_directory)
	if state_status != .None {
		return error_make(
			.State_Corrupt,
			"applied FAT32 Edit root is not a safe directory",
			false,
			.Uncertain,
		)
	}
	defer companionio.close_directory(&state)
	edit, edit_status := companionio.open_child(&state, "edit", false)
	if edit_status != .None {
		return error_make(
			.State_Corrupt,
			"applied FAT32 Edit directory is unavailable",
			false,
			.Uncertain,
		)
	}
	defer companionio.close_directory(&edit)
	intent_file, _, intent_status := companionio.open_file(&edit, "apply.intent", {.Read})
	if intent_status != .None {
		return error_make(
			.State_Corrupt,
			"applied FAT32 Edit intent is unavailable",
			false,
			.Uncertain,
		)
	}
	intent: [APPLY_INTENT_BYTES]u8
	intent_ok := read_exact_at(intent_file, intent[:], 0)
	_ = os.close(intent_file)
	meta_file, _, meta_status := companionio.open_file(&edit, "edit.meta", {.Read})
	if meta_status != .None {
		return error_make(
			.State_Corrupt,
			"applied FAT32 Edit metadata is unavailable",
			false,
			.Uncertain,
		)
	}
	meta: [EDIT_META_BYTES]u8
	meta_ok := read_exact_at(meta_file, meta[:], 0)
	_ = os.close(meta_file)
	if !intent_ok ||
	   !meta_ok ||
	   !validate_transaction_header(intent[:], APPLY_INTENT_MAGIC, APPLY_INTENT_BYTES) ||
	   !validate_transaction_header(meta[:], EDIT_META_MAGIC, EDIT_META_BYTES) ||
	   get_u64le(intent[:], 16) != expected_transaction ||
	   get_u64le(meta[:], 16) != expected_transaction {
		return error_make(
			.State_Corrupt,
			"applied FAT32 Edit evidence does not match its durable owner",
			false,
			.Uncertain,
		)
	}
	edit_names := [?]string{"overlay.bin", "presence.bin", "apply.intent", "edit.meta"}
	for name in edit_names {
		if !companionio.remove_file(&edit, name) {
			return error_make(.IO, "cannot retire applied FAT32 Edit evidence", true, .Applied)
		}
	}
	if !companionio.retire_directory(&state, &edit) {
		return error_make(.IO, "cannot retire applied FAT32 Edit evidence", true, .Applied)
	}
	return Edit_Error{outcome = .Applied}
}

discard :: proc(session: ^Edit_Session) -> Edit_Error {
	if session == nil || session.impl == nil {return {}}
	if session.impl.closed {return error_make(.Invalid_State, "FAT32 edit session is closed")}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit session has an active job")
	}
	removed := close_impl(session.impl, true)
	session.impl = nil
	if !removed {
		return error_make(
			.IO,
			"cannot safely retire discarded FAT32 Edit evidence",
			true,
			.Preserved,
		)
	}
	return Edit_Error{outcome = .Preserved}
}

recover_apply :: proc(
	base: disk.Block_Device,
	state_directory: string,
	sink: Apply_Sink = {},
) -> Edit_Error {
	if state_directory ==
	   "" {return error_make(.Invalid_Argument, "FAT32 edit companion directory is unavailable")}
	apply_sink := sink
	if apply_sink.ctx == nil {apply_sink = {
			ctx   = base.ctx,
			write = base.write,
			flush = base.flush,
		}}
	state, state_status := companionio.open_path(state_directory)
	if state_status == .Missing {return {}}
	if state_status != .None {
		return error_make(
			.State_Corrupt,
			"FAT32 edit recovery root is not a safe directory",
			false,
			.Uncertain,
		)
	}
	defer companionio.close_directory(&state)
	edit, edit_status := companionio.open_child(&state, "edit", false)
	if edit_status == .Missing {return {}}
	if edit_status != .None {
		return error_make(
			.State_Corrupt,
			"FAT32 edit recovery directory is unsafe",
			false,
			.Uncertain,
		)
	}
	defer companionio.close_directory(&edit)
	intent_exists, intent_safe, _ := companionio.probe_file(&edit, "apply.intent")
	if !intent_exists {return intent_safe ? Edit_Error{} : error_make(.State_Corrupt, "FAT32 Apply intent is unsafe", false, .Uncertain)}
	if !intent_safe {
		return error_make(.State_Corrupt, "FAT32 Apply intent is unsafe", false, .Uncertain)
	}
	intent_file, _, intent_status := companionio.open_file(&edit, "apply.intent", {.Read})
	if intent_status !=
	   .None {return error_make(.State_Corrupt, "cannot open the interrupted FAT32 Apply intent", false, .Uncertain)}
	intent: [APPLY_INTENT_BYTES]u8
	intent_ok := read_exact_at(intent_file, intent[:], 0)
	_ = os.close(intent_file)
	meta_file, _, meta_status := companionio.open_file(&edit, "edit.meta", {.Read})
	if meta_status !=
	   .None {return error_make(.State_Corrupt, "interrupted FAT32 Apply has no edit metadata", false, .Uncertain)}
	meta: [EDIT_META_BYTES]u8
	meta_ok := read_exact_at(meta_file, meta[:], 0)
	_ = os.close(meta_file)
	if !intent_ok ||
	   !meta_ok ||
	   !validate_transaction_header(intent[:], APPLY_INTENT_MAGIC, APPLY_INTENT_BYTES) ||
	   !validate_transaction_header(meta[:], EDIT_META_MAGIC, EDIT_META_BYTES) ||
	   get_u64le(intent[:], 16) != get_u64le(meta[:], 16) ||
	   get_u64le(intent[:], 24) != base.sector_count ||
	   get_u64le(meta[:], 24) != base.sector_count ||
	   get_u64le(intent[:], 32) != get_u64le(meta[:], 32) {
		return error_make(
			.State_Corrupt,
			"interrupted FAT32 Apply state is inconsistent",
			false,
			.Uncertain,
		)
	}
	overlay_file, _, overlay_status := companionio.open_file(&edit, "overlay.bin", {.Read})
	if overlay_status !=
	   .None {return error_make(.State_Corrupt, "interrupted FAT32 Apply overlay is missing", false, .Uncertain)}
	defer if overlay_file != nil {os.close(overlay_file)}
	bitmap_file, _, bitmap_status := companionio.open_file(&edit, "presence.bin", {.Read})
	if bitmap_status !=
	   .None {return error_make(.State_Corrupt, "interrupted FAT32 Apply bitmap is missing", false, .Uncertain)}
	defer if bitmap_file != nil {os.close(bitmap_file)}
	apply_error := apply_overlay_files(
		apply_sink,
		overlay_file,
		bitmap_file,
		base.sector_count,
		get_u64le(intent[:], 32),
		get_u64le(intent[:], 40),
	)
	if apply_error.code != .None {return apply_error}
	_ = os.close(overlay_file)
	overlay_file = nil
	_ = os.close(bitmap_file)
	bitmap_file = nil
	edit_names := [?]string{"overlay.bin", "presence.bin", "apply.intent", "edit.meta"}
	for name in edit_names {
		if !companionio.remove_file(&edit, name) {
			return error_make(
				.IO,
				"FAT32 Apply completed but its companion evidence could not be retired",
				true,
				.Applied,
			)
		}
	}
	if !companionio.retire_directory(&state, &edit) {
		return error_make(
			.IO,
			"FAT32 Apply completed but its companion evidence could not be retired",
			true,
			.Applied,
		)
	}
	return Edit_Error{outcome = .Applied}
}
