// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"
import win98media "../win98media"

session_error_wrap :: proc(
	code: Error_Code,
	diagnostic: string,
	session_error: fat32session.Session_Error,
) -> Error {
	err := error_make(code, diagnostic)
	err.session_error = session_error
	return err
}

media_error_wrap :: proc(diagnostic: win98media.Diagnostic) -> Error {
	err := error_make(.Media_Rejected, "Windows 98 media inspection failed")
	err.media_diagnostic = diagnostic
	return err
}

disk_detect :: proc(
	session: ^fat32session.Edit_Session,
	image_identity: [16]u8,
) -> (
	Disk_State,
	Preparation_Owner,
	Error,
) {
	windows, windows_error := fat32session.edit_stat(session, "WINDOWS")
	if windows_error.code != .None {
		return .Empty, {}, session_error_wrap(.Edit_Failed, "cannot inspect WINDOWS on the selected image", windows_error)
	}
	if windows.exists {return .Existing_Windows, {}, {}}
	owner, owner_exists, owner_error := owner_read(session)
	if owner_error.code != .None {return .Empty, {}, owner_error}
	io, io_error := fat32session.edit_stat(session, BOOTSTRAP_SYSTEM_NAMES[0])
	command, command_error := fat32session.edit_stat(session, BOOTSTRAP_SYSTEM_NAMES[2])
	msdos, msdos_error := fat32session.edit_stat(session, BOOTSTRAP_SYSTEM_NAMES[1])
	if io_error.code != .None || command_error.code != .None || msdos_error.code != .None {
		failure := io_error
		if failure.code == .None {failure = command_error}
		if failure.code == .None {failure = msdos_error}
		return .Empty, {}, session_error_wrap(.Edit_Failed, "cannot inspect DOS files on the selected image", failure)
	}
	if owner_exists {
		if owner.image_identity != image_identity ||
		   !io.exists ||
		   io.is_directory ||
		   !command.exists ||
		   command.is_directory ||
		   !msdos.exists ||
		   msdos.is_directory ||
		   io.first_cluster != owner.boot_target.first_cluster {
			return .Empty, {}, error_make(.Ownership_Mismatch, "prepared image content does not match its ownership marker")
		}
		return .Prepared, owner, {}
	}
	if io.is_directory ||
	   command.is_directory ||
	   msdos.is_directory ||
	   io.exists != command.exists ||
	   io.exists != msdos.exists {
		return .Partial_DOS, {}, {}
	}
	if io.exists && command.exists {return .Existing_DOS, {}, {}}
	return .Empty, {}, {}
}

boot_source_inspect :: proc(
	media_info: ^win98media.Media_Info,
	iso_path: string,
	boot_floppy_path: string,
	disk_state: Disk_State,
) -> (
	Boot_Source,
	Error,
) {
	if disk_state == .Existing_DOS || disk_state == .Prepared {
		return .Existing_DOS, {}
	}
	if media_info.has_embedded_boot_floppy {
		image, image_diagnostic := win98media.read_boot_floppy(iso_path, context.temp_allocator)
		defer delete(image, context.temp_allocator)
		if image_diagnostic != .None {
			err := error_make(
				.Boot_Floppy_Invalid,
				"the embedded El Torito boot floppy could not be read safely",
			)
			err.boot_diagnostic = .Boot_Image_Invalid
			if image_diagnostic == .Image_Read_Failed {
				err.boot_diagnostic = .Boot_Image_Open_Failed
			}
			return .Embedded, err
		}
		seed, seed_diagnostic := image_boot_seed_parse(image, context.temp_allocator)
		if seed_diagnostic != .None {
			err := error_make(
				.Boot_Floppy_Invalid,
				"the embedded El Torito boot floppy is not a usable Windows 98 FAT12 boot seed",
			)
			err.boot_diagnostic = seed_diagnostic
			return .Embedded, err
		}
		image_boot_seed_destroy(&seed)
		return .Embedded, {}
	}
	if boot_floppy_path == "" {
		return .Required, error_make(
			.Boot_Floppy_Required,
			"this Windows 98 media requires a matching FAT12 boot-floppy image",
		)
	}
	seed, boot_diagnostic := image_boot_seed_extract(boot_floppy_path)
	if boot_diagnostic != .None {
		err := error_make(
			.Boot_Floppy_Invalid,
			"the selected boot-floppy image is not a usable Windows 98 FAT12 boot seed",
		)
		err.boot_diagnostic = boot_diagnostic
		return .Provided, err
	}
	image_boot_seed_destroy(&seed)
	return .Provided, {}
}

inspect :: proc(
	request: Inspect_Request,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> (
	Inspection,
	Error,
) {
	if request.image_path == "" || request.iso_path == "" || request.edit_session_id == "" {
		return {}, error_make(.Invalid_Argument, "image, ISO, and Edit session id are required")
	}
	image_info, image_error := fat32session.validate_image(request.image_path, adapter)
	if image_error.code != .None {
		return {}, session_error_wrap(.Image_Rejected, "hard-drive image validation failed", image_error)
	}
	defer fat32session.image_info_destroy(&image_info)
	media_info, media_diagnostic := win98media.inspect(request.iso_path)
	if media_diagnostic != .None {return {}, media_error_wrap(media_diagnostic)}
	inspection := Inspection {
		media_info     = media_info,
		image_identity = image_info.image_id,
	}
	if media_info.win98_total_bytes > MAX_STAGING_BYTES ||
	   media_info.win98_file_count > MAX_STAGING_FILES {
		return inspection, error_make(
			.Staging_Limit,
			"Windows 98 source exceeds the bounded preparation workspace",
		)
	}
	if image_info.dirty && request.requested_transaction_id == 0 {
		return inspection, error_make(
			.Recovery_Failed,
			"dirty hard-drive image requires its bound Edit transaction id",
		)
	}
	session, open_error := fat32session.open_edit(
		request.image_path,
		request.edit_session_id,
		request.requested_transaction_id,
		adapter,
	)
	if open_error.code != .None {
		return inspection, session_error_wrap(
			.Edit_Failed,
			"cannot open the hard-drive Edit session",
			open_error,
		)
	}
	adoption_staged := false
	if !image_info.retvrn99_format {
		adoption, adoption_error := fat32session.edit_adopt_image(session)
		if adoption_error.code != .None {
			prepare_discard_session(&session)
			return inspection, session_error_wrap(
				.Edit_Failed,
				"cannot stage the compatible hard drive for RETVRN99 adoption",
				adoption_error,
			)
		}
		inspection.image_identity = adoption.image_identity
		adoption_staged = adoption.staged
	}
	state, owner, detect_error := disk_detect(session, inspection.image_identity)
	if detect_error.code == .None && state == .Prepared {
		if request.requested_transaction_id != 0 &&
		   request.requested_transaction_id != owner.transaction_id {
			detect_error = error_make(
				.Ownership_Mismatch,
				"prepared image transaction does not match the requested installation state",
			)
		} else {
			detect_error = abandon_verify_owned_content(session, &owner)
		}
	}
	inspection.disk_state = state
	inspection.pending_edit =
		image_info.dirty && fat32session.edit_changed_sector_count(session) > 0
	if state == .Prepared {
		inspection.prepared_transaction_id = owner.transaction_id
		inspection.boot_target = owner.boot_target
	} else if inspection.pending_edit {
		inspection.prepared_transaction_id = fat32session.edit_transaction_id(session)
	}
	close_error: fat32session.Session_Error
	if adoption_staged && !image_info.dirty {
		close_error = fat32session.edit_finish(session, false)
		inspection.pending_edit = false
	} else if inspection.pending_edit {
		close_error = fat32session.edit_close_retain(session)
	} else {
		close_error = fat32session.edit_finish(session, false)
	}
	if detect_error.code != .None {return inspection, detect_error}
	if close_error.code != .None {
		return inspection, session_error_wrap(
			.Edit_Failed,
			"cannot close the inspection Edit session",
			close_error,
		)
	}
	if state == .Existing_Windows {
		return inspection, error_make(
			.Existing_Windows,
			"the selected hard drive already contains WINDOWS",
		)
	}
	if state == .Partial_DOS {
		return inspection, error_make(
			.Partial_DOS,
			"the selected hard drive contains an incomplete DOS system",
		)
	}
	inspection.boot_source, detect_error = boot_source_inspect(
		&inspection.media_info,
		request.iso_path,
		request.boot_floppy_path,
		state,
	)
	if detect_error.code != .None {return inspection, detect_error}
	return inspection, {}
}
