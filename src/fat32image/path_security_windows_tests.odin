#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"
import "core:testing"

@(private = "file")
fat32image_windows_test_file_symlink :: proc(target, link: string) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, 0x2))
}

@(test)
fat32image_test_windows_static_symlink_and_directory_are_rejected :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "source.img")
	if !create_ok {return}
	defer info_destroy(&created)
	link, link_error := filepath.join({directory, "link.img"}, context.temp_allocator)
	non_file, directory_error := filepath.join(
		{directory, "directory.img"},
		context.temp_allocator,
	)
	if !testing.expect(t, link_error == nil && directory_error == nil) ||
	   !testing.expect(t, fat32image_windows_test_file_symlink(path, link)) ||
	   !testing.expect_value(t, os.make_directory(non_file), os.Error(nil)) {
		return
	}

	_, link_validation_error := validate(link)
	testing.expect_value(t, link_validation_error.code, Error_Code.Path_Unsupported)
	linked, link_open_error := open(link, .Read_Write)
	testing.expect_value(t, link_open_error.code, Error_Code.Path_Unsupported)
	if linked != nil {_ = close(linked, .Retain)}
	_, directory_validation_error := validate(non_file)
	testing.expect_value(t, directory_validation_error.code, Error_Code.Path_Unsupported)
	directory_image, directory_open_error := open(non_file, .Read_Write)
	testing.expect_value(t, directory_open_error.code, Error_Code.Path_Unsupported)
	if directory_image != nil {_ = close(directory_image, .Retain)}
}
