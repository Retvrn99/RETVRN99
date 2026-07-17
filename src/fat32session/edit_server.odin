// SPDX-License-Identifier: GPL-3.0-only
package fat32session

@(private = "package")
server_edit_malformed :: proc(diagnostic: string) -> Session_Error {
	return error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, diagnostic)
}

@(private = "package")
server_handle_edit_open :: proc(payload: []u8) -> (^Edit_Session, []u8, Session_Error) {
	if len(payload) <
	   16 {return nil, nil, server_edit_malformed("FAT32 Edit open request is truncated")}
	path_length := int(get_u32le(payload, 0))
	session_length := int(get_u32le(payload, 4))
	if path_length <= 0 ||
	   path_length > PROTOCOL_EDIT_MAX_HOST_PATH_BYTES ||
	   session_length <= 0 ||
	   session_length > PROTOCOL_EDIT_MAX_SESSION_ID_BYTES ||
	   path_length > len(payload) - 16 ||
	   session_length != len(payload) - 16 - path_length {
		return nil, nil, server_edit_malformed("FAT32 Edit open request length is invalid")
	}
	image_path := string(payload[16:16 + path_length])
	session_id := string(payload[16 + path_length:])
	session, open_error := open_edit_in_process(image_path, session_id, get_u64le(payload, 8))
	if open_error.code != .None {return nil, nil, open_error}
	response := make([]u8, 16, context.temp_allocator)
	put_u64le(response, 0, edit_transaction_id(session))
	put_u64le(response, 8, edit_changed_sector_count(session))
	return session, response, {}
}

@(private = "package")
server_handle_edit_list :: proc(session: ^Edit_Session, payload: []u8) -> ([]u8, Session_Error) {
	if len(payload) <
	   16 {return nil, server_edit_malformed("FAT32 Edit list request is truncated")}
	limit := int(get_u32le(payload, 8))
	path_length := int(get_u32le(payload, 12))
	if limit <= 0 ||
	   limit > PROTOCOL_EDIT_MAX_PAGE_ENTRIES ||
	   path_length < 0 ||
	   path_length > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES ||
	   16 + path_length != len(payload) {
		return nil, server_edit_malformed("FAT32 Edit list request length is invalid")
	}
	page, list_error := edit_list(
		session,
		string(payload[16:]),
		get_u64le(payload, 0),
		limit,
		context.temp_allocator,
	)
	if list_error.code != .None {return nil, list_error}
	defer edit_page_destroy(&page, context.temp_allocator)
	response, encoded := protocol_edit_page_encode(&page, context.temp_allocator)
	if !encoded {
		return nil, error_make(
			.Frame_Too_Large,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit listing response exceeds its protocol bound",
		)
	}
	return response, {}
}

@(private = "package")
server_handle_edit_stat :: proc(session: ^Edit_Session, payload: []u8) -> ([]u8, Session_Error) {
	path, decoded := protocol_edit_path_decode(payload, PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES, true)
	if !decoded {return nil, server_edit_malformed("FAT32 Edit stat path is malformed")}
	info, stat_error := edit_stat(session, path)
	if stat_error.code != .None {return nil, stat_error}
	encoded := protocol_edit_stat_encode(info)
	response := make([]u8, len(encoded), context.temp_allocator)
	copy(response, encoded[:])
	return response, {}
}

@(private = "package")
server_handle_edit_read :: proc(session: ^Edit_Session, payload: []u8) -> ([]u8, Session_Error) {
	if len(payload) <
	   20 {return nil, server_edit_malformed("FAT32 Edit read request is truncated")}
	path_length := int(get_u32le(payload, 16))
	length := get_u64le(payload, 8)
	if path_length <= 0 ||
	   path_length > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES ||
	   20 + path_length != len(payload) ||
	   length > MAX_BLOCK_BYTES {
		return nil, server_edit_malformed("FAT32 Edit read request length is invalid")
	}
	result, read_error := edit_read(
		session,
		string(payload[20:]),
		get_u64le(payload, 0),
		length,
		context.temp_allocator,
	)
	if read_error.code != .None {return nil, read_error}
	defer edit_read_destroy(&result, context.temp_allocator)
	response, encoded := protocol_edit_read_encode(&result, context.temp_allocator)
	if !encoded {return nil, error_make(.Frame_Too_Large, false, .Not_Started, 0, 0, "FAT32 Edit read response exceeds 128 KiB")}
	return response, {}
}

@(private = "package")
server_edit_changed_response :: proc(
	session: ^Edit_Session,
	operation_error: Session_Error,
) -> (
	[]u8,
	Session_Error,
) {
	if operation_error.code != .None {return nil, operation_error}
	response := make([]u8, 8, context.temp_allocator)
	put_u64le(response, 0, edit_changed_sector_count(session))
	return response, {}
}

@(private = "package")
server_handle_edit_single_mutation :: proc(
	session: ^Edit_Session,
	kind: Protocol_Kind,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	path, decoded := protocol_edit_path_decode(payload, PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES)
	if !decoded {return nil, server_edit_malformed("FAT32 Edit mutation path is malformed")}
	err: Session_Error
	#partial switch kind {
	case .Edit_Mkdir:
		err = edit_mkdir(session, path)
	case .Edit_Remove:
		err = edit_remove_recursive(session, path)
	case .Edit_Begin_Remove:
		err = edit_begin_remove_recursive(session, path)
	}
	return server_edit_changed_response(session, err)
}

@(private = "package")
server_handle_edit_pair_mutation :: proc(
	session: ^Edit_Session,
	kind: Protocol_Kind,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	first_maximum := PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES
	second_maximum := PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES
	if kind == .Edit_Begin_Import_File || kind == .Edit_Begin_Import_Tree {
		first_maximum = PROTOCOL_EDIT_MAX_HOST_PATH_BYTES
	}
	if kind == .Edit_Begin_Export_File {second_maximum = PROTOCOL_EDIT_MAX_HOST_PATH_BYTES}
	first, second, flags, decoded := protocol_edit_path_pair_decode(
		payload,
		first_maximum,
		second_maximum,
	)
	if !decoded {return nil, server_edit_malformed("FAT32 Edit path-pair request is malformed")}
	err: Session_Error
	#partial switch kind {
	case .Edit_Rename:
		if flags != 0 {return nil, server_edit_malformed("FAT32 Edit rename flags are invalid")}
		err = edit_rename(session, first, second)
	case .Edit_Begin_Import_File:
		if flags & ~u32(1) !=
		   0 {return nil, server_edit_malformed("FAT32 Edit import flags are invalid")}
		err = edit_begin_import_file(session, first, second, flags & 1 != 0)
	case .Edit_Begin_Import_Tree:
		if flags & ~u32(1) !=
		   0 {return nil, server_edit_malformed("FAT32 Edit tree-import flags are invalid")}
		err = edit_begin_import_tree(session, first, second, flags & 1 != 0)
	case .Edit_Begin_Export_File:
		if flags != 0 {return nil, server_edit_malformed("FAT32 Edit export flags are invalid")}
		err = edit_begin_export_file(session, first, second)
	}
	return server_edit_changed_response(session, err)
}

@(private = "package")
server_handle_edit_job_step :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) !=
	   0 {return nil, server_edit_malformed("FAT32 Edit job-step request is malformed")}
	progress, step_error := edit_job_step(session)
	if step_error.code != .None {return nil, step_error}
	encoded := protocol_edit_job_encode(progress, edit_changed_sector_count(session))
	response := make([]u8, len(encoded), context.temp_allocator)
	copy(response, encoded[:])
	return response, {}
}

@(private = "package")
server_handle_edit_job_cancel :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) !=
	   0 {return nil, server_edit_malformed("FAT32 Edit job-cancel request is malformed")}
	return server_edit_changed_response(session, edit_job_cancel(session))
}

@(private = "package")
server_handle_edit_adopt_image :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) != 0 {
		return nil, server_edit_malformed("FAT32 Edit adoption request is malformed")
	}
	result, adoption_error := edit_adopt_image(session)
	if adoption_error.code != .None {return nil, adoption_error}
	response := make([]u8, 32, context.temp_allocator)
	copy(response[:16], result.image_identity[:])
	if result.staged {response[16] = 1}
	put_u64le(response, 24, edit_changed_sector_count(session))
	return response, {}
}

@(private = "package")
server_handle_edit_patch_boot_loader :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) !=
	   4 {return nil, server_edit_malformed("FAT32 Edit boot-loader patch request is malformed")}
	target, patch_error := edit_patch_boot_loader(session, get_u32le(payload, 0))
	if patch_error.code != .None {return nil, patch_error}
	response := make([]u8, 24, context.temp_allocator)
	put_u32le(response, 0, target.first_cluster)
	put_u64le(response, 8, target.lba)
	put_u64le(response, 16, edit_changed_sector_count(session))
	return response, {}
}

@(private = "package")
server_handle_edit_restore_boot_loader :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) !=
	   0 {return nil, server_edit_malformed("FAT32 Edit boot-loader restore request is malformed")}
	return server_edit_changed_response(session, edit_restore_boot_loader(session))
}

@(private = "package")
server_edit_apply_response :: proc(progress: Edit_Apply_Progress) -> []u8 {
	encoded := protocol_edit_apply_encode(progress)
	response := make([]u8, len(encoded), context.temp_allocator)
	copy(response, encoded[:])
	return response
}

@(private = "package")
server_handle_edit_apply_begin :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) != 0 {
		return nil, server_edit_malformed("FAT32 Edit Apply-begin request is malformed")
	}
	progress, begin_error := edit_begin_apply(session)
	if begin_error.code != .None {return nil, begin_error}
	return server_edit_apply_response(progress), {}
}

@(private = "package")
server_handle_edit_apply_step :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	bool,
	Session_Error,
) {
	if len(payload) != 0 {
		return nil, false, server_edit_malformed("FAT32 Edit Apply-step request is malformed")
	}
	progress, step_error := edit_step_apply(session)
	if step_error.code != .None {return nil, false, step_error}
	return server_edit_apply_response(progress), progress.state == .Complete, {}
}

@(private = "package")
server_handle_edit_apply_cancel :: proc(
	session: ^Edit_Session,
	payload: []u8,
) -> (
	[]u8,
	Session_Error,
) {
	if len(payload) != 0 {
		return nil, server_edit_malformed("FAT32 Edit Apply-cancel request is malformed")
	}
	cancel_error := edit_cancel_apply(session)
	if cancel_error.code != .None {return nil, cancel_error}
	return nil, {}
}
