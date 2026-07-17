// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"

abandon_verify_owned_content :: proc(
	session: ^fat32session.Edit_Session,
	owner: ^Preparation_Owner,
) -> Error {
	payload_marker := PAYLOAD_MARKER
	payload_marker_path := PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME
	payload_exists, payload_owned, payload_error := edit_file_equals(
		session,
		payload_marker_path,
		transmute([]u8)payload_marker,
	)
	if payload_error.code != .None {return payload_error}
	if !payload_exists || !payload_owned {
		return error_make(
			.Ownership_Mismatch,
			"GSWSETUP no longer matches its preparation ownership marker",
		)
	}
	launcher_exists, launcher_owned, launcher_error := edit_file_has_prefix(
		session,
		LAUNCHER_PATH,
		LAUNCHER_MARKER,
	)
	if launcher_error.code != .None {return launcher_error}
	if !launcher_exists || !launcher_owned {
		return error_make(
			.Ownership_Mismatch,
			"GSWSETUP.BAT is missing or no longer RETVRN99-owned",
		)
	}
	autoexec := BOOTSTRAP_AUTOEXEC
	autoexec_exists, autoexec_owned, autoexec_error := edit_file_equals(
		session,
		AUTOEXEC_PATH,
		transmute([]u8)autoexec,
	)
	if autoexec_error.code != .None {return autoexec_error}
	if !autoexec_exists || !autoexec_owned {
		return error_make(
			.Ownership_Mismatch,
			"AUTOEXEC.BAT no longer matches the RETVRN99 bootstrap",
		)
	}
	backup, backup_error := fat32session.edit_stat(session, AUTOEXEC_BACKUP_PATH)
	if backup_error.code !=
	   .None {return edit_failure("cannot inspect the preparation AUTOEXEC backup", backup_error)}
	if owner.autoexec_backup && (!backup.exists || backup.is_directory) {
		return error_make(
			.Ownership_Mismatch,
			"the preparation AUTOEXEC backup is missing or invalid",
		)
	}
	system_names := BOOTSTRAP_SYSTEM_NAMES
	for owned, index in owner.system_owned {
		if !owned {continue}
		fingerprint, exists, fingerprint_error := edit_file_fingerprint(
			session,
			system_names[index],
			BOOTSTRAP_IMAGE_MAX_BYTES,
		)
		if fingerprint_error.code != .None {return fingerprint_error}
		if !exists || fingerprint != owner.system_fingerprints[index] {
			return error_make(.Ownership_Mismatch, "an owned DOS boot-seed file was modified")
		}
	}
	return {}
}

@(private = "file")
abandon_fingerprint_matches :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	want: File_Fingerprint,
) -> (
	exists, matches: bool,
	err: Error,
) {
	stat, stat_error := fat32session.edit_stat(session, path)
	if stat_error.code != .None {
		return false, false, edit_failure("cannot inspect an owned DOS file", stat_error)
	}
	if !stat.exists {return false, false, {}}
	if stat.is_directory || stat.size != want.size {return true, false, {}}
	fingerprint, found, fingerprint_error := edit_file_fingerprint(session, path, want.size)
	if fingerprint_error.code != .None {return found, false, fingerprint_error}
	return found, fingerprint == want, {}
}

@(private = "file")
abandon_remove_consumed_payload :: proc(
	session: ^fat32session.Edit_Session,
	cancellation: Cancellation,
	progress: Progress_Hook,
) -> Error {
	marker_path := PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME
	if remove_error := edit_remove_existing(
		session,
		marker_path,
		cancellation,
		progress,
		.Abandon_Removing,
	);
	   remove_error.code != .None {
		return remove_error
	}
	page, list_error := fat32session.edit_list(session, PAYLOAD_PATH, 0, 1)
	if list_error.code != .None {
		return edit_failure("cannot inspect the consumed Setup directory", list_error)
	}
	defer fat32session.edit_page_destroy(&page)
	if len(page.entries) != 0 || page.has_more {return {}}
	return edit_remove_existing(
		session,
		PAYLOAD_PATH,
		cancellation,
		progress,
		.Abandon_Removing,
	)
}

abandon :: proc(
	request: Abandon_Request,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> (
	Abandon_Result,
	Error,
) {
	if request.image_path == "" ||
	   request.edit_session_id == "" ||
	   request.preparation_transaction_id == 0 {
		return {}, error_make(.Invalid_Argument, "image, Edit session id, and preparation transaction id are required")
	}
	image_info, image_error := fat32session.validate_image(request.image_path, adapter)
	if image_error.code != .None {
		return {}, session_error_wrap(.Image_Rejected, "hard-drive image validation failed", image_error)
	}
	defer fat32session.image_info_destroy(&image_info)
	result := Abandon_Result {
		image_identity      = image_info.image_id,
		edit_transaction_id = request.preparation_transaction_id,
	}
	if !image_info.enrolled || !image_info.retvrn99_format {
		return result, error_make(
			.Image_Not_RETVRN99,
			"abandonment requires the bound RETVRN99 hard-drive image",
		)
	}
	session, open_error := fat32session.open_edit(
		request.image_path,
		request.edit_session_id,
		request.preparation_transaction_id,
		adapter,
	)
	if open_error.code != .None {
		return result, session_error_wrap(
			.Edit_Failed,
			"cannot open the bound preparation Edit transaction",
			open_error,
		)
	}
	defer prepare_discard_session(&session)
	owner, owner_exists, owner_error := owner_read(session)
	if owner_error.code != .None {return result, owner_error}
	if !owner_exists {
		if image_info.dirty {
			prepare_discard_session(&session)
			return result, {}
		}
		return result, error_make(
			.Not_Prepared,
			"the selected hard drive has no RETVRN99 preparation marker",
		)
	}
	if owner.image_identity != image_info.image_id ||
	   owner.transaction_id != request.preparation_transaction_id {
		return result, error_make(
			.Ownership_Mismatch,
			"preparation ownership does not match the selected image and transaction",
		)
	}
	if !request.allow_consumed_content {
		if verify_error := abandon_verify_owned_content(session, &owner);
		   verify_error.code != .None {
			return result, verify_error
		}
	}
	payload_marker := PAYLOAD_MARKER
	payload_marker_path := PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME
	_, payload_owned, payload_error := edit_file_equals(
		session,
		payload_marker_path,
		transmute([]u8)payload_marker,
	)
	if payload_error.code != .None {return result, payload_error}
	if payload_owned {
		remove_error: Error
		if request.allow_consumed_content {
			remove_error = abandon_remove_consumed_payload(
				session,
				request.cancellation,
				request.progress,
			)
		} else {
			remove_error = edit_remove_existing(
				session,
				PAYLOAD_PATH,
				request.cancellation,
				request.progress,
				.Abandon_Removing,
			)
		}
		if remove_error.code != .None {
			return result, remove_error
		}
	}
	_, launcher_owned, launcher_error := edit_file_has_prefix(
		session,
		LAUNCHER_PATH,
		LAUNCHER_MARKER,
	)
	if launcher_error.code != .None {return result, launcher_error}
	if launcher_owned {
		if remove_error := edit_remove_existing(
			session,
			LAUNCHER_PATH,
			request.cancellation,
			request.progress,
			.Abandon_Removing,
		);
		   remove_error.code != .None {return result, remove_error}
	}
	if remove_error := edit_remove_existing(
		session,
		OWNER_FILE_NAME,
		request.cancellation,
		request.progress,
		.Abandon_Removing,
	);
	   remove_error.code != .None {return result, remove_error}
	autoexec := BOOTSTRAP_AUTOEXEC
	autoexec_exists, autoexec_owned, autoexec_error := edit_file_equals(
		session,
		AUTOEXEC_PATH,
		transmute([]u8)autoexec,
	)
	if autoexec_error.code != .None {return result, autoexec_error}
	if autoexec_owned {
		if remove_error := edit_remove_existing(
			session,
			AUTOEXEC_PATH,
			request.cancellation,
			request.progress,
			.Abandon_Removing,
		);
		   remove_error.code != .None {return result, remove_error}
		autoexec_exists = false
	}
	if owner.autoexec_backup {
		backup, backup_error := fat32session.edit_stat(session, AUTOEXEC_BACKUP_PATH)
		if backup_error.code != .None {
			return result, edit_failure("cannot inspect the preparation AUTOEXEC backup", backup_error)
		}
		if backup.exists && !backup.is_directory && !autoexec_exists {
			rename_error := fat32session.edit_rename(
				session,
				AUTOEXEC_BACKUP_PATH,
				AUTOEXEC_PATH,
			)
			if rename_error.code != .None {
				return result, edit_failure(
					"cannot restore the pre-install AUTOEXEC.BAT",
					rename_error,
				)
			}
		}
	}
	restore_boot := false
	system_names := BOOTSTRAP_SYSTEM_NAMES
	for owned, index in owner.system_owned {
		if !owned {continue}
		_, matches, match_error := abandon_fingerprint_matches(
			session,
			system_names[index],
			owner.system_fingerprints[index],
		)
		if match_error.code != .None {return result, match_error}
		if matches {
			if remove_error := edit_remove_existing(
				session,
				system_names[index],
				request.cancellation,
				request.progress,
				.Abandon_Removing,
			);
			   remove_error.code != .None {
				return result, remove_error
			}
			if index == 0 {restore_boot = true}
		}
	}
	if restore_boot {
		if restore_error := fat32session.edit_restore_boot_loader(session);
		   restore_error.code != .None {
			return result, edit_failure(
				"cannot restore the RETVRN99 FAT32 boot stub",
				restore_error,
			)
		}
	}
	apply_error := edit_apply_run(
		&session,
		request.cancellation,
		request.progress,
		.Abandon_Before_Apply,
		"cannot durably apply Windows 98 installation abandonment",
	)
	if apply_error.code != .None {
		if apply_error.code != .Cancelled && session != nil {
			prepare_retain_session(&session)
		}
		return result, apply_error
	}
	return result, {}
}
