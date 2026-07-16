// SPDX-License-Identifier: GPL-3.0-only
package securehost

import "core:os"
import "core:strings"
import linux "core:sys/linux"

@(private = "package")
platform_open_directory :: proc(path: string) -> (Directory, bool) {
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil || absolute == "" || absolute[0] != '/' {return {}, false}
	root, root_error := linux.openat(
		linux.AT_FDCWD,
		cstring("/"),
		{.CLOEXEC, .DIRECTORY, .NOFOLLOW, .PATH},
	)
	if root_error != .NONE {return {}, false}
	parts := strings.split(absolute[1:], "/", context.temp_allocator)
	current := root
	for part in parts {
		if part == "" {continue}
		if !component_valid(part) {
			_ = linux.close(current)
			return {}, false
		}
		cpart, part_error := strings.clone_to_cstring(part, context.temp_allocator)
		if part_error != nil {
			_ = linux.close(current)
			return {}, false
		}
		child, open_error := linux.openat(
			current,
			cpart,
			{.CLOEXEC, .DIRECTORY, .NOFOLLOW, .PATH},
		)
		_ = linux.close(current)
		if open_error != .NONE {return {}, false}
		current = child
	}
	return {handle = uintptr(current)}, true
}

@(private = "package")
platform_create_directory :: proc(parent: ^Directory, name: string) -> (Directory, bool) {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return {}, false}
	mode: linux.Mode = {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
	if linux.mkdirat(linux.Fd(parent.handle), cname, mode) != .NONE {return {}, false}
	fd, open_error := linux.openat(
		linux.Fd(parent.handle),
		cname,
		{.CLOEXEC, .DIRECTORY, .NOFOLLOW, .PATH},
	)
	if open_error != .NONE {return {}, false}
	return {handle = uintptr(fd)}, true
}

@(private = "package")
platform_create_file :: proc(parent: ^Directory, name: string) -> (^os.File, bool) {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return nil, false}
	mode: linux.Mode = {.IRUSR, .IWUSR}
	fd, open_error := linux.openat(
		linux.Fd(parent.handle),
		cname,
		{.CLOEXEC, .CREAT, .EXCL, .NOFOLLOW, .WRONLY},
		mode,
	)
	if open_error != .NONE {return nil, false}
	file := os.new_file(uintptr(fd), name)
	if file == nil {
		_ = linux.close(fd)
		return nil, false
	}
	return file, true
}

@(private = "package")
platform_close_directory :: proc(directory: ^Directory) {
	_ = linux.close(linux.Fd(directory.handle))
}

@(private = "package")
platform_discard_file :: proc(parent: ^Directory, _: ^os.File, name: string) -> bool {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return false}
	return linux.unlinkat(linux.Fd(parent.handle), cname, {}) == .NONE
}
