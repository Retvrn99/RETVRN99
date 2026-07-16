// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:os"
import win32 "core:sys/windows"

@(private = "package")
tlb_platform_path_is_safe_regular :: proc(path: string) -> bool {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	attributes := win32.GetFileAttributesW(wide)
	return(
		attributes != win32.INVALID_FILE_ATTRIBUTES &&
		attributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) == 0 \
	)
}

@(private = "package")
tlb_platform_file_identity :: proc(file: ^os.File) -> (TLB_File_Identity, bool) {
	if file == nil || win32.GetFileType(win32.HANDLE(os.fd(file))) != win32.FILE_TYPE_DISK {
		return {}, false
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	if !bool(win32.GetFileInformationByHandle(win32.HANDLE(os.fd(file)), &info)) ||
	   info.dwFileAttributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		return {}, false
	}
	return {
		device  = u64(info.dwVolumeSerialNumber),
		file_id = u128(info.nFileIndexHigh) << 32 | u128(info.nFileIndexLow),
	}, true
}

@(private = "package")
tlb_platform_publish_no_replace :: proc(
	source, destination: string,
) -> TLB_Publication_Status {
	from := win32.utf8_to_wstring(source, context.temp_allocator)
	to := win32.utf8_to_wstring(destination, context.temp_allocator)
	if from == nil || to == nil {return .Failed}
	if bool(win32.MoveFileExW(from, to, win32.MOVEFILE_WRITE_THROUGH)) {
		return .Published
	}
	if win32.GetFileAttributesW(to) != win32.INVALID_FILE_ATTRIBUTES {
		return .Conflict
	}
	return .Failed
}
