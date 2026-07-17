// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_process_test_create :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := create_image({path = path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return path, false}
	image_info_destroy(&info)
	return path, true
}

@(private = "file")
edit_process_test_expect_pages_equal :: proc(t: ^testing.T, left, right: ^Edit_Page) {
	testing.expect_value(t, right.next_cursor, left.next_cursor)
	testing.expect_value(t, right.has_more, left.has_more)
	if !testing.expect_value(t, len(right.entries), len(left.entries)) {return}
	for index in 0 ..< len(left.entries) {
		a := &left.entries[index]
		b := &right.entries[index]
		testing.expect_value(t, b.name, a.name)
		testing.expect_value(t, b.short_name, a.short_name)
		testing.expect_value(t, b.is_directory, a.is_directory)
		testing.expect_value(t, b.first_cluster, a.first_cluster)
		testing.expect_value(t, b.size, a.size)
		testing.expect_value(t, b.modified_date, a.modified_date)
		testing.expect_value(t, b.modified_time, a.modified_time)
	}
}

@(test)
edit_process_adapter_test_trace_matches_in_process_with_korean_lfn :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-process-trace-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_ok := edit_process_test_create(t, root, "left.img")
	right_path, right_ok := edit_process_test_create(t, root, "right.img")
	if !left_ok || !right_ok {return}
	source, source_error := filepath.join({root, "한국어 원본.bin"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {return}
	content := []u8{0x52, 0x45, 0x54, 0x56, 0x52, 0x4E, 0x39, 0x39}
	if !testing.expect_value(t, os.write_entire_file(source, content), os.Error(nil)) {return}
	left, left_error := open_edit(left_path, "edit-trace-in-process", 0, .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	defer if left != nil {_ = edit_close_retain(left)}
	right, right_error := open_edit(right_path, "edit-trace-process", 0, .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {return}
	defer if right != nil {_ = edit_close_retain(right)}
	testing.expect(t, edit_transaction_id(left) != 0)
	testing.expect(t, edit_transaction_id(right) != 0)
	left_mkdir := edit_mkdir(left, "게임")
	right_mkdir := edit_mkdir(right, "게임")
	testing.expect_value(t, right_mkdir.code, left_mkdir.code)
	if !testing.expect_value(t, left_mkdir.code, Error_Code.None) {return}
	left_begin := edit_begin_import_file(left, source, "게임/안녕하세요.txt")
	right_begin := edit_begin_import_file(right, source, "게임/안녕하세요.txt")
	if !testing.expect_value(t, right_begin.code, left_begin.code) ||
	   !testing.expect_value(t, left_begin.code, Error_Code.None) {return}
	for {
		left_progress, left_step_error := edit_job_step(left)
		right_progress, right_step_error := edit_job_step(right)
		if !testing.expect_value(t, right_step_error.code, left_step_error.code) {return}
		if !testing.expect_value(t, left_step_error.code, Error_Code.None) {return}
		testing.expect_value(t, right_progress.state, left_progress.state)
		testing.expect_value(t, right_progress.completed_bytes, left_progress.completed_bytes)
		testing.expect_value(t, right_progress.total_bytes, left_progress.total_bytes)
		testing.expect_value(t, right_progress.items_completed, left_progress.items_completed)
		if left_progress.state == .Complete {break}
		if !testing.expect(
			t,
			left_progress.state != .Failed && left_progress.state != .Cancelled,
		) {return}
	}
	testing.expect_value(t, edit_changed_sector_count(right), edit_changed_sector_count(left))
	left_invalid_page, left_invalid_error := edit_list(
		left,
		"게임",
		0,
		EDIT_PAGE_ENTRY_LIMIT + 1,
	)
	right_invalid_page, right_invalid_error := edit_list(
		right,
		"게임",
		0,
		EDIT_PAGE_ENTRY_LIMIT + 1,
	)
	defer edit_page_destroy(&left_invalid_page)
	defer edit_page_destroy(&right_invalid_page)
	testing.expect_value(t, right_invalid_error.code, left_invalid_error.code)
	testing.expect_value(t, left_invalid_error.code, Error_Code.Invalid_Argument)
	left_page, left_list_error := edit_list(left, "게임", 0, EDIT_PAGE_ENTRY_LIMIT)
	right_page, right_list_error := edit_list(right, "게임", 0, EDIT_PAGE_ENTRY_LIMIT)
	if !testing.expect_value(t, right_list_error.code, left_list_error.code) {return}
	if !testing.expect_value(t, left_list_error.code, Error_Code.None) {return}
	defer edit_page_destroy(&left_page)
	defer edit_page_destroy(&right_page)
	edit_process_test_expect_pages_equal(t, &left_page, &right_page)
	left_stat, left_stat_error := edit_stat(left, "게임/안녕하세요.txt")
	right_stat, right_stat_error := edit_stat(right, "게임/안녕하세요.txt")
	testing.expect_value(t, right_stat_error.code, left_stat_error.code)
	if !testing.expect_value(t, left_stat_error.code, Error_Code.None) {return}
	testing.expect_value(t, right_stat.exists, left_stat.exists)
	testing.expect_value(t, right_stat.size, left_stat.size)
	left_read, left_read_error := edit_read(left, "게임/안녕하세요.txt", 0, MAX_BLOCK_BYTES)
	right_read, right_read_error := edit_read(
		right,
		"게임/안녕하세요.txt",
		0,
		MAX_BLOCK_BYTES,
	)
	if testing.expect_value(t, right_read_error.code, left_read_error.code) &&
	   testing.expect_value(t, left_read_error.code, Error_Code.None) {
		testing.expect_value(t, string(right_read.data), string(left_read.data))
	} else {
		edit_read_destroy(&left_read)
		edit_read_destroy(&right_read)
		return
	}
	edit_read_destroy(&left_read)
	edit_read_destroy(&right_read)
	left_rename := edit_rename(left, "게임/안녕하세요.txt", "게임/변경.txt")
	right_rename := edit_rename(right, "게임/안녕하세요.txt", "게임/변경.txt")
	testing.expect_value(t, right_rename.code, left_rename.code)
	if !testing.expect_value(t, left_rename.code, Error_Code.None) {return}
	left_io_begin := edit_begin_import_file(left, source, "IO.SYS")
	right_io_begin := edit_begin_import_file(right, source, "IO.SYS")
	if !testing.expect_value(t, right_io_begin.code, left_io_begin.code) ||
	   !testing.expect_value(t, left_io_begin.code, Error_Code.None) {return}
	for {
		left_progress, left_step_error := edit_job_step(left)
		right_progress, right_step_error := edit_job_step(right)
		if !testing.expect_value(t, right_step_error.code, left_step_error.code) {return}
		if !testing.expect_value(t, left_step_error.code, Error_Code.None) {return}
		testing.expect_value(t, right_progress.state, left_progress.state)
		if left_progress.state == .Complete {break}
		if !testing.expect(
			t,
			left_progress.state != .Failed && left_progress.state != .Cancelled,
		) {return}
	}
	left_io, left_io_error := edit_stat(left, "IO.SYS")
	right_io, right_io_error := edit_stat(right, "IO.SYS")
	if !testing.expect_value(t, right_io_error.code, left_io_error.code) ||
	   !testing.expect_value(t, left_io_error.code, Error_Code.None) {return}
	testing.expect_value(t, right_io.first_cluster, left_io.first_cluster)
	left_target, left_patch_error := edit_patch_boot_loader(left, left_io.first_cluster)
	right_target, right_patch_error := edit_patch_boot_loader(right, right_io.first_cluster)
	if !testing.expect_value(t, right_patch_error.code, left_patch_error.code) ||
	   !testing.expect_value(t, left_patch_error.code, Error_Code.None) {return}
	testing.expect_value(t, right_target, left_target)
	left_apply := edit_finish(left, true)
	left = nil
	right_apply := edit_finish(right, true)
	right = nil
	testing.expect_value(t, right_apply.code, left_apply.code)
	if !testing.expect_value(t, left_apply.code, Error_Code.None) {return}
	left_verify, left_verify_error := open_edit(left_path, "edit-verify-left", 0, .In_Process)
	right_verify, right_verify_error := open_edit(right_path, "edit-verify-right", 0, .Process)
	if !testing.expect_value(t, right_verify_error.code, left_verify_error.code) ||
	   !testing.expect_value(t, left_verify_error.code, Error_Code.None) {return}
	left_verify_stat, _ := edit_stat(left_verify, "게임/변경.txt")
	right_verify_stat, _ := edit_stat(right_verify, "게임/변경.txt")
	testing.expect_value(t, right_verify_stat.exists, left_verify_stat.exists)
	testing.expect_value(t, right_verify_stat.size, left_verify_stat.size)
	testing.expect_value(t, edit_finish(left_verify, false).code, Error_Code.None)
	testing.expect_value(t, edit_finish(right_verify, false).code, Error_Code.None)
	left_image, left_image_error := fat32image.open(left_path, .Read_Only)
	right_image, right_image_error := fat32image.open(right_path, .Read_Only)
	if !testing.expect_value(t, left_image_error.code, fat32image.Error_Code.None) ||
	   !testing.expect_value(t, right_image_error.code, fat32image.Error_Code.None) {
		return
	}
	left_vbr, right_vbr: [fat32image.SECTOR_BYTES]u8
	testing.expect_value(
		t,
		fat32image.block_read(left_image, u64(left_image.info.partition_lba), left_vbr[:]).code,
		fat32image.Error_Code.None,
	)
	testing.expect_value(
		t,
		fat32image.block_read(right_image, u64(right_image.info.partition_lba), right_vbr[:]).code,
		fat32image.Error_Code.None,
	)
	testing.expect_value(
		t,
		get_u32le(left_vbr[:], fat32image.VBR_CLUSTER_OFFSET),
		left_target.first_cluster,
	)
	testing.expect_value(
		t,
		get_u64le(left_vbr[:], fat32image.VBR_IO_SYS_LBA_OFFSET),
		left_target.lba,
	)
	testing.expect_value(
		t,
		get_u32le(right_vbr[:], fat32image.VBR_CLUSTER_OFFSET),
		right_target.first_cluster,
	)
	testing.expect_value(
		t,
		get_u64le(right_vbr[:], fat32image.VBR_IO_SYS_LBA_OFFSET),
		right_target.lba,
	)
	testing.expect_value(t, fat32image.close(left_image, .Clean).code, fat32image.Error_Code.None)
	testing.expect_value(t, fat32image.close(right_image, .Clean).code, fat32image.Error_Code.None)
	left_restore, left_restore_open := open_edit(left_path, "edit-restore-left", 0, .In_Process)
	right_restore, right_restore_open := open_edit(right_path, "edit-restore-right", 0, .Process)
	if !testing.expect_value(t, right_restore_open.code, left_restore_open.code) ||
	   !testing.expect_value(t, left_restore_open.code, Error_Code.None) {return}
	left_restore_error := edit_restore_boot_loader(left_restore)
	right_restore_error := edit_restore_boot_loader(right_restore)
	testing.expect_value(t, right_restore_error.code, left_restore_error.code)
	if !testing.expect_value(t, left_restore_error.code, Error_Code.None) {return}
	testing.expect_value(t, edit_finish(left_restore, true).code, Error_Code.None)
	testing.expect_value(t, edit_finish(right_restore, true).code, Error_Code.None)
	left_image, left_image_error = fat32image.open(left_path, .Read_Only)
	right_image, right_image_error = fat32image.open(right_path, .Read_Only)
	if !testing.expect_value(t, left_image_error.code, fat32image.Error_Code.None) ||
	   !testing.expect_value(t, right_image_error.code, fat32image.Error_Code.None) {
		return
	}
	testing.expect_value(
		t,
		fat32image.block_read(left_image, u64(left_image.info.partition_lba), left_vbr[:]).code,
		fat32image.Error_Code.None,
	)
	testing.expect_value(
		t,
		fat32image.block_read(right_image, u64(right_image.info.partition_lba), right_vbr[:]).code,
		fat32image.Error_Code.None,
	)
	testing.expect_value(t, left_vbr[90], u8(0xCD))
	testing.expect_value(t, left_vbr[91], u8(0x18))
	testing.expect_value(t, right_vbr[90], u8(0xCD))
	testing.expect_value(t, right_vbr[91], u8(0x18))
	testing.expect_value(t, fat32image.close(left_image, .Clean).code, fat32image.Error_Code.None)
	testing.expect_value(t, fat32image.close(right_image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
edit_process_adapter_test_completed_cleanup_warning_consumes_apply_and_discard :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-process-completed-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	apply_modes := [?]bool{false, true}
	for apply_changes, index in apply_modes {
		path, created := edit_process_test_create(
			t,
			root,
			apply_changes ? "apply.img" : "discard.img",
		)
		if !created {return}
		session, open_error := open_edit(
			path,
			apply_changes ? "completed-process-apply" : "completed-process-discard",
			0,
			.Process,
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_mkdir(session, "COMPLETED").code, Error_Code.None) {
			_ = edit_close_retain(session)
			return
		}
		if !companion_test_add_cleanup_blocker(t, path) {
			_ = edit_close_retain(session)
			return
		}
		finish_error := edit_finish(session, apply_changes)
		testing.expect_value(t, finish_error.code, Error_Code.Wal_IO)
		testing.expect_value(t, finish_error.outcome, Operation_Outcome.Completed)
		reopened, reopen_error := open_edit(
			path,
			fmt.tprintf("completed-process-verify-%d", index),
			0,
			.In_Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		info, stat_error := edit_stat(reopened, "COMPLETED")
		testing.expect_value(t, stat_error.code, Error_Code.None)
		testing.expect_value(t, info.exists, apply_changes)
		testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None)
	}
}

@(test)
edit_process_adapter_test_orphan_retains_transaction_and_pending_tree :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-process-orphan-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, create_ok := edit_process_test_create(t, root, "orphan.img")
	if !create_ok {return}
	session, open_error := open_edit(path, "edit-orphan", 0, .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	transaction := edit_transaction_id(session)
	if !testing.expect(t, transaction != 0) {return}
	if !testing.expect_value(t, edit_mkdir(session, "PENDING").code, Error_Code.None) {return}
	impl := (^Edit_Process_Implementation)(session.ctx)
	process_test_close_request(impl.transport)
	if !process_test_wait(t, impl.transport, 3) {return}
	testing.expect_value(t, edit_close_retain(session).code, Error_Code.None)
	session = nil
	reopened, reopen_error := open_edit(path, "edit-orphan-reopen", transaction, .Process)
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	info, stat_error := edit_stat(reopened, "PENDING")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, info.exists && info.is_directory)
	testing.expect_value(t, edit_transaction_id(reopened), transaction)
	testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None)
}

@(test)
edit_process_adapter_test_alias_collision_is_typed_and_replaceable :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-process-collision-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, create_ok := edit_process_test_create(t, root, "collision.img")
	if !create_ok {return}
	source, source_error := filepath.join({root, "source.bin"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {return}
	if !testing.expect_value(t, os.write_entire_file(source, []u8{4, 2}), os.Error(nil)) {return}
	session, open_error := open_edit(path, "edit-collision", 0, .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = edit_close_retain(session)}
	if !testing.expect_value(
		t,
		edit_begin_import_file(session, source, "Folder 000.txt").code,
		Error_Code.None,
	) {return}
	for {
		progress, step_error := edit_job_step(session)
		if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
		if progress.state == .Complete {break}
		if !testing.expect(t, progress.state != .Failed && progress.state != .Cancelled) {return}
	}
	testing.expect_value(
		t,
		edit_begin_import_file(session, source, "Folder 001.txt").code,
		Error_Code.Name_Collision,
	)
	if !testing.expect_value(
		t,
		edit_begin_import_file(session, source, "Folder 001.txt", true).code,
		Error_Code.None,
	) {return}
	for {
		progress, step_error := edit_job_step(session)
		if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
		if progress.state == .Complete {break}
		if !testing.expect(t, progress.state != .Failed && progress.state != .Cancelled) {return}
	}
	old_info, old_error := edit_stat(session, "Folder 000.txt")
	new_info, new_error := edit_stat(session, "Folder 001.txt")
	testing.expect_value(t, old_error.code, Error_Code.None)
	testing.expect(t, !old_info.exists)
	testing.expect_value(t, new_error.code, Error_Code.None)
	testing.expect(t, new_info.exists && new_info.size == 2)
	testing.expect_value(t, edit_finish(session, false).code, Error_Code.None)
	session = nil
}

@(private = "file")
edit_process_test_expect_clean :: proc(t: ^testing.T, path: string) -> bool {
	state_root, root_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, root_ok && !os.exists(state_root)) {return false}
	info, validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return false}
	defer image_info_destroy(&info)
	return testing.expect(t, !info.dirty)
}

@(test)
edit_process_adapter_test_apply_recovers_every_durable_close_phase :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-apply-crash-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	phases := [?]Crash_Phase {
		.Edit_Intent_Durable,
		.Edit_Image_Applied,
		.Edit_Image_Synced,
		.Edit_Apply_Ready,
		.Edit_Clean_Pending,
		.Edit_Evidence_Retired,
		.Edit_Marker_Clean,
		.Edit_Completed,
		.Edit_Cleanup,
	}
	for phase, index in phases {
		path, created := edit_process_test_create(
			t,
			root,
			fmt.tprintf("apply-crash-%d.img", index),
		)
		if !created {return}
		session, open_error := open_edit_process_configured(
			path,
			fmt.tprintf("apply-crash-first-%d", index),
			0,
			crash_phase_name(phase),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_mkdir(session, "RECOVERED").code, Error_Code.None) {
			_ = edit_close_retain(session)
			return
		}
		finish_error := edit_finish(session, true)
		if !testing.expect_value(t, finish_error.code, Error_Code.Transport_Lost) {
			if finish_error.code == .None {session = nil} else {_ = edit_close_retain(session)}
			return
		}
		if !testing.expect_value(t, edit_close_retain(session).code, Error_Code.None) {return}
		reopened, reopen_error := open_edit(
			path,
			fmt.tprintf("apply-crash-second-%d", index),
			0,
			.Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		info, stat_error := edit_stat(reopened, "RECOVERED")
		testing.expect_value(t, stat_error.code, Error_Code.None)
		testing.expect(t, info.exists && info.is_directory)
		if !testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None) {return}
		if !edit_process_test_expect_clean(t, path) {return}
	}
}

@(test)
edit_process_adapter_test_discard_recovers_every_durable_close_phase :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-discard-crash-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	phases := [?]Crash_Phase {
		.Edit_Discarded,
		.Edit_Clean_Pending,
		.Edit_Marker_Clean,
		.Edit_Completed,
		.Edit_Cleanup,
	}
	for phase, index in phases {
		path, created := edit_process_test_create(
			t,
			root,
			fmt.tprintf("discard-crash-%d.img", index),
		)
		if !created {return}
		session, open_error := open_edit_process_configured(
			path,
			fmt.tprintf("discard-crash-first-%d", index),
			0,
			crash_phase_name(phase),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_mkdir(session, "DISCARDED").code, Error_Code.None) {
			_ = edit_close_retain(session)
			return
		}
		finish_error := edit_finish(session, false)
		if !testing.expect_value(t, finish_error.code, Error_Code.Transport_Lost) {
			if finish_error.code == .None {session = nil} else {_ = edit_close_retain(session)}
			return
		}
		if !testing.expect_value(t, edit_close_retain(session).code, Error_Code.None) {return}
		reopened, reopen_error := open_edit(
			path,
			fmt.tprintf("discard-crash-second-%d", index),
			0,
			.Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		info, stat_error := edit_stat(reopened, "DISCARDED")
		testing.expect_value(t, stat_error.code, Error_Code.None)
		testing.expect(t, !info.exists)
		if !testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None) {return}
		if !edit_process_test_expect_clean(t, path) {return}
	}
}

@(test)
edit_process_adapter_test_machine_open_finishes_clean_pending_apply :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-machine-recovery-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := edit_process_test_create(t, root, "machine-recovery.img")
	if !created {return}
	edit_session, open_error := open_edit_process_configured(
		path,
		"machine-recovery-edit",
		0,
		crash_phase_name(.Edit_Clean_Pending),
	)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, edit_mkdir(edit_session, "MACHINE").code, Error_Code.None) {
		_ = edit_close_retain(edit_session)
		return
	}
	finish_error := edit_finish(edit_session, true)
	if !testing.expect_value(t, finish_error.code, Error_Code.Transport_Lost) {
		if finish_error.code ==
		   .None {edit_session = nil} else {_ = edit_close_retain(edit_session)}
		return
	}
	if !testing.expect_value(t, edit_close_retain(edit_session).code, Error_Code.None) {return}
	machine_session, machine_error := open_machine(path, "machine-recovery-machine", .Process)
	if !testing.expect_value(t, machine_error.code, Error_Code.None) {return}
	batch, observe_error := observe(machine_session, []Probe{{kind = .Stat, path = "MACHINE"}})
	defer observation_batch_destroy(&batch)
	testing.expect_value(t, observe_error.code, Error_Code.None)
	testing.expect(t, !batch.pending)
	if testing.expect_value(t, len(batch.items), 1) {
		testing.expect_value(t, batch.items[0].type, Observed_Type.Directory)
	}
	if !testing.expect_value(t, close(machine_session, .Commit).code, Error_Code.None) {return}
	edit_process_test_expect_clean(t, path)
}
