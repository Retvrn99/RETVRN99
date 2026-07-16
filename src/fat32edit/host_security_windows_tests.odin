#+build windows

// SPDX-License-Identifier: GPL-3.0-only

package fat32edit

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import win32 "core:sys/windows"
import "core:testing"

@(private = "file")
host_security_test_open :: proc(
	t: ^testing.T,
) -> (
	directory, state: string,
	image: ^fat32image.Image,
	ok: bool,
) {
	directory_value, directory_error := os.make_directory_temp(
		"",
		"retvrn99-host-security-*",
		context.temp_allocator,
	)
	directory = directory_value
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	path, path_error := filepath.join({directory, "drive.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	state, path_error = filepath.join(
		{directory, ".drive.img.retvrn99-fat32"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	created, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	fat32image.info_destroy(&created)
	image, create_error = fat32image.open(path, .Read_Write)
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	ok = true
	return
}

@(private = "file")
host_security_test_session :: proc(
	t: ^testing.T,
	image: ^fat32image.Image,
	state: string,
) -> (
	Edit_Session,
	bool,
) {
	base := fat32image.block_device(image)
	owner := fat32image.edit_block_device(image)
	session, edit_error := open(
		base,
		state,
		0,
		{ctx = owner.ctx, write = owner.write, flush = owner.flush},
	)
	return session, testing.expect_value(t, edit_error.code, Error_Code.None)
}

@(private = "file")
host_security_test_symlink :: proc(target, link: string, directory: bool) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	flags := win32.DWORD(0x2)
	if directory {flags |= 0x1}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, flags))
}

@(test)
fat32edit_test_windows_device_and_file_reparse_are_rejected :: proc(t: ^testing.T) {
	directory, state, image, ok := host_security_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	target, _ := filepath.join({directory, "target.bin"}, context.temp_allocator)
	link, _ := filepath.join({directory, "link.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(target, "target"), os.Error(nil)) {return}
	session, session_ok := host_security_test_session(t, image, state)
	if !session_ok {return}
	_, device_error := begin_import_file(&session, `\\.\NUL`, "DEVICE.BIN")
	testing.expect_value(t, device_error.code, Error_Code.Host_Path_Unsafe)
	if !testing.expect(t, host_security_test_symlink(target, link, false)) {return}
	_, link_error := begin_import_file(&session, link, "LINK.BIN")
	testing.expect_value(t, link_error.code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_windows_tree_root_and_child_reparse_are_rejected :: proc(t: ^testing.T) {
	directory, state, image, ok := host_security_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	target_tree, _ := filepath.join({directory, "target-tree"}, context.temp_allocator)
	host_tree, _ := filepath.join({directory, "host-tree"}, context.temp_allocator)
	tree_link, _ := filepath.join({directory, "tree-link"}, context.temp_allocator)
	child_target, _ := filepath.join({directory, "child-target.bin"}, context.temp_allocator)
	child_link, _ := filepath.join({host_tree, "child-link.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(target_tree), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory_all(host_tree), os.Error(nil)) ||
	   !testing.expect_value(t, os.write_entire_file(child_target, "child"), os.Error(nil)) {
		return
	}
	session, session_ok := host_security_test_session(t, image, state)
	if !session_ok {return}
	if !testing.expect(t, host_security_test_symlink(target_tree, tree_link, true)) ||
	   !testing.expect(t, host_security_test_symlink(child_target, child_link, false)) {
		return
	}
	_, root_error := begin_import_tree(&session, tree_link, "ROOTLINK")
	testing.expect_value(t, root_error.code, Error_Code.Host_Path_Unsafe)
	job, begin_error := begin_import_tree(&session, host_tree, "TREE")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	for job.state != .Complete && job.state != .Failed {_ = job_step(&job)}
	testing.expect_value(t, job.state, Job_State.Failed)
	testing.expect_value(t, job_error(&job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_windows_export_parent_swap_cannot_escape_or_redirect_cleanup :: proc(t: ^testing.T) {
	directory, state, image, ok := host_security_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "source.bin"}, context.temp_allocator)
	parent, _ := filepath.join({directory, "parent"}, context.temp_allocator)
	held, _ := filepath.join({directory, "held"}, context.temp_allocator)
	outside, _ := filepath.join({directory, "outside"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source, "guest"), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory(parent), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory(outside), os.Error(nil)) {
		return
	}
	session, session_ok := host_security_test_session(t, image, state)
	if !session_ok {return}
	import_job, import_error := begin_import_file(&session, source, "GUEST.BIN")
	if !testing.expect_value(t, import_error.code, Error_Code.None) {return}
	for import_job.state != .Complete && import_job.state != .Failed {_ = job_step(&import_job)}
	if !testing.expect_value(t, import_job.state, Job_State.Complete) {return}
	job_destroy(&import_job)
	destination, _ := filepath.join({parent, "payload.bin"}, context.temp_allocator)
	export_job, export_error := begin_export_file(&session, "GUEST.BIN", destination)
	if !testing.expect_value(t, export_error.code, Error_Code.None) {return}
	defer job_destroy(&export_job)
	testing.expect(t, os.rename(parent, held) != nil)
	testing.expect_value(t, job_cancel(&export_job).code, Error_Code.Cancelled)
	held_file, _ := filepath.join({parent, "payload.bin"}, context.temp_allocator)
	testing.expect(t, !os.exists(held_file))
	if !testing.expect_value(t, os.rename(parent, held), os.Error(nil)) {return}
	if !testing.expect(t, host_security_test_symlink(outside, parent, true)) {return}
	escaped_file, _ := filepath.join({outside, "payload.bin"}, context.temp_allocator)
	testing.expect(t, !os.exists(escaped_file))
	unsafe_destination, _ := filepath.join({parent, "escaped.bin"}, context.temp_allocator)
	_, unsafe_error := begin_export_file(&session, "GUEST.BIN", unsafe_destination)
	testing.expect_value(t, unsafe_error.code, Error_Code.Host_Path_Unsafe)
	escaped_attempt, _ := filepath.join({outside, "escaped.bin"}, context.temp_allocator)
	testing.expect(t, !os.exists(escaped_attempt))
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}
