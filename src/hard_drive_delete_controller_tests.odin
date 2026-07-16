// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:testing"
import "fat32session"
import "host"

@(test)
hard_drive_delete_controller_test_recursive_delete_is_stepped_and_cancellable :: proc(
	t: ^testing.T,
) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "delete-controller.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"TREE", "TREE/A", "TREE/A/B", "TREE/C"},
		nil,
	) {
		return
	}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	tree, found := hard_drive_controller_test_find_row(&controller, "TREE")
	if !testing.expect(t, found) {return}
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			host.Hard_Drive_UI_Action{kind = .Delete, entry_id = tree.id},
		),
	) {
		return
	}
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.Delete)
	testing.expect(t, controller.job_active && controller.model.progress.active)
	for _ in 0 ..< 8 {
		hard_drive_controller_step(&controller)
		if controller.model.progress.completed > 0 {break}
	}
	if !testing.expect(t, controller.model.progress.completed > 0) {return}
	testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Cancel_Operation}),
	)
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, !controller.job_active && !controller.model.progress.active)
	testing.expect(t, controller.model.pending_changes > 0)
	partial, partial_error := fat32session.edit_stat(controller.session, "TREE")
	testing.expect_value(t, partial_error.code, fat32session.Error_Code.None)
	if !testing.expect(t, partial.exists && partial.is_directory) {return}

	tree, found = hard_drive_controller_test_find_row(&controller, "TREE")
	if !testing.expect(t, found) {return}
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			host.Hard_Drive_UI_Action{kind = .Delete, entry_id = tree.id},
		),
	) {
		return
	}
	steps := 0
	for controller.operation != .None && steps < 32 {
		hard_drive_controller_step(&controller)
		steps += 1
	}
	testing.expect(t, steps > 1 && steps < 32)
	removed, removed_error := fat32session.edit_stat(controller.session, "TREE")
	testing.expect_value(t, removed_error.code, fat32session.Error_Code.None)
	testing.expect(t, !removed.exists)
}
