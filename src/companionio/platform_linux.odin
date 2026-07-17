// SPDX-License-Identifier: GPL-3.0-only
package companionio

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import securehost "../securehost"
import linux "core:sys/linux"

platform_linux_status :: proc(error: linux.Errno) -> Status {
	if error == .NONE {return .None}
	if error == .ENOENT {return .Missing}
	if error == .ELOOP || error == .ENOTDIR {return .Unsafe}
	return .Failed
}

platform_linux_identity :: proc(fd: linux.Fd, directory: bool) -> (Identity, bool) {
	info: linux.Stat
	if fd < 0 || linux.fstat(fd, &info) != .NONE {return {}, false}
	if directory != linux.S_ISDIR(info.mode) || !directory && !linux.S_ISREG(info.mode) {
		return {}, false
	}
	return {
		valid   = true,
		device  = u64(info.dev),
		file_id = u128(info.ino),
	}, true
}

platform_linux_directory_at :: proc(parent: linux.Fd, name: string) -> (linux.Fd, Status) {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return -1, .Failed}
	fd, open_error := linux.openat(parent, cname, {.CLOEXEC, .DIRECTORY, .NOFOLLOW})
	if open_error != .NONE {return -1, platform_linux_status(open_error)}
	if _, valid := platform_linux_identity(fd, true); !valid {
		_ = linux.close(fd)
		return -1, .Unsafe
	}
	return fd, .None
}

platform_open_path :: proc(
	path: string,
	create: bool,
	allocator: runtime.Allocator,
) -> (
	Directory,
	Status,
) {
	parent_path := filepath.dir(path)
	name := filepath.base(path)
	if !leaf_valid(name) {return {}, .Failed}
	secure_parent, parent_ok := securehost.open_directory(parent_path)
	if !parent_ok {return {}, .Failed}
	parent := linux.Fd(secure_parent.handle)
	secure_parent.handle = 0
	if create {
		cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
		if name_error != nil {
			_ = linux.close(parent)
			return {}, .Failed
		}
		mode: linux.Mode = {.IRUSR, .IWUSR, .IXUSR}
		create_error := linux.mkdirat(parent, cname, mode)
		if create_error != .NONE && create_error != .EEXIST {
			_ = linux.close(parent)
			return {}, platform_linux_status(create_error)
		}
	}
	fd, status := platform_linux_directory_at(parent, name)
	if status != .None {
		_ = linux.close(parent)
		return {}, status
	}
	identity, _ := platform_linux_identity(fd, true)
	return {
		handle        = uintptr(fd),
		parent_handle = uintptr(parent),
		open          = true,
		owns_parent   = true,
		path          = strings.clone(path, allocator),
		name          = strings.clone(name, allocator),
		identity      = identity,
	}, .None
}

platform_open_child :: proc(
	parent: ^Directory,
	name: string,
	create: bool,
	allocator: runtime.Allocator,
) -> (
	Directory,
	Status,
) {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return {}, .Failed}
	if create {
		mode: linux.Mode = {.IRUSR, .IWUSR, .IXUSR}
		create_error := linux.mkdirat(linux.Fd(parent.handle), cname, mode)
		if create_error != .NONE && create_error != .EEXIST {
			return {}, platform_linux_status(create_error)
		}
	}
	fd, status := platform_linux_directory_at(linux.Fd(parent.handle), name)
	if status != .None {return {}, status}
	identity, _ := platform_linux_identity(fd, true)
	path, path_error := filepath.join({parent.path, name}, allocator)
	if path_error != nil {
		_ = linux.close(fd)
		return {}, .Failed
	}
	return {
		handle        = uintptr(fd),
		parent_handle = parent.handle,
		open          = true,
		path          = path,
		name          = strings.clone(name, allocator),
		identity      = identity,
	}, .None
}

platform_close_directory :: proc(directory: ^Directory) {
	if directory.open {_ = linux.close(linux.Fd(directory.handle))}
	if directory.owns_parent {_ = linux.close(linux.Fd(directory.parent_handle))}
}

platform_sync_directory :: proc(directory: ^Directory) -> bool {
	return linux.fsync(linux.Fd(directory.handle)) == .NONE
}

platform_open_file :: proc(
	directory: ^Directory,
	name: string,
	flags: os.File_Flags,
) -> (
	^os.File,
	bool,
	Status,
) {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return nil, false, .Failed}
	open_flags: linux.Open_Flags = {.CLOEXEC, .NOFOLLOW}
	if .Read in flags && (.Write in flags || .Append in flags) {
		open_flags += {.RDWR}
	} else if .Write in flags || .Append in flags {
		open_flags += {.WRONLY}
	}
	if .Create in flags {open_flags += {.CREAT}}
	if .Excl in flags {open_flags += {.EXCL}}
	if .Trunc in flags {open_flags += {.TRUNC}}
	if .Sync in flags {open_flags += {.DSYNC}}
	mode: linux.Mode = {.IRUSR, .IWUSR}
	fd, open_error := linux.openat(linux.Fd(directory.handle), cname, open_flags, mode)
	if open_error != .NONE {return nil, false, platform_linux_status(open_error)}
	if _, valid := platform_linux_identity(fd, false); !valid {
		_ = linux.close(fd)
		return nil, false, .Unsafe
	}
	path, path_error := filepath.join({directory.path, name}, context.temp_allocator)
	if path_error != nil {
		_ = linux.close(fd)
		return nil, false, .Failed
	}
	created := .Create in flags && .Excl in flags
	return os.new_file(uintptr(fd), path), created, .None
}

platform_remove_file :: proc(directory: ^Directory, name: string) -> bool {
	cname, name_error := strings.clone_to_cstring(name, context.temp_allocator)
	if name_error != nil {return false}
	file, _, file_status := platform_open_file(directory, name, {.Read})
	if file_status == .Missing {return true}
	if file_status != .None || file == nil {return false}
	_ = os.close(file)
	return linux.unlinkat(linux.Fd(directory.handle), cname, {}) == .NONE
}

platform_retire_directory :: proc(parent: ^Directory, child: ^Directory) -> bool {
	if child == nil || !child.open {return false}
	parent_handle := child.parent_handle
	if parent != nil {
		if !parent.open {return false}
		parent_handle = parent.handle
	}
	cname, name_error := strings.clone_to_cstring(child.name, context.temp_allocator)
	if name_error != nil {return false}
	_ = linux.close(linux.Fd(child.handle))
	child.open = false
	return linux.unlinkat(linux.Fd(parent_handle), cname, {.REMOVEDIR}) == .NONE
}
