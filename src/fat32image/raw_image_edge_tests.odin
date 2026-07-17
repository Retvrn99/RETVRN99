// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
fat32image_test_end_ranges_are_exact_and_never_extend_the_image :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "range.img")
	if !create_ok {return}
	defer info_destroy(&created)
	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}

	logical_size, size_error := os.file_size(image.file)
	if !testing.expect_value(t, size_error, os.Error(nil)) {return}
	last_lba := image.info.sector_count - 1
	last: [SECTOR_BYTES]u8
	for &value, index in last {value = u8(index * 17 + 9)}
	testing.expect_value(t, block_write(image, last_lba, last[:]).code, Error_Code.None)
	readback: [SECTOR_BYTES]u8
	testing.expect_value(t, block_read(image, last_lba, readback[:]).code, Error_Code.None)
	testing.expect_value(t, string(readback[:]), string(last[:]))

	crossing: [SECTOR_BYTES * 2]u8
	testing.expect_value(t, block_write(image, last_lba, crossing[:]).code, Error_Code.Out_Of_Range)
	testing.expect_value(t, block_read(image, last_lba, crossing[:]).code, Error_Code.Out_Of_Range)
	testing.expect_value(
		t,
		block_write(image, image.info.sector_count, last[:]).code,
		Error_Code.Out_Of_Range,
	)
	testing.expect_value(t, block_read(image, max(u64), last[:]).code, Error_Code.Out_Of_Range)
	empty: [0]u8
	testing.expect_value(t, block_read(image, 0, empty[:]).code, Error_Code.Invalid_Argument)
	after_size, after_size_error := os.file_size(image.file)
	testing.expect_value(t, after_size_error, os.Error(nil))
	testing.expect_value(t, after_size, logical_size)
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
}

@(test)
fat32image_test_alias_open_is_rejected_by_the_image_lock :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "original.img")
	if !create_ok {return}
	defer info_destroy(&created)
	alias, alias_error := filepath.join({directory, "alias.img"}, context.temp_allocator)
	if !testing.expect(t, alias_error == nil) {return}
	if !testing.expect_value(t, os.link(path, alias), os.Error(nil)) {return}

	image, open_error := open(path, .Read_Write)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	duplicate, duplicate_error := open(alias, .Read_Write)
	testing.expect_value(t, duplicate_error.code, Error_Code.Locked)
	if duplicate != nil {_ = close(duplicate, .Retain)}
	testing.expect_value(t, close(image, .Clean).code, Error_Code.None)
}
