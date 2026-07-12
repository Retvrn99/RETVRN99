// SPDX-License-Identifier: GPL-3.0-only
package win98prep

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_replace_path_commits_complete_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	current, _ := filepath.join({root, "current"})
	next, _ := filepath.join({root, "next"})
	backup, _ := filepath.join({root, "backup"})
	_ = os.make_directory(current)
	_ = os.make_directory(next)
	old_file, _ := filepath.join({current, "old.txt"})
	new_file, _ := filepath.join({next, "new.txt"})
	_ = os.write_entire_file(old_file, "old")
	_ = os.write_entire_file(new_file, "new")

	testing.expect(t, replace_path(next, current, backup))
	testing.expect(t, !os.exists(old_file))
	committed, _ := filepath.join({current, "new.txt"})
	testing.expect(t, os.exists(committed))
	testing.expect(t, !os.exists(next))
	testing.expect(t, !os.exists(backup))
}

@(test)
test_fallback_batch_is_language_neutral :: proc(t: ^testing.T) {
	batch := fallback_msbatch()
	testing.expect(t, len(batch) > 0)
	testing.expect(t, contains(batch, `Signature="$CHICAGO$"`))
	testing.expect(t, contains(batch, `InstallDir="C:\WINDOWS"`))
}

@(private)
install_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(base, "retvrn99_win98install_*", context.allocator)
	testing.expect(t, dir_error == nil)
	return dir
}

@(private)
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {return true}
	if len(needle) > len(haystack) {return false}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {return true}
	}
	return false
}
