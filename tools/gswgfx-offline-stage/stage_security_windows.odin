// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

Gswgfx_Stream_Data :: struct {
	stream_size: win32.LARGE_INTEGER,
	stream_name: [win32.MAX_PATH + 36]u16,
}

#assert(size_of(Gswgfx_Stream_Data) == 600)

@(default_calling_convention = "system")
foreign kernel32 {
	FindFirstStreamW :: proc(
		file_name: win32.LPCWSTR,
		info_level: i32,
		find_data: ^Gswgfx_Stream_Data,
		flags: win32.DWORD,
	) -> win32.HANDLE ---
	FindNextStreamW :: proc(
		find_stream: win32.HANDLE,
		find_data: ^Gswgfx_Stream_Data,
	) -> win32.BOOL ---
}

GSWGFX_ERROR_INVALID_FUNCTION :: win32.DWORD(1)
GSWGFX_ERROR_HANDLE_EOF :: win32.DWORD(38)
GSWGFX_ERROR_NOT_SUPPORTED :: win32.DWORD(50)
GSWGFX_ERROR_INVALID_PARAMETER :: win32.DWORD(87)

gswgfx_stage_stream_name_is_default :: proc(
	name: ^[win32.MAX_PATH + 36]u16,
) -> bool {
	if name == nil {return false}
	expected := [7]u16{':', ':', '$', 'D', 'A', 'T', 'A'}
	for value, index in expected {
		if name[index] != value {return false}
	}
	return name[len(expected)] == 0
}

gswgfx_stage_platform_no_stream_syntax :: proc(path: string) -> bool {
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil || absolute == "" {return false}
	start := 0
	if len(absolute) >= 2 && absolute[1] == ':' {start = 2}
	for index in start ..< len(absolute) {
		if absolute[index] == ':' {return false}
	}
	return true
}

gswgfx_stage_platform_no_named_streams :: proc(path: string) -> bool {
	if !gswgfx_stage_platform_no_stream_syntax(path) {return false}
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	data := new(Gswgfx_Stream_Data, context.temp_allocator)
	defer free(data, context.temp_allocator)
	find := FindFirstStreamW(wide, 0, data, 0)
	if find == win32.INVALID_HANDLE_VALUE {
		error := win32.GetLastError()
		return error == GSWGFX_ERROR_HANDLE_EOF ||
			error == GSWGFX_ERROR_INVALID_FUNCTION ||
			error == GSWGFX_ERROR_NOT_SUPPORTED ||
			error == GSWGFX_ERROR_INVALID_PARAMETER
	}
	defer win32.FindClose(find)
	if !gswgfx_stage_stream_name_is_default(&data.stream_name) {return false}
	if bool(FindNextStreamW(find, data)) {return false}
	return win32.GetLastError() == GSWGFX_ERROR_HANDLE_EOF
}
