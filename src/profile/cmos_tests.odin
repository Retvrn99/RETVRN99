// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_cmos_missing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "cmos.bin"})

	data, diagnostic := cmos_load(path)
	testing.expect_value(t, diagnostic, Cmos_Diagnostic.Missing)
	testing.expect_value(t, data, Cmos_Data{})
}

@(test)
test_cmos_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "nested", "cmos.bin"})

	expected: Cmos_Data
	for &value, index in expected {
		value = u8(index)
	}
	testing.expect_value(t, cmos_save(path, expected), Cmos_Diagnostic.None)
	actual, diagnostic := cmos_load(path)
	testing.expect_value(t, diagnostic, Cmos_Diagnostic.None)
	testing.expect_value(t, actual, expected)

	info, serr := os.stat(path, context.allocator)
	testing.expect(t, serr == nil)
	testing.expect_value(t, info.size, i64(CMOS_SIZE))
}

@(test)
test_cmos_wrong_size_is_malformed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "cmos.bin"})
	testing.expect(t, os.write_entire_file(path, make([]u8, CMOS_SIZE - 1)) == nil)

	data, diagnostic := cmos_load(path)
	testing.expect_value(t, diagnostic, Cmos_Diagnostic.Malformed)
	testing.expect_value(t, data, Cmos_Data{})
}

@(test)
test_cmos_save_overwrites_existing_image :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "cmos.bin"})

	first: Cmos_Data
	first[0] = 0x11
	second: Cmos_Data
	second[0] = 0x22
	second[CMOS_SIZE - 1] = 0x99
	testing.expect_value(t, cmos_save(path, first), Cmos_Diagnostic.None)
	testing.expect_value(t, cmos_save(path, second), Cmos_Diagnostic.None)

	actual, diagnostic := cmos_load(path)
	testing.expect_value(t, diagnostic, Cmos_Diagnostic.None)
	testing.expect_value(t, actual, second)
}
