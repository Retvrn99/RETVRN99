// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
profile_test_lock_rejects_second_owner_and_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_lock_*", context.temp_allocator)
	defer os.remove_all(root)
	first, second: Lock
	testing.expect_value(t, lock_acquire(&first, root, "first"), Lock_Diagnostic.None)
	testing.expect_value(t, lock_acquire(&second, root, "second"), Lock_Diagnostic.Owned)
	lock_release(&first)
	testing.expect_value(t, lock_acquire(&second, root, "second"), Lock_Diagnostic.None)
	lock_release(&second)
}

@(test)
profile_test_lock_preserves_stale_owner_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	root, _ := os.make_directory_temp(base, "retvrn99_profile_stale_*", context.temp_allocator)
	defer os.remove_all(root)
	path, _ := filepath.join({root, PROFILE_LOCK_FILE}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, "0\nstale\n") == nil)
	lock: Lock
	testing.expect_value(t, lock_acquire(&lock, root, "replacement"), Lock_Diagnostic.None)
	entries, read_error := os.read_all_directory_by_path(root, context.temp_allocator)
	if testing.expect(t, read_error == nil) {
		stale_found := false
		for entry in entries {
			if strings.has_prefix(entry.name, PROFILE_LOCK_FILE + ".stale.") {
				stale_found = true
				// The record is named from the owner pid and a nanosecond
				// reading and nothing else. Formatting a struct with a numeric
				// verb would leave the verb error text in the filename here.
				suffix := entry.name[len(PROFILE_LOCK_FILE + ".stale."):]
				plain := strings.count(suffix, ".") == 1
				for character in suffix {
					plain =
						plain &&
						(character == '.' ||
								character == '-' ||
								(character >= '0' && character <= '9'))
				}
				testing.expect(t, plain, entry.name)
			}
			os.file_info_delete(entry, context.temp_allocator)
		}
		testing.expect(t, stale_found)
	}
	lock_release(&lock)
}
