// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

@(private = "package")
platform_sync_directory :: proc(_: string) -> bool {
	return true
}

FSCTL_SET_SPARSE :: 0x000900C4

@(private = "package")
platform_prepare_sparse :: proc(file: ^os.File) -> bool {
	if file == nil {return false}
	bytes: win32.DWORD
	return bool(
		win32.DeviceIoControl(
			win32.HANDLE(os.fd(file)),
			FSCTL_SET_SPARSE,
			nil,
			0,
			nil,
			0,
			&bytes,
			nil,
		),
	)
}

@(private = "package")
platform_host_extended_path :: proc(path: string) -> (string, bool) {
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil || absolute == "" {return "", false}
	if len(absolute) >= 4 && strings.has_prefix(absolute, `\\.\`) {return "", false}
	if len(absolute) >= 4 && strings.has_prefix(absolute, `\\?\`) {return absolute, true}
	if len(absolute) >= 3 && absolute[1] == ':' && (absolute[2] == '\\' || absolute[2] == '/') {
		return strings.concatenate({`\\?\`, absolute}, context.temp_allocator), true
	}
	if strings.has_prefix(absolute, `\\`) {
		return strings.concatenate({`\\?\UNC\`, absolute[2:]}, context.temp_allocator), true
	}
	return "", false
}

@(private = "package")
platform_host_handle :: proc(path: string, read: bool) -> win32.HANDLE {
	extended, path_ok := platform_host_extended_path(path)
	if !path_ok {return win32.INVALID_HANDLE_VALUE}
	wide := win32.utf8_to_wstring(extended, context.temp_allocator)
	if wide == nil {return win32.INVALID_HANDLE_VALUE}
	access := win32.FILE_READ_ATTRIBUTES
	if read {access = win32.GENERIC_READ}
	return win32.CreateFileW(
		wide,
		access,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
}

@(private = "package")
platform_host_handle_identity :: proc(
	handle: win32.HANDLE,
	kind: Host_Object_Kind,
) -> (
	Host_Object_Identity,
	bool,
) {
	if handle == win32.INVALID_HANDLE_VALUE || win32.GetFileType(handle) != win32.FILE_TYPE_DISK {
		return {}, false
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	basic: win32.FILE_BASIC_INFO
	if !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   !bool(win32.GetFileInformationByHandleEx(handle, .FileBasicInfo, &basic, size_of(basic))) ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
	   basic.FileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return {}, false
	}
	is_directory := info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0
	if kind == .Directory != is_directory {return {}, false}
	identity := Host_Object_Identity {
		valid        = true,
		kind         = kind,
		device       = u64(info.dwVolumeSerialNumber),
		size         = u64(info.nFileSizeHigh) << 32 | u64(info.nFileSizeLow),
		write_token  = u64(basic.LastWriteTime),
		change_token = u64(basic.ChangeTime),
	}
	file_index := u64(info.nFileIndexHigh) << 32 | u64(info.nFileIndexLow)
	for index in 0 ..< 8 {identity.file_id[index] = u8(file_index >> u64(index * 8))}
	return identity, true
}

@(private = "package")
platform_host_component_safe :: proc(path: string) -> (exists, safe: bool) {
	handle := platform_host_handle(path, false)
	if handle == win32.INVALID_HANDLE_VALUE {return false, false}
	defer win32.CloseHandle(handle)
	info: win32.BY_HANDLE_FILE_INFORMATION
	if !bool(win32.GetFileInformationByHandle(handle, &info)) {return true, false}
	return true, info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT == 0
}

@(private = "package")
platform_host_snapshot :: proc(
	path: string,
	kind: Host_Object_Kind,
) -> (
	Host_Object_Identity,
	bool,
) {
	handle := platform_host_handle(path, false)
	if handle == win32.INVALID_HANDLE_VALUE {return {}, false}
	defer win32.CloseHandle(handle)
	return platform_host_handle_identity(handle, kind)
}

@(private = "package")
platform_host_open :: proc(
	path: string,
	kind: Host_Object_Kind,
	expected: Host_Object_Identity,
) -> (
	^os.File,
	bool,
) {
	handle := platform_host_handle(path, true)
	if handle == win32.INVALID_HANDLE_VALUE {return nil, false}
	identity, identity_ok := platform_host_handle_identity(handle, kind)
	if !identity_ok || !host_identity_equal(identity, expected) {
		_ = win32.CloseHandle(handle)
		return nil, false
	}
	file := os.new_file(uintptr(handle), path)
	if file == nil {
		_ = win32.CloseHandle(handle)
		return nil, false
	}
	return file, true
}

@(private = "package")
platform_host_verify_open :: proc(file: ^os.File, expected: Host_Object_Identity) -> bool {
	if file == nil {return false}
	identity, ok := platform_host_handle_identity(win32.HANDLE(os.fd(file)), expected.kind)
	return ok && host_identity_equal(identity, expected)
}

@(private = "package")
platform_host_verify_path :: proc(path: string, expected: Host_Object_Identity) -> bool {
	identity, ok := platform_host_snapshot(path, expected.kind)
	return ok && host_identity_equal(identity, expected)
}
