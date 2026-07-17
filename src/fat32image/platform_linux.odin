// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import "core:strings"
import linux "core:sys/linux"

@(private = "package")
platform_prepare_sparse :: proc(file: ^os.File) -> bool {
	if file == nil {return false}
	probe_bytes := i64(16 * 1024 * 1024)
	if os.truncate(file, probe_bytes) != nil {return false}
	sparse := platform_image_is_sparse(file)
	if os.truncate(file, 0) != nil {return false}
	return sparse
}

@(private = "package")
platform_image_is_sparse :: proc(file: ^os.File) -> bool {
	if file == nil {return false}
	stat: linux.Stat
	if linux.fstat(linux.Fd(os.fd(file)), &stat) != .NONE {return false}
	return u64(stat.blocks) * 512 < u64(stat.size)
}

@(private = "package")
platform_image_allocated_bytes :: proc(file: ^os.File) -> (u64, bool) {
	if file == nil {return 0, false}
	stat: linux.Stat
	if linux.fstat(linux.Fd(os.fd(file)), &stat) != .NONE {return 0, false}
	return u64(stat.blocks) * 512, true
}

@(private = "package")
platform_image_path_is_safe_regular :: proc(path: string) -> bool {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	stat: linux.Stat
	return linux.lstat(cpath, &stat) == .NONE && linux.S_ISREG(stat.mode)
}

@(private = "package")
platform_image_lock :: proc(file: ^os.File) -> bool {
	return file != nil && linux.flock(linux.Fd(os.fd(file)), {.EX, .NB}) == .NONE
}

@(private = "package")
platform_image_unlock :: proc(file: ^os.File) {
	if file != nil {_ = linux.flock(linux.Fd(os.fd(file)), {.UN})}
}

@(private = "package")
platform_publish_no_replace :: proc(source, destination: string) -> bool {
	from, from_error := strings.clone_to_cstring(source, context.temp_allocator)
	to, to_error := strings.clone_to_cstring(destination, context.temp_allocator)
	if from_error != nil || to_error != nil {return false}
	rename_error := linux.renameat2(linux.AT_FDCWD, from, linux.AT_FDCWD, to, {.NOREPLACE})
	if rename_error == .NONE {return true}
	if rename_error != .ENOSYS {return false}
	if os.link(source, destination) != nil {return false}
	_ = os.remove(source)
	return true
}

@(private = "package")
platform_sync_published_parent :: proc(path: string) -> bool {
	parent := filepath.dir(path)
	cparent, parent_error := strings.clone_to_cstring(parent, context.temp_allocator)
	if parent_error != nil {return false}
	fd, open_error := linux.openat(linux.AT_FDCWD, cparent, {.CLOEXEC, .DIRECTORY, .NOFOLLOW})
	if open_error != .NONE {return false}
	sync_error := linux.fsync(fd)
	close_error := linux.close(fd)
	return sync_error == .NONE && close_error == .NONE
}
