// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_dos_seed_placeholder_disables_boot_logo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "MSDOS.SYS"})
	testing.expect(t, os.write_entire_file(path, "; \r\n") == nil)

	testing.expect_value(t, dos_seed_prepare(dir), Dos_Seed_Diagnostic.Updated)
	testing.expect(t, dos_seed_is_managed(dir))
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), DOS_SEED_MSDOS_SYS)
}

@(test)
test_dos_seed_preserves_configured_file :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "MSDOS.SYS"})
	configured := "[Options]\r\nLogo=1\r\n"
	testing.expect(t, os.write_entire_file(path, configured) == nil)

	testing.expect_value(t, dos_seed_prepare(dir), Dos_Seed_Diagnostic.Preserved)
	testing.expect(t, !dos_seed_is_managed(dir))
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(data), configured)
}

@(test)
test_dos_seed_missing_file_is_not_created :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	testing.expect_value(t, dos_seed_prepare(dir), Dos_Seed_Diagnostic.Missing)
}
