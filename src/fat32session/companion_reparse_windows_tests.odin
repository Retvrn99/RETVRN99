#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"

companion_windows_last_junction_error: u32
companion_windows_last_junction_stage: u32

@(private = "file")
companion_windows_test_symlink :: proc(target, link: string) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, 0x1 | 0x2))
}

@(private = "file")
companion_windows_test_file_symlink :: proc(target, link: string) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, 0x2))
}

@(private = "file")
companion_windows_test_junction :: proc(target, link: string) -> bool {
	companion_windows_last_junction_stage = 1
	absolute, absolute_error := os.get_absolute_path(target, context.temp_allocator)
	if absolute_error != nil {return false}
	companion_windows_last_junction_stage = 2
	substitute := strings.concatenate({`\??\`, absolute}, context.temp_allocator)
	substitute_wide := win32.utf8_to_wstring(substitute, context.temp_allocator)
	print_wide := win32.utf8_to_wstring(absolute, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if substitute_wide == nil || print_wide == nil || link_wide == nil {return false}
	companion_windows_last_junction_stage = 3
	if !bool(win32.CreateDirectoryW(link_wide, nil)) {
		companion_windows_last_junction_error = win32.GetLastError()
		return false
	}
	companion_windows_last_junction_stage = 4
	substitute_utf16 := string16(substitute_wide)
	print_utf16 := string16(print_wide)
	substitute_units := len(substitute_utf16)
	print_units := len(print_utf16)
	path_bytes := (substitute_units + 1 + print_units + 1) * 2
	if path_bytes > 4 * 1024 - 16 {return false}
	companion_windows_last_junction_stage = 5
	buffer: [4 * 1024]u8
	put_u32le(buffer[:], 0, win32.IO_REPARSE_TAG_MOUNT_POINT)
	put_u16le(buffer[:], 4, u16(8 + path_bytes))
	put_u16le(buffer[:], 8, 0)
	put_u16le(buffer[:], 10, u16(substitute_units * 2))
	put_u16le(buffer[:], 12, u16((substitute_units + 1) * 2))
	put_u16le(buffer[:], 14, u16(print_units * 2))
	for index in 0 ..< substitute_units {
		put_u16le(buffer[:], 16 + index * 2, substitute_utf16[index])
	}
	print_start := 16 + (substitute_units + 1) * 2
	for index in 0 ..< print_units {
		put_u16le(buffer[:], print_start + index * 2, print_utf16[index])
	}
	companion_windows_last_junction_stage = 6
	handle := win32.CreateFileW(
		link_wide,
		win32.GENERIC_WRITE,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OPEN_REPARSE_POINT,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {return false}
	companion_windows_last_junction_stage = 7
	bytes: win32.DWORD
	ok := bool(
		win32.DeviceIoControl(
			handle,
			win32.FSCTL_SET_REPARSE_POINT,
			&buffer[0],
			win32.DWORD(16 + path_bytes),
			nil,
			0,
			&bytes,
			nil,
		),
	)
	companion_windows_last_junction_error = win32.GetLastError()
	_ = win32.CloseHandle(handle)
	return ok
}

@(private = "file")
companion_windows_test_environment :: proc(
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
companion_windows_test_cleanup :: proc(root, outside, link: string) {
	if link != "" {_ = os.remove(link)}
	if root != "" {_ = os.remove_all(root)}
	if outside != "" {_ = os.remove_all(outside)}
}

@(test)
companion_test_windows_fresh_machine_and_edit_reject_symlink_and_junction :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for junction in variants {
		root, outside, image_path, state_root, sentinel, environment_ok :=
			companion_windows_test_environment(t, "retvrn99-companion-fresh-*")
		if !environment_ok {return}
		defer companion_windows_test_cleanup(root, outside, state_root)
		link_ok := false
		if junction {
			link_ok = companion_windows_test_junction(outside, state_root)
		} else {
			link_ok = companion_windows_test_symlink(outside, state_root)
		}
		if !testing.expect(t, link_ok) {return}
		testing.expect(t, !companion_directory_prepare(state_root, false))
		testing.expect(t, !companion_directory_prepare(state_root, true))
		machine, machine_error := open_in_process(image_path, "unsafe-fresh-machine")
		testing.expect(t, machine == nil && machine_error.code != .None)
		edit, edit_error := open_edit(image_path, "unsafe-fresh-edit", 0, .In_Process)
		testing.expect(t, edit == nil && edit_error.code != .None)
		testing.expect(t, os.exists(sentinel))
	}
}

@(test)
companion_test_windows_machine_and_edit_recovery_reject_reparse_swap :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for edit_session in variants {
		root, outside, image_path, state_root, sentinel, environment_ok :=
			companion_windows_test_environment(t, "retvrn99-companion-recovery-*")
		if !environment_ok {return}
		defer companion_windows_test_cleanup(root, outside, state_root)
		if edit_session {
			edit, edit_error := open_edit(image_path, "reparse-edit-first", 0, .In_Process)
			if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
			if !testing.expect_value(t, edit_mkdir(edit, "PENDING").code, Error_Code.None) ||
			   !testing.expect_value(t, edit_close_retain(edit).code, Error_Code.None) {
				return
			}
		} else {
			machine, machine_error := open_in_process(image_path, "reparse-machine-first")
			if !testing.expect_value(t, machine_error.code, Error_Code.None) {return}
			if !testing.expect_value(t, close(machine, .Retain).code, Error_Code.None) {return}
		}
		held, path_error := filepath.join({root, "held-state"}, context.temp_allocator)
		if !testing.expect(t, path_error == nil) ||
		   !testing.expect_value(t, os.rename(state_root, held), os.Error(nil)) {
			return
		}
		if !testing.expect(t, companion_windows_test_junction(outside, state_root)) {return}
		if edit_session {
			reopened, reopen_error := open_edit(image_path, "reparse-edit-second", 0, .In_Process)
			testing.expect(t, reopened == nil && reopen_error.code != .None)
		} else {
			reopened, reopen_error := open_in_process(image_path, "reparse-machine-second")
			testing.expect(t, reopened == nil && reopen_error.code != .None)
		}
		testing.expect(t, os.exists(sentinel))
	}
}

@(test)
companion_test_windows_cleanup_never_removes_through_reparse_leaf :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for junction in variants {
		root, outside, _, state_root, sentinel, environment_ok :=
			companion_windows_test_environment(t, "retvrn99-companion-cleanup-*")
		if !environment_ok {return}
		defer companion_windows_test_cleanup(root, outside, state_root)
		link_ok := false
		if junction {
			link_ok = companion_windows_test_junction(outside, state_root)
		} else {
			link_ok = companion_windows_test_symlink(outside, state_root)
		}
		if !testing.expect(t, link_ok) {return}
		testing.expect(t, !companion_directory_remove(state_root))
		testing.expect(t, os.exists(state_root) && os.exists(sentinel))
	}
}

@(test)
companion_test_windows_edit_child_recovery_rejects_symlink_and_junction :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for junction in variants {
		root, outside, image_path, state_root, sentinel, environment_ok :=
			companion_windows_test_environment(t, "retvrn99-companion-edit-child-*")
		if !environment_ok {return}
		root = strings.clone(root)
		outside = strings.clone(outside)
		image_path = strings.clone(image_path)
		state_root = strings.clone(state_root)
		sentinel = strings.clone(sentinel)
		edit_path, edit_path_error := filepath.join({state_root, "edit"})
		held_path, held_path_error := filepath.join({state_root, "held-edit"})
		if !testing.expect(t, edit_path_error == nil && held_path_error == nil) {return}
		edit, edit_error := open_edit(image_path, "edit-child-first", 0, .In_Process)
		if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_mkdir(edit, "PENDING").code, Error_Code.None) ||
		   !testing.expect_value(t, edit_close_retain(edit).code, Error_Code.None) ||
		   !testing.expect_value(t, os.rename(edit_path, held_path), os.Error(nil)) {
			return
		}
		if !testing.expectf(t, !os.exists(edit_path), "renamed edit child still exists") {return}
		linked := false
		if junction {
			linked = companion_windows_test_junction(outside, edit_path)
		} else {
			linked = companion_windows_test_symlink(outside, edit_path)
		}
		if !testing.expectf(
			t,
			linked,
			"cannot create edit-child reparse (junction=%v, stage=%d, error=%d)",
			junction,
			companion_windows_last_junction_stage,
			companion_windows_last_junction_error,
		) {return}
		reopened, reopen_error := open_edit(image_path, "edit-child-second", 0, .In_Process)
		testing.expect(t, reopened == nil && reopen_error.code != .None)
		identity, identity_ok := platform_companion_directory_identity(state_root)
		boundary, boundary_ok := companion_boundary_open(state_root, context.temp_allocator)
		if testing.expect(t, identity_ok && boundary_ok) {
			testing.expect(t, !companion_remove_known_tree(&boundary, identity))
			companion_boundary_close(&boundary, context.temp_allocator)
		}
		testing.expect(t, os.exists(sentinel))
		companion_windows_test_cleanup(root, outside, edit_path)
		delete(root)
		delete(outside)
		delete(image_path)
		delete(state_root)
		delete(sentinel)
		delete(edit_path)
		delete(held_path)
	}
}

@(test)
companion_test_windows_machine_leaves_reject_file_symlink_and_junction :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for junction in variants {
		root, outside, image_path, state_root, sentinel, environment_ok :=
			companion_windows_test_environment(t, "retvrn99-companion-machine-leaf-*")
		if !environment_ok {return}
		root = strings.clone(root)
		outside = strings.clone(outside)
		image_path = strings.clone(image_path)
		state_root = strings.clone(state_root)
		sentinel = strings.clone(sentinel)
		machine, machine_error := open_in_process(image_path, "machine-leaf-first")
		if !testing.expect_value(t, machine_error.code, Error_Code.None) ||
		   !testing.expect_value(t, close(machine, .Retain).code, Error_Code.None) {
			return
		}
		state_b, state_b_error := filepath.join({state_root, "state.b"})
		if !testing.expect(t, state_b_error == nil) {return}
		state_name := os.exists(state_b) ? "state.b" : "state.a"
		leaf, leaf_error := filepath.join({state_root, state_name})
		held, held_error := filepath.join({state_root, "held-state"})
		if !testing.expect(t, leaf_error == nil && held_error == nil) ||
		   !testing.expect_value(t, os.rename(leaf, held), os.Error(nil)) {
			return
		}
		if !testing.expectf(t, !os.exists(leaf), "renamed Machine leaf still exists") {return}
		linked := false
		if junction {
			linked = companion_windows_test_junction(outside, leaf)
		} else {
			linked = companion_windows_test_file_symlink(sentinel, leaf)
		}
		if !testing.expectf(
			t,
			linked,
			"cannot create Machine-leaf reparse (junction=%v, stage=%d, error=%d)",
			junction,
			companion_windows_last_junction_stage,
			companion_windows_last_junction_error,
		) {return}
		reopened, reopen_error := open_in_process(image_path, "machine-leaf-second")
		testing.expect(t, reopened == nil && reopen_error.code != .None)
		identity, identity_ok := platform_companion_directory_identity(state_root)
		boundary, boundary_ok := companion_boundary_open(state_root, context.temp_allocator)
		if testing.expect(t, identity_ok && boundary_ok) {
			testing.expect(t, !companion_remove_known_tree(&boundary, identity))
			companion_boundary_close(&boundary, context.temp_allocator)
		}
		testing.expect(t, os.exists(sentinel))
		companion_windows_test_cleanup(root, outside, leaf)
		delete(root)
		delete(outside)
		delete(image_path)
		delete(state_root)
		delete(sentinel)
		delete(state_b)
		delete(leaf)
		delete(held)
	}
}
