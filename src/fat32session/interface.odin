// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import disk "../disk"
import fat32fs "../fat32fs"
import fat32image "../fat32image"
import "base:runtime"

MAX_BLOCK_BYTES :: 128 * 1024
MAX_DIAGNOSTIC_BYTES :: 512
OBSERVATION_CHUNK_BYTES :: 128 * 1024
MAX_OBSERVATION_BYTES :: 16 * 1024 * 1024
MAX_OBSERVATION_PROBES :: 1024
MAX_OBSERVATION_PATH_BYTES :: fat32fs.MAX_PATH_BYTES

Image_Info :: fat32image.Image_Info
Create_Image_Request :: fat32image.Create_Request

image_info_destroy :: proc(info: ^Image_Info, allocator := context.allocator) {
	fat32image.info_destroy(info, allocator)
}

Adapter_Kind :: enum u8 {
	In_Process,
	Process,
}

DEFAULT_ADAPTER :: Adapter_Kind.Process

Barrier_Reason :: enum u8 {
	Block_Flush,
	Observation,
	Reset,
	Stop,
	Clean_Close,
}

Materialization :: enum u8 {
	Materialized,
	Pending,
}

Close_Mode :: enum u8 {
	Commit,
	Retain,
}

Error_Code :: enum u16 {
	None,
	Invalid_Argument,
	Invalid_State,
	Image_Missing,
	Image_Already_Exists,
	Image_Invalid,
	Image_Locked,
	Image_IO,
	Protected_Write,
	Sparse_Unsupported,
	Wal_IO,
	Recovery_Failed,
	State_Mismatch,
	FAT_Invalid,
	Protocol_Mismatch,
	Protocol_Malformed,
	Protocol_Order,
	Frame_Too_Large,
	Helper_Missing,
	Helper_Launch_Failed,
	Transport_Lost,
	Observation_Pending,
	Observation_IO,
	Internal,
	Name_Collision,
}

Operation_Outcome :: enum u8 {
	Not_Started,
	Completed,
	Retained,
	Uncertain,
}

Session_Error :: struct {
	code:              Error_Code,
	retryable:         bool,
	outcome:           Operation_Outcome,
	sequence:          u64,
	durable_sequence:  u64,
	diagnostic:        [MAX_DIAGNOSTIC_BYTES]u8,
	diagnostic_length: u16,
}

error_ok :: proc(err: ^Session_Error) -> bool {
	return err == nil || err.code == .None
}

error_text :: proc(err: ^Session_Error) -> string {
	if err == nil || err.diagnostic_length == 0 {return ""}
	return string(err.diagnostic[:int(err.diagnostic_length)])
}

error_make :: proc(
	code: Error_Code,
	retryable: bool,
	outcome: Operation_Outcome,
	sequence, durable_sequence: u64,
	diagnostic: string,
) -> Session_Error {
	result := Session_Error {
		code             = code,
		retryable        = retryable,
		outcome          = outcome,
		sequence         = sequence,
		durable_sequence = durable_sequence,
	}
	count := min(len(diagnostic), MAX_DIAGNOSTIC_BYTES)
	copy(result.diagnostic[:count], transmute([]u8)diagnostic)
	result.diagnostic_length = u16(count)
	return result
}

Barrier_Result :: struct {
	sequence:         u64,
	durable_sequence: u64,
	materialization:  Materialization,
}

Probe_Kind :: enum u8 {
	Stat,
	Read_Range,
	Read_Tail,
}

Probe :: struct {
	kind:   Probe_Kind,
	path:   string,
	offset: u64,
	length: u64,
}

Observed_Type :: enum u8 {
	Missing,
	Regular,
	Directory,
}

Observation :: struct {
	path:   string,
	type:   Observed_Type,
	size:   u64,
	offset: u64,
	data:   []u8,
}

Observation_Batch :: struct {
	barrier: Barrier_Result,
	pending: bool,
	items:   []Observation,
}

observation_probes_validate :: proc(
	probes: []Probe,
	sequence, durable_sequence: u64,
) -> Session_Error {
	if len(probes) == 0 {
		return error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			sequence,
			durable_sequence,
			"at least one FAT observation probe is required",
		)
	}
	if len(probes) > MAX_OBSERVATION_PROBES {
		return error_make(
			.Frame_Too_Large,
			false,
			.Not_Started,
			sequence,
			durable_sequence,
			"FAT observation probe count exceeds its bound",
		)
	}
	total_requested: u64
	for probe in probes {
		if probe.kind < .Stat || probe.kind > .Read_Tail {
			return error_make(
				.Invalid_Argument,
				false,
				.Not_Started,
				sequence,
				durable_sequence,
				"FAT observation probe kind is invalid",
			)
		}
		if len(probe.path) > MAX_OBSERVATION_PATH_BYTES {
			return error_make(
				.Frame_Too_Large,
				false,
				.Not_Started,
				sequence,
				durable_sequence,
				"FAT observation path exceeds its bound",
			)
		}
		if probe.kind == .Stat {continue}
		if probe.length > MAX_OBSERVATION_BYTES ||
		   total_requested > MAX_OBSERVATION_BYTES - probe.length {
			return error_make(
				.Frame_Too_Large,
				false,
				.Not_Started,
				sequence,
				durable_sequence,
				"FAT observation result exceeds its cumulative bound",
			)
		}
		total_requested += probe.length
	}
	return {}
}

observation_batch_destroy :: proc(batch: ^Observation_Batch, allocator := context.allocator) {
	if batch == nil {return}
	for &item in batch.items {
		delete(item.path, allocator)
		delete(item.data, allocator)
	}
	delete(batch.items, allocator)
	batch^ = {}
}

Machine_Operations :: struct {
	ready:          proc(ctx: rawptr) -> bool,
	terminal_error: proc(ctx: rawptr) -> (Session_Error, bool),
	barrier:        proc(ctx: rawptr, reason: Barrier_Reason) -> (Barrier_Result, Session_Error),
	observe:        proc(
		ctx: rawptr,
		probes: []Probe,
		allocator: runtime.Allocator,
	) -> (
		Observation_Batch,
		Session_Error,
	),
	close:          proc(ctx: rawptr, mode: Close_Mode) -> Session_Error,
	destroy:        proc(ctx: rawptr),
}

session_terminal_error :: proc(session: ^Machine_Session) -> (Session_Error, bool) {
	if session == nil || session.ctx == nil || session.operations.terminal_error == nil {
		return {}, false
	}
	return session.operations.terminal_error(session.ctx)
}

Machine_Session :: struct {
	ctx:        rawptr,
	adapter:    Adapter_Kind,
	device:     disk.Block_Device,
	operations: Machine_Operations,
}

session_ready :: proc(session: ^Machine_Session) -> bool {
	return(
		session != nil &&
		session.ctx != nil &&
		session.operations.ready != nil &&
		session.operations.ready(session.ctx) \
	)
}

block_device :: proc(session: ^Machine_Session) -> disk.Block_Device {
	if !session_ready(session) {return {}}
	return session.device
}

barrier :: proc(
	session: ^Machine_Session,
	reason: Barrier_Reason,
) -> (
	Barrier_Result,
	Session_Error,
) {
	if session == nil || session.ctx == nil || session.operations.barrier == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is not open")
	}
	return session.operations.barrier(session.ctx, reason)
}

observe :: proc(
	session: ^Machine_Session,
	probes: []Probe,
	allocator := context.allocator,
) -> (
	Observation_Batch,
	Session_Error,
) {
	if session == nil || session.ctx == nil || session.operations.observe == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Machine session is not open")
	}
	return session.operations.observe(session.ctx, probes, allocator)
}

close :: proc(session: ^Machine_Session, mode: Close_Mode) -> Session_Error {
	if session == nil {return {}}
	if session.ctx == nil || session.operations.close == nil {
		free(session)
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Machine session is not open",
		)
	}
	err := session.operations.close(session.ctx, mode)
	if err.code != .None && mode == .Commit && err.outcome != .Completed {return err}
	if session.operations.destroy != nil {session.operations.destroy(session.ctx)}
	session.ctx = nil
	free(session)
	return err
}

validate_image :: proc(
	path: string,
	adapter := DEFAULT_ADAPTER,
	allocator := context.allocator,
) -> (
	Image_Info,
	Session_Error,
) {
	switch adapter {
	case .In_Process:
		return validate_image_in_process(path, allocator)
	case .Process:
		return process_validate_image(path, allocator)
	}
	return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "unknown FAT32 Adapter")
}

@(private = "package")
validate_image_for_session :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	fat32image.Image_Info,
	bool,
	fat32image.Image_Error,
) {
	info, validation_error := fat32image.validate(path, allocator)
	if validation_error.code == .None {return info, false, {}}
	if validation_error.code != .Invalid_FAT32 {return {}, false, validation_error}
	recovery_info, recovery_error := fat32image.validate_recovery(path, allocator)
	if recovery_error.code == .None {return recovery_info, true, {}}
	return {}, false, validation_error
}

@(private = "package")
validate_image_in_process :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	Image_Info,
	Session_Error,
) {
	info, _, image_error := validate_image_for_session(path, allocator)
	if image_error.code != .None {return {}, image_error_map(image_error, 0, 0)}
	state_error := companion_state_validate(&info)
	if state_error.code != .None {
		image_info_destroy(&info, allocator)
		return {}, state_error
	}
	return info, {}
}

create_image :: proc(
	request: Create_Image_Request,
	adapter := DEFAULT_ADAPTER,
	allocator := context.allocator,
) -> (
	Image_Info,
	Session_Error,
) {
	switch adapter {
	case .In_Process:
		info, image_error := fat32image.create(request, allocator)
		return info, image_error_map(image_error, 0, 0)
	case .Process:
		return process_create_image(request, allocator)
	}
	return {}, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "unknown FAT32 Adapter")
}

open_machine :: proc(
	path, machine_session_id: string,
	adapter := DEFAULT_ADAPTER,
) -> (
	^Machine_Session,
	Session_Error,
) {
	switch adapter {
	case .In_Process:
		return open_in_process(path, machine_session_id)
	case .Process:
		return open_process(path, machine_session_id)
	}
	return nil, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "unknown FAT32 Adapter")
}
