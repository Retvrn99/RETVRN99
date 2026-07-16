// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

@(private = "package")
error_make :: proc(code: Error_Code, diagnostic: string) -> Error {
	result := Error{code = code}
	count := min(len(diagnostic), MAX_ERROR_TEXT_BYTES)
	copy(result.diagnostic[:count], transmute([]u8)diagnostic)
	result.diagnostic_length = u16(count)
	return result
}

Error_Make :: proc(code: Error_Code, diagnostic: string) -> Error {
	return error_make(code, diagnostic)
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
