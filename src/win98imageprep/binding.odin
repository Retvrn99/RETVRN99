// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"

verify_preparation_binding :: proc(
	request: Verify_Binding_Request,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> (
	Preparation_Binding,
	Error,
) {
	if request.image_path == "" ||
	   request.edit_session_id == "" ||
	   request.preparation_transaction_id == 0 {
		return {}, error_make(.Invalid_Argument, "image, Edit session id, and preparation transaction id are required")
	}
	identity_valid := false
	for octet in request.expected_image_identity {
		if octet != 0 {identity_valid = true; break}
	}
	if !identity_valid {
		return {}, error_make(.Invalid_Argument, "expected image identity is required")
	}
	image_info, image_error := fat32session.validate_image(request.image_path, adapter)
	if image_error.code != .None {
		return {}, session_error_wrap(.Image_Rejected, "hard-drive image validation failed", image_error)
	}
	defer fat32session.image_info_destroy(&image_info)
	if !image_info.enrolled || !image_info.retvrn99_format {
		return {}, error_make(.Image_Not_RETVRN99, "Windows 98 preparation binding requires a RETVRN99 hard-drive image")
	}
	if image_info.image_id != request.expected_image_identity {
		return {}, error_make(.Image_Identity_Mismatch, "the selected hard drive does not match the prepared image identity")
	}
	session, open_error := fat32session.open_edit(
		request.image_path,
		request.edit_session_id,
		request.preparation_transaction_id,
		adapter,
	)
	if open_error.code != .None {
		return {}, session_error_wrap(.Edit_Failed, "cannot inspect the bound preparation Edit transaction", open_error)
	}
	defer if session != nil {
		if image_info.dirty {
			prepare_retain_session(&session)
		} else {
			prepare_discard_session(&session)
		}
	}
	owner: Preparation_Owner
	if request.allow_consumed_content {
		owner_exists: bool
		owner_error: Error
		owner, owner_exists, owner_error = owner_read(session)
		if owner_error.code != .None {return {}, owner_error}
		if !owner_exists {
			return {}, error_make(
				.Not_Prepared,
				"the selected hard drive no longer contains its Windows 98 preparation owner",
			)
		}
	} else {
		state, detected_owner, detect_error := disk_detect(session, image_info.image_id)
		if detect_error.code != .None {return {}, detect_error}
		if state != .Prepared {
			return {}, error_make(
				.Not_Prepared,
				"the selected hard drive does not contain a prepared Windows 98 installation",
			)
		}
		owner = detected_owner
	}
	if owner.image_identity != image_info.image_id ||
	   owner.image_identity != request.expected_image_identity {
		return {}, error_make(.Image_Identity_Mismatch, "preparation ownership does not match the selected image identity")
	}
	if owner.transaction_id != request.preparation_transaction_id {
		return {}, error_make(.Transaction_Mismatch, "preparation ownership does not match the selected Edit transaction")
	}
	if !request.allow_consumed_content {
		if ownership_error := abandon_verify_owned_content(session, &owner);
		   ownership_error.code != .None {
			return {}, ownership_error
		}
	}
	close_error := fat32session.edit_finish(session, false)
	if close_error.code != .None {
		if close_error.outcome == .Completed {
			session = nil
		} else {
			prepare_retain_session(&session)
		}
		return {}, session_error_wrap(.Edit_Failed, "cannot close the preparation binding inspection", close_error)
	}
	session = nil
	return Preparation_Binding {
		image_identity = image_info.image_id,
		edit_transaction_id = owner.transaction_id,
		boot_target = owner.boot_target,
	}, {}
}
