// SPDX-License-Identifier: GPL-3.0-only
package securehost

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

OBJ_CASE_INSENSITIVE :: u32(0x00000040)
OBJ_DONT_REPARSE     :: u32(0x00001000)

FILE_DIRECTORY_FILE           :: u32(0x00000001)
FILE_SYNCHRONOUS_IO_NONALERT   :: u32(0x00000020)
FILE_OPEN_REPARSE_POINT        :: u32(0x00200000)

@(private = "package")
directory_access :: proc(writable: bool) -> u32 {
	access := u32(
		win32.FILE_LIST_DIRECTORY |
		win32.FILE_TRAVERSE |
		win32.FILE_READ_ATTRIBUTES |
		win32.SYNCHRONIZE,
	)
	if writable {access |= win32.FILE_ADD_FILE | win32.FILE_ADD_SUBDIRECTORY}
	return access
}

@(private = "package")
handle_is_directory :: proc(handle: win32.HANDLE) -> bool {
	if handle == nil || handle == win32.INVALID_HANDLE_VALUE ||
	   win32.GetFileType(handle) != win32.FILE_TYPE_DISK {
		return false
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	return(
		bool(win32.GetFileInformationByHandle(handle, &info)) &&
		info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0 &&
		info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0 \
	)
}

@(private = "package")
nt_open_relative :: proc(
	parent: win32.HANDLE,
	name: string,
	desired_access, disposition, options, attributes: u32,
) -> win32.HANDLE {
	wide := win32.utf8_to_utf16(name, context.temp_allocator)
	if len(wide) == 0 || len(wide) > int(max(u16)) / 2 {return win32.INVALID_HANDLE_VALUE}
	unicode := win32.UNICODE_STRING {
		Length        = u16(len(wide) * 2),
		MaximumLength = u16(len(wide) * 2),
		Buffer        = raw_data(wide),
	}
	object := win32.OBJECT_ATTRIBUTES {
		Length        = size_of(win32.OBJECT_ATTRIBUTES),
		RootDirectory = parent,
		ObjectName    = &unicode,
		Attributes    = OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE,
	}
	io: win32.IO_STATUS_BLOCK
	handle: win32.HANDLE
	status := win32.NtCreateFile(
		&handle,
		desired_access,
		&object,
		&io,
		nil,
		attributes,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		disposition,
		options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT,
		nil,
		0,
	)
	if status != 0 {return win32.INVALID_HANDLE_VALUE}
	return handle
}

@(private = "package")
open_root :: proc(path: string, final_writable: bool) -> (win32.HANDLE, []string, bool) {
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil || absolute == "" || strings.has_prefix(absolute, `\\.\`) ||
	   strings.has_prefix(absolute, `\\?\`) {
		return win32.INVALID_HANDLE_VALUE, nil, false
	}
	normalized, _ := strings.replace_all(absolute, "/", "\\", context.temp_allocator)
	root := ""
	remainder := ""
	if len(normalized) >= 3 && normalized[1] == ':' && normalized[2] == '\\' {
		root = strings.concatenate({`\\?\`, normalized[:3]}, context.temp_allocator)
		remainder = normalized[3:]
	} else if strings.has_prefix(normalized, `\\`) {
		without_prefix := normalized[2:]
		first := strings.index_byte(without_prefix, '\\')
		if first <= 0 {return win32.INVALID_HANDLE_VALUE, nil, false}
		second_relative := strings.index_byte(without_prefix[first + 1:], '\\')
		share_end := len(without_prefix)
		if second_relative >= 0 {share_end = first + 1 + second_relative}
		if share_end <= first + 1 {return win32.INVALID_HANDLE_VALUE, nil, false}
		root = strings.concatenate(
			{`\\?\UNC\`, without_prefix[:share_end], `\`},
			context.temp_allocator,
		)
		if share_end < len(without_prefix) {remainder = without_prefix[share_end + 1:]}
	} else {
		return win32.INVALID_HANDLE_VALUE, nil, false
	}
	for len(remainder) > 0 && remainder[len(remainder) - 1] == '\\' {
		remainder = remainder[:len(remainder) - 1]
	}
	parts: []string
	if remainder != "" {
		parts = strings.split(remainder, "\\", context.temp_allocator)
		for part in parts {
			if !component_valid(part) {return win32.INVALID_HANDLE_VALUE, nil, false}
		}
	}
	wide := win32.utf8_to_wstring(root, context.temp_allocator)
	if wide == nil {return win32.INVALID_HANDLE_VALUE, nil, false}
	root_writable := final_writable && len(parts) == 0
	handle := win32.CreateFileW(
		wide,
		directory_access(root_writable),
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if !handle_is_directory(handle) {
		if handle != win32.INVALID_HANDLE_VALUE {_ = win32.CloseHandle(handle)}
		return win32.INVALID_HANDLE_VALUE, nil, false
	}
	return handle, parts, true
}

@(private = "package")
platform_open_directory :: proc(path: string) -> (Directory, bool) {
	handle, parts, root_ok := open_root(path, true)
	if !root_ok {return {}, false}
	for part, index in parts {
		child := nt_open_relative(
			handle,
			part,
			directory_access(index == len(parts) - 1),
			win32.FILE_OPEN,
			FILE_DIRECTORY_FILE,
			win32.FILE_ATTRIBUTE_NORMAL,
		)
		_ = win32.CloseHandle(handle)
		if !handle_is_directory(child) {
			if child != win32.INVALID_HANDLE_VALUE {_ = win32.CloseHandle(child)}
			return {}, false
		}
		handle = child
	}
	return {handle = uintptr(handle)}, true
}

@(private = "package")
platform_create_directory :: proc(parent: ^Directory, name: string) -> (Directory, bool) {
	handle := nt_open_relative(
		win32.HANDLE(parent.handle),
		name,
		directory_access(true),
		win32.FILE_CREATE,
		FILE_DIRECTORY_FILE,
		win32.FILE_ATTRIBUTE_DIRECTORY,
	)
	if !handle_is_directory(handle) {
		if handle != win32.INVALID_HANDLE_VALUE {_ = win32.CloseHandle(handle)}
		return {}, false
	}
	return {handle = uintptr(handle)}, true
}

@(private = "package")
platform_create_file :: proc(parent: ^Directory, name: string) -> (^os.File, bool) {
	handle := nt_open_relative(
		win32.HANDLE(parent.handle),
		name,
		u32(win32.GENERIC_WRITE | win32.FILE_READ_ATTRIBUTES | win32.DELETE | win32.SYNCHRONIZE),
		win32.FILE_CREATE,
		win32.FILE_NON_DIRECTORY_FILE,
		win32.FILE_ATTRIBUTE_NORMAL,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return nil, false}
	info: win32.BY_HANDLE_FILE_INFORMATION
	if win32.GetFileType(handle) != win32.FILE_TYPE_DISK ||
	   !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		_ = win32.CloseHandle(handle)
		return nil, false
	}
	file := os.new_file(uintptr(handle), name)
	if file == nil {
		_ = win32.CloseHandle(handle)
		return nil, false
	}
	return file, true
}

@(private = "package")
platform_close_directory :: proc(directory: ^Directory) {
	_ = win32.CloseHandle(win32.HANDLE(directory.handle))
}

@(private = "package")
platform_discard_file :: proc(_: ^Directory, file: ^os.File, _: string) -> bool {
	if file == nil {return false}
	disposition := struct {DeleteFile: win32.BOOL}{DeleteFile = win32.TRUE}
	return bool(
		win32.SetFileInformationByHandle(
			win32.HANDLE(os.fd(file)),
			.FileDispositionInfo,
			&disposition,
			size_of(disposition),
		),
	)
}
