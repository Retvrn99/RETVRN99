// SPDX-License-Identifier: GPL-3.0-only
package companionio

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import securehost "../securehost"
import win32 "core:sys/windows"

FILE_DIRECTORY_FILE :: u32(0x00000001)
FILE_SYNCHRONOUS_IO_NONALERT :: u32(0x00000020)
FILE_OPEN_REPARSE_POINT :: u32(0x00200000)
OBJ_CASE_INSENSITIVE :: u32(0x00000040)
STATUS_OBJECT_NAME_NOT_FOUND :: win32.NTSTATUS(-1073741772)
STATUS_OBJECT_PATH_NOT_FOUND :: win32.NTSTATUS(-1073741766)

File_Disposition_Info :: struct {
	delete_file: win32.BOOL,
}

platform_status :: proc(status: win32.NTSTATUS) -> Status {
	if status >= 0 {return .None}
	if status == STATUS_OBJECT_NAME_NOT_FOUND || status == STATUS_OBJECT_PATH_NOT_FOUND {
		return .Missing
	}
	return .Failed
}

platform_identity :: proc(handle: win32.HANDLE, directory: bool) -> (Identity, bool) {
	if handle == win32.INVALID_HANDLE_VALUE || win32.GetFileType(handle) != win32.FILE_TYPE_DISK {
		return {}, false
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	if !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
	   (info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) != directory {
		return {}, false
	}
	return {
		valid   = true,
		device  = u64(info.dwVolumeSerialNumber),
		file_id = u128(info.nFileIndexHigh) << 32 | u128(info.nFileIndexLow),
	}, true
}

platform_relative_handle :: proc(
	parent: win32.HANDLE,
	name: string,
	access, disposition, options: u32,
) -> (
	win32.HANDLE,
	bool,
	Status,
) {
	wide := win32.utf8_to_utf16(name, context.temp_allocator)
	if len(wide) <= 0 || len(wide) > int(max(u16)) / 2 {
		return win32.INVALID_HANDLE_VALUE, false, .Failed
	}
	unicode := win32.UNICODE_STRING {
		Length        = u16(len(wide) * 2),
		MaximumLength = u16(len(wide) * 2),
		Buffer        = raw_data(wide),
	}
	attributes := win32.OBJECT_ATTRIBUTES {
		Length        = size_of(win32.OBJECT_ATTRIBUTES),
		RootDirectory = parent,
		ObjectName    = &unicode,
		Attributes    = OBJ_CASE_INSENSITIVE,
	}
	io: win32.IO_STATUS_BLOCK
	handle := win32.INVALID_HANDLE_VALUE
	status := win32.NtCreateFile(
		&handle,
		access,
		&attributes,
		&io,
		nil,
		win32.FILE_ATTRIBUTE_NORMAL,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		disposition,
		options,
		nil,
		0,
	)
	result := platform_status(status)
	return handle, io.Information == 2, result
}

platform_absolute_directory :: proc(path: string) -> (win32.HANDLE, Status) {
	directory, opened := securehost.open_directory(path)
	if !opened {return win32.INVALID_HANDLE_VALUE, .Failed}
	handle := win32.HANDLE(directory.handle)
	directory.handle = 0
	if _, valid := platform_identity(handle, true); !valid {
		_ = win32.CloseHandle(handle)
		return win32.INVALID_HANDLE_VALUE, .Unsafe
	}
	return handle, .None
}

platform_open_path :: proc(
	path: string,
	create: bool,
	allocator: runtime.Allocator,
) -> (
	Directory,
	Status,
) {
	parent_path := filepath.dir(path)
	name := filepath.base(path)
	if !leaf_valid(name) {return {}, .Failed}
	parent, parent_status := platform_absolute_directory(parent_path)
	if parent_status != .None {return {}, parent_status}
	disposition := u32(win32.FILE_OPEN)
	if create {disposition = win32.FILE_OPEN_IF}
	handle, _, status := platform_relative_handle(
		parent,
		name,
		win32.FILE_LIST_DIRECTORY | win32.FILE_READ_ATTRIBUTES | win32.FILE_TRAVERSE |
			win32.FILE_ADD_FILE | win32.FILE_ADD_SUBDIRECTORY | win32.SYNCHRONIZE,
		disposition,
		FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
	)
	if status != .None {
		_ = win32.CloseHandle(parent)
		return {}, status
	}
	identity, valid := platform_identity(handle, true)
	if !valid {
		_ = win32.CloseHandle(handle)
		_ = win32.CloseHandle(parent)
		return {}, .Unsafe
	}
	return {
		handle        = uintptr(handle),
		parent_handle = uintptr(parent),
		open          = true,
		owns_parent   = true,
		path          = strings.clone(path, allocator),
		name          = strings.clone(name, allocator),
		identity      = identity,
	}, .None
}

platform_open_child :: proc(
	parent: ^Directory,
	name: string,
	create: bool,
	allocator: runtime.Allocator,
) -> (
	Directory,
	Status,
) {
	disposition := u32(win32.FILE_OPEN)
	if create {disposition = win32.FILE_OPEN_IF}
	handle, _, status := platform_relative_handle(
		win32.HANDLE(parent.handle),
		name,
		win32.FILE_LIST_DIRECTORY | win32.FILE_READ_ATTRIBUTES | win32.FILE_TRAVERSE |
			win32.FILE_ADD_FILE | win32.FILE_ADD_SUBDIRECTORY | win32.SYNCHRONIZE,
		disposition,
		FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
	)
	if status != .None {return {}, status}
	identity, valid := platform_identity(handle, true)
	if !valid {
		_ = win32.CloseHandle(handle)
		return {}, .Unsafe
	}
	path, path_error := filepath.join({parent.path, name}, allocator)
	if path_error != nil {
		_ = win32.CloseHandle(handle)
		return {}, .Failed
	}
	return {
		handle        = uintptr(handle),
		parent_handle = parent.handle,
		open          = true,
		path          = path,
		name          = strings.clone(name, allocator),
		identity      = identity,
	}, .None
}

platform_close_directory :: proc(directory: ^Directory) {
	if directory.open {_ = win32.CloseHandle(win32.HANDLE(directory.handle))}
	if directory.owns_parent && directory.parent_handle != 0 {
		_ = win32.CloseHandle(win32.HANDLE(directory.parent_handle))
	}
}

platform_sync_directory :: proc(directory: ^Directory) -> bool {
	_, valid := platform_identity(win32.HANDLE(directory.handle), true)
	return valid
}

platform_open_file :: proc(
	directory: ^Directory,
	name: string,
	flags: os.File_Flags,
) -> (
	^os.File,
	bool,
	Status,
) {
	access := u32(win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE)
	if .Read in flags {access |= win32.GENERIC_READ}
	if .Write in flags || .Append in flags {access |= win32.GENERIC_WRITE}
	disposition := u32(win32.FILE_OPEN)
	if .Create in flags {disposition = .Excl in flags ? win32.FILE_CREATE : win32.FILE_OPEN_IF}
	handle, created, status := platform_relative_handle(
		win32.HANDLE(directory.handle),
		name,
		access,
		disposition,
		win32.FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
	)
	if status != .None {return nil, false, status}
	if _, valid := platform_identity(handle, false); !valid {
		_ = win32.CloseHandle(handle)
		return nil, false, .Unsafe
	}
	path, path_error := filepath.join({directory.path, name}, context.temp_allocator)
	if path_error != nil {
		_ = win32.CloseHandle(handle)
		return nil, false, .Failed
	}
	return os.new_file(uintptr(handle), path), created, .None
}

platform_remove_file :: proc(directory: ^Directory, name: string) -> bool {
	handle, _, status := platform_relative_handle(
		win32.HANDLE(directory.handle),
		name,
		win32.DELETE | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE,
		win32.FILE_OPEN,
		win32.FILE_NON_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
	)
	if status == .Missing {return true}
	if status != .None {return false}
	if _, valid := platform_identity(handle, false); !valid {
		_ = win32.CloseHandle(handle)
		return false
	}
	disposition := File_Disposition_Info{delete_file = win32.TRUE}
	marked := bool(win32.SetFileInformationByHandle(
		handle,
		.FileDispositionInfo,
		&disposition,
		size_of(disposition),
	))
	closed := bool(win32.CloseHandle(handle))
	return marked && closed
}

platform_retire_directory :: proc(parent: ^Directory, child: ^Directory) -> bool {
	if child == nil || !child.open {return false}
	parent_handle := child.parent_handle
	if parent != nil {
		if !parent.open {return false}
		parent_handle = parent.handle
	}
	expected := child.identity
	name := child.name
	_ = win32.CloseHandle(win32.HANDLE(child.handle))
	child.open = false
	handle, _, status := platform_relative_handle(
		win32.HANDLE(parent_handle),
		name,
		win32.DELETE | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE,
		win32.FILE_OPEN,
		FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT | FILE_OPEN_REPARSE_POINT,
	)
	if status != .None {return false}
	identity, valid := platform_identity(handle, true)
	if !valid || !identity_equal(identity, expected) {
		_ = win32.CloseHandle(handle)
		return false
	}
	disposition := File_Disposition_Info{delete_file = win32.TRUE}
	marked := bool(win32.SetFileInformationByHandle(
		handle,
		.FileDispositionInfo,
		&disposition,
		size_of(disposition),
	))
	if !marked {
		_ = win32.CloseHandle(handle)
		return false
	}
	_ = win32.CloseHandle(handle)
	return true
}
