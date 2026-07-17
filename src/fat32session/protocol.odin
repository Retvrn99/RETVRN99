// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "base:intrinsics"
import "base:runtime"
import "core:os"
import sse42 "core:simd/x86"
import "core:strings"

PROTOCOL_MAGIC :: u32(0x50393952)
PROTOCOL_VERSION :: u16(7)
PROTOCOL_HEADER_BYTES :: 32
PROTOCOL_MAX_PAYLOAD :: MAX_BLOCK_BYTES + 4096
PROTOCOL_RESPONSE_BIT :: u16(0x8000)

Protocol_Kind :: enum u16 {
	Validate = 1,
	Create,
	Open_Machine,
	Read,
	Write,
	Barrier,
	Observe,
	Close,
	Shutdown,
	Open_Edit,
	Edit_List,
	Edit_Stat,
	Edit_Read,
	Edit_Mkdir,
	Edit_Rename,
	Edit_Remove,
	Edit_Begin_Remove,
	Edit_Begin_Import_File,
	Edit_Begin_Import_Tree,
	Edit_Begin_Export_File,
	Edit_Job_Step,
	Edit_Job_Cancel,
	Edit_Adopt_Image,
	Edit_Patch_Boot_Loader,
	Edit_Restore_Boot_Loader,
	Edit_Apply_Begin,
	Edit_Apply_Step,
	Edit_Apply_Cancel,
	Edit_Discard,
	Edit_Retain,
}

Protocol_Flag :: enum u32 {
	Error = 0,
	Terminal,
}

Protocol_Flags :: bit_set[Protocol_Flag;u32]

Protocol_Frame :: struct {
	kind:       u16,
	request_id: u64,
	flags:      Protocol_Flags,
	payload:    []u8,
}

protocol_frame_destroy :: proc(frame: ^Protocol_Frame, allocator := context.allocator) {
	if frame == nil {return}
	delete(frame.payload, allocator)
	frame^ = {}
}

protocol_write_exact :: proc(file: ^os.File, data: []u8) -> bool {
	total := 0
	for total < len(data) {
		count, write_error := os.write(file, data[total:])
		if write_error != nil || count == 0 {return false}
		total += count
	}
	return true
}

protocol_read_exact :: proc(file: ^os.File, data: []u8) -> bool {
	total := 0
	for total < len(data) {
		count, read_error := os.read(file, data[total:])
		if read_error != nil || count == 0 {return false}
		total += count
	}
	return true
}

@(private = "file", enable_target_feature = "sse4.2")
protocol_checksum_update :: proc(checksum: u32, data: []u8) -> u32 {
	value := checksum
	offset := 0
	for offset + 8 <= len(data) {
		word := intrinsics.unaligned_load((^u64)(raw_data(data[offset:])))
		value = u32(sse42._mm_crc32_u64(u64(value), word))
		offset += 8
	}
	for octet in data[offset:] {value = sse42._mm_crc32_u8(value, octet)}
	return value
}

protocol_frame_checksum :: proc(header, payload: []u8) -> u32 {
	checksum := protocol_checksum_update(0xffff_ffff, header)
	checksum = protocol_checksum_update(checksum, payload)
	return ~checksum
}

protocol_write_frame :: proc(file: ^os.File, frame: Protocol_Frame) -> Session_Error {
	if file == nil || len(frame.payload) > PROTOCOL_MAX_PAYLOAD {
		return error_make(
			.Frame_Too_Large,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 protocol payload exceeds its bound",
		)
	}
	header: [PROTOCOL_HEADER_BYTES]u8
	put_u32le(header[:], 0, PROTOCOL_MAGIC)
	put_u16le(header[:], 4, PROTOCOL_VERSION)
	put_u16le(header[:], 6, frame.kind)
	put_u32le(header[:], 8, u32(len(frame.payload)))
	put_u64le(header[:], 16, frame.request_id)
	put_u32le(header[:], 24, transmute(u32)frame.flags)
	put_u32le(header[:], 12, protocol_frame_checksum(header[:], frame.payload))
	if !protocol_write_exact(file, header[:]) || !protocol_write_exact(file, frame.payload) {
		return error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe write failed")
	}
	return {}
}

protocol_write_frame_parts :: proc(
	file: ^os.File,
	kind: u16,
	request_id: u64,
	flags: Protocol_Flags,
	parts: ..[]u8,
) -> Session_Error {
	payload_length := 0
	for part in parts {
		if len(part) > PROTOCOL_MAX_PAYLOAD - payload_length {
			return error_make(
				.Frame_Too_Large,
				false,
				.Not_Started,
				0,
				0,
				"FAT32 protocol payload exceeds its bound",
			)
		}
		payload_length += len(part)
	}
	if file == nil {
		return error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe is unavailable")
	}
	header: [PROTOCOL_HEADER_BYTES]u8
	put_u32le(header[:], 0, PROTOCOL_MAGIC)
	put_u16le(header[:], 4, PROTOCOL_VERSION)
	put_u16le(header[:], 6, kind)
	put_u32le(header[:], 8, u32(payload_length))
	put_u64le(header[:], 16, request_id)
	put_u32le(header[:], 24, transmute(u32)flags)
	checksum := protocol_checksum_update(0xffff_ffff, header[:])
	for part in parts {
		checksum = protocol_checksum_update(checksum, part)
	}
	put_u32le(header[:], 12, ~checksum)
	if !protocol_write_exact(file, header[:]) {
		return error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe write failed")
	}
	for part in parts {
		if !protocol_write_exact(file, part) {
			return error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe write failed")
		}
	}
	return {}
}

protocol_read_frame_into :: proc(
	file: ^os.File,
	payload: []u8,
) -> (
	kind: u16,
	request_id: u64,
	flags: Protocol_Flags,
	payload_length: int,
	err: Session_Error,
) {
	header: [PROTOCOL_HEADER_BYTES]u8
	if file == nil || !protocol_read_exact(file, header[:]) {
		err = error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe closed")
		return
	}
	if get_u32le(header[:], 0) != PROTOCOL_MAGIC || get_u16le(header[:], 4) != PROTOCOL_VERSION {
		err = error_make(.Protocol_Mismatch, false, .Not_Started, 0, 0, "FAT32 protocol version mismatch")
		return
	}
	payload_length = int(get_u32le(header[:], 8))
	if payload_length < 0 || payload_length > PROTOCOL_MAX_PAYLOAD || payload_length > len(payload) {
		err = error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 protocol frame length is invalid")
		return
	}
	want_checksum := get_u32le(header[:], 12)
	put_u32le(header[:], 12, 0)
	if payload_length > 0 && !protocol_read_exact(file, payload[:payload_length]) {
		err = error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe payload is incomplete")
		return
	}
	if protocol_frame_checksum(header[:], payload[:payload_length]) != want_checksum {
		err = error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 protocol checksum failed")
		return
	}
	kind = get_u16le(header[:], 6)
	request_id = get_u64le(header[:], 16)
	flags = transmute(Protocol_Flags)get_u32le(header[:], 24)
	return
}

protocol_read_frame :: proc(
	file: ^os.File,
	allocator: runtime.Allocator,
) -> (
	Protocol_Frame,
	Session_Error,
) {
	header: [PROTOCOL_HEADER_BYTES]u8
	if file == nil || !protocol_read_exact(file, header[:]) {
		return {}, error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe closed")
	}
	if get_u32le(header[:], 0) != PROTOCOL_MAGIC || get_u16le(header[:], 4) != PROTOCOL_VERSION {
		return {}, error_make(.Protocol_Mismatch, false, .Not_Started, 0, 0, "FAT32 protocol version mismatch")
	}
	payload_length := int(get_u32le(header[:], 8))
	if payload_length < 0 || payload_length > PROTOCOL_MAX_PAYLOAD {
		return {}, error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 protocol frame length is invalid")
	}
	want_checksum := get_u32le(header[:], 12)
	put_u32le(header[:], 12, 0)
	payload := make([]u8, payload_length, allocator)
	if payload_length > 0 && !protocol_read_exact(file, payload) {
		delete(payload, allocator)
		return {}, error_make(.Transport_Lost, false, .Uncertain, 0, 0, "FAT32 pipe payload is incomplete")
	}
	if protocol_frame_checksum(header[:], payload) != want_checksum {
		delete(payload, allocator)
		return {}, error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 protocol checksum failed")
	}
	return Protocol_Frame {
		kind = get_u16le(header[:], 6),
		request_id = get_u64le(header[:], 16),
		flags = transmute(Protocol_Flags)get_u32le(header[:], 24),
		payload = payload,
	}, {}
}

protocol_error_encode :: proc(err: Session_Error, allocator: runtime.Allocator) -> []u8 {
	value := err
	length := int(value.diagnostic_length)
	payload := make([]u8, 24 + length, allocator)
	put_u16le(payload, 0, u16(err.code))
	payload[2] = err.retryable ? 1 : 0
	payload[3] = u8(err.outcome)
	put_u64le(payload, 4, err.sequence)
	put_u64le(payload, 12, err.durable_sequence)
	put_u16le(payload, 20, u16(length))
	copy(payload[24:], value.diagnostic[:length])
	return payload
}

protocol_error_decode :: proc(payload: []u8) -> Session_Error {
	if len(payload) <
	   24 {return error_make(.Protocol_Malformed, false, .Not_Started, 0, 0, "FAT32 error frame is truncated")}
	length := int(get_u16le(payload, 20))
	if length > MAX_DIAGNOSTIC_BYTES || 24 + length != len(payload) {
		return error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 error frame length is invalid",
		)
	}
	code := get_u16le(payload, 0)
	retry := payload[2]
	outcome := payload[3]
	if code > u16(Error_Code.Name_Collision) ||
	   retry > 1 ||
	   outcome > u8(Operation_Outcome.Uncertain) {
		return error_make(
			.Protocol_Malformed,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 error frame contains an invalid enum value",
		)
	}
	err := Session_Error {
		code             = Error_Code(code),
		retryable        = retry == 1,
		outcome          = Operation_Outcome(outcome),
		sequence         = get_u64le(payload, 4),
		durable_sequence = get_u64le(payload, 12),
	}
	copy(err.diagnostic[:length], payload[24:])
	err.diagnostic_length = u16(length)
	return err
}

protocol_barrier_encode :: proc(result: Barrier_Result) -> [24]u8 {
	payload: [24]u8
	put_u64le(payload[:], 0, result.sequence)
	put_u64le(payload[:], 8, result.durable_sequence)
	payload[16] = u8(result.materialization)
	return payload
}

protocol_barrier_decode :: proc(payload: []u8) -> (Barrier_Result, bool) {
	if len(payload) != 24 || payload[16] > u8(Materialization.Pending) {return {}, false}
	return Barrier_Result {
			sequence = get_u64le(payload, 0),
			durable_sequence = get_u64le(payload, 8),
			materialization = Materialization(payload[16]),
		},
		true
}

protocol_barrier_reason_decode :: proc(value: u8) -> (Barrier_Reason, bool) {
	if value > u8(Barrier_Reason.Clean_Close) {return {}, false}
	return Barrier_Reason(value), true
}

protocol_close_mode_decode :: proc(value: u8) -> (Close_Mode, bool) {
	if value > u8(Close_Mode.Retain) {return {}, false}
	return Close_Mode(value), true
}

PROTOCOL_IMAGE_INFO_BYTES :: 56

protocol_image_info_encode :: proc(
	info: ^fat32image.Image_Info,
	allocator: runtime.Allocator,
) -> []u8 {
	if info == nil {return nil}
	payload := make([]u8, PROTOCOL_IMAGE_INFO_BYTES + len(info.path), allocator)
	put_u64le(payload, 0, info.sector_count)
	put_u32le(payload, 8, info.partition_lba)
	put_u32le(payload, 12, info.partition_sectors)
	payload[16] = info.sectors_per_cluster
	put_u16le(payload, 18, info.reserved_sectors)
	put_u32le(payload, 20, info.marker_sector)
	flags: u32
	if info.sparse {flags |= 1}
	if info.enrolled {flags |= 2}
	if info.dirty {flags |= 4}
	if info.retvrn99_format {flags |= 8}
	put_u32le(payload, 24, flags)
	copy(payload[32:48], info.image_id[:])
	put_u32le(payload, 48, u32(len(info.path)))
	copy(payload[PROTOCOL_IMAGE_INFO_BYTES:], transmute([]u8)info.path)
	return payload
}

protocol_image_info_decode :: proc(
	payload: []u8,
	allocator: runtime.Allocator,
) -> (
	fat32image.Image_Info,
	bool,
) {
	if len(payload) < PROTOCOL_IMAGE_INFO_BYTES {return {}, false}
	path_length := int(get_u32le(payload, 48))
	if path_length < 0 ||
	   PROTOCOL_IMAGE_INFO_BYTES + path_length != len(payload) {return {}, false}
	flags := get_u32le(payload, 24)
	info := fat32image.Image_Info {
		path                = strings.clone(
			string(payload[PROTOCOL_IMAGE_INFO_BYTES:]),
			allocator,
		),
		sector_count        = get_u64le(payload, 0),
		partition_lba       = get_u32le(payload, 8),
		partition_sectors   = get_u32le(payload, 12),
		sectors_per_cluster = payload[16],
		reserved_sectors    = get_u16le(payload, 18),
		marker_sector       = get_u32le(payload, 20),
		sparse              = flags & 1 != 0,
		enrolled            = flags & 2 != 0,
		dirty               = flags & 4 != 0,
		retvrn99_format     = flags & 8 != 0,
	}
	copy(info.image_id[:], payload[32:48])
	return info, true
}
