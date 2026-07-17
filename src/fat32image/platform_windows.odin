// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import win32 "core:sys/windows"

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
platform_image_is_sparse :: proc(file: ^os.File) -> bool {
	if file == nil {return false}
	info: win32.FILE_BASIC_INFO
	return(
		bool(
			win32.GetFileInformationByHandleEx(
				win32.HANDLE(os.fd(file)),
				.FileBasicInfo,
				&info,
				size_of(info),
			),
		) &&
		info.FileAttributes & win32.FILE_ATTRIBUTE_SPARSE_FILE != 0 \
	)
}

@(private = "package")
platform_image_allocated_bytes :: proc(file: ^os.File) -> (u64, bool) {
	if file == nil {return 0, false}
	info: win32.FILE_STANDARD_INFO
	if !bool(
		win32.GetFileInformationByHandleEx(
			win32.HANDLE(os.fd(file)),
			.FileStandardInfo,
			&info,
			size_of(info),
		),
	) {
		return 0, false
	}
	return u64(info.AllocationSize), true
}

@(private = "package")
platform_image_path_is_safe_regular :: proc(path: string) -> bool {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	attributes := win32.GetFileAttributesW(wide)
	return(
		attributes != win32.INVALID_FILE_ATTRIBUTES &&
		attributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) == 0 \
	)
}

@(private = "package")
platform_image_lock :: proc(file: ^os.File) -> bool {
	if file == nil {return false}
	overlapped: win32.OVERLAPPED
	return bool(
		win32.LockFileEx(
			win32.HANDLE(os.fd(file)),
			win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY,
			0,
			0xFFFF_FFFF,
			0xFFFF_FFFF,
			&overlapped,
		),
	)
}

@(private = "package")
platform_image_unlock :: proc(file: ^os.File) {
	if file == nil {return}
	overlapped: win32.OVERLAPPED
	_ = win32.UnlockFileEx(win32.HANDLE(os.fd(file)), 0, 0xFFFF_FFFF, 0xFFFF_FFFF, &overlapped)
}

@(private = "package")
platform_publish_no_replace :: proc(source, destination: string) -> bool {
	from := win32.utf8_to_wstring(source, context.temp_allocator)
	to := win32.utf8_to_wstring(destination, context.temp_allocator)
	return bool(win32.MoveFileExW(from, to, win32.MOVEFILE_WRITE_THROUGH))
}

@(private = "package")
platform_sync_published_parent :: proc(_: string) -> bool {
	return true
}
