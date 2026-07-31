// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

PROFILE_LOCK_FILE :: ".profile.lock"
PROFILE_GUARD_FILE :: ".profile.guard"

Lock_Diagnostic :: enum {
	None,
	Invalid_Argument,
	Create_Directory_Failed,
	Path_Failed,
	Identity_Failed,
	Owned,
	Owner_Unknown,
	Open_Failed,
	Native_Lock_Failed,
	Write_Failed,
	Stale_Preserve_Failed,
	Raced,
}

Lock_File_Open_Status :: enum {
	None,
	Exists,
	Missing,
	Failed,
}

Lock_File_Lock_Status :: enum {
	Acquired,
	Busy,
	Failed,
}

Lock_File_Identity :: struct {
	namespace: u64,
	object_lo: u64,
	object_hi: u64,
}

Lock_Process_State :: enum {
	Dead,
	Live,
	Unknown,
}

Lock :: struct {
	file:      ^os.File,
	guard:     ^os.File,
	path:      string,
	owner_pid: u32,
	owned:     bool,
}

Lock_Owner :: struct {
	pid:   u32,
	start: u64,
}

lock_owner_from_bytes :: proc(data: []u8) -> (owner: Lock_Owner, valid: bool) {
	lines, lines_error := strings.split_lines(string(data), context.temp_allocator)
	if lines_error != nil || len(lines) < 2 {return}
	pid, pid_ok := strconv.parse_u64_of_base(strings.trim_space(lines[0]), 10)
	if !pid_ok || pid == 0 || pid > 0xFFFF_FFFF {return}
	owner.pid = u32(pid)
	if len(lines) >= 3 && strings.trim_space(lines[2]) != "" {
		start, start_ok := strconv.parse_u64_of_base(strings.trim_space(lines[2]), 10)
		if !start_ok {return {}, false}
		owner.start = start
	}
	return owner, true
}

lock_owner :: proc(path: string) -> (owner: Lock_Owner) {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return}
	defer delete(data, context.temp_allocator)
	owner, _ = lock_owner_from_bytes(data)
	return
}

lock_write_record :: proc(file: ^os.File, contents: string) -> bool {
	if file == nil || os.truncate(file, 0) != nil {return false}
	if _, seek_error := os.seek(file, 0, io.Seek_From.Start); seek_error != nil {return false}
	written, write_error := os.write(file, transmute([]u8)contents)
	return write_error == nil && written == len(contents) && os.sync(file) == nil
}

lock_preserve_stale :: proc(root: string, owner: Lock_Owner, data: []u8) -> bool {
	stale_name := fmt.tprintf(
		"%s.stale.%d.%d",
		PROFILE_LOCK_FILE,
		owner.pid,
		time.tick_now()._nsec,
	)
	stale, stale_error := filepath.join({root, stale_name}, context.temp_allocator)
	if stale_error != nil {return false}
	file, open_error := os.open(stale, {.Write, .Create, .Excl, .Sync})
	if open_error != nil {return false}
	written, write_error := os.write(file, data)
	synced := write_error == nil && written == len(data) && os.sync(file) == nil
	closed := os.close(file) == nil
	if !synced || !closed {_ = os.remove(stale)}
	return synced && closed
}

lock_acquire :: proc(lock: ^Lock, root, session_id: string) -> Lock_Diagnostic {
	pid := u32(os.get_pid())
	start, start_ok := lock_process_start_token(pid)
	return lock_acquire_with_identity(lock, root, session_id, pid, start, start_ok)
}

@(private = "package")
lock_acquire_with_identity :: proc(
	lock: ^Lock,
	root, session_id: string,
	pid: u32,
	start: u64,
	start_ok: bool,
) -> Lock_Diagnostic {
	if lock == nil || root == "" || session_id == "" {return .Invalid_Argument}
	if os.make_directory_all(root) != nil {return .Create_Directory_Failed}
	path, path_error := filepath.join({root, PROFILE_LOCK_FILE})
	if path_error != nil {return .Path_Failed}
	if !start_ok || start == 0 {
		delete(path)
		return .Identity_Failed
	}
	contents := fmt.tprintf("%d\n%s\n%d\n", pid, session_id, start)
	guard, guard_status := lock_guard_acquire(root)
	if guard_status == .Busy {
		owner := lock_owner(path)
		lock.path = path
		lock.owner_pid = owner.pid
		return .Owned
	}
	if guard_status != .Acquired || guard == nil {
		delete(path)
		return .Native_Lock_Failed
	}
	guard_retained := false
	defer if !guard_retained {lock_guard_release(guard)}

	for _ in 0 ..< 8 {
		file, open_status := lock_file_open(path, true)
		created := open_status == .None
		if open_status == .Exists {
			file, open_status = lock_file_open(path, false)
		}
		if open_status == .Missing {continue}
		if open_status != .None || file == nil {
			delete(path)
			return .Open_Failed
		}

		if created && !lock_write_record(file, contents) {
			_ = os.close(file)
			delete(path)
			return .Write_Failed
		}

		lock_status := lock_file_try_exclusive(file)
		if created {
			for attempt in 0 ..< 32 {
				if lock_status != .Busy {break}
				time.sleep(time.Millisecond)
				lock_status = lock_file_try_exclusive(file)
			}
		}
		if lock_status == .Busy {
			owner := lock_owner(path)
			_ = os.close(file)
			lock.path = path
			lock.owner_pid = owner.pid
			return .Owned
		}
		if lock_status != .Acquired {
			_ = os.close(file)
			delete(path)
			return .Native_Lock_Failed
		}
		if !lock_file_path_matches(file, path) {
			lock_file_unlock(file)
			_ = os.close(file)
			continue
		}

		if !created {
			if _, seek_error := os.seek(file, 0, io.Seek_From.Start); seek_error != nil {
				lock_file_unlock(file)
				_ = os.close(file)
				delete(path)
				return .Open_Failed
			}
			data, read_error := os.read_entire_file_from_file(file, context.temp_allocator)
			if read_error != nil {
				lock_file_unlock(file)
				_ = os.close(file)
				delete(path)
				return .Open_Failed
			}
			owner, valid := lock_owner_from_bytes(data)
			if !valid {
				delete(data, context.temp_allocator)
				lock_file_unlock(file)
				_ = os.close(file)
				lock.path = path
				return .Owner_Unknown
			}
			state := lock_process_state(owner)
			if state != .Dead {
				delete(data, context.temp_allocator)
				lock_file_unlock(file)
				_ = os.close(file)
				lock.path = path
				lock.owner_pid = owner.pid
				return state == .Live ? .Owned : .Owner_Unknown
			}
			if !lock_preserve_stale(root, owner, data) {
				delete(data, context.temp_allocator)
				lock_file_unlock(file)
				_ = os.close(file)
				delete(path)
				return .Stale_Preserve_Failed
			}
			delete(data, context.temp_allocator)
			if !lock_write_record(file, contents) {
				lock_file_unlock(file)
				_ = os.close(file)
				delete(path)
				return .Write_Failed
			}
		}

		lock.file = file
		lock.guard = guard
		lock.path = path
		lock.owner_pid = pid
		lock.owned = true
		guard_retained = true
		return .None
	}
	delete(path)
	return .Raced
}

lock_release :: proc(lock: ^Lock) {
	if lock == nil {return}
	retired := ""
	if lock.owned && lock.file != nil && lock.path != "" &&
	   lock_file_path_matches(lock.file, lock.path) {
		retired = fmt.tprintf(
			"%s.release.%d.%d",
			lock.path,
			os.get_pid(),
			time.tick_now()._nsec,
		)
		if os.rename(lock.path, retired) != nil {retired = ""}
	}
	if lock.file != nil {
		if lock.owned {lock_file_unlock(lock.file)}
		_ = os.close(lock.file)
	}
	if retired != "" {_ = os.remove(retired)}
	if lock.guard != nil {lock_guard_release(lock.guard)}
	delete(lock.path)
	lock^ = {}
}
