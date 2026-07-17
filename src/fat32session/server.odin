// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"

server_request_valid :: proc(previous_request_id: u64, frame: Protocol_Frame) -> bool {
	return(
		frame.request_id == previous_request_id + 1 &&
		frame.kind >= u16(Protocol_Kind.Validate) &&
		frame.kind <= u16(Protocol_Kind.Edit_Retain) \
	)
}

server_send_error :: proc(
	output: ^os.File,
	kind: u16,
	request_id: u64,
	err: Session_Error,
) -> bool {
	payload := protocol_error_encode(err, context.temp_allocator)
	return(
		protocol_write_frame(output, Protocol_Frame{kind = kind | PROTOCOL_RESPONSE_BIT, request_id = request_id, flags = {.Error}, payload = payload}).code ==
		.None \
	)
}

server_send_machine_error :: proc(
	output: ^os.File,
	kind: u16,
	request_id: u64,
	session: ^Machine_Session,
	err: Session_Error,
) -> bool {
	flags := Protocol_Flags{.Error}
	_, terminal := session_terminal_error(session)
	if terminal {flags += {.Terminal}}
	payload := protocol_error_encode(err, context.temp_allocator)
	return(
		protocol_write_frame(output, Protocol_Frame{kind = kind | PROTOCOL_RESPONSE_BIT, request_id = request_id, flags = flags, payload = payload}).code ==
		.None \
	)
}

server_send :: proc(output: ^os.File, kind: u16, request_id: u64, payload: []u8) -> bool {
	return(
		protocol_write_frame(output, Protocol_Frame{kind = kind | PROTOCOL_RESPONSE_BIT, request_id = request_id, payload = payload}).code ==
		.None \
	)
}

server_runtime_error :: proc(session: ^Machine_Session, diagnostic: string) -> Session_Error {
	if session != nil && session.adapter == .In_Process {
		return in_process_runtime_error((^In_Process_Implementation)(session.ctx), diagnostic)
	}
	return error_make(.Internal, false, .Uncertain, 0, 0, diagnostic)
}

server_close_orphan :: proc(session: ^Machine_Session) {
	if session == nil {return}
	commit_error := close(session, .Commit)
	if commit_error.code != .None && commit_error.outcome != .Completed {
		_ = close(session, .Retain)
	}
}

server_close_edit_orphan :: proc(session: ^Edit_Session) {
	if session == nil {return}
	_ = edit_close_retain(session)
}

server_handle_open :: proc(payload: []u8) -> (^Machine_Session, []u8, Session_Error) {
	if len(payload) < 8 {
		return nil, nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 open request is truncated",
		)
	}
	path_length := int(get_u32le(payload, 0))
	session_length := int(get_u32le(payload, 4))
	if path_length <= 0 ||
	   session_length <= 0 ||
	   8 + path_length + session_length != len(payload) {
		return nil, nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 open request length is invalid",
		)
	}
	image_path := string(payload[8:8 + path_length])
	machine_session_id := string(payload[8 + path_length:])
	session, open_error := open_in_process(image_path, machine_session_id)
	if open_error.code != .None {return nil, nil, open_error}
	impl := (^In_Process_Implementation)(session.ctx)
	response := make([]u8, 24, context.temp_allocator)
	put_u64le(response, 0, session.device.sector_count)
	put_u64le(response, 8, impl.sequence)
	put_u64le(response, 16, impl.durable_sequence)
	return session, response, {}
}

server_handle_observe :: proc(session: ^Machine_Session, payload: []u8) -> ([]u8, Session_Error) {
	if len(payload) < 28 {
		return nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 observation request is truncated",
		)
	}
	path_length := int(get_u32le(payload, 24))
	if path_length < 0 || 28 + path_length != len(payload) {
		return nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 observation path length is invalid",
		)
	}
	probe := Probe {
		kind   = Probe_Kind(payload[0]),
		offset = get_u64le(payload, 8),
		length = get_u64le(payload, 16),
		path   = string(payload[28:]),
	}
	if probe.length > OBSERVATION_CHUNK_BYTES {
		return nil, error_make(
			.Frame_Too_Large,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 observation chunk exceeds 128 KiB",
		)
	}
	batch, observe_error := observe(session, []Probe{probe}, context.temp_allocator)
	if observe_error.code != .None {return nil, observe_error}
	defer observation_batch_destroy(&batch, context.temp_allocator)
	if batch.pending {
		response := make([]u8, 48 + len(probe.path), context.temp_allocator)
		put_u64le(response, 0, batch.barrier.sequence)
		put_u64le(response, 8, batch.barrier.durable_sequence)
		response[16] = u8(batch.barrier.materialization)
		response[17] = 1
		put_u32le(response, 20, u32(len(probe.path)))
		copy(response[48:], transmute([]u8)probe.path)
		return response, {}
	}
	if len(batch.items) != 1 {
		return nil, error_make(
			.Internal,
			false,
			.Uncertain,
			batch.barrier.sequence,
			batch.barrier.durable_sequence,
			"FAT32 observation returned the wrong item count",
		)
	}
	item := &batch.items[0]
	response := make([]u8, 48 + len(item.path) + len(item.data), context.temp_allocator)
	put_u64le(response, 0, batch.barrier.sequence)
	put_u64le(response, 8, batch.barrier.durable_sequence)
	response[16] = u8(batch.barrier.materialization)
	response[17] = batch.pending ? 1 : 0
	response[18] = u8(item.type)
	put_u32le(response, 20, u32(len(item.path)))
	put_u64le(response, 24, item.size)
	put_u64le(response, 32, item.offset)
	put_u32le(response, 40, u32(len(item.data)))
	copy(response[48:], transmute([]u8)item.path)
	copy(response[48 + len(item.path):], item.data)
	return response, {}
}

server_handle_validate :: proc(payload: []u8) -> ([]u8, Session_Error) {
	if len(payload) == 0 {
		return nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 validation path is empty",
		)
	}
	info, validation_error := validate_image_in_process(string(payload), context.temp_allocator)
	if validation_error.code != .None {return nil, validation_error}
	defer image_info_destroy(&info, context.temp_allocator)
	return protocol_image_info_encode(&info, context.temp_allocator), {}
}

server_handle_create :: proc(payload: []u8) -> ([]u8, Session_Error) {
	if len(payload) <= 8 {
		return nil, error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 create request is truncated",
		)
	}
	request := fat32image.Create_Request {
		path                  = string(payload[8:]),
		capacity_gib          = get_u32le(payload, 0),
		allow_full_allocation = get_u32le(payload, 4) != 0,
	}
	info, image_error := fat32image.create(request, context.temp_allocator)
	if image_error.code != .None {return nil, image_error_map(image_error, 0, 0)}
	defer fat32image.info_destroy(&info, context.temp_allocator)
	return protocol_image_info_encode(&info, context.temp_allocator), {}
}

serve :: proc(input, output: ^os.File) -> int {
	if input == nil || output == nil {return 2}
	request_id: u64
	session: ^Machine_Session
	edit_session: ^Edit_Session
	defer if session != nil {_ = close(session, .Retain)}
	defer if edit_session != nil {_ = edit_close_retain(edit_session)}
	for {
		frame, frame_error := protocol_read_frame(input, context.temp_allocator)
		if frame_error.code != .None {
			server_close_orphan(session)
			session = nil
			server_close_edit_orphan(edit_session)
			edit_session = nil
			free_all(context.temp_allocator)
			return 3
		}
		kind := frame.kind
		id := frame.request_id
		if !server_request_valid(request_id, frame) {
			_ = server_send_error(
				output,
				kind,
				id,
				error_make(
					.Protocol_Order,
					false,
					.Not_Started,
					0,
					0,
					"FAT32 request ordering is invalid",
				),
			)
			protocol_frame_destroy(&frame, context.temp_allocator)
			free_all(context.temp_allocator)
			return 4
		}
		request_id = id
		protocol_kind := Protocol_Kind(kind)
		is_service :=
			protocol_kind == .Validate || protocol_kind == .Create || protocol_kind == .Shutdown
		is_open := protocol_kind == .Open_Machine || protocol_kind == .Open_Edit
		is_machine_operation := protocol_kind >= .Read && protocol_kind <= .Close
		is_edit_operation := protocol_kind >= .Edit_List && protocol_kind <= .Edit_Retain
		active := session != nil || edit_session != nil
		lifecycle_valid :=
			is_service && !active ||
			is_open && !active ||
			is_machine_operation && session != nil && edit_session == nil ||
			is_edit_operation && edit_session != nil && session == nil
		if !lifecycle_valid {
			_ = server_send_error(
				output,
				kind,
				id,
				error_make(
					.Invalid_State,
					false,
					.Not_Started,
					0,
					0,
					"FAT32 session lifecycle request is invalid",
				),
			)
			protocol_frame_destroy(&frame, context.temp_allocator)
			free_all(context.temp_allocator)
			return 5
		}
		keep_running := true
		exit_after_response := false
		switch protocol_kind {
		case .Validate:
			payload, err := server_handle_validate(frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Create:
			payload, err := server_handle_create(frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Open_Machine:
			opened, payload, err := server_handle_open(frame.payload)
			if err.code == .None {
				session = opened
				keep_running = server_send(output, kind, id, payload)
			} else {
				keep_running = server_send_error(output, kind, id, err)
			}
		case .Open_Edit:
			opened, payload, err := server_handle_edit_open(frame.payload)
			if err.code == .None {
				edit_session = opened
				keep_running = server_send(output, kind, id, payload)
			} else {
				keep_running = server_send_error(output, kind, id, err)
			}
		case .Read:
			if len(frame.payload) != 12 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 read request is malformed",
					),
				)
				break
			}
			length := int(get_u32le(frame.payload, 8))
			if length <= 0 || length > MAX_BLOCK_BYTES || length % fat32image.SECTOR_BYTES != 0 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Frame_Too_Large,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 read length is invalid",
					),
				)
				break
			}
			data: [MAX_BLOCK_BYTES]u8
			if !session.device.read(session.device.ctx, get_u64le(frame.payload, 0), data[:length]) {
				keep_running = server_send_machine_error(
					output,
					kind,
					id,
					session,
					server_runtime_error(session, "FAT32 helper read failed"),
				)
			} else {
				keep_running = server_send(output, kind, id, data[:length])
			}
		case .Write:
			if len(frame.payload) <= 8 ||
			   len(frame.payload) - 8 > MAX_BLOCK_BYTES ||
			   (len(frame.payload) - 8) % fat32image.SECTOR_BYTES != 0 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Frame_Too_Large,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 write length is invalid",
					),
				)
			} else if !session.device.write(
				session.device.ctx,
				get_u64le(frame.payload, 0),
				frame.payload[8:],
			) {
				keep_running = server_send_machine_error(
					output,
					kind,
					id,
					session,
					server_runtime_error(session, "FAT32 helper write failed"),
				)
			} else {
				impl := (^In_Process_Implementation)(session.ctx)
				response: [16]u8
				put_u64le(response[:], 0, impl.sequence)
				put_u64le(response[:], 8, impl.durable_sequence)
				keep_running = server_send(output, kind, id, response[:])
			}
		case .Barrier:
			if len(frame.payload) != 1 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 barrier request is malformed",
					),
				)
				break
			}
			reason, reason_valid := protocol_barrier_reason_decode(frame.payload[0])
			if !reason_valid {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 barrier reason is invalid",
					),
				)
				break
			}
			result, err := barrier(session, reason)
			if err.code != .None {
				keep_running = server_send_machine_error(output, kind, id, session, err)
			} else {
				payload := protocol_barrier_encode(result)
				keep_running = server_send(output, kind, id, payload[:])
			}
		case .Observe:
			payload, err := server_handle_observe(session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_machine_error(output, kind, id, session, err)
		case .Close:
			if len(frame.payload) != 1 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 close request is malformed",
					),
				)
				break
			}
			mode, mode_valid := protocol_close_mode_decode(frame.payload[0])
			if !mode_valid {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 close mode is invalid",
					),
				)
				break
			}
			err := close(session, mode)
			released := err.code == .None || mode == .Retain || err.outcome == .Completed
			if released {session = nil}
			if err.code != .None {
				keep_running =
					released ? server_send_error(output, kind, id, err) :
					server_send_machine_error(output, kind, id, session, err)
			} else {
				keep_running = server_send(output, kind, id, nil)
			}
			if released {exit_after_response = true}
		case .Edit_List:
			payload, err := server_handle_edit_list(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Stat:
			payload, err := server_handle_edit_stat(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Read:
			payload, err := server_handle_edit_read(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Mkdir, .Edit_Remove, .Edit_Begin_Remove:
			payload, err := server_handle_edit_single_mutation(
				edit_session,
				protocol_kind,
				frame.payload,
			)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Rename,
		     .Edit_Begin_Import_File,
		     .Edit_Begin_Import_Tree,
		     .Edit_Begin_Export_File:
			payload, err := server_handle_edit_pair_mutation(
				edit_session,
				protocol_kind,
				frame.payload,
			)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Job_Step:
			payload, err := server_handle_edit_job_step(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Job_Cancel:
			payload, err := server_handle_edit_job_cancel(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Adopt_Image:
			payload, err := server_handle_edit_adopt_image(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Patch_Boot_Loader:
			payload, err := server_handle_edit_patch_boot_loader(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Restore_Boot_Loader:
			payload, err := server_handle_edit_restore_boot_loader(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Apply_Begin:
			payload, err := server_handle_edit_apply_begin(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Apply_Step:
			payload, completed, err := server_handle_edit_apply_step(
				edit_session,
				frame.payload,
			)
			if err.code != .None {
				if err.outcome == .Completed {
					edit_session = nil
					exit_after_response = true
				}
				keep_running = server_send_error(output, kind, id, err)
			} else {
				keep_running = server_send(output, kind, id, payload)
				if completed {
					edit_release_completed(edit_session)
					edit_session = nil
					exit_after_response = true
				}
			}
		case .Edit_Apply_Cancel:
			payload, err := server_handle_edit_apply_cancel(edit_session, frame.payload)
			keep_running =
				err.code == .None ? server_send(output, kind, id, payload) : server_send_error(output, kind, id, err)
		case .Edit_Discard, .Edit_Retain:
			if len(frame.payload) != 0 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					server_edit_malformed("FAT32 Edit close request is malformed"),
				)
				break
			}
			err: Session_Error
			if protocol_kind == .Edit_Discard {
				err = edit_finish(edit_session, false)
			} else {
				err = edit_close_retain(edit_session)
			}
			released := err.code == .None || err.outcome == .Completed
			if released {edit_session = nil}
			if err.code != .None {
				keep_running = server_send_error(output, kind, id, err)
			} else {
				keep_running = server_send(output, kind, id, nil)
			}
			if released {exit_after_response = true}
		case .Shutdown:
			if len(frame.payload) != 0 {
				keep_running = server_send_error(
					output,
					kind,
					id,
					error_make(
						.Protocol_Malformed,
						false,
						.Not_Started,
						0,
						0,
						"FAT32 shutdown request is malformed",
					),
				)
			} else {
				keep_running = server_send(output, kind, id, nil)
				exit_after_response = true
			}
		}
		protocol_frame_destroy(&frame, context.temp_allocator)
		free_all(context.temp_allocator)
		if exit_after_response {return keep_running ? 0 : 6}
		if !keep_running {
			server_close_orphan(session)
			session = nil
			server_close_edit_orphan(edit_session)
			edit_session = nil
			return 6
		}
	}
}
