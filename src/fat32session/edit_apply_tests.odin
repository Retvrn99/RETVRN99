// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_apply_test_create :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := create_image({path = path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return path, false}
	image_info_destroy(&info)
	return path, true
}

@(private = "file")
edit_apply_test_expect_progress_equal :: proc(
	t: ^testing.T,
	left, right: Edit_Apply_Progress,
) -> bool {
	return testing.expect_value(t, right.state, left.state) &&
	       testing.expect_value(t, right.completed_units, left.completed_units) &&
	       testing.expect_value(t, right.total_units, left.total_units) &&
	       testing.expect_value(t, right.applied_sectors, left.applied_sectors) &&
	       testing.expect_value(t, right.total_sectors, left.total_sectors) &&
	       testing.expect_value(t, right.cancellable, left.cancellable)
}

@(test)
edit_apply_test_process_and_in_process_step_and_cancel_match :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-stepped-process-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_ok := edit_apply_test_create(t, root, "left.img")
	right_path, right_ok := edit_apply_test_create(t, root, "right.img")
	if !left_ok || !right_ok {return}
	left, left_error := open_edit(left_path, "stepped-left", 0, .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	defer if left != nil {_ = edit_close_retain(left)}
	right, right_error := open_edit(right_path, "stepped-right", 0, .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {return}
	defer if right != nil {_ = edit_close_retain(right)}
	if !testing.expect_value(t, edit_mkdir(left, "STEPPED").code, Error_Code.None) ||
	   !testing.expect_value(t, edit_mkdir(right, "STEPPED").code, Error_Code.None) {
		return
	}
	left_progress, left_begin_error := edit_begin_apply(left)
	right_progress, right_begin_error := edit_begin_apply(right)
	if !testing.expect_value(t, right_begin_error.code, left_begin_error.code) ||
	   !testing.expect_value(t, left_begin_error.code, Error_Code.None) ||
	   !edit_apply_test_expect_progress_equal(t, left_progress, right_progress) {
		return
	}
	testing.expect_value(t, left_progress.state, Edit_Apply_State.Ready)
	testing.expect(t, left_progress.cancellable)
	testing.expect_value(t, edit_cancel_apply(left).code, Error_Code.None)
	testing.expect_value(t, edit_cancel_apply(right).code, Error_Code.None)
	testing.expect(t, edit_ready(left) && edit_ready(right))
	left_info, left_stat_error := edit_stat(left, "STEPPED")
	right_info, right_stat_error := edit_stat(right, "STEPPED")
	testing.expect_value(t, right_stat_error.code, left_stat_error.code)
	testing.expect_value(t, left_info.exists, true)
	testing.expect_value(t, right_info.exists, true)
	left_progress, left_begin_error = edit_begin_apply(left)
	right_progress, right_begin_error = edit_begin_apply(right)
	if !testing.expect_value(t, right_begin_error.code, left_begin_error.code) ||
	   !testing.expect_value(t, left_begin_error.code, Error_Code.None) ||
	   !edit_apply_test_expect_progress_equal(t, left_progress, right_progress) {
		return
	}
	left_progress, left_error = edit_step_apply(left)
	right_progress, right_error = edit_step_apply(right)
	if !testing.expect_value(t, right_error.code, left_error.code) ||
	   !testing.expect_value(t, left_error.code, Error_Code.None) ||
	   !edit_apply_test_expect_progress_equal(t, left_progress, right_progress) {
		return
	}
	testing.expect_value(t, left_progress.state, Edit_Apply_State.Applying)
	testing.expect(t, !left_progress.cancellable)
	testing.expect_value(t, edit_cancel_apply(left).code, Error_Code.Invalid_State)
	testing.expect_value(t, edit_cancel_apply(right).code, Error_Code.Invalid_State)
	steps := 1
	for left_progress.state != .Complete {
		left_progress, left_error = edit_step_apply(left)
		right_progress, right_error = edit_step_apply(right)
		if !testing.expect_value(t, right_error.code, left_error.code) ||
		   !testing.expect_value(t, left_error.code, Error_Code.None) ||
		   !edit_apply_test_expect_progress_equal(t, left_progress, right_progress) {
			return
		}
		steps += 1
		if !testing.expect(t, steps < 1024) {return}
	}
	testing.expect(t, steps > 2)
	testing.expect(t, !edit_ready(left) && !edit_ready(right))
	edit_release_completed(left)
	left = nil
	edit_release_completed(right)
	right = nil
	left_verify, left_verify_error := open_edit(
		left_path,
		"stepped-left-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, left_verify_error.code, Error_Code.None) {return}
	right_verify, right_verify_error := open_edit(
		right_path,
		"stepped-right-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, right_verify_error.code, Error_Code.None) {
		_ = edit_close_retain(left_verify)
		return
	}
	left_info, left_stat_error = edit_stat(left_verify, "STEPPED")
	right_info, right_stat_error = edit_stat(right_verify, "STEPPED")
	testing.expect_value(t, left_stat_error.code, Error_Code.None)
	testing.expect_value(t, right_stat_error.code, Error_Code.None)
	testing.expect(t, left_info.exists && left_info.is_directory)
	testing.expect(t, right_info.exists && right_info.is_directory)
	testing.expect_value(t, edit_finish(left_verify, false).code, Error_Code.None)
	testing.expect_value(t, edit_finish(right_verify, false).code, Error_Code.None)
}
