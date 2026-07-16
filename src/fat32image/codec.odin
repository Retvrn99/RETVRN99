// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"

@(private = "package")
error_make :: proc(code: Error_Code, retryable: bool, diagnostic: string) -> Image_Error {
	result := Image_Error {
		code      = code,
		retryable = retryable,
	}
	count := min(len(diagnostic), MAX_ERROR_TEXT_BYTES)
	copy(result.diagnostic[:count], transmute([]u8)diagnostic)
	result.diagnostic_length = u16(count)
	return result
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

@(private = "package")
read_exact_at :: proc(file: ^os.File, data: []u8, offset: i64) -> bool {
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
	total := 0
	for total < len(data) {
		count, write_error := os.write_at(file, data[total:], offset + i64(total))
		if count > 0 {total += count}
		if write_error != nil || count == 0 {return false}
	}
	return true
}

@(private = "package")
sector_offset :: proc(lba: u64) -> (i64, bool) {
	bytes := lba * SECTOR_BYTES
	if lba != 0 && bytes / SECTOR_BYTES != lba || bytes > u64(max(i64)) {return 0, false}
	return i64(bytes), true
}
