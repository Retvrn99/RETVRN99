// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"

prepare_result_take_inspection :: proc(inspection: ^Inspection) -> Prepare_Result {
	result := Prepare_Result {
		media_info          = inspection.media_info,
		image_identity      = inspection.image_identity,
		edit_transaction_id = inspection.prepared_transaction_id,
		boot_source         = inspection.boot_source,
		boot_target         = inspection.boot_target,
		recovered           = inspection.disk_state == .Prepared && !inspection.pending_edit,
	}
	inspection.media_info = {}
	return result
}

Prepare_Apply_Binding :: struct {
	hook:    Binding_Hook,
	binding: Preparation_Binding,
}

prepare_apply_binding_persist :: proc(ctx: rawptr) -> Error {
	value := (^Prepare_Apply_Binding)(ctx)
	if value == nil || value.hook.persist == nil {return {}}
	if value.hook.persist(value.hook.ctx, value.binding) {return {}}
	return error_make(
		.Binding_Failed,
		"cannot persist the image-bound Windows 98 installation state",
	)
}

prepare_discard_session :: proc(session: ^^fat32session.Edit_Session) {
	if session == nil || session^ == nil {return}
	discard_error := fat32session.edit_finish(session^, false)
	if discard_error.code != .None && discard_error.outcome != .Completed {
		_ = fat32session.edit_close_retain(session^)
	}
	session^ = nil
}

prepare_retain_session :: proc(session: ^^fat32session.Edit_Session) {
	if session == nil || session^ == nil {return}
	_ = fat32session.edit_close_retain(session^)
	session^ = nil
}

prepare_open_edit :: proc(
	request: Prepare_Request,
	adapter: fat32session.Adapter_Kind,
) -> (
	^fat32session.Edit_Session,
	Error,
) {
	session, open_error := fat32session.open_edit(
		request.image_path,
		request.edit_session_id,
		request.requested_transaction_id,
		adapter,
	)
	if open_error.code != .None {
		return nil, session_error_wrap(
			.Edit_Failed,
			"cannot open the Windows 98 preparation Edit transaction",
			open_error,
		)
	}
	if request.requested_transaction_id != 0 &&
	   fat32session.edit_changed_sector_count(session) > 0 {
		discard_error := fat32session.edit_finish(session, false)
		if discard_error.code != .None {
			if discard_error.outcome != .Completed {
				_ = fat32session.edit_close_retain(session)
			}
			return nil, session_error_wrap(
				.Recovery_Failed,
				"cannot discard an interrupted preparation transaction",
				discard_error,
			)
		}
		session, open_error = fat32session.open_edit(
			request.image_path,
			request.edit_session_id,
			request.requested_transaction_id,
			adapter,
		)
		if open_error.code != .None {
			return nil, session_error_wrap(
				.Recovery_Failed,
				"cannot restart the recovered preparation transaction",
				open_error,
			)
		}
	}
	return session, {}
}

prepare :: proc(
	request: Prepare_Request,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> (
	Prepare_Result,
	Error,
) {
	inspection, inspect_error := inspect(
		Inspect_Request {
			image_path = request.image_path,
			iso_path = request.iso_path,
			boot_floppy_path = request.boot_floppy_path,
			edit_session_id = request.edit_session_id,
			requested_transaction_id = request.requested_transaction_id,
		},
		adapter,
	)
	defer inspection_destroy(&inspection)
	result := prepare_result_take_inspection(&inspection)
	if inspect_error.code != .None {return result, inspect_error}
	if cancelled(request.cancellation, .Media_Inspected) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	if result.recovered {return result, {}}
	session, open_error := prepare_open_edit(request, adapter)
	if open_error.code != .None {return result, open_error}
	defer prepare_discard_session(&session)
	result.edit_transaction_id = fat32session.edit_transaction_id(session)
	if result.edit_transaction_id == 0 {
		return result, error_make(
			.Internal,
			"Windows 98 preparation Edit transaction has no identity",
		)
	}
	adoption, adoption_error := fat32session.edit_adopt_image(session)
	if adoption_error.code != .None {
		return result, session_error_wrap(
			.Edit_Failed,
			"cannot stage the compatible hard drive for RETVRN99 adoption",
			adoption_error,
		)
	}
	result.image_identity = adoption.image_identity
	if cancelled(request.cancellation, .Edit_Opened) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	disk_state, _, detect_error := disk_detect(session, result.image_identity)
	if detect_error.code != .None {return result, detect_error}
	if disk_state == .Existing_Windows {
		return result, error_make(
			.Existing_Windows,
			"the selected hard drive already contains WINDOWS",
		)
	}
	if disk_state == .Partial_DOS {
		return result, error_make(
			.Partial_DOS,
			"the selected hard drive contains an incomplete DOS system",
		)
	}
	if disk_state == .Prepared {
		return result, error_make(
			.Already_Prepared,
			"the selected hard drive is already prepared for Windows 98 Setup",
		)
	}
	result.boot_source, detect_error = boot_source_inspect(
		&result.media_info,
		request.iso_path,
		request.boot_floppy_path,
		disk_state,
	)
	if detect_error.code != .None {return result, detect_error}
	staging, staging_error := staging_open(request.scratch_parent)
	if staging_error.code != .None {return result, staging_error}
	defer staging_destroy(&staging)
	if disk_state != .Existing_DOS {
		if seed_error := staging_boot_seed(
			&staging,
			request.iso_path,
			request.boot_floppy_path,
			result.boot_source,
		); seed_error.code != .None {
			return result, seed_error
		}
	}
	if cancelled(request.cancellation, .Boot_Seed_Staged) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	if setup_error := staging_setup_source(
		&staging,
		request.iso_path,
		&result.media_info,
		request.options,
	); setup_error.code != .None {
		return result, setup_error
	}
	if cancelled(request.cancellation, .Setup_Extracted) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	if launcher_error := staging_launchers(
		&staging,
		result.media_info.setup_executable,
		disk_state != .Existing_DOS,
		request.options,
	); launcher_error.code != .None {
		return result, launcher_error
	}
	if ownership_error := edit_prepare_owned_destinations(
		session,
		request.cancellation,
		request.progress,
	); ownership_error.code != .None {
		return result, ownership_error
	}
	system_owned, system_error := edit_import_system_files(
		session,
		&staging,
		disk_state,
		request.cancellation,
		request.progress,
	)
	if system_error.code != .None {return result, system_error}
	if cancelled(request.cancellation, .DOS_Imported) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	autoexec_backup, autoexec_error := edit_prepare_autoexec(
		session,
		&staging,
		request.cancellation,
		request.progress,
	)
	if autoexec_error.code != .None {return result, autoexec_error}
	if payload_error := edit_import_tree(
		session,
		staging.setup,
		PAYLOAD_PATH,
		request.cancellation,
		.Payload_Imported,
		request.progress,
	); payload_error.code != .None {
		return result, payload_error
	}
	if cancelled(request.cancellation, .Payload_Imported) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	if launcher_error := edit_import_file(
		session,
		staging.launcher,
		LAUNCHER_PATH,
		false,
		request.cancellation,
		.Launcher_Imported,
		request.progress,
	); launcher_error.code != .None {
		return result, launcher_error
	}
	if cancelled(request.cancellation, .Launcher_Imported) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	io_stat, io_stat_error := fat32session.edit_stat(session, BOOTSTRAP_SYSTEM_NAMES[0])
	if io_stat_error.code != .None ||
	   !io_stat.exists ||
	   io_stat.is_directory ||
	   io_stat.first_cluster < 2 {
		if io_stat_error.code != .None {
			return result, edit_failure(
				"cannot locate the staged IO.SYS boot target",
				io_stat_error,
			)
		}
		return result, error_make(.Partial_DOS, "IO.SYS is unavailable after DOS staging")
	}
	edit_target, patch_error := fat32session.edit_patch_boot_loader(session, io_stat.first_cluster)
	if patch_error.code != .None {
		return result, edit_failure("cannot stage the RETVRN99 FAT32 boot loader", patch_error)
	}
	result.boot_target = Boot_Target {
		first_cluster = edit_target.first_cluster,
		lba           = edit_target.lba,
	}
	if cancelled(request.cancellation, .Boot_Loader_Staged) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	owner := Preparation_Owner {
		valid               = true,
		system_owned        = system_owned,
		autoexec_backup     = autoexec_backup,
		transaction_id      = result.edit_transaction_id,
		image_identity      = result.image_identity,
		boot_target         = result.boot_target,
		system_fingerprints = staging.system_fingerprints,
	}
	if owner_error := staging_owner_write(&staging, owner); owner_error.code != .None {
		return result, owner_error
	}
	if owner_import_error := edit_import_file(
		session,
		staging.owner,
		OWNER_FILE_NAME,
		false,
		request.cancellation,
		.Before_Apply,
		request.progress,
	); owner_import_error.code != .None {
		return result, owner_import_error
	}
	if cancelled(request.cancellation, .Before_Apply) {
		return result, error_make(.Cancelled, "Windows 98 image preparation was cancelled")
	}
	binding := Prepare_Apply_Binding {
		hook = request.binding_hook,
		binding = {
			image_identity      = result.image_identity,
			edit_transaction_id = result.edit_transaction_id,
			boot_target         = result.boot_target,
		},
	}
	apply_error := edit_apply_run(
		&session,
		request.cancellation,
		request.progress,
		.Before_Apply,
		"cannot durably apply Windows 98 image preparation",
		{
			ctx = &binding,
			run = prepare_apply_binding_persist,
		},
	)
	if apply_error.code != .None {
		if apply_error.code != .Cancelled &&
		   apply_error.code != .Binding_Failed &&
		   session != nil {
			prepare_retain_session(&session)
		}
		return result, apply_error
	}
	result.used_existing_dos = disk_state == .Existing_DOS
	return result, {}
}
