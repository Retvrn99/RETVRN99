// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"

lock_guard_acquire :: proc(root: string) -> (^os.File, Lock_File_Lock_Status) {
	path, path_error := filepath.join({root, PROFILE_GUARD_FILE}, context.temp_allocator)
	if path_error != nil {return nil, .Failed}
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return nil, .Failed}
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return nil, .Failed}
	info: win32.BY_HANDLE_FILE_INFORMATION
	if win32.GetFileType(handle) != win32.FILE_TYPE_DISK ||
	   !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		_ = win32.CloseHandle(handle)
		return nil, .Failed
	}
	guard := os.new_file(uintptr(handle), path)
	status := lock_file_try_exclusive(guard)
	if status != .Acquired {
		_ = os.close(guard)
		return nil, status
	}
	return guard, .Acquired
}

lock_guard_release :: proc(guard: ^os.File) {
	if guard == nil {return}
	lock_file_unlock(guard)
	_ = os.close(guard)
}

lock_file_open :: proc(path: string, create_exclusive: bool) -> (^os.File, Lock_File_Open_Status) {
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return nil, .Failed}
	disposition := create_exclusive ? win32.CREATE_NEW : win32.OPEN_EXISTING
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		disposition,
		win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		error_code := win32.GetLastError()
		if create_exclusive &&
		   (error_code == win32.ERROR_FILE_EXISTS || error_code == win32.ERROR_ALREADY_EXISTS) {
			return nil, .Exists
		}
		if !create_exclusive &&
		   (error_code == win32.ERROR_FILE_NOT_FOUND || error_code == win32.ERROR_PATH_NOT_FOUND) {
			return nil, .Missing
		}
		return nil, .Failed
	}
	info: win32.BY_HANDLE_FILE_INFORMATION
	if win32.GetFileType(handle) != win32.FILE_TYPE_DISK ||
	   !bool(win32.GetFileInformationByHandle(handle, &info)) ||
	   info.dwFileAttributes & (win32.FILE_ATTRIBUTE_DIRECTORY | win32.FILE_ATTRIBUTE_REPARSE_POINT) != 0 {
		_ = win32.CloseHandle(handle)
		return nil, .Failed
	}
	return os.new_file(uintptr(handle), path), .None
}

lock_file_try_exclusive :: proc(file: ^os.File) -> Lock_File_Lock_Status {
	if file == nil {return .Failed}
	overlapped := win32.OVERLAPPED {
		Offset     = 0xFFFF_FFFF,
		OffsetHigh = 0x7FFF_FFFF,
	}
	if bool(win32.LockFileEx(
		win32.HANDLE(os.fd(file)),
		win32.LOCKFILE_EXCLUSIVE_LOCK | win32.LOCKFILE_FAIL_IMMEDIATELY,
		0,
		1,
		0,
		&overlapped,
	)) {
		return .Acquired
	}
	return win32.GetLastError() == win32.ERROR_LOCK_VIOLATION ? .Busy : .Failed
}

lock_file_unlock :: proc(file: ^os.File) {
	if file == nil {return}
	overlapped := win32.OVERLAPPED {
		Offset     = 0xFFFF_FFFF,
		OffsetHigh = 0x7FFF_FFFF,
	}
	_ = win32.UnlockFileEx(
		win32.HANDLE(os.fd(file)),
		0,
		1,
		0,
		&overlapped,
	)
}

lock_file_identity :: proc(handle: win32.HANDLE) -> (Lock_File_Identity, bool) {
	info: win32.BY_HANDLE_FILE_INFORMATION
	if handle == win32.INVALID_HANDLE_VALUE ||
	   !bool(win32.GetFileInformationByHandle(handle, &info)) {
		return {}, false
	}
	return {
		namespace = u64(info.dwVolumeSerialNumber),
		object_lo = u64(info.nFileIndexHigh) << 32 | u64(info.nFileIndexLow),
	}, true
}

lock_file_path_matches :: proc(file: ^os.File, path: string) -> bool {
	if file == nil {return false}
	want, want_ok := lock_file_identity(win32.HANDLE(os.fd(file)))
	if !want_ok {return false}
	wide := win32.utf8_to_wstring(path, context.temp_allocator)
	if wide == nil {return false}
	handle := win32.CreateFileW(
		wide,
		win32.FILE_READ_ATTRIBUTES,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return false}
	defer _ = win32.CloseHandle(handle)
	got, got_ok := lock_file_identity(handle)
	return got_ok && got == want
}

lock_process_start_token :: proc(pid: u32) -> (u64, bool) {
	handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if handle == nil {return 0, false}
	defer _ = win32.CloseHandle(handle)
	creation, exited, kernel, user: win32.FILETIME
	if !bool(win32.GetProcessTimes(handle, &creation, &exited, &kernel, &user)) {
		return 0, false
	}
	return u64(creation.dwHighDateTime) << 32 | u64(creation.dwLowDateTime), true
}

lock_process_state :: proc(owner: Lock_Owner) -> Lock_Process_State {
	if owner.pid == 0 {return .Unknown}
	handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, owner.pid)
	if handle == nil {
		return win32.GetLastError() == win32.ERROR_INVALID_PARAMETER ? .Dead : .Unknown
	}
	defer _ = win32.CloseHandle(handle)
	exit_code: win32.DWORD
	if !bool(win32.GetExitCodeProcess(handle, &exit_code)) {return .Unknown}
	if exit_code != 259 {return .Dead}
	if owner.start == 0 {return .Live}
	start, start_ok := lock_process_start_token(owner.pid)
	if !start_ok {return .Unknown}
	return start == owner.start ? .Live : .Dead
}
