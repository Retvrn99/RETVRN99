// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
install_test_failed_boot_sentinel_missing_is_success :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_failed_boot_sentinel_test_directory(t)
	defer os.remove_all(dir)
	testing.expect_value(
		t,
		install_failed_boot_sentinel_cleanup(dir, true),
		Install_Failed_Boot_Sentinel_Diagnostic.None,
	)
}

@(test)
install_test_failed_boot_sentinel_is_removed_only_for_install_reset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_failed_boot_sentinel_test_directory(t)
	defer os.remove_all(dir)
	windows, _ := filepath.join({dir, "WINDOWS"})
	sentinel, _ := filepath.join({windows, "WNBOOTNG.STS"})
	testing.expect(t, os.make_directory_all(windows) == nil)
	testing.expect(t, os.write_entire_file(sentinel, "setup") == nil)

	testing.expect_value(
		t,
		install_failed_boot_sentinel_cleanup(dir, false),
		Install_Failed_Boot_Sentinel_Diagnostic.None,
	)
	testing.expect(t, os.is_file(sentinel))
	testing.expect_value(
		t,
		install_failed_boot_sentinel_cleanup(dir, true),
		Install_Failed_Boot_Sentinel_Diagnostic.None,
	)
	_, stat_error := os.lstat(sentinel, context.temp_allocator)
	testing.expect_value(t, stat_error, os.Error(os.General_Error.Not_Exist))
}

@(test)
install_test_failed_boot_sentinel_non_regular_entry_blocks_reset :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_failed_boot_sentinel_test_directory(t)
	defer os.remove_all(dir)
	sentinel, _ := filepath.join({dir, "WINDOWS", "WNBOOTNG.STS"})
	testing.expect(t, os.make_directory_all(sentinel) == nil)

	testing.expect_value(
		t,
		install_failed_boot_sentinel_cleanup(dir, true),
		Install_Failed_Boot_Sentinel_Diagnostic.Not_Regular,
	)
	testing.expect(t, os.is_directory(sentinel))
}

@(private = "file")
install_failed_boot_sentinel_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(
		base,
		"retvrn99_failed_boot_sentinel_*",
		context.allocator,
	)
	testing.expect(t, dir_error == nil)
	return dir
}
