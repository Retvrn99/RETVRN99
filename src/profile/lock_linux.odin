// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:strconv"
import linux "core:sys/linux"

lock_guard_acquire :: proc(root: string) -> (^os.File, Lock_File_Lock_Status) {
	path, path_error := filepath.join({root, PROFILE_GUARD_FILE}, context.temp_allocator)
	if path_error != nil {return nil, .Failed}
	croot, clone_error := strings.clone_to_cstring(path, context.temp_allocator)
	if clone_error != nil {return nil, .Failed}
	fd, open_error := linux.openat(
		linux.AT_FDCWD,
		croot,
		{.CLOEXEC, .CREAT, .NOFOLLOW, .RDWR},
		{.IRUSR, .IWUSR},
	)
	if open_error != .NONE {return nil, .Failed}
	stat: linux.Stat
	if linux.fstat(fd, &stat) != .NONE || !linux.S_ISREG(stat.mode) {
		_ = linux.close(fd)
		return nil, .Failed
	}
	lock_error := linux.flock(fd, {.EX, .NB})
	if lock_error != .NONE {
		_ = linux.close(fd)
		return nil, lock_error == .EAGAIN ? .Busy : .Failed
	}
	return os.new_file(uintptr(fd), path), .Acquired
}

lock_guard_release :: proc(guard: ^os.File) {
	if guard == nil {return}
	_ = linux.flock(linux.Fd(os.fd(guard)), {.UN})
	_ = os.close(guard)
}

lock_file_open :: proc(path: string, create_exclusive: bool) -> (^os.File, Lock_File_Open_Status) {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return nil, .Failed}
	flags: linux.Open_Flags = {.CLOEXEC, .NOFOLLOW, .RDWR}
	if create_exclusive {flags += {.CREAT, .EXCL}}
	fd, open_error := linux.openat(
		linux.AT_FDCWD,
		cpath,
		flags,
		linux.Mode{.IRUSR, .IWUSR},
	)
	if open_error != .NONE {
		if create_exclusive && open_error == .EEXIST {return nil, .Exists}
		if !create_exclusive && open_error == .ENOENT {return nil, .Missing}
		return nil, .Failed
	}
	stat: linux.Stat
	if linux.fstat(fd, &stat) != .NONE || !linux.S_ISREG(stat.mode) {
		_ = linux.close(fd)
		return nil, .Failed
	}
	return os.new_file(uintptr(fd), path), .None
}

lock_file_try_exclusive :: proc(file: ^os.File) -> Lock_File_Lock_Status {
	if file == nil {return .Failed}
	result := linux.flock(linux.Fd(os.fd(file)), {.EX, .NB})
	if result == .NONE {return .Acquired}
	return result == .EAGAIN ? .Busy : .Failed
}

lock_file_unlock :: proc(file: ^os.File) {
	if file != nil {_ = linux.flock(linux.Fd(os.fd(file)), {.UN})}
}

lock_file_identity :: proc(fd: linux.Fd) -> (Lock_File_Identity, bool) {
	stat: linux.Stat
	if linux.fstat(fd, &stat) != .NONE {return {}, false}
	return {
		namespace = u64(stat.dev),
		object_lo = u64(stat.ino),
	}, true
}

lock_file_path_matches :: proc(file: ^os.File, path: string) -> bool {
	if file == nil {return false}
	want, want_ok := lock_file_identity(linux.Fd(os.fd(file)))
	if !want_ok {return false}
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	stat: linux.Stat
	if linux.lstat(cpath, &stat) != .NONE || !linux.S_ISREG(stat.mode) {return false}
	got := Lock_File_Identity {
		namespace = u64(stat.dev),
		object_lo = u64(stat.ino),
	}
	return got == want
}

lock_process_observation :: proc(pid: u32) -> (start: u64, state: u8, ok: bool) {
	data, read_error := os.read_entire_file(
		fmt.tprintf("/proc/%d/stat", pid),
		context.temp_allocator,
	)
	if read_error != nil {return}
	defer delete(data, context.temp_allocator)
	text := string(data)
	comm_end := strings.last_index_byte(text, ')')
	if comm_end < 0 {return}
	fields, fields_error := strings.fields(text[comm_end + 1:], context.temp_allocator)
	if fields_error != nil || len(fields) < 20 || len(fields[0]) != 1 {return}
	value, value_ok := strconv.parse_u64_of_base(fields[19], 10)
	if !value_ok || value == 0 {return}
	return value, fields[0][0], true
}

lock_process_start_token :: proc(pid: u32) -> (u64, bool) {
	start, _, ok := lock_process_observation(pid)
	return start, ok
}

lock_process_state :: proc(owner: Lock_Owner) -> Lock_Process_State {
	if owner.pid == 0 || owner.pid > 0x7FFF_FFFF {return .Unknown}
	probe := linux.kill(linux.Pid(owner.pid), linux.Signal(0))
	if probe == .ESRCH {return .Dead}
	if probe != .NONE && probe != .EPERM {return .Unknown}
	if owner.start == 0 {return .Live}
	start, state, observed := lock_process_observation(owner.pid)
	if !observed {return .Unknown}
	if state == 'Z' {return .Dead}
	return start == owner.start ? .Live : .Dead
}
