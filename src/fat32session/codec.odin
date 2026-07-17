// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"

put_u16le :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

put_u32le :: proc(data: []u8, offset: int, value: u32) {
	for index in 0 ..< 4 {data[offset + index] = u8(value >> u32(index * 8))}
}

put_u64le :: proc(data: []u8, offset: int, value: u64) {
	for index in 0 ..< 8 {data[offset + index] = u8(value >> u64(index * 8))}
}

get_u16le :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

get_u32le :: proc(data: []u8, offset: int) -> u32 {
	value: u32
	for index in 0 ..< 4 {value |= u32(data[offset + index]) << u32(index * 8)}
	return value
}

get_u64le :: proc(data: []u8, offset: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {value |= u64(data[offset + index]) << u64(index * 8)}
	return value
}

file_read_exact_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
	total := 0
	for total < len(data) {
		count, read_error := os.read_at(file, data[total:], offset + i64(total))
		if count > 0 {total += count}
		if read_error != nil && read_error != .EOF || count == 0 {return false}
	}
	return true
}
file_write_exact_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
	total := 0
	for total < len(data) {
		count, write_error := os.write_at(file, data[total:], offset + i64(total))
		if count > 0 {total += count}
		if write_error != nil || count == 0 {return false}
	}
	return true
}

image_error_map :: proc(
	err: fat32image.Image_Error,
	sequence, durable_sequence: u64,
) -> Session_Error {
	if err.code == .None {return {}}
	code := Error_Code.Image_IO
	#partial switch err.code {
	case .Invalid_Argument, .Capacity_Out_Of_Range, .Path_Unsupported:
		code = .Invalid_Argument
	case .Already_Exists:
		code = .Image_Already_Exists
	case .Sparse_Unsupported:
		code = .Sparse_Unsupported
	case .Not_Found, .Open_Failed:
		code = .Image_Missing
	case .Locked:
		code = .Image_Locked
	case .Invalid_Size, .Invalid_MBR, .Partition_Unsupported, .Invalid_VBR,
	     .Invalid_FAT32, .Marker_Unavailable, .Marker_Invalid:
		code = .Image_Invalid
	case .Protected_Write:
		code = .Protected_Write
	case .Out_Of_Range, .Read_Only, .Closed:
		code = .Invalid_State
	}
	value := err
	return error_make(
		code,
		err.retryable,
		.Uncertain,
		sequence,
		durable_sequence,
		fat32image.error_text(&value),
	)
}
