#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import "core:os"
import "core:path/filepath"
import "core:strings"
import linux "core:sys/linux"
import "core:testing"

@(test)
fat32image_test_linux_static_symlink_and_fifo_are_rejected :: proc(t: ^testing.T) {
	directory, directory_ok := fat32image_test_directory(t)
	if !directory_ok {return}
	defer os.remove_all(directory)
	path, created, create_ok := fat32image_test_create(t, directory, "source.img")
	if !create_ok {return}
	defer info_destroy(&created)
	link, link_error := filepath.join({directory, "link.img"}, context.temp_allocator)
	fifo, fifo_error := filepath.join({directory, "pipe.img"}, context.temp_allocator)
	if !testing.expect(t, link_error == nil && fifo_error == nil) ||
	   !testing.expect_value(t, os.symlink(path, link), os.Error(nil)) {
		return
	}
	cfifo, cstring_error := strings.clone_to_cstring(fifo, context.temp_allocator)
	if !testing.expect(t, cstring_error == nil) ||
	   !testing.expect_value(
			   t,
			   linux.mknod(cfifo, {.IFIFO, .IRUSR, .IWUSR}, 0),
			   linux.Errno.NONE,
		   ) {
		return
	}

	_, link_validation_error := validate(link)
	testing.expect_value(t, link_validation_error.code, Error_Code.Path_Unsupported)
	linked, link_open_error := open(link, .Read_Write)
	testing.expect_value(t, link_open_error.code, Error_Code.Path_Unsupported)
	if linked != nil {_ = close(linked, .Retain)}
	_, fifo_validation_error := validate(fifo)
	testing.expect_value(t, fifo_validation_error.code, Error_Code.Path_Unsupported)
	pipe, fifo_open_error := open(fifo, .Read_Write)
	testing.expect_value(t, fifo_open_error.code, Error_Code.Path_Unsupported)
	if pipe != nil {_ = close(pipe, .Retain)}
}
