// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"

COPY_TREE_MAX_DEPTH :: 64

copy_directory_tree :: proc(destination, source: string) -> bool {
	if !copy_tree_directory(source) || !copy_tree_directory(destination) {return false}
	return copy_directory_tree_walk(destination, source, 0)
}

@(private = "file")
copy_directory_tree_walk :: proc(destination, source: string, depth: int) -> bool {
	if depth > COPY_TREE_MAX_DEPTH {return false}
	infos, read_error := os.read_all_directory_by_path(source, context.temp_allocator)
	if read_error != nil {return false}
	defer os.file_info_slice_delete(infos, context.temp_allocator)

	for &info in infos {
		target, join_error := filepath.join({destination, info.name}, context.temp_allocator)
		if join_error != nil {return false}
		ok := false
		#partial switch info.type {
		case .Directory:
			ok = !os.exists(target) &&
			     os.make_directory(target) == nil &&
			     copy_directory_tree_walk(target, info.fullpath, depth + 1)
		case .Regular:
			ok = !os.exists(target) && os.copy_file(target, info.fullpath) == nil
		}
		delete(target, context.temp_allocator)
		if !ok {return false}
	}
	return true
}

@(private = "file")
copy_tree_directory :: proc(path: string) -> bool {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {return false}
	defer os.file_info_delete(info, context.temp_allocator)
	return info.type == .Directory
}
