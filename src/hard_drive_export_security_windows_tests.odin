#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"

@(private = "file")
hard_drive_export_test_symlink :: proc(target, link: string) -> bool {
	target_wide := win32.utf8_to_wstring(target, context.temp_allocator)
	link_wide := win32.utf8_to_wstring(link, context.temp_allocator)
	if target_wide == nil || link_wide == nil {return false}
	return bool(win32.CreateSymbolicLinkW(link_wide, target_wide, 0x1 | 0x2))
}

@(test)
hard_drive_controller_test_recursive_export_reparse_swap_fails_closed :: proc(t: ^testing.T) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "export-race.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"Games", "Games/Sub"},
		[]Test_Image_File{{path = "Games/Sub/payload.bin", data = "guest"}},
	) {
		return
	}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	games, found := hard_drive_controller_test_find_row(&controller, "Games")
	if !testing.expect(t, found) {return}
	export_parent, _ := filepath.join({root, "export"}, context.temp_allocator)
	outside, _ := filepath.join({root, "outside"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(export_parent), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory(outside), os.Error(nil)) {
		return
	}
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{
				kind      = .Export,
				path      = export_parent,
				entry_id  = games.id,
				recursive = true,
			},
		),
	) {
		return
	}
	original, _ := filepath.join({export_parent, "Games"}, context.temp_allocator)
	held, _ := filepath.join({export_parent, "Games-held"}, context.temp_allocator)
	if !testing.expect_value(t, os.rename(original, held), os.Error(nil)) {return}
	if !testing.expect(t, hard_drive_export_test_symlink(outside, original)) {return}
	for _ in 0 ..< 16 {
		if controller.operation == .None {break}
		hard_drive_controller_step(&controller)
	}
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, controller.model.diagnostic != "")
	held_sub, _ := filepath.join({held, "Sub"}, context.temp_allocator)
	escaped_sub, _ := filepath.join({outside, "Sub"}, context.temp_allocator)
	escaped_file, _ := filepath.join({outside, "Sub", "payload.bin"}, context.temp_allocator)
	testing.expect(t, os.exists(held_sub))
	testing.expect(t, !os.exists(escaped_sub))
	testing.expect(t, !os.exists(escaped_file))
	testing.expect(t, !controller.job_active)
}

@(test)
hard_drive_controller_test_cancelled_recursive_export_preserves_partial_safely :: proc(t: ^testing.T) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "export-cancel.img")
	if image_path == "" {return}
	if !test_image_write_files(t, image_path, []string{"Games"}, nil) {return}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	games, found := hard_drive_controller_test_find_row(&controller, "Games")
	if !testing.expect(t, found) {return}
	export_parent, _ := filepath.join({root, "export"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory(export_parent), os.Error(nil)) {return}
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Export, path = export_parent, entry_id = games.id, recursive = true},
		),
	) {
		return
	}
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Cancel_Operation}),
	)
	partial, _ := filepath.join({export_parent, "Games"}, context.temp_allocator)
	testing.expect(t, os.exists(partial))
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, strings.contains(controller.model.diagnostic, "partial destination folder"))
}
