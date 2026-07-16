// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import disk "../disk"
import fat32image "../fat32image"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Process_Implementation :: struct {
	allocator:        runtime.Allocator,
	request:          ^os.File,
	response:         ^os.File,
	process:          os.Process,
	launched:         bool,
	closed:           bool,
	frozen:           bool,
	request_id:       u64,
	sequence:         u64,
	durable_sequence: u64,
	last_error:       Session_Error,
}

process_helper_path :: proc(allocator: runtime.Allocator) -> (string, Session_Error) {
	info, info_error := os.current_process_info({.Executable_Path}, context.temp_allocator)
	if info_error != nil {
		return "", error_make(
			.Helper_Missing,
			false,
			.Not_Started,
			0,
			0,
			"cannot locate the RETVRN99-FAT32 helper",
		)
	}
	defer os.free_process_info(info, context.temp_allocator)
	path, path_error := filepath.join(
		{filepath.dir(info.executable_path), HELPER_EXECUTABLE},
		allocator,
	)
	if path_error != nil || !os.exists(path) {
		delete(path, allocator)
		return "", error_make(
			.Helper_Missing,
			false,
			.Not_Started,
			0,
			0,
			"RETVRN99-FAT32 is missing beside RETVRN99",
		)
	}
	return path, {}
}

@(private = "package")
process_launch :: proc(
	allocator := context.allocator,
	crash_phase := "",
) -> (
	^Process_Implementation,
	Session_Error,
) {
	helper, helper_error := process_helper_path(allocator)
	if helper_error.code != .None {return nil, helper_error}
	defer delete(helper, allocator)
	child_input, parent_request, input_error := process_pipe_create()
	if input_error != nil {
		return nil, error_make(
			.Helper_Launch_Failed,
			false,
			.Not_Started,
			0,
			0,
			"cannot create the FAT32 request pipe",
		)
	}
	parent_response, child_output, output_error := process_pipe_create()
	if output_error != nil {
		_ = os.close(child_input)
		_ = os.close(parent_request)
		return nil, error_make(
			.Helper_Launch_Failed,
			false,
			.Not_Started,
			0,
			0,
			"cannot create the FAT32 response pipe",
		)
	}
	if !process_pipe_parent_ends_secure(parent_request, parent_response) {
		_ = os.close(child_input)
		_ = os.close(parent_request)
		_ = os.close(parent_response)
		_ = os.close(child_output)
		return nil, error_make(
			.Helper_Launch_Failed,
			false,
			.Not_Started,
			0,
			0,
			"cannot secure the FAT32 parent pipe handles",
		)
	}
	command := []string{helper, "--pipe"}
	if crash_phase != "" {
		command = []string{helper, "--pipe", "--crash-phase", crash_phase}
	}
	process, launch_error := os.process_start(
		os.Process_Desc {
			working_dir = filepath.dir(helper),
			command = command,
			stdin = child_input,
			stdout = child_output,
		},
	)
	_ = os.close(child_input)
	_ = os.close(child_output)
	if launch_error != nil {
		_ = os.close(parent_request)
		_ = os.close(parent_response)
		return nil, error_make(
			.Helper_Launch_Failed,
			false,
			.Not_Started,
			0,
			0,
			"RETVRN99-FAT32 could not be launched",
		)
	}
	impl := new(Process_Implementation, allocator)
	impl.allocator = allocator
	impl.request = parent_request
	impl.response = parent_response
	impl.process = process
	impl.launched = true
	return impl, {}
}

process_transport_fail :: proc(
	impl: ^Process_Implementation,
	err: Session_Error,
) -> Session_Error {
	result := err
	if impl != nil {
		impl.frozen = true
		result.sequence = impl.sequence
		result.durable_sequence = impl.durable_sequence
		impl.last_error = result
	}
	return result
}

@(private = "package")
process_helper_error_is_terminal :: proc(flags: Protocol_Flags, err: Session_Error) -> bool {
	if .Terminal in flags {return true}
	return(
		err.code == .Protocol_Malformed ||
		err.code == .Protocol_Mismatch ||
		err.code == .Protocol_Order ||
		err.code == .Transport_Lost ||
		err.code == .FAT_Invalid ||
		err.code == .State_Mismatch \
	)
}

@(private = "package")
process_helper_fail :: proc(
	impl: ^Process_Implementation,
	flags: Protocol_Flags,
	err: Session_Error,
) -> Session_Error {
	if impl == nil || !process_helper_error_is_terminal(flags, err) {return err}
	impl.frozen = true
	impl.sequence = max(impl.sequence, err.sequence)
	impl.durable_sequence = max(impl.durable_sequence, err.durable_sequence)
	impl.last_error = err
	return err
}

process_exchange :: proc(
	impl: ^Process_Implementation,
	kind: Protocol_Kind,
	payload: []u8,
	allocator := context.temp_allocator,
) -> (
	Protocol_Frame,
	Session_Error,
) {
	if impl == nil || impl.closed || impl.frozen {
		if impl != nil && impl.last_error.code != .None {return {}, impl.last_error}
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 helper is not available")
	}
	impl.request_id += 1
	write_error := protocol_write_frame(
		impl.request,
		Protocol_Frame{kind = u16(kind), request_id = impl.request_id, payload = payload},
	)
	if write_error.code != .None {return {}, process_transport_fail(impl, write_error)}
	frame, read_error := protocol_read_frame(impl.response, allocator)
	if read_error.code != .None {return {}, process_transport_fail(impl, read_error)}
	if frame.request_id != impl.request_id || frame.kind != u16(kind) | PROTOCOL_RESPONSE_BIT {
		protocol_frame_destroy(&frame, allocator)
		return {}, process_transport_fail(impl, error_make(.Protocol_Order, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 helper response ordering is invalid"))
	}
	if .Error in frame.flags {
		err := protocol_error_decode(frame.payload)
		flags := frame.flags
		protocol_frame_destroy(&frame, allocator)
		return {}, process_helper_fail(impl, flags, err)
	}
	return frame, {}
}

process_exchange_parts :: proc(
	impl: ^Process_Implementation,
	kind: Protocol_Kind,
	parts: ..[]u8,
	allocator := context.temp_allocator,
) -> (
	Protocol_Frame,
	Session_Error,
) {
	if impl == nil || impl.closed || impl.frozen {
		if impl != nil && impl.last_error.code != .None {return {}, impl.last_error}
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 helper is not available")
	}
	impl.request_id += 1
	write_error := protocol_write_frame_parts(
		impl.request,
		u16(kind),
		impl.request_id,
		{},
		..parts,
	)
	if write_error.code != .None {return {}, process_transport_fail(impl, write_error)}
	frame, read_error := protocol_read_frame(impl.response, allocator)
	if read_error.code != .None {return {}, process_transport_fail(impl, read_error)}
	if frame.request_id != impl.request_id || frame.kind != u16(kind) | PROTOCOL_RESPONSE_BIT {
		protocol_frame_destroy(&frame, allocator)
		return {}, process_transport_fail(impl, error_make(.Protocol_Order, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 helper response ordering is invalid"))
	}
	if .Error in frame.flags {
		err := protocol_error_decode(frame.payload)
		flags := frame.flags
		protocol_frame_destroy(&frame, allocator)
		return {}, process_helper_fail(impl, flags, err)
	}
	return frame, {}
}

process_exchange_into :: proc(
	impl: ^Process_Implementation,
	kind: Protocol_Kind,
	request_payload, response_payload: []u8,
) -> (int, Session_Error) {
	if impl == nil || impl.closed || impl.frozen {
		if impl != nil && impl.last_error.code != .None {return 0, impl.last_error}
		return 0, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 helper is not available")
	}
	impl.request_id += 1
	write_error := protocol_write_frame(
		impl.request,
		Protocol_Frame{kind = u16(kind), request_id = impl.request_id, payload = request_payload},
	)
	if write_error.code != .None {return 0, process_transport_fail(impl, write_error)}
	response_kind, response_id, flags, length, read_error := protocol_read_frame_into(
		impl.response,
		response_payload,
	)
	if read_error.code != .None {return 0, process_transport_fail(impl, read_error)}
	if response_id != impl.request_id || response_kind != u16(kind) | PROTOCOL_RESPONSE_BIT {
		return 0, process_transport_fail(impl, error_make(.Protocol_Order, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 helper response ordering is invalid"))
	}
	if .Error in flags {
		err := protocol_error_decode(response_payload[:length])
		return 0, process_helper_fail(impl, flags, err)
	}
	return length, {}
}

@(private = "file")
process_shutdown :: proc(impl: ^Process_Implementation) {
	if impl == nil || impl.closed || impl.frozen {return}
	frame, _ := process_exchange(impl, .Shutdown, nil)
	protocol_frame_destroy(&frame, context.temp_allocator)
	impl.closed = true
}

process_validate_image :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> (
	Image_Info,
	Session_Error,
) {
	if path ==
	   "" {return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "hard-drive image path is empty")}
	impl, launch_error := process_launch(allocator)
	if launch_error.code != .None {return {}, launch_error}
	defer process_destroy(impl)
	frame, exchange_error := process_exchange(impl, .Validate, transmute([]u8)path)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	info, decoded := protocol_image_info_decode(frame.payload, allocator)
	if !decoded {return {}, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 image validation response is malformed"))}
	process_shutdown(impl)
	return info, {}
}

process_create_image :: proc(
	request: Create_Image_Request,
	allocator: runtime.Allocator,
) -> (
	Image_Info,
	Session_Error,
) {
	if request.path ==
	   "" {return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "hard-drive image path is empty")}
	impl, launch_error := process_launch(allocator)
	if launch_error.code != .None {return {}, launch_error}
	defer process_destroy(impl)
	payload := make([]u8, 8 + len(request.path), context.temp_allocator)
	put_u32le(payload, 0, request.capacity_gib)
	put_u32le(payload, 4, request.allow_full_allocation ? 1 : 0)
	copy(payload[8:], transmute([]u8)request.path)
	frame, exchange_error := process_exchange(impl, .Create, payload)
	if exchange_error.code != .None {return {}, exchange_error}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	info, decoded := protocol_image_info_decode(frame.payload, allocator)
	if !decoded {return {}, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 image creation response is malformed"))}
	process_shutdown(impl)
	return info, {}
}

open_process :: proc(image_path, machine_session_id: string) -> (^Machine_Session, Session_Error) {
	return open_process_configured(image_path, machine_session_id, "")
}

open_process_configured :: proc(
	image_path, machine_session_id, crash_phase: string,
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
	allocator := context.allocator
	impl, launch_error := process_launch(allocator, crash_phase)
	if launch_error.code != .None {return nil, launch_error}
	payload := make([]u8, 8 + len(image_path) + len(machine_session_id), context.temp_allocator)
	put_u32le(payload, 0, u32(len(image_path)))
	put_u32le(payload, 4, u32(len(machine_session_id)))
	copy(payload[8:], transmute([]u8)image_path)
	copy(payload[8 + len(image_path):], transmute([]u8)machine_session_id)
	frame, open_error := process_exchange(impl, .Open_Machine, payload)
	if open_error.code != .None {
		process_destroy(impl)
		return nil, open_error
	}
	if len(frame.payload) != 24 {
		protocol_frame_destroy(&frame, context.temp_allocator)
		err := process_transport_fail(
			impl,
			error_make(
				.Protocol_Malformed,
				false,
				.Not_Started,
				0,
				0,
				"FAT32 open response is malformed",
			),
		)
		process_destroy(impl)
		return nil, err
	}
	sector_count := get_u64le(frame.payload, 0)
	impl.sequence = get_u64le(frame.payload, 8)
	impl.durable_sequence = get_u64le(frame.payload, 16)
	protocol_frame_destroy(&frame, context.temp_allocator)
	session := new(Machine_Session, allocator)
	session.ctx = impl
	session.adapter = .Process
	session.device = disk.Block_Device {
		ctx          = impl,
		sector_count = sector_count,
		read         = process_block_read,
		write        = process_block_write,
		flush        = process_block_flush,
	}
	session.operations = Machine_Operations {
		ready = process_ready,
		terminal_error = process_terminal_error,
		barrier = process_barrier,
		observe = process_observe,
		close = process_close,
		destroy = proc(ctx: rawptr) {process_destroy((^Process_Implementation)(ctx))},
	}
	return session, {}
}

process_ready :: proc(ctx: rawptr) -> bool {
	impl := (^Process_Implementation)(ctx)
	if impl == nil || !impl.launched || impl.closed || impl.frozen {return false}
	_, terminal := process_terminal_error(impl)
	return !terminal
}

process_terminal_error :: proc(ctx: rawptr) -> (Session_Error, bool) {
	impl := (^Process_Implementation)(ctx)
	if impl == nil {return {}, false}
	if impl.last_error.code != .None && impl.frozen {return impl.last_error, true}
	if impl.closed || !impl.launched {return {}, false}
	state, wait_error := os.process_wait(impl.process, 0)
	if wait_error == os.General_Error.Timeout {return {}, false}
	if wait_error != nil {
		err := process_transport_fail(
			impl,
			error_make(
				.Transport_Lost,
				false,
				.Uncertain,
				impl.sequence,
				impl.durable_sequence,
				"cannot determine RETVRN99-FAT32 helper health",
			),
		)
		return err, true
	}
	if !state.exited {return {}, false}
	impl.launched = false
	err := process_transport_fail(
		impl,
		error_make(
			.Transport_Lost,
			false,
			.Uncertain,
			impl.sequence,
			impl.durable_sequence,
			fmt.tprintf("RETVRN99-FAT32 helper exited unexpectedly with code %d", state.exit_code),
		),
	)
	return err, true
}

process_block_read :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^Process_Implementation)(ctx)
	if len(data) == 0 ||
	   len(data) > MAX_BLOCK_BYTES ||
	   len(data) % fat32image.SECTOR_BYTES != 0 {return false}
	payload: [12]u8
	put_u64le(payload[:], 0, lba)
	put_u32le(payload[:], 8, u32(len(data)))
	length, err := process_exchange_into(impl, .Read, payload[:], data)
	if err.code != .None {return false}
	if length != len(data) {
		_ = process_transport_fail(
			impl,
			error_make(
				.Protocol_Malformed,
				false,
				.Uncertain,
				impl.sequence,
				impl.durable_sequence,
				"FAT32 read response length is invalid",
			),
		)
		return false
	}
	return true
}

process_block_write :: proc(ctx: rawptr, lba: u64, data: []u8) -> bool {
	impl := (^Process_Implementation)(ctx)
	if len(data) == 0 ||
	   len(data) > MAX_BLOCK_BYTES ||
	   len(data) % fat32image.SECTOR_BYTES != 0 {return false}
	prefix: [8]u8
	put_u64le(prefix[:], 0, lba)
	frame, err := process_exchange_parts(impl, .Write, prefix[:], data)
	if err.code != .None {return false}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) != 16 {
		_ = process_transport_fail(
			impl,
			error_make(
				.Protocol_Malformed,
				false,
				.Uncertain,
				impl.sequence,
				impl.durable_sequence,
				"FAT32 write response is malformed",
			),
		)
		return false
	}
	impl.sequence = get_u64le(frame.payload, 0)
	impl.durable_sequence = get_u64le(frame.payload, 8)
	return true
}

process_block_flush :: proc(ctx: rawptr) -> bool {
	_, err := process_barrier(ctx, .Block_Flush)
	return err.code == .None
}

process_barrier :: proc(ctx: rawptr, reason: Barrier_Reason) -> (Barrier_Result, Session_Error) {
	impl := (^Process_Implementation)(ctx)
	frame, err := process_exchange(impl, .Barrier, []u8{u8(reason)})
	if err.code != .None {return {}, err}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	result, ok := protocol_barrier_decode(frame.payload)
	if !ok {return {}, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 barrier response is malformed"))}
	impl.sequence = result.sequence
	impl.durable_sequence = result.durable_sequence
	return result, {}
}

process_observe_chunk :: proc(
	impl: ^Process_Implementation,
	probe: Probe,
	allocator: runtime.Allocator,
) -> (
	Barrier_Result,
	Observation,
	bool,
	Session_Error,
) {
	validation_error := observation_probes_validate(
		[]Probe{probe},
		impl.sequence,
		impl.durable_sequence,
	)
	if validation_error.code != .None {return {}, {}, false, validation_error}
	if probe.length > OBSERVATION_CHUNK_BYTES {
		return {}, {}, false, error_make(.Frame_Too_Large, false, .Not_Started, impl.sequence, impl.durable_sequence, "FAT observation chunk exceeds 128 KiB")
	}
	payload := make([]u8, 28 + len(probe.path), context.temp_allocator)
	payload[0] = u8(probe.kind)
	put_u64le(payload, 8, probe.offset)
	put_u64le(payload, 16, probe.length)
	put_u32le(payload, 24, u32(len(probe.path)))
	copy(payload[28:], transmute([]u8)probe.path)
	frame, err := process_exchange(impl, .Observe, payload)
	if err.code != .None {return {}, {}, false, err}
	defer protocol_frame_destroy(&frame, context.temp_allocator)
	if len(frame.payload) < 48 {
		return {}, {}, false, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 observation response is truncated"))
	}
	path_length := int(get_u32le(frame.payload, 20))
	data_length := int(get_u32le(frame.payload, 40))
	if path_length < 0 ||
	   path_length > MAX_OBSERVATION_PATH_BYTES ||
	   data_length < 0 ||
	   data_length > OBSERVATION_CHUNK_BYTES ||
	   48 + path_length + data_length != len(frame.payload) {
		return {}, {}, false, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 observation response length is invalid"))
	}
	pending := frame.payload[17] == 1
	if string(frame.payload[48:48 + path_length]) != probe.path ||
	   frame.payload[16] > u8(Materialization.Pending) ||
	   frame.payload[17] > 1 ||
	   frame.payload[18] > u8(Observed_Type.Directory) ||
	   u64(data_length) > probe.length ||
	   pending != (Materialization(frame.payload[16]) == .Pending) ||
	   pending && data_length != 0 {
		return {}, {}, false, process_transport_fail(impl, error_make(.Protocol_Malformed, false, .Uncertain, impl.sequence, impl.durable_sequence, "FAT32 observation response is invalid"))
	}
	result := Barrier_Result {
		sequence         = get_u64le(frame.payload, 0),
		durable_sequence = get_u64le(frame.payload, 8),
		materialization  = Materialization(frame.payload[16]),
	}
	item := Observation {
		path   = strings.clone(string(frame.payload[48:48 + path_length]), allocator),
		type   = Observed_Type(frame.payload[18]),
		size   = get_u64le(frame.payload, 24),
		offset = get_u64le(frame.payload, 32),
		data   = make([]u8, data_length, allocator),
	}
	copy(item.data, frame.payload[48 + path_length:])
	impl.sequence = result.sequence
	impl.durable_sequence = result.durable_sequence
	if pending {
		delete(item.path, allocator)
		delete(item.data, allocator)
		return result, {}, true, {}
	}
	return result, item, false, {}
}

process_observe :: proc(
	ctx: rawptr,
	probes: []Probe,
	allocator: runtime.Allocator,
) -> (
	Observation_Batch,
	Session_Error,
) {
	impl := (^Process_Implementation)(ctx)
	if impl == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is closed")
	}
	validation_error := observation_probes_validate(probes, impl.sequence, impl.durable_sequence)
	if validation_error.code != .None {return {}, validation_error}
	batch := Observation_Batch {
		items = make([]Observation, len(probes), allocator),
	}
	coherent := false
	for probe, index in probes {
		stat_result, stat_item, stat_pending, stat_error := process_observe_chunk(
			impl,
			Probe{kind = .Stat, path = probe.path},
			allocator,
		)
		if stat_error.code != .None {
			observation_batch_destroy(&batch, allocator)
			batch.pending = stat_error.code == .Observation_Pending
			return batch, stat_error
		}
		if stat_pending {
			observation_batch_destroy(&batch, allocator)
			return Observation_Batch {
					barrier = stat_result,
					pending = true,
				},
				{}
		}
		if !coherent {
			batch.barrier = stat_result
			coherent = true
		} else if stat_result.sequence != batch.barrier.sequence ||
		   stat_result.durable_sequence != batch.barrier.durable_sequence {
			delete(stat_item.path, allocator)
			delete(stat_item.data, allocator)
			observation_batch_destroy(&batch, allocator)
			return {}, error_make(.Observation_IO, true, .Uncertain, stat_result.sequence, stat_result.durable_sequence, "FAT32 observation lost sequence coherence")
		}
		batch.items[index] = stat_item
		if probe.kind == .Stat || stat_item.type != .Regular {continue}
		start := probe.offset
		if probe.kind ==
		   .Read_Tail {start = stat_item.size > probe.length ? stat_item.size - probe.length : 0}
		start = min(start, stat_item.size)
		wanted := min(probe.length, stat_item.size - start)
		if wanted > MAX_OBSERVATION_BYTES {
			observation_batch_destroy(&batch, allocator)
			return {}, error_make(.Frame_Too_Large, false, .Not_Started, stat_result.sequence, stat_result.durable_sequence, "FAT32 observation allocation is too large")
		}
		batch.items[index].offset = start
		batch.items[index].data = make([]u8, int(wanted), allocator)
		copied: u64
		for copied < wanted {
			length := min(u64(OBSERVATION_CHUNK_BYTES), wanted - copied)
			chunk_result, chunk, chunk_pending, chunk_error := process_observe_chunk(
				impl,
				Probe {
					kind = .Read_Range,
					path = probe.path,
					offset = start + copied,
					length = length,
				},
				context.temp_allocator,
			)
			if chunk_error.code != .None || chunk_pending ||
			   chunk_result.sequence != batch.barrier.sequence ||
			   chunk_result.durable_sequence != batch.barrier.durable_sequence ||
			   u64(len(chunk.data)) != length {
				delete(chunk.path, context.temp_allocator)
				delete(chunk.data, context.temp_allocator)
				observation_batch_destroy(&batch, allocator)
				if chunk_error.code != .None {return {}, chunk_error}
				if chunk_pending {
					return Observation_Batch {
							barrier = chunk_result,
							pending = true,
						},
						{}
				}
				return {}, error_make(.Observation_IO, true, .Uncertain, chunk_result.sequence, chunk_result.durable_sequence, "FAT32 observation chunk is incoherent")
			}
			copy(batch.items[index].data[int(copied):], chunk.data)
			delete(chunk.path, context.temp_allocator)
			delete(chunk.data, context.temp_allocator)
			copied += length
		}
	}
	return batch, {}
}

process_close :: proc(ctx: rawptr, mode: Close_Mode) -> Session_Error {
	impl := (^Process_Implementation)(ctx)
	if impl == nil {return {}}
	if mode == .Retain && (impl.closed || impl.frozen) {
		impl.closed = true
		return {}
	}
	frame, err := process_exchange(impl, .Close, []u8{u8(mode)})
	if err.code != .None {
		if mode == .Retain {
			impl.closed = true
			return {}
		}
		return err
	}
	protocol_frame_destroy(&frame, context.temp_allocator)
	impl.closed = true
	return {}
}

process_destroy :: proc(impl: ^Process_Implementation) {
	if impl == nil {return}
	if impl.request != nil {_ = os.close(impl.request)}
	if impl.response != nil {_ = os.close(impl.response)}
	if impl.launched {
		state, wait_error := os.process_wait(impl.process, 5 * time.Second)
		if wait_error != nil || !state.exited {
			_ = os.process_kill(impl.process)
			_, _ = os.process_wait(impl.process)
		}
	}
	free(impl, impl.allocator)
}
