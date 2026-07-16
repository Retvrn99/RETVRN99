// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:strings"
import linux "core:sys/linux"

@(private = "package")
platform_companion_directory_valid :: proc(path: string) -> bool {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	fd, open_error := linux.openat(
		linux.AT_FDCWD,
		cpath,
		{.CLOEXEC, .DIRECTORY, .NOFOLLOW},
	)
	if open_error != .NONE {return false}
	info: linux.Stat
	valid := linux.fstat(fd, &info) == .NONE && linux.S_ISDIR(info.mode)
	return linux.close(fd) == .NONE && valid
}

@(private = "package")
platform_companion_directory_identity :: proc(
	path: string,
) -> (
	Companion_Directory_Identity,
	bool,
) {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return {}, false}
	fd, open_error := linux.openat(
		linux.AT_FDCWD,
		cpath,
		{.CLOEXEC, .DIRECTORY, .NOFOLLOW},
	)
	if open_error != .NONE {return {}, false}
	defer linux.close(fd)
	info: linux.Stat
	if linux.fstat(fd, &info) != .NONE || !linux.S_ISDIR(info.mode) {return {}, false}
	return {
		valid = true,
		device = u64(info.dev),
		file_id = u128(info.ino),
	}, true
}

@(private = "package")
platform_companion_directory_hide :: proc(path: string) -> bool {
	return platform_companion_directory_valid(path)
}

@(private = "package")
platform_companion_directory_hidden :: proc(_: string) -> bool {
	return true
}

@(private = "package")
platform_companion_directory_sync :: proc(path: string) -> bool {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	fd, open_error := linux.openat(linux.AT_FDCWD, cpath, {.CLOEXEC, .DIRECTORY, .NOFOLLOW})
	if open_error != .NONE {return false}
	sync_error := linux.fsync(fd)
	close_error := linux.close(fd)
	return sync_error == .NONE && close_error == .NONE
}
