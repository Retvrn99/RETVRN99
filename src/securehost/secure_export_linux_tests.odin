#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package securehost

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
securehost_test_linux_relative_creation_stays_under_held_parent :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-secure-export-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
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
	if !testing.expect_value(t, os.rename(parent, held_path), os.Error(nil)) ||
	   !testing.expect_value(t, os.symlink(outside, parent), os.Error(nil)) {
		return
	}
	created, create_ok := create_file(&held, "payload.bin")
	if !testing.expect(t, create_ok) {return}
	testing.expect(t, close_created_file(&created))
	held_file, _ := filepath.join({held_path, "payload.bin"}, context.temp_allocator)
	escaped_file, _ := filepath.join({outside, "payload.bin"}, context.temp_allocator)
	testing.expect(t, os.exists(held_file))
	testing.expect(t, !os.exists(escaped_file))
}
