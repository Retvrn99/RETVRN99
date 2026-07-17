// SPDX-License-Identifier: GPL-3.0-only
package companionio

import "core:os"

Status :: enum u8 {
	None,
	Missing,
	Unsafe,
	Failed,
}

Identity :: struct {
	valid:   bool,
	device:  u64,
	file_id: u128,
}

Directory :: struct {
	handle:        uintptr,
	parent_handle: uintptr,
	open:          bool,
	owns_parent:   bool,
	path:          string,
	name:          string,
	identity:      Identity,
}

identity_equal :: proc(left, right: Identity) -> bool {
	return left.valid && right.valid && left.device == right.device && left.file_id == right.file_id
}

leaf_valid :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." {return false}
	for byte in transmute([]u8)name {
		if byte == '/' || byte == '\\' || byte == 0 {return false}
	}
	return true
}

open_path :: proc(
	path: string,
	create: bool = false,
	allocator := context.allocator,
) -> (
	Directory,
	Status,
) {
	if path == "" {return {}, .Failed}
	return platform_open_path(path, create, allocator)
}

open_child :: proc(
	parent: ^Directory,
	name: string,
	create: bool,
	allocator := context.allocator,
) -> (
	Directory,
	Status,
) {
	if parent == nil || !parent.open || !leaf_valid(name) {return {}, .Failed}
	return platform_open_child(parent, name, create, allocator)
}

close_directory :: proc(directory: ^Directory, allocator := context.allocator) {
	if directory == nil {return}
	platform_close_directory(directory)
	delete(directory.path, allocator)
	delete(directory.name, allocator)
	directory^ = {}
}

sync_directory :: proc(directory: ^Directory) -> bool {
	return directory != nil && directory.open && platform_sync_directory(directory)
}

open_file :: proc(
	directory: ^Directory,
	name: string,
	flags: os.File_Flags,
) -> (
	file: ^os.File,
	created: bool,
	status: Status,
) {
	if directory == nil || !directory.open || !leaf_valid(name) {return nil, false, .Failed}
	return platform_open_file(directory, name, flags)
}

probe_file :: proc(directory: ^Directory, name: string) -> (exists, safe: bool, size: i64) {
	file, _, status := open_file(directory, name, {.Read})
	if status == .Missing {return false, true, 0}
	if status != .None || file == nil {return true, false, 0}
	defer os.close(file)
	file_size, size_error := os.file_size(file)
	return true, size_error == nil, file_size
}

remove_file :: proc(directory: ^Directory, name: string) -> bool {
	return directory != nil && directory.open && leaf_valid(name) &&
	       platform_remove_file(directory, name)
}

retire_directory :: proc(parent: ^Directory, child: ^Directory) -> bool {
	if child == nil || !child.open {return false}
	return platform_retire_directory(parent, child)
}
