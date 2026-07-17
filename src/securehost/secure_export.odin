// SPDX-License-Identifier: GPL-3.0-only
package securehost

import "core:os"
import "core:path/filepath"
import "core:strings"

MAX_HOST_PATH_BYTES :: 32 * 1024

Directory :: struct {
	handle: uintptr,
}

Created_File :: struct {
	parent: Directory,
	file:   ^os.File,
	name:   string,
}

directory_valid :: proc(directory: ^Directory) -> bool {
	return directory != nil && directory.handle != 0 && directory.handle != ~uintptr(0)
}

component_valid :: proc(name: string) -> bool {
	if name == "" || name == "." || name == ".." || len(name) > MAX_HOST_PATH_BYTES {
		return false
	}
	for byte in transmute([]u8)name {
		switch byte {
		case 0, '/', '\\', '<', '>', ':', '"', '|', '?', '*':
			return false
		}
	}
	return true
}

open_directory :: proc(path: string) -> (Directory, bool) {
	if path == "" || len(path) > MAX_HOST_PATH_BYTES {return {}, false}
	return platform_open_directory(path)
}

create_directory :: proc(parent: ^Directory, name: string) -> (Directory, bool) {
	if !directory_valid(parent) || !component_valid(name) {return {}, false}
	return platform_create_directory(parent, name)
}

close_directory :: proc(directory: ^Directory) {
	if directory == nil {return}
	if directory_valid(directory) {platform_close_directory(directory)}
	directory^ = {}
}

create_file :: proc(parent: ^Directory, name: string) -> (Created_File, bool) {
	if !directory_valid(parent) || !component_valid(name) {return {}, false}
	file, ok := platform_create_file(parent, name)
	if !ok {return {}, false}
	result := Created_File {
		parent = parent^,
		file   = file,
		name   = strings.clone(name),
	}
	parent^ = {}
	return result, true
}

create_file_path :: proc(path: string) -> (Created_File, bool) {
	if path == "" || len(path) > MAX_HOST_PATH_BYTES {return {}, false}
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil || absolute == "" {return {}, false}
	name := filepath.base(absolute)
	if !component_valid(name) {return {}, false}
	parent_path := filepath.dir(absolute)
	parent, parent_ok := open_directory(parent_path)
	if !parent_ok {return {}, false}
	created, create_ok := create_file(&parent, name)
	if !create_ok {
		close_directory(&parent)
		return {}, false
	}
	return created, true
}

close_created_file :: proc(created: ^Created_File) -> bool {
	if created == nil {return false}
	ok := true
	if created.file != nil {
		ok = os.close(created.file) == nil
		created.file = nil
	}
	close_directory(&created.parent)
	delete(created.name)
	created^ = {}
	return ok
}

discard_created_file :: proc(created: ^Created_File) -> bool {
	if created == nil {return false}
	removed := false
	if created.file != nil && directory_valid(&created.parent) && component_valid(created.name) {
		removed = platform_discard_file(&created.parent, created.file, created.name)
	}
	closed := close_created_file(created)
	return removed && closed
}
