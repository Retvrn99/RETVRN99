// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
fat32edit_recursive_delete_job_test_steps_and_cancels_between_entries :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-fat32edit-delete-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	image_path, path_error := filepath.join({root, "drive.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	state_path: string
	state_path, path_error = filepath.join(
		{root, ".drive.img.retvrn99-fat32"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	created, create_error := fat32image.create({path = image_path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	fat32image.info_destroy(&created)
	image, open_error := fat32image.open(image_path, .Read_Write)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	base := fat32image.block_device(image)
	owner := fat32image.edit_block_device(image)
	session, edit_error := open(
		base,
		state_path,
		0,
		{ctx = owner.ctx, write = owner.write, flush = owner.flush},
	)
	if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
	paths := [?]string{"TREE", "TREE/A", "TREE/A/B", "TREE/C"}
	for path in paths {
		if !testing.expect_value(t, mkdir(&session, path).code, Error_Code.None) {return}
	}
	job, begin_error := begin_remove_recursive(&session, "TREE")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	root_before, _ := stat(&session, "TREE")
	testing.expect(t, root_before.exists)
	previous_items: u64
	for _ in 0 ..< 3 {
		progress := job_step(&job)
		testing.expect(t, progress.items_completed - previous_items <= 1)
		previous_items = progress.items_completed
	}
	if !testing.expect(t, previous_items > 0) {return}
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	root_after_cancel, _ := stat(&session, "TREE")
	child_after_cancel, _ := stat(&session, "TREE/A/B")
	testing.expect(t, root_after_cancel.exists && root_after_cancel.is_directory)
	testing.expect(t, !child_after_cancel.exists)

	job, begin_error = begin_remove_recursive(&session, "TREE")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	previous_items = 0
	steps := 0
	for job.state != .Complete && job.state != .Failed {
		progress := job_step(&job)
		testing.expect(t, progress.items_completed - previous_items <= 1)
		previous_items = progress.items_completed
		steps += 1
	}
	testing.expect_value(t, job.state, Job_State.Complete)
	testing.expect(t, steps > 1 && previous_items >= 3)
	job_destroy(&job)
	removed, stat_error := stat(&session, "TREE")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, !removed.exists)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}
