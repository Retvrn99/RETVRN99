// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import win32 "core:sys/windows"

@(private = "file")
platform_companion_directory_secure :: proc(path: string, hide: bool) -> bool {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	handle := win32.CreateFileW(
		wide,
		win32.FILE_READ_ATTRIBUTES,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return false}
	defer win32.CloseHandle(handle)
	info: win32.BY_HANDLE_FILE_INFORMATION
	if win32.GetFileType(handle) != win32.FILE_TYPE_DISK ||
	   !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return false
	}
	if hide && info.dwFileAttributes & win32.FILE_ATTRIBUTE_HIDDEN == 0 {
		if !bool(win32.SetFileAttributesW(
			wide,
			info.dwFileAttributes | win32.FILE_ATTRIBUTE_HIDDEN,
		)) {
			return false
		}
		if !bool(win32.GetFileInformationByHandle(handle, &info)) ||
		   info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 ||
		   info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 ||
		   info.dwFileAttributes & win32.FILE_ATTRIBUTE_HIDDEN == 0 {
			return false
		}
	}
	return true
}

@(private = "package")
platform_companion_directory_valid :: proc(path: string) -> bool {
	return platform_companion_directory_secure(path, false)
}

@(private = "package")
platform_companion_directory_identity :: proc(
	path: string,
) -> (
	Companion_Directory_Identity,
	bool,
) {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return {}, false}
	handle := win32.CreateFileW(
		wide,
		win32.FILE_READ_ATTRIBUTES,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return {}, false}
	defer win32.CloseHandle(handle)
	info: win32.BY_HANDLE_FILE_INFORMATION
	if !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 ||
	   info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return {}, false
	}
	file_id := u128(info.nFileIndexHigh) << 32 | u128(info.nFileIndexLow)
	return {
		valid = true,
		device = u64(info.dwVolumeSerialNumber),
		file_id = file_id,
	}, true
}

@(private = "package")
platform_companion_directory_hide :: proc(path: string) -> bool {
	return platform_companion_directory_secure(path, true)
}

@(private = "package")
platform_companion_directory_hidden :: proc(path: string) -> bool {
	if !platform_companion_directory_valid(path) {return false}
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	attributes := win32.GetFileAttributesW(wide)
	return(
		attributes != win32.INVALID_FILE_ATTRIBUTES &&
		attributes & win32.FILE_ATTRIBUTE_HIDDEN != 0 \
	)
}

@(private = "package")
platform_companion_directory_sync :: proc(path: string) -> bool {
	return platform_companion_directory_valid(path)
}
