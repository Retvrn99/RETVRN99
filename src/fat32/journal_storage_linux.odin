// SPDX-License-Identifier: GPL-3.0-only
package fat32

import "core:os"
import linux "core:sys/linux"

journal_create_temp_file :: proc(backing_dir, pattern: string) -> (^os.File, os.Error) {
	return os.create_temp_file(backing_dir, pattern)
}

journal_process_is_live :: proc(pid: u32) -> bool {
	if pid == 0 || pid > 0x7FFF_FFFF {return false}
	if pid == u32(os.get_pid()) {return true}
	return linux.kill(linux.Pid(pid), linux.Signal(0)) != .ESRCH
}

// Extending a regular Linux file through pwrite creates holes automatically.
overlay_prepare_sparse :: proc(file: ^os.File) -> bool {
	return file != nil
}

// An unlinked open file is reclaimed by the kernel even after a process crash.
overlay_secure_backing_path :: proc(path: string) -> (linked, ok: bool) {
	if err := os.remove(path); err != nil {return true, false}
	return false, true
}

overlay_scavenge_stale :: proc(backing_dir: string) {
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
	return os.remove(path)
}

overlay_allocated_size :: proc(file: ^os.File) -> (u64, bool) {
	return 0, false
}
