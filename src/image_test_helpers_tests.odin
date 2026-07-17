// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import "fat32session"

Test_Image_File :: struct {
	path: string,
	data: string,
}

test_image_create :: proc(
	t: ^testing.T,
	root, name: string,
	adapter := fat32session.Adapter_Kind.In_Process,
) -> string {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return ""}
	info, create_error := fat32session.create_image(
		{path = path, capacity_gib = 1, allow_full_allocation = true},
		adapter,
		context.temp_allocator,
	)
	if !testing.expect(t, create_error.code == .None) {return ""}
	fat32session.image_info_destroy(&info, context.temp_allocator)
	return path
}

test_image_write_files :: proc(
	t: ^testing.T,
	image_path: string,
	directories: []string,
	files: []Test_Image_File,
	adapter := fat32session.Adapter_Kind.In_Process,
) -> bool {
	edit, open_error := fat32session.open_edit(image_path, "root-test-edit", 0, adapter)
	if !testing.expect(t, open_error.code == .None && edit != nil) {return false}
	for directory in directories {
		info, stat_error := fat32session.edit_stat(edit, directory)
		if !testing.expect(t, stat_error.code == .None) {
			_ = fat32session.edit_finish(edit, false)
			return false
		}
		if info.exists {
			if !testing.expect(t, info.is_directory) {
				_ = fat32session.edit_finish(edit, false)
				return false
			}
			continue
		}
		if mkdir_error := fat32session.edit_mkdir(edit, directory);
		   !testing.expect(t, mkdir_error.code == .None) {
			_ = fat32session.edit_finish(edit, false)
			return false
		}
	}
	base, base_error := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, base_error == nil) {
		_ = fat32session.edit_finish(edit, false)
		return false
	}
	host_root, host_error := os.make_directory_temp(
		base,
		"retvrn99_image_file_*",
		context.temp_allocator,
	)
	if !testing.expect(t, host_error == nil) {
		_ = fat32session.edit_finish(edit, false)
		return false
	}
	defer os.remove_all(host_root)
	source, source_error := filepath.join({host_root, "source.bin"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {
		_ = fat32session.edit_finish(edit, false)
		return false
	}
	for file in files {
		if !testing.expect(t, os.write_entire_file(source, file.data) == nil) {
			_ = fat32session.edit_finish(edit, false)
			return false
		}
		destination, stat_error := fat32session.edit_stat(edit, file.path)
		if !testing.expect(t, stat_error.code == .None) {
			_ = fat32session.edit_finish(edit, false)
			return false
		}
		if begin_error := fat32session.edit_begin_import_file(
			edit,
			source,
			file.path,
			destination.exists,
		); !testing.expect(t, begin_error.code == .None) {
			_ = fat32session.edit_finish(edit, false)
			return false
		}
		for {
			progress, step_error := fat32session.edit_job_step(edit)
			if !testing.expect(t, step_error.code == .None) {
				_ = fat32session.edit_finish(edit, false)
				return false
			}
			if progress.state == .Complete {break}
			if !testing.expect(t, progress.state != .Failed && progress.state != .Cancelled) {
				_ = fat32session.edit_finish(edit, false)
				return false
			}
		}
	}
	apply_error := fat32session.edit_finish(edit, true)
	return testing.expect(t, apply_error.code == .None)
}
