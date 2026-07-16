// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32fs "../fat32fs"
import "core:os"

@(private = "package")
error_make :: proc(
	code: Error_Code,
	diagnostic: string,
	retryable := false,
	outcome := Operation_Outcome.Not_Started,
) -> Edit_Error {
	result := Edit_Error {
		code      = code,
		retryable = retryable,
		outcome   = outcome,
	}
	count := min(len(diagnostic), MAX_ERROR_TEXT_BYTES)
	copy(result.diagnostic[:count], transmute([]u8)diagnostic)
	result.diagnostic_length = u16(count)
	return result
}

@(private = "package")
error_from_fat32 :: proc(err: fat32fs.Error) -> Edit_Error {
	code: Error_Code
	#partial switch err.code {
	case .None:
		return {}
	case .Invalid_Path:
		code = .Invalid_Path
	case .Not_Found:
		code = .Not_Found
	case .Name_Collision:
		code = .Name_Collision
	case .No_Space:
		code = .No_Space
	case .IO:
		code = .IO
	case .Mutation_Conflict:
		code = .Invalid_State
	case:
		code = .Fat32
	}
	copy_error := err
	return error_make(code, fat32fs.error_text(&copy_error))
}

@(private = "package")
read_exact_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
	if file == nil {return false}
	total := 0
	for total < len(data) {
		count, read_error := os.read_at(file, data[total:], offset + i64(total))
		if count > 0 {total += count}
		if read_error != nil && read_error != .EOF || count == 0 {return false}
	}
	return true
}

@(private = "package")
write_exact_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
	if file == nil {return false}
	total := 0
	for total < len(data) {
		count, write_error := os.write_at(file, data[total:], offset + i64(total))
		if count > 0 {total += count}
		if write_error != nil || count == 0 {return false}
	}
	return true
}

@(private = "package")
put_u16le :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private = "package")
put_u32le :: proc(data: []u8, offset: int, value: u32) {
	for index in 0 ..< 4 {data[offset + index] = u8(value >> u32(index * 8))}
}

@(private = "package")
put_u64le :: proc(data: []u8, offset: int, value: u64) {
	for index in 0 ..< 8 {data[offset + index] = u8(value >> u64(index * 8))}
}

@(private = "package")
get_u16le :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private = "package")
get_u32le :: proc(data: []u8, offset: int) -> u32 {
	value: u32
	for index in 0 ..< 4 {value |= u32(data[offset + index]) << u32(index * 8)}
	return value
}

@(private = "package")
get_u64le :: proc(data: []u8, offset: int) -> u64 {
	value: u64
	for index in 0 ..< 8 {value |= u64(data[offset + index]) << u64(index * 8)}
	return value
}
