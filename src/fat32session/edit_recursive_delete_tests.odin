// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_recursive_delete_test_create :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := create_image({path = path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return path, false}
	image_info_destroy(&info)
	return path, true
}

@(private = "file")
edit_recursive_delete_test_step_pair :: proc(
	t: ^testing.T,
	left, right: ^Edit_Session,
) -> (
	Edit_Job_Progress,
	bool,
) {
	left_progress, left_error := edit_job_step(left)
	right_progress, right_error := edit_job_step(right)
	if !testing.expect_value(t, right_error.code, left_error.code) ||
	   !testing.expect_value(t, left_error.code, Error_Code.None) {
		return {}, false
	}
	testing.expect_value(t, right_progress.state, left_progress.state)
	testing.expect_value(t, right_progress.completed_bytes, left_progress.completed_bytes)
	testing.expect_value(t, right_progress.total_bytes, left_progress.total_bytes)
	testing.expect_value(t, right_progress.items_completed, left_progress.items_completed)
	return left_progress, true
}

@(test)
edit_recursive_delete_test_process_and_in_process_step_cancel_parity :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-delete-process-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_created := edit_recursive_delete_test_create(t, root, "left.img")
	right_path, right_created := edit_recursive_delete_test_create(t, root, "right.img")
	if !left_created || !right_created {return}
	left, left_open_error := open_edit(left_path, "delete-left", 0, .In_Process)
	if !testing.expect_value(t, left_open_error.code, Error_Code.None) {return}
	defer if left != nil {_ = edit_close_retain(left)}
	right, right_open_error := open_edit(right_path, "delete-right", 0, .Process)
	if !testing.expect_value(t, right_open_error.code, Error_Code.None) {return}
	defer if right != nil {_ = edit_close_retain(right)}
	paths := [?]string{"TREE", "TREE/A", "TREE/A/B", "TREE/C", "TREE/D"}
	for path in paths {
		left_error := edit_mkdir(left, path)
		right_error := edit_mkdir(right, path)
		testing.expect_value(t, right_error.code, left_error.code)
		if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	}
	left_begin := edit_begin_remove_recursive(left, "TREE")
	right_begin := edit_begin_remove_recursive(right, "TREE")
	testing.expect_value(t, right_begin.code, left_begin.code)
	if !testing.expect_value(t, left_begin.code, Error_Code.None) {return}
	progress: Edit_Job_Progress
	for progress.items_completed == 0 {
		ok: bool
		progress, ok = edit_recursive_delete_test_step_pair(t, left, right)
		if !ok {return}
	}
	left_cancel := edit_job_cancel(left)
	right_cancel := edit_job_cancel(right)
	testing.expect_value(t, right_cancel.code, left_cancel.code)
	testing.expect_value(t, left_cancel.code, Error_Code.None)
	testing.expect_value(t, edit_changed_sector_count(right), edit_changed_sector_count(left))
	left_root, left_stat_error := edit_stat(left, "TREE")
	right_root, right_stat_error := edit_stat(right, "TREE")
	testing.expect_value(t, right_stat_error.code, left_stat_error.code)
	testing.expect(t, left_root.exists && right_root.exists)

	left_begin = edit_begin_remove_recursive(left, "TREE")
	right_begin = edit_begin_remove_recursive(right, "TREE")
	testing.expect_value(t, right_begin.code, left_begin.code)
	if !testing.expect_value(t, left_begin.code, Error_Code.None) {return}
	steps := 0
	for {
		ok: bool
		progress, ok = edit_recursive_delete_test_step_pair(t, left, right)
		if !ok {return}
		steps += 1
		if progress.state == .Complete {break}
		if !testing.expect(t, progress.state == .Running || progress.state == .Pending) {return}
	}
	testing.expect(t, steps > 1)
	left_removed, left_removed_error := edit_stat(left, "TREE")
	right_removed, right_removed_error := edit_stat(right, "TREE")
	testing.expect_value(t, right_removed_error.code, left_removed_error.code)
	testing.expect(t, !left_removed.exists && !right_removed.exists)
	testing.expect_value(t, edit_finish(left, false).code, Error_Code.None)
	left = nil
	testing.expect_value(t, edit_finish(right, false).code, Error_Code.None)
	right = nil
}
