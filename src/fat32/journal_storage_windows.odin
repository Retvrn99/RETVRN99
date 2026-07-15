// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import "core:sync"
import win32 "core:sys/windows"
import "core:time"

FSCTL_SET_SPARSE :: 0x000900C4

@(private = "file")
overlay_storage_gate: sync.Mutex

journal_create_temp_file :: proc(backing_dir, pattern: string) -> (^os.File, os.Error) {
	sync.lock(&overlay_storage_gate)
	defer sync.unlock(&overlay_storage_gate)
	err: os.Error
	for attempt in 0 ..< 20 {
		file: ^os.File
		file, err = os.create_temp_file(backing_dir, pattern)
		if err == nil {return file, nil}
		if err != .Permission_Denied || attempt == 19 {return nil, err}
		time.sleep(25 * time.Millisecond)
	}
	return nil, err
}

journal_process_is_live :: proc(pid: u32) -> bool {
	if pid == 0 {return false}
	if pid == u32(os.get_pid()) {return true}
	handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if handle != nil {
		_ = win32.CloseHandle(handle)
		return true
	}
	return win32.GetLastError() == win32.ERROR_ACCESS_DENIED
}

overlay_prepare_sparse :: proc(file: ^os.File) -> bool {
	bytes: win32.DWORD
	return bool(win32.DeviceIoControl(
		win32.HANDLE(os.fd(file)),
		FSCTL_SET_SPARSE,
		nil,
		0,
		nil,
		0,
		&bytes,
		nil,
	))
}

overlay_secure_backing_path :: proc(path: string) -> (linked, ok: bool) {
	return true, true
}

// Windows core:os opens without FILE_SHARE_DELETE, so remove succeeds only
// after the owning VM has closed or crashed. A live journal is never unlinked.
overlay_scavenge_stale :: proc(backing_dir: string) {
	sync.lock(&overlay_storage_gate)
	defer sync.unlock(&overlay_storage_gate)
	entries, err := os.read_all_directory_by_path(backing_dir, context.temp_allocator)
	if err != nil {return}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Regular && journal_stale_temp(entry.name) {
			_ = os.remove(entry.fullpath)
		}
	}
}

overlay_remove_backing :: proc(path: string) -> os.Error {
	err: os.Error
	for attempt in 0 ..< 20 {
		err = os.remove(path)
		if err == nil || err == .Not_Exist {return err}
		if attempt < 19 {time.sleep(25 * time.Millisecond)}
	}
	return err
}

overlay_allocated_size :: proc(file: ^os.File) -> (u64, bool) {
	if file == nil {return 0, false}
	info: win32.FILE_STANDARD_INFO
	if !bool(win32.GetFileInformationByHandleEx(
		win32.HANDLE(os.fd(file)),
		.FileStandardInfo,
		&info,
		size_of(info),
	)) {
		return 0, false
	}
	return u64(info.AllocationSize), true
}
