#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package securehost

import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"
import "core:testing"

@(private = "file")
test_directory_symlink :: proc(target, link: string) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, 0x1 | 0x2))
}

@(private = "file")
test_root :: proc(t: ^testing.T) -> (string, bool) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-secure-export-*",
		context.temp_allocator,
	)
	return root, testing.expect_value(t, root_error, os.Error(nil))
}

@(test)
securehost_test_windows_relative_creation_stays_under_held_parent :: proc(t: ^testing.T) {
	root, ok := test_root(t)
	if !ok {return}
	defer os.remove_all(root)
	parent, _ := filepath.join({root, "parent"}, context.temp_allocator)
	held_path, _ := filepath.join({root, "held"}, context.temp_allocator)
	outside, _ := filepath.join({root, "outside"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(parent), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory(outside), os.Error(nil)) {
		return
	}
	held, held_ok := open_directory(parent)
	if !testing.expect(t, held_ok) {return}
	defer close_directory(&held)
	if !testing.expect_value(t, os.rename(parent, held_path), os.Error(nil)) {return}
	if !testing.expect(t, test_directory_symlink(outside, parent)) {return}
	created, create_ok := create_file(&held, "payload.bin")
	if !testing.expect(t, create_ok) {return}
	payload := []u8{'h', 'e', 'l', 'd'}
	count, write_error := os.write_at(created.file, payload, 0)
	testing.expect_value(t, count, len(payload))
	testing.expect_value(t, write_error, os.Error(nil))
	testing.expect(t, close_created_file(&created))
	held_file, _ := filepath.join({held_path, "payload.bin"}, context.temp_allocator)
	escaped_file, _ := filepath.join({outside, "payload.bin"}, context.temp_allocator)
	testing.expect(t, os.exists(held_file))
	testing.expect(t, !os.exists(escaped_file))
}

@(test)
securehost_test_windows_reparse_traversal_fails_closed :: proc(t: ^testing.T) {
	root, ok := test_root(t)
	if !ok {return}
	defer os.remove_all(root)
	outside, _ := filepath.join({root, "outside"}, context.temp_allocator)
	link, _ := filepath.join({root, "link"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(outside), os.Error(nil)) {return}
	if !testing.expect(t, test_directory_symlink(outside, link)) {return}
	_, open_ok := open_directory(link)
	testing.expect(t, !open_ok)
	destination, _ := filepath.join({link, "escaped.bin"}, context.temp_allocator)
	created, create_ok := create_file_path(destination)
	if create_ok {_ = discard_created_file(&created)}
	testing.expect(t, !create_ok)
	escaped, _ := filepath.join({outside, "escaped.bin"}, context.temp_allocator)
	testing.expect(t, !os.exists(escaped))
}

@(test)
securehost_test_windows_partial_file_is_discarded_through_held_handle :: proc(t: ^testing.T) {
	root, ok := test_root(t)
	if !ok {return}
	defer os.remove_all(root)
	parent, parent_ok := open_directory(root)
	if !testing.expect(t, parent_ok) {return}
	created, create_ok := create_file(&parent, "partial.bin")
	if !testing.expect(t, create_ok) {return}
	path, _ := filepath.join({root, "partial.bin"}, context.temp_allocator)
	testing.expect(t, os.exists(path))
	testing.expect(t, discard_created_file(&created))
	testing.expect(t, !os.exists(path))
}
