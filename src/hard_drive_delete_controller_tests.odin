// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:strings"
import "core:testing"
import "fat32session"
import "host"

hard_drive_delete_controller_test_snapshot :: proc(
	entry_ids: []u64,
	directory_count: int,
) -> host.Hard_Drive_Delete_Snapshot {
	snapshot: host.Hard_Drive_Delete_Snapshot
	snapshot.count = min(len(entry_ids), host.HARD_DRIVE_BROWSER_SELECTION_CAPACITY)
	snapshot.directory_count = directory_count
	snapshot.file_count = snapshot.count - directory_count
	for entry_id, index in entry_ids[:snapshot.count] {snapshot.entry_ids[index] = entry_id}
	return snapshot
}

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
			host.Hard_Drive_UI_Action {
				kind = .Delete,
				delete_snapshot = hard_drive_delete_controller_test_snapshot([]u64{tree.id}, 1),
			},
		),
	) {
		return
	}
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.Delete)
	testing.expect(t, controller.job_active && controller.model.progress.active)
	for _ in 0 ..< 8 {
		hard_drive_controller_step(&controller)
		if controller.delete_current_items > 0 {break}
	}
	if !testing.expect(t, controller.delete_current_items > 0) {return}
	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Cancel_Operation}))
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	testing.expect(t, !controller.job_active && !controller.model.progress.active)
	testing.expect(t, controller.model.pending_changes > 0)
	testing.expect(t, strings.contains(controller.model.diagnostic, "Apply or Discard"))
	partial, partial_error := fat32session.edit_stat(controller.session, "TREE")
	testing.expect_value(t, partial_error.code, fat32session.Error_Code.None)
	if !testing.expect(t, partial.exists && partial.is_directory) {return}

	tree, found = hard_drive_controller_test_find_row(&controller, "TREE")
	if !testing.expect(t, found) {return}
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			host.Hard_Drive_UI_Action {
				kind = .Delete,
				delete_snapshot = hard_drive_delete_controller_test_snapshot([]u64{tree.id}, 1),
			},
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
	testing.expect_value(t, controller.model.pending_delete_count, 1)
	removed, removed_error := fat32session.edit_stat(controller.session, "TREE")
	testing.expect_value(t, removed_error.code, fat32session.Error_Code.None)
	testing.expect(t, !removed.exists)
}

@(test)
hard_drive_delete_controller_test_batches_are_validated_staged_and_discardable :: proc(
	t: ^testing.T,
) {
	root, ok := hard_drive_controller_test_root(t)
	if !ok {return}
	defer delete(root)
	defer os.remove_all(root)
	image_path := test_image_create(t, root, "delete-batch-controller.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"GAMES", "GAMES/SAVES", "README.TXT", "SETUP.EXE"},
		nil,
	) {
		return
	}
	controller: Hard_Drive_Controller
	hard_drive_controller_init(&controller, .In_Process)
	defer hard_drive_controller_destroy(&controller)
	if !testing.expect(t, hard_drive_controller_open(&controller, image_path)) {return}
	games, games_found := hard_drive_controller_test_find_row(&controller, "GAMES")
	readme, readme_found := hard_drive_controller_test_find_row(&controller, "README.TXT")
	setup, setup_found := hard_drive_controller_test_find_row(&controller, "SETUP.EXE")
	if !testing.expect(t, games_found && readme_found && setup_found) {return}
	games_id, readme_id, setup_id := games.id, readme.id, setup.id

	duplicate := hard_drive_delete_controller_test_snapshot([]u64{games_id, games_id}, 2)
	testing.expect(
		t,
		!hard_drive_controller_handle(&controller, {kind = .Delete, delete_snapshot = duplicate}),
	)
	testing.expect_value(t, controller.operation, Hard_Drive_Controller_Operation.None)
	unchanged, unchanged_error := fat32session.edit_stat(controller.session, "GAMES")
	testing.expect_value(t, unchanged_error.code, fat32session.Error_Code.None)
	testing.expect(t, unchanged.exists)

	first_batch := hard_drive_delete_controller_test_snapshot([]u64{games_id, readme_id}, 2)
	if !testing.expect(
		t,
		hard_drive_controller_handle(&controller, {kind = .Delete, delete_snapshot = first_batch}),
	) {
		return
	}
	steps := 0
	for controller.operation != .None && steps < 128 {
		hard_drive_controller_step(&controller)
		steps += 1
	}
	if !testing.expect(t, steps > 1 && steps < 128) {return}
	testing.expect_value(t, controller.model.pending_delete_count, 2)
	testing.expect_value(t, controller.model.pending_changes, 2)
	games, games_found = hard_drive_controller_find_row(&controller, games_id)
	readme, readme_found = hard_drive_controller_find_row(&controller, readme_id)
	testing.expect(t, games_found && games.pending_deletion)
	testing.expect(t, readme_found && readme.pending_deletion)

	second_batch := hard_drive_delete_controller_test_snapshot([]u64{setup_id}, 1)
	if !testing.expect(
		t,
		hard_drive_controller_handle(
			&controller,
			{kind = .Delete, delete_snapshot = second_batch},
		),
	) {
		return
	}
	for controller.operation != .None && steps < 192 {
		hard_drive_controller_step(&controller)
		steps += 1
	}
	testing.expect(t, steps < 192)
	testing.expect_value(t, controller.model.pending_delete_count, 3)
	testing.expect_value(t, controller.model.pending_changes, 3)

	testing.expect(t, hard_drive_controller_handle(&controller, {kind = .Discard}))
	testing.expect_value(t, controller.model.pending_delete_count, 0)
	testing.expect_value(t, controller.model.pending_changes, 0)
	restored_paths := []string{"GAMES", "README.TXT", "SETUP.EXE"}
	for path in restored_paths {
		info, stat_error := fat32session.edit_stat(controller.session, path)
		testing.expect_value(t, stat_error.code, fat32session.Error_Code.None)
		testing.expect(t, info.exists)
	}
}
