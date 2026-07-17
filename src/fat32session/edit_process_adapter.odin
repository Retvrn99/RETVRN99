// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "base:runtime"

Edit_Process_Implementation :: struct {
	allocator:   runtime.Allocator,
	transport:   ^Process_Implementation,
	transaction: u64,
	changed:     u64,
	apply_active: bool,
	apply_progress: Edit_Apply_Progress,
}

@(private = "package")
edit_process_protocol_fail :: proc(
	impl: ^Edit_Process_Implementation,
	diagnostic: string,
) -> Session_Error {
	if impl == nil || impl.transport == nil {
		return error_make(.Protocol_Malformed, false, .Uncertain, 0, 0, diagnostic)
	}
	return process_transport_fail(
		impl.transport,
		error_make(.Protocol_Malformed, false, .Uncertain, 0, 0, diagnostic),
	)
}

open_edit_process :: proc(
	image_path, session_id: string,
	requested_transaction: u64 = 0,
) -> (
	^Edit_Session,
	Session_Error,
) {
	return open_edit_process_configured(image_path, session_id, requested_transaction, "")
}

@(private = "package")
open_edit_process_configured :: proc(
	image_path, session_id: string,
	requested_transaction: u64,
	crash_phase: string,
) -> (
	^Edit_Session,
	Session_Error,
) {
	if image_path == "" ||
	   session_id == "" ||
	   len(image_path) > PROTOCOL_EDIT_MAX_HOST_PATH_BYTES ||
	   len(session_id) > PROTOCOL_EDIT_MAX_SESSION_ID_BYTES ||
	   len(image_path) > max(int) - len(session_id) - 16 {
		return nil, error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"image path or Edit session id is invalid",
		)
	}
	allocator := context.allocator
	transport, launch_error := process_launch(allocator, crash_phase)
	if launch_error.code != .None {return nil, launch_error}
	payload := make([]u8, 16 + len(image_path) + len(session_id), context.temp_allocator)
	put_u32le(payload, 0, u32(len(image_path)))
	put_u32le(payload, 4, u32(len(session_id)))
	put_u64le(payload, 8, requested_transaction)
	copy(payload[16:], transmute([]u8)image_path)
	copy(payload[16 + len(image_path):], transmute([]u8)session_id)
	frame, open_error := process_exchange(transport, .Open_Edit, payload)
	if open_error.code != .None {
		process_destroy(transport)
		return nil, open_error
	}
	if len(frame.payload) != 16 || get_u64le(frame.payload, 0) == 0 {
		protocol_frame_destroy(&frame, context.temp_allocator)
		err := process_transport_fail(
			transport,
			error_make(
				.Protocol_Malformed,
				false,
				.Uncertain,
				0,
				0,
				"FAT32 Edit open response is malformed",
			),
		)
		process_destroy(transport)
		return nil, err
	}
	impl := new(Edit_Process_Implementation, allocator)
	impl.allocator = allocator
	impl.transport = transport
	impl.transaction = get_u64le(frame.payload, 0)
	impl.changed = get_u64le(frame.payload, 8)
	protocol_frame_destroy(&frame, context.temp_allocator)
	session := new(Edit_Session, allocator)
	session.ctx = impl
	session.adapter = .Process
	session.operations = edit_process_operations()
	return session, {}
}

@(private = "package")
edit_process_operations :: proc() -> Edit_Operations {
	return {
		ready = edit_process_ready,
		transaction_id = proc(ctx: rawptr) -> u64 {return(
				(^Edit_Process_Implementation)(ctx).transaction \
			)},
		changed_sector_count = proc(ctx: rawptr) -> u64 {return(
				(^Edit_Process_Implementation)(ctx).changed \
			)},
		list = edit_process_list,
		stat = edit_process_stat,
		read = edit_process_read,
		mkdir = proc(
			ctx: rawptr,
			path: string,
		) -> Session_Error {return edit_process_single_mutation(ctx, .Edit_Mkdir, path)},
		rename = proc(ctx: rawptr, source, destination: string) -> Session_Error {
			return edit_process_pair_mutation(ctx, .Edit_Rename, source, destination, false)
		},
		remove_recursive = proc(
			ctx: rawptr,
			path: string,
		) -> Session_Error {return edit_process_single_mutation(ctx, .Edit_Remove, path)},
		begin_remove_recursive = proc(
			ctx: rawptr,
			path: string,
		) -> Session_Error {return edit_process_single_mutation(ctx, .Edit_Begin_Remove, path)},
		begin_import_file = proc(
			ctx: rawptr,
			host_source, guest_destination: string,
			replace: bool,
		) -> Session_Error {
			return edit_process_pair_mutation(
				ctx,
				.Edit_Begin_Import_File,
				host_source,
				guest_destination,
				replace,
			)
		},
		begin_import_tree = proc(
			ctx: rawptr,
			host_source, guest_destination: string,
			replace: bool,
		) -> Session_Error {
			return edit_process_pair_mutation(
				ctx,
				.Edit_Begin_Import_Tree,
				host_source,
				guest_destination,
				replace,
			)
		},
		begin_export_file = proc(
			ctx: rawptr,
			guest_source, host_destination: string,
		) -> Session_Error {
			return edit_process_pair_mutation(
				ctx,
				.Edit_Begin_Export_File,
				guest_source,
				host_destination,
				false,
			)
		},
		job_step = edit_process_job_step,
		job_cancel = edit_process_job_cancel,
		adopt_image = edit_process_adopt_image,
		patch_boot_loader = edit_process_patch_boot_loader,
		restore_boot_loader = proc(ctx: rawptr) -> Session_Error {
			return edit_process_exchange_changed(
				(^Edit_Process_Implementation)(ctx),
				.Edit_Restore_Boot_Loader,
				nil,
			)
		},
		begin_apply = edit_process_begin_apply,
		step_apply = edit_process_step_apply,
		cancel_apply = edit_process_cancel_apply,
		apply = edit_process_apply,
		discard = proc(ctx: rawptr) -> Session_Error {return edit_process_close(
				ctx,
				.Edit_Discard,
			)},
		close_retain = proc(ctx: rawptr) -> Session_Error {return edit_process_close(
				ctx,
				.Edit_Retain,
			)},
		destroy = proc(ctx: rawptr) {edit_process_destroy((^Edit_Process_Implementation)(ctx))},
	}
}

edit_process_ready :: proc(ctx: rawptr) -> bool {
	impl := (^Edit_Process_Implementation)(ctx)
	return(
		impl != nil &&
		impl.transport != nil &&
		!impl.apply_active &&
		process_ready(impl.transport) \
	)
}

@(private = "package")
edit_process_decode_apply :: proc(
	impl: ^Edit_Process_Implementation,
	frame: ^Protocol_Frame,
) -> (
	Edit_Apply_Progress,
	Session_Error,
) {
	progress, decoded := protocol_edit_apply_decode(frame.payload)
	if !decoded {
		return {}, edit_process_protocol_fail(
			impl,
			"FAT32 Edit Apply progress response is malformed",
		)
	}
	return progress, {}
}

edit_process_begin_apply :: proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error) {
	impl := (^Edit_Process_Implementation)(ctx)
	if impl == nil || impl.transport == nil || impl.apply_active {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"another FAT32 Edit Apply is active",
		)
	}
	frame, exchange_error := process_exchange(impl.transport, .Edit_Apply_Begin, nil)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	progress, decode_error := edit_process_decode_apply(impl, &frame)
	if decode_error.code != .None {return {}, decode_error}
	if progress.state != .Ready || !progress.cancellable {
		return {}, edit_process_protocol_fail(
			impl,
			"FAT32 Edit Apply begin response has an invalid state",
		)
	}
	impl.apply_active = true
	impl.apply_progress = progress
	return progress, {}
}

edit_process_step_apply :: proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error) {
	impl := (^Edit_Process_Implementation)(ctx)
	if impl == nil || impl.transport == nil || !impl.apply_active {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply is not active",
		)
	}
	frame, exchange_error := process_exchange(impl.transport, .Edit_Apply_Step, nil)
	if exchange_error.code != .None {return impl.apply_progress, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	progress, decode_error := edit_process_decode_apply(impl, &frame)
	if decode_error.code != .None {return impl.apply_progress, decode_error}
	if progress.state != .Applying && progress.state != .Complete || progress.cancellable {
		return impl.apply_progress, edit_process_protocol_fail(
			impl,
			"FAT32 Edit Apply step response has an invalid state",
		)
	}
	if progress.completed_units < impl.apply_progress.completed_units ||
	   progress.applied_sectors < impl.apply_progress.applied_sectors ||
	   progress.total_units != impl.apply_progress.total_units ||
	   progress.total_sectors != impl.apply_progress.total_sectors {
		return impl.apply_progress, edit_process_protocol_fail(
			impl,
			"FAT32 Edit Apply progress moved backwards",
		)
	}
	impl.apply_progress = progress
	if progress.state == .Complete {
		impl.apply_active = false
		impl.transport.closed = true
	}
	return progress, {}
}

edit_process_cancel_apply :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_Process_Implementation)(ctx)
	if impl == nil || impl.transport == nil || !impl.apply_active {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply is not active",
		)
	}
	if !impl.apply_progress.cancellable {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply cannot be cancelled after its durable intent",
		)
	}
	frame, exchange_error := process_exchange(impl.transport, .Edit_Apply_Cancel, nil)
	if exchange_error.code != .None {return exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) != 0 {
		return edit_process_protocol_fail(impl, "FAT32 Edit Apply cancel response is malformed")
	}
	impl.apply_active = false
	impl.apply_progress = {}
	return {}
}

edit_process_apply :: proc(ctx: rawptr) -> Session_Error {
	impl := (^Edit_Process_Implementation)(ctx)
	_, begin_error := edit_process_begin_apply(ctx)
	if begin_error.code != .None {return begin_error}
	for impl.apply_active {
		progress, step_error := edit_process_step_apply(ctx)
		if step_error.code != .None {return step_error}
		if progress.state == .Complete {break}
	}
	return {}
}

@(private = "package")
edit_process_exchange_changed :: proc(
	impl: ^Edit_Process_Implementation,
	kind: Protocol_Kind,
	payload: []u8,
) -> Session_Error {
	frame, exchange_error := process_exchange(impl.transport, kind, payload)
	if exchange_error.code != .None {return exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) != 8 {
		return edit_process_protocol_fail(impl, "FAT32 Edit mutation response is malformed")
	}
	impl.changed = get_u64le(frame.payload, 0)
	return {}
}

edit_process_list :: proc(
	ctx: rawptr,
	path: string,
	cursor: u64,
	limit: int,
	allocator: runtime.Allocator,
) -> (
	Edit_Page,
	Session_Error,
) {
	impl := (^Edit_Process_Implementation)(ctx)
	if limit <= 0 ||
	   limit > PROTOCOL_EDIT_MAX_PAGE_ENTRIES ||
	   len(path) > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES {
		return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "FAT32 Edit page request exceeds its bound")
	}
	payload := make([]u8, 16 + len(path), context.temp_allocator)
	put_u64le(payload, 0, cursor)
	put_u32le(payload, 8, u32(limit))
	put_u32le(payload, 12, u32(len(path)))
	copy(payload[16:], transmute([]u8)path)
	frame, exchange_error := process_exchange(impl.transport, .Edit_List, payload)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	page, decoded := protocol_edit_page_decode(frame.payload, allocator)
	if !decoded {return {}, edit_process_protocol_fail(impl, "FAT32 Edit listing response is malformed")}
	return page, {}
}

edit_process_stat :: proc(ctx: rawptr, path: string) -> (Edit_Stat, Session_Error) {
	impl := (^Edit_Process_Implementation)(ctx)
	payload := protocol_edit_path_encode(
		path,
		PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES,
		context.temp_allocator,
	)
	if payload ==
	   nil {return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "FAT32 Edit stat path exceeds its bound")}
	frame, exchange_error := process_exchange(impl.transport, .Edit_Stat, payload)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	info, decoded := protocol_edit_stat_decode(frame.payload)
	if !decoded {return {}, edit_process_protocol_fail(impl, "FAT32 Edit stat response is malformed")}
	return info, {}
}

edit_process_read :: proc(
	ctx: rawptr,
	path: string,
	offset, length: u64,
	allocator: runtime.Allocator,
) -> (
	Edit_Read_Result,
	Session_Error,
) {
	impl := (^Edit_Process_Implementation)(ctx)
	if path == "" || len(path) > PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES || length > MAX_BLOCK_BYTES {
		return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "FAT32 Edit read request exceeds its bound")
	}
	payload := make([]u8, 20 + len(path), context.temp_allocator)
	put_u64le(payload, 0, offset)
	put_u64le(payload, 8, length)
	put_u32le(payload, 16, u32(len(path)))
	copy(payload[20:], transmute([]u8)path)
	frame, exchange_error := process_exchange(impl.transport, .Edit_Read, payload)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	result, decoded := protocol_edit_read_decode(frame.payload, allocator)
	if !decoded {return {}, edit_process_protocol_fail(impl, "FAT32 Edit read response is malformed")}
	return result, {}
}

@(private = "package")
edit_process_single_mutation :: proc(
	ctx: rawptr,
	kind: Protocol_Kind,
	path: string,
) -> Session_Error {
	impl := (^Edit_Process_Implementation)(ctx)
	payload := protocol_edit_path_encode(
		path,
		PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES,
		context.temp_allocator,
	)
	if payload == nil || path == "" {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit mutation path exceeds its bound",
		)
	}
	return edit_process_exchange_changed(impl, kind, payload)
}

@(private = "package")
edit_process_pair_mutation :: proc(
	ctx: rawptr,
	kind: Protocol_Kind,
	first, second: string,
	flag: bool,
) -> Session_Error {
	impl := (^Edit_Process_Implementation)(ctx)
	first_maximum := PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES
	second_maximum := PROTOCOL_EDIT_MAX_GUEST_PATH_BYTES
	if kind == .Edit_Begin_Import_File || kind == .Edit_Begin_Import_Tree {
		first_maximum = PROTOCOL_EDIT_MAX_HOST_PATH_BYTES
	}
	if kind == .Edit_Begin_Export_File {second_maximum = PROTOCOL_EDIT_MAX_HOST_PATH_BYTES}
	payload := protocol_edit_path_pair_encode(
		first,
		second,
		flag ? 1 : 0,
		first_maximum,
		second_maximum,
		context.temp_allocator,
	)
	if payload ==
	   nil {return error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "FAT32 Edit path pair exceeds its bound")}
	return edit_process_exchange_changed(impl, kind, payload)
}

edit_process_job_step :: proc(ctx: rawptr) -> (Edit_Job_Progress, Session_Error) {
	impl := (^Edit_Process_Implementation)(ctx)
	frame, exchange_error := process_exchange(impl.transport, .Edit_Job_Step, nil)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	progress, changed, decoded := protocol_edit_job_decode(frame.payload)
	if !decoded {return {}, edit_process_protocol_fail(impl, "FAT32 Edit job response is malformed")}
	impl.changed = changed
	return progress, {}
}

edit_process_job_cancel :: proc(ctx: rawptr) -> Session_Error {
	return edit_process_exchange_changed(
		(^Edit_Process_Implementation)(ctx),
		.Edit_Job_Cancel,
		nil,
	)
}

edit_process_adopt_image :: proc(ctx: rawptr) -> (Edit_Adoption_Result, Session_Error) {
	impl := (^Edit_Process_Implementation)(ctx)
	frame, exchange_error := process_exchange(impl.transport, .Edit_Adopt_Image, nil)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) != 32 || frame.payload[16] > 1 {
		return {}, edit_process_protocol_fail(impl, "FAT32 Edit adoption response is malformed")
	}
	result: Edit_Adoption_Result
	copy(result.image_identity[:], frame.payload[:16])
	result.staged = frame.payload[16] == 1
	impl.changed = get_u64le(frame.payload, 24)
	return result, {}
}

edit_process_patch_boot_loader :: proc(
	ctx: rawptr,
	io_sys_cluster: u32,
) -> (
	Boot_Target,
	Session_Error,
) {
	impl := (^Edit_Process_Implementation)(ctx)
	payload: [4]u8
	put_u32le(payload[:], 0, io_sys_cluster)
	frame, exchange_error := process_exchange(impl.transport, .Edit_Patch_Boot_Loader, payload[:])
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) != 24 ||
	   get_u32le(frame.payload, 0) != io_sys_cluster ||
	   get_u64le(frame.payload, 8) == 0 {
		return {}, edit_process_protocol_fail(impl, "FAT32 Edit boot-loader patch response is malformed")
	}
	impl.changed = get_u64le(frame.payload, 16)
	return Boot_Target{first_cluster = io_sys_cluster, lba = get_u64le(frame.payload, 8)}, {}
}

@(private = "package")
edit_process_close :: proc(ctx: rawptr, kind: Protocol_Kind) -> Session_Error {
	impl := (^Edit_Process_Implementation)(ctx)
	if impl == nil || impl.transport == nil {return {}}
	if kind == .Edit_Retain && (impl.transport.closed || impl.transport.frozen) {
		impl.transport.closed = true
		return {}
	}
	frame, exchange_error := process_exchange(impl.transport, kind, nil)
	if exchange_error.code != .None {
		if kind == .Edit_Retain {
			impl.transport.closed = true
			return {}
		}
		return exchange_error
	}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) !=
	   0 {return edit_process_protocol_fail(impl, "FAT32 Edit close response is malformed")}
	impl.transport.closed = true
	return {}
}

edit_process_destroy :: proc(impl: ^Edit_Process_Implementation) {
	if impl == nil {return}
	if impl.transport != nil {process_destroy(impl.transport)}
	free(impl, impl.allocator)
}
