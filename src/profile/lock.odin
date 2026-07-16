// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

PROFILE_LOCK_FILE :: ".profile.lock"

Lock_Diagnostic :: enum {
	None,
	Invalid_Argument,
	Create_Directory_Failed,
	Path_Failed,
	Owned,
	Open_Failed,
	Write_Failed,
	Stale_Preserve_Failed,
	Raced,
}

Lock :: struct {
	file:  ^os.File,
	path:  string,
	owned: bool,
}

lock_owner_pid :: proc(path: string) -> u32 {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return 0}
	defer delete(data, context.temp_allocator)
	fields, fields_error := strings.fields(string(data), context.temp_allocator)
	if fields_error != nil || len(fields) == 0 {return 0}
	value, ok := strconv.parse_u64_of_base(fields[0], 10)
	if !ok || value > 0xFFFF_FFFF {return 0}
	return u32(value)
}

lock_acquire :: proc(lock: ^Lock, root, session_id: string) -> Lock_Diagnostic {
	if lock == nil || root == "" || session_id == "" {return .Invalid_Argument}
	if os.make_directory_all(root) != nil {return .Create_Directory_Failed}
	path, path_error := filepath.join({root, PROFILE_LOCK_FILE})
	if path_error != nil {return .Path_Failed}
	for _ in 0 ..< 2 {
		file, open_error := os.open(path, {.Write, .Create, .Excl, .Sync})
		if open_error == nil {
			contents := fmt.tprintf("%d\n%s\n", os.get_pid(), session_id)
			written, write_error := os.write(file, transmute([]u8)contents)
			if write_error != nil || written != len(contents) || os.sync(file) != nil {
				_ = os.close(file)
				_ = os.remove(path)
				delete(path)
				return .Write_Failed
			}
			lock.file = file
			lock.path = path
			lock.owned = true
			return .None
		}
		if open_error != .Exist {
			delete(path)
			return .Open_Failed
		}
		owner := lock_owner_pid(path)
		if lock_process_live(owner) {
			delete(path)
			return .Owned
		}
		stale_name := fmt.tprintf("%s.stale.%d.%d", PROFILE_LOCK_FILE, owner, time.tick_now())
		stale, stale_error := filepath.join({root, stale_name}, context.temp_allocator)
		if stale_error != nil || os.rename(path, stale) != nil {
			delete(path)
			return .Stale_Preserve_Failed
		}
	}
	delete(path)
	return .Raced
}

lock_release :: proc(lock: ^Lock) {
	if lock == nil {return}
	if lock.file != nil {_ = os.close(lock.file)}
	if lock.owned && lock.path != "" {_ = os.remove(lock.path)}
	delete(lock.path)
	lock^ = {}
}
