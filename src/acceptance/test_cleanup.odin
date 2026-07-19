// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:os"

// The Windows implementation of os.remove_all delegates to SHFileOperationW,
// which can wait on shell services indefinitely in headless test runners. Keep
// acceptance fixture cleanup direct and deterministic instead.
@(private = "package")
acceptance_test_remove_tree :: proc(path: string) {
	if path == "" || !os.exists(path) {return}
	directory, open_error := os.open(path, {.Read})
	if open_error != nil {
		_ = os.remove(path)
		return
	}
	entries, read_error := os.read_directory(directory, -1, context.temp_allocator)
	_ = os.close(directory)
	if read_error != nil {
		_ = os.remove(path)
		return
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if entry.type == .Directory {
			acceptance_test_remove_tree(entry.fullpath)
		} else {
			_ = os.remove(entry.fullpath)
		}
	}
	_ = os.remove(path)
}
