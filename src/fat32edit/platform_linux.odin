// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import "core:os"
import "core:strings"
import linux "core:sys/linux"

@(private = "package")
platform_sync_directory :: proc(path: string) -> bool {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return false}
	fd, open_error := linux.openat(linux.AT_FDCWD, cpath, {.CLOEXEC, .DIRECTORY, .NOFOLLOW})
	if open_error != .NONE {return false}
	sync_error := linux.fsync(fd)
	close_error := linux.close(fd)
	return sync_error == .NONE && close_error == .NONE
}

@(private = "package")
platform_prepare_sparse :: proc(file: ^os.File) -> bool {
	return file != nil
}

@(private = "package")
platform_host_fd :: proc(path: string, kind: Host_Object_Kind, read: bool) -> linux.Fd {
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return -1}
	flags: linux.Open_Flags = {.CLOEXEC, .NOFOLLOW}
	if read {
		flags += {.NONBLOCK}
		if kind == .Directory {flags += {.DIRECTORY}}
	} else {
		flags += {.PATH}
	}
	fd, open_error := linux.openat(linux.AT_FDCWD, cpath, flags)
	if open_error != .NONE {return -1}
	return fd
}

@(private = "package")
platform_host_fd_identity :: proc(
	fd: linux.Fd,
	kind: Host_Object_Kind,
) -> (
	Host_Object_Identity,
	bool,
) {
	if fd < 0 {return {}, false}
	info: linux.Stat
	if linux.fstat(fd, &info) != .NONE {return {}, false}
	is_directory := linux.S_ISDIR(info.mode)
	if kind == .Directory != is_directory || kind == .Regular && !linux.S_ISREG(info.mode) {
		return {}, false
	}
	identity := Host_Object_Identity {
		valid        = true,
		kind         = kind,
		device       = u64(info.dev),
		size         = u64(info.size),
		write_token  = u64(info.mtime.time_sec) * 1_000_000_000 + u64(info.mtime.time_nsec),
		change_token = u64(info.ctime.time_sec) * 1_000_000_000 + u64(info.ctime.time_nsec),
	}
	inode := u64(info.ino)
	for index in 0 ..< 8 {identity.file_id[index] = u8(inode >> u64(index * 8))}
	return identity, true
}

@(private = "package")
platform_host_component_safe :: proc(path: string) -> (exists, safe: bool) {
	fd := platform_host_fd(path, .Regular, false)
	if fd < 0 {return false, false}
	defer linux.close(fd)
	info: linux.Stat
	if linux.fstat(fd, &info) != .NONE {return true, false}
	return true, !linux.S_ISLNK(info.mode)
}

@(private = "package")
platform_host_snapshot :: proc(
	path: string,
	kind: Host_Object_Kind,
) -> (
	Host_Object_Identity,
	bool,
) {
	fd := platform_host_fd(path, kind, false)
	if fd < 0 {return {}, false}
	defer linux.close(fd)
	return platform_host_fd_identity(fd, kind)
}

@(private = "package")
platform_host_open :: proc(
	path: string,
	kind: Host_Object_Kind,
	expected: Host_Object_Identity,
) -> (
	^os.File,
	bool,
) {
	fd := platform_host_fd(path, kind, true)
	if fd < 0 {return nil, false}
	identity, identity_ok := platform_host_fd_identity(fd, kind)
	if !identity_ok || !host_identity_equal(identity, expected) {
		_ = linux.close(fd)
		return nil, false
	}
	file := os.new_file(uintptr(fd), path)
	if file == nil {
		_ = linux.close(fd)
		return nil, false
	}
	return file, true
}

@(private = "package")
platform_host_verify_open :: proc(file: ^os.File, expected: Host_Object_Identity) -> bool {
	if file == nil {return false}
	identity, ok := platform_host_fd_identity(linux.Fd(os.fd(file)), expected.kind)
	return ok && host_identity_equal(identity, expected)
}

@(private = "package")
platform_host_verify_path :: proc(path: string, expected: Host_Object_Identity) -> bool {
	identity, ok := platform_host_snapshot(path, expected.kind)
	return ok && host_identity_equal(identity, expected)
}
