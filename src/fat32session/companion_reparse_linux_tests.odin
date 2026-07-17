#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
companion_linux_test_environment :: proc(
	t: ^testing.T,
	prefix: string,
) -> (
	root, outside, image_path, state_root, sentinel: string,
	ok: bool,
) {
	root_value, root_error := os.make_directory_temp("", prefix, context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	root = root_value
	outside_value, outside_error := os.make_directory_temp(
		"",
		"retvrn99-companion-outside-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, outside_error, os.Error(nil)) {return}
	outside = outside_value
	image_path, ok = session_test_image(t, root, "drive.img")
	if !ok {return}
	state_root, ok = companion_path(image_path, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	sentinel_value, path_error := filepath.join({outside, "sentinel.txt"}, context.temp_allocator)
	sentinel = sentinel_value
	if !testing.expect(t, path_error == nil) ||
	   !testing.expect_value(t, os.write_entire_file(sentinel, "outside"), os.Error(nil)) {
		ok = false
		return
	}
	ok = true
	return
}

@(private = "file")
companion_linux_test_cleanup :: proc(root, outside, link: string) {
	if link != "" {_ = os.remove(link)}
	if root != "" {_ = os.remove_all(root)}
	if outside != "" {_ = os.remove_all(outside)}
}

@(test)
companion_test_linux_fresh_machine_edit_and_cleanup_reject_symlink :: proc(t: ^testing.T) {
	root, outside, image_path, state_root, sentinel, environment_ok :=
		companion_linux_test_environment(t, "retvrn99-companion-fresh-*")
	if !environment_ok {return}
	defer companion_linux_test_cleanup(root, outside, state_root)
	if !testing.expect_value(t, os.symlink(outside, state_root), os.Error(nil)) {return}
	testing.expect(t, !companion_directory_prepare(state_root, false))
	testing.expect(t, !companion_directory_prepare(state_root, true))
	testing.expect(t, !companion_directory_remove(state_root))
	machine, machine_error := open_in_process(image_path, "unsafe-fresh-machine")
	testing.expect(t, machine == nil && machine_error.code != .None)
	edit, edit_error := open_edit(image_path, "unsafe-fresh-edit", 0, .In_Process)
	testing.expect(t, edit == nil && edit_error.code != .None)
	testing.expect(t, os.exists(state_root) && os.exists(sentinel))
}

@(test)
companion_test_linux_machine_and_edit_recovery_reject_symlink_swap :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for edit_session in variants {
		root, outside, image_path, state_root, sentinel, environment_ok :=
			companion_linux_test_environment(t, "retvrn99-companion-recovery-*")
		if !environment_ok {return}
		defer companion_linux_test_cleanup(root, outside, state_root)
		if edit_session {
			edit, edit_error := open_edit(image_path, "symlink-edit-first", 0, .In_Process)
			if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
			if !testing.expect_value(t, edit_mkdir(edit, "PENDING").code, Error_Code.None) ||
			   !testing.expect_value(t, edit_close_retain(edit).code, Error_Code.None) {
				return
			}
		} else {
			machine, machine_error := open_in_process(image_path, "symlink-machine-first")
			if !testing.expect_value(t, machine_error.code, Error_Code.None) {return}
			if !testing.expect_value(t, close(machine, .Retain).code, Error_Code.None) {return}
		}
		held, path_error := filepath.join({root, "held-state"}, context.temp_allocator)
		if !testing.expect(t, path_error == nil) ||
		   !testing.expect_value(t, os.rename(state_root, held), os.Error(nil)) ||
		   !testing.expect_value(t, os.symlink(outside, state_root), os.Error(nil)) {
			return
		}
		if edit_session {
			reopened, reopen_error := open_edit(
				image_path,
				"symlink-edit-second",
				0,
				.In_Process,
			)
			testing.expect(t, reopened == nil && reopen_error.code != .None)
		} else {
			reopened, reopen_error := open_in_process(image_path, "symlink-machine-second")
			testing.expect(t, reopened == nil && reopen_error.code != .None)
		}
		testing.expect(t, os.exists(sentinel))
	}
}
