// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"

edit_failure :: proc(diagnostic: string, session_error: fat32session.Session_Error) -> Error {
	return session_error_wrap(.Edit_Failed, diagnostic, session_error)
}

progress_emit :: proc(hook: Progress_Hook, progress: Progress_Update) -> Progress_Action {
	if hook.update == nil {return .Continue}
	return hook.update(hook.ctx, progress)
}

edit_job_progress :: proc(
	progress: fat32session.Edit_Job_Progress,
	phase: Progress_Phase,
	point: Cancel_Point,
) -> Progress_Update {
	state := Progress_State.Pending
	switch progress.state {
	case .Running:
		state = .Running
	case .Complete:
		state = .Complete
	case .Cancelled:
		state = .Cancelled
	case .Failed:
		state = .Failed
	case .Pending:
	}
	return {
		phase           = phase,
		point           = point,
		state           = state,
		completed_bytes = progress.completed_bytes,
		total_bytes     = progress.total_bytes,
		items_completed = progress.items_completed,
		cancellable     = state == .Pending || state == .Running,
	}
}

edit_job_cancel :: proc(
	session: ^fat32session.Edit_Session,
	hook: Progress_Hook,
	progress: Progress_Update,
) -> Error {
	cancel_error := fat32session.edit_job_cancel(session)
	cancelled_progress := progress
	cancelled_progress.state = .Cancelled
	cancelled_progress.cancellable = false
	_ = progress_emit(hook, cancelled_progress)
	if cancel_error.code != .None {
		return edit_failure("cannot safely cancel a bounded FAT32 Edit job", cancel_error)
	}
	return error_make(.Cancelled, "Windows 98 image operation was cancelled")
}

edit_job_run :: proc(
	session: ^fat32session.Edit_Session,
	cancellation: Cancellation,
	hook: Progress_Hook,
	point: Cancel_Point,
	phase: Progress_Phase,
) -> Error {
	current := Progress_Update {
		phase       = phase,
		point       = point,
		state       = .Pending,
		cancellable = true,
	}
	if progress_emit(hook, current) == .Cancel || cancelled(cancellation, point) {
		return edit_job_cancel(session, hook, current)
	}
	for {
		progress, step_error := fat32session.edit_job_step(session)
		current = edit_job_progress(progress, phase, point)
		if step_error.code != .None {
			_ = fat32session.edit_job_cancel(session)
			current.state = .Failed
			current.cancellable = false
			_ = progress_emit(hook, current)
			return edit_failure("a bounded FAT32 Edit job failed", step_error)
		}
		action := progress_emit(hook, current)
		switch progress.state {
		case .Complete:
			return {}
		case .Cancelled:
			return error_make(.Cancelled, "Windows 98 image preparation was cancelled")
		case .Failed:
			_ = fat32session.edit_job_cancel(session)
			return error_make(.Edit_Failed, "a bounded FAT32 Edit job failed")
		case .Pending, .Running:
		}
		if action == .Cancel || cancelled(cancellation, point) {
			return edit_job_cancel(session, hook, current)
		}
	}
}

edit_apply_progress :: proc(
	progress: fat32session.Edit_Apply_Progress,
	point: Cancel_Point,
) -> Progress_Update {
	state := Progress_State.Pending
	switch progress.state {
	case .Applying:
		state = .Running
	case .Complete:
		state = .Complete
	case .Cancelled:
		state = .Cancelled
	case .Failed:
		state = .Failed
	case .Ready:
	}
	return {
		phase           = .Apply,
		point           = point,
		state           = state,
		completed_units = progress.completed_units,
		total_units     = progress.total_units,
		applied_sectors = progress.applied_sectors,
		total_sectors   = progress.total_sectors,
		cancellable     = progress.cancellable,
	}
}

edit_apply_cancel :: proc(
	session: ^fat32session.Edit_Session,
	hook: Progress_Hook,
	progress: Progress_Update,
) -> Error {
	cancel_error := fat32session.edit_cancel_apply(session)
	cancelled_progress := progress
	cancelled_progress.state = .Cancelled
	cancelled_progress.cancellable = false
	_ = progress_emit(hook, cancelled_progress)
	if cancel_error.code != .None {
		return session_error_wrap(
			.Apply_Failed,
			"cannot safely cancel FAT32 Apply before its durable intent",
			cancel_error,
		)
	}
	return error_make(.Cancelled, "Windows 98 image operation was cancelled")
}

Apply_Ready_Hook :: struct {
	ctx: rawptr,
	run: proc(ctx: rawptr) -> Error,
}

edit_apply_run :: proc(
	session: ^^fat32session.Edit_Session,
	cancellation: Cancellation,
	hook: Progress_Hook,
	point: Cancel_Point,
	diagnostic: string,
	ready_hook: Apply_Ready_Hook = {},
) -> Error {
	if session == nil || session^ == nil {
		return error_make(.Internal, "bounded FAT32 Apply has no Edit session")
	}
	apply_progress, begin_error := fat32session.edit_begin_apply(session^)
	if begin_error.code != .None {
		return session_error_wrap(.Apply_Failed, diagnostic, begin_error)
	}
	current := edit_apply_progress(apply_progress, point)
	if progress_emit(hook, current) == .Cancel || cancelled(cancellation, point) {
		return edit_apply_cancel(session^, hook, current)
	}
	if ready_hook.run != nil {
		current.cancellable = false
		_ = progress_emit(hook, current)
		if ready_error := ready_hook.run(ready_hook.ctx); ready_error.code != .None {
			cancel_error := edit_apply_cancel(session^, hook, current)
			if cancel_error.code != .Cancelled {return cancel_error}
			return ready_error
		}
	}
	for {
		apply_progress, step_error := fat32session.edit_step_apply(session^)
		current = edit_apply_progress(apply_progress, point)
		if step_error.code != .None {
			if step_error.outcome == .Completed {
				session^ = nil
				current.state = .Complete
				current.cancellable = false
			} else {
				current.state = .Failed
				current.cancellable = false
			}
			_ = progress_emit(hook, current)
			return session_error_wrap(.Apply_Failed, diagnostic, step_error)
		}
		action := progress_emit(hook, current)
		if apply_progress.state == .Complete {
			fat32session.edit_release_completed(session^)
			session^ = nil
			return {}
		}
		request_cancelled := action == .Cancel || cancelled(cancellation, point)
		if request_cancelled && apply_progress.cancellable {
			return edit_apply_cancel(session^, hook, current)
		}
	}
}

edit_import_file :: proc(
	session: ^fat32session.Edit_Session,
	host_source, guest_destination: string,
	replace: bool,
	cancellation: Cancellation,
	point: Cancel_Point,
	hook: Progress_Hook = {},
) -> Error {
	begin_error := fat32session.edit_begin_import_file(
		session,
		host_source,
		guest_destination,
		replace,
	)
	if begin_error.code !=
	   .None {return edit_failure("cannot begin a FAT32 file import", begin_error)}
	return edit_job_run(session, cancellation, hook, point, .Import)
}

edit_import_tree :: proc(
	session: ^fat32session.Edit_Session,
	host_source, guest_destination: string,
	cancellation: Cancellation,
	point: Cancel_Point,
	hook: Progress_Hook = {},
) -> Error {
	begin_error := fat32session.edit_begin_import_tree(session, host_source, guest_destination)
	if begin_error.code !=
	   .None {return edit_failure("cannot begin the Windows 98 Setup tree import", begin_error)}
	return edit_job_run(session, cancellation, hook, point, .Import)
}

edit_remove_existing :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	cancellation: Cancellation = {},
	hook: Progress_Hook = {},
	point: Cancel_Point = .Abandon_Removing,
) -> Error {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code !=
	   .None {return edit_failure("cannot inspect an existing FAT path", stat_error)}
	if !stat.exists {return {}}
	begin_error := fat32session.edit_begin_remove_recursive(session, path)
	if begin_error.code !=
	   .None {return edit_failure("cannot begin removal of an owned FAT path", begin_error)}
	return edit_job_run(session, cancellation, hook, point, .Remove)
}

edit_prepare_owned_destinations :: proc(
	session: ^fat32session.Edit_Session,
	cancellation: Cancellation,
	hook: Progress_Hook,
) -> Error {
	payload_marker_path := PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME
	payload_stat, payload_stat_error := fat32session.edit_stat(session, PAYLOAD_PATH)
	if payload_stat_error.code !=
	   .None {return edit_failure("cannot inspect the Setup destination", payload_stat_error)}
	if payload_stat.exists {
		if !payload_stat.is_directory {
			return error_make(
				.Ownership_Mismatch,
				"GSWSETUP exists but is not a RETVRN99-owned directory",
			)
		}
		marker := PAYLOAD_MARKER
		_, marker_matches, marker_error := edit_file_equals(
			session,
			payload_marker_path,
			transmute([]u8)marker,
		)
		if marker_error.code != .None {return marker_error}
		if !marker_matches {
			return error_make(
				.Ownership_Mismatch,
				"GSWSETUP does not carry the RETVRN99 ownership marker",
			)
		}
		if remove_error := edit_remove_existing(
			session,
			PAYLOAD_PATH,
			cancellation,
			hook,
			.Edit_Opened,
		);
		   remove_error.code != .None {
			return remove_error
		}
	}
	launcher_exists, launcher_owned, launcher_error := edit_file_has_prefix(
		session,
		LAUNCHER_PATH,
		LAUNCHER_MARKER,
	)
	if launcher_error.code != .None {return launcher_error}
	if launcher_exists {
		if !launcher_owned {
			return error_make(.Ownership_Mismatch, "GSWSETUP.BAT is not RETVRN99-owned")
		}
		return edit_remove_existing(
			session,
			LAUNCHER_PATH,
			cancellation,
			hook,
			.Edit_Opened,
		)
	}
	return {}
}

edit_prepare_autoexec :: proc(
	session: ^fat32session.Edit_Session,
	staging: ^Host_Staging,
	cancellation: Cancellation,
	hook: Progress_Hook = {},
) -> (
	backed_up: bool,
	err: Error,
) {
	autoexec_text := BOOTSTRAP_AUTOEXEC
	autoexec_exists, autoexec_owned, autoexec_error := edit_file_equals(
		session,
		AUTOEXEC_PATH,
		transmute([]u8)autoexec_text,
	)
	if autoexec_error.code != .None && autoexec_error.code != .Ownership_Mismatch {
		return false, autoexec_error
	}
	backup, backup_error := fat32session.edit_stat(session, AUTOEXEC_BACKUP_PATH)
	if backup_error.code !=
	   .None {return false, edit_failure("cannot inspect the AUTOEXEC backup", backup_error)}
	if autoexec_exists && !autoexec_owned {
		if backup.exists {
			return false, error_make(
				.Ownership_Mismatch,
				"GSWAUTO.PRV already exists beside a non-owned AUTOEXEC.BAT",
			)
		}
		rename_error := fat32session.edit_rename(session, AUTOEXEC_PATH, AUTOEXEC_BACKUP_PATH)
		if rename_error.code !=
		   .None {return false, edit_failure("cannot stage the AUTOEXEC.BAT backup", rename_error)}
		backed_up = true
	} else if !autoexec_exists && backup.exists {
		return false, error_make(
			.Ownership_Mismatch,
			"GSWAUTO.PRV exists without the RETVRN99 bootstrap AUTOEXEC.BAT",
		)
	}
	if autoexec_owned {return backup.exists, {}}
	err = edit_import_file(
		session,
		staging.autoexec,
		AUTOEXEC_PATH,
		false,
		cancellation,
		.Launcher_Imported,
		hook,
	)
	return backed_up, err
}

edit_import_system_files :: proc(
	session: ^fat32session.Edit_Session,
	staging: ^Host_Staging,
	disk_state: Disk_State,
	cancellation: Cancellation,
	hook: Progress_Hook = {},
) -> (
	[3]bool,
	Error,
) {
	owned: [3]bool
	if disk_state == .Existing_DOS {return owned, {}}
	for name, index in BOOTSTRAP_SYSTEM_NAMES {
		stat, stat_error := fat32session.edit_stat(session, name)
		if stat_error.code !=
		   .None {return {}, edit_failure("cannot inspect a DOS system file", stat_error)}
		if stat.exists {
			if stat.is_directory {return {}, error_make(.Partial_DOS, "a DOS system filename is occupied by a directory")}
			continue
		}
		if import_error := edit_import_file(
			session,
			staging.dos[index],
			name,
			false,
			cancellation,
			.DOS_Imported,
			hook,
		); import_error.code != .None {
			return {}, import_error
		}
		owned[index] = true
	}
	return owned, {}
}
