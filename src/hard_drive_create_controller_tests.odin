// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:thread"
import "fat32session"

@(test)
hard_drive_create_worker_test_completes_without_blocking_caller :: proc(t: ^testing.T) {
	root := install_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	path, path_error := filepath.join({root, "created.img"})
	defer delete(path)
	if !testing.expect(t, path_error == nil) {return}
	worker: Hard_Drive_Create_Worker
	defer hard_drive_create_worker_destroy(&worker)
	if !testing.expect(
		t,
		hard_drive_create_worker_begin(&worker, path, 1, false, .In_Process),
	) {return}
	testing.expect(t, hard_drive_create_worker_running(&worker))
	result: Hard_Drive_Create_Worker_Result
	for !result.ready {
		result = hard_drive_create_worker_poll(&worker)
		if !result.ready {thread.yield()}
	}
	defer fat32session.image_info_destroy(&result.info)
	testing.expect(t, !result.cancelled)
	testing.expect_value(t, result.error.code, fat32session.Error_Code.None)
	testing.expect(t, os.exists(path))

	cancel_path, cancel_path_error := filepath.join({root, "cancelled.img"})
	defer delete(cancel_path)
	if !testing.expect(t, cancel_path_error == nil) {return}
	if !testing.expect(
		t,
		hard_drive_create_worker_begin(&worker, cancel_path, 1, false, .In_Process),
	) {return}
	for hard_drive_create_worker_running(&worker) {thread.yield()}
	testing.expect(t, hard_drive_create_worker_cancel(&worker))
	cancelled := hard_drive_create_worker_poll(&worker)
	testing.expect(t, cancelled.ready)
	testing.expect(t, cancelled.cancelled)
	testing.expect(t, !os.exists(cancel_path))
}
