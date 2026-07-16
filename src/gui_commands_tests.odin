// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "fat32image"
import "fat32session"
import "host"
import "profile"
import sdl3 "vendor:sdl3"

@(test)
gui_storage_dispatch_test_requires_stopped_unblocked_machine :: proc(t: ^testing.T) {
	testing.expect(t, gui_storage_dispatch_allowed(false, false, false))
	testing.expect(t, !gui_storage_dispatch_allowed(true, false, false))
	testing.expect(t, !gui_storage_dispatch_allowed(false, true, false))
	testing.expect(t, !gui_storage_dispatch_allowed(false, false, true))
}

@(test)
gui_storage_lifecycle_test_invalid_install_state_is_distinct_but_locked :: proc(
	t: ^testing.T,
) {
	shared: Shared
	machine_running, install_locked := gui_storage_lifecycle_snapshot(&shared)
	testing.expect(t, !machine_running)
	testing.expect(t, !install_locked)

	shared.install_recovery_required = true
	machine_running, install_locked = gui_storage_lifecycle_snapshot(&shared)
	testing.expect(t, !machine_running)
	testing.expect(t, install_locked)
	testing.expect(t, !shared.installing_windows_98)

	shared.install_recovery_required = false
	shared.installing_windows_98 = true
	_, install_locked = gui_storage_lifecycle_snapshot(&shared)
	testing.expect(t, install_locked)
}

@(test)
pending_hard_drive_dialog_test_callback_moves_all_paths :: proc(t: ^testing.T) {
	pending := pending_hard_drive_dialog_create()
	testing.expect(t, !pending_hard_drive_dialog_active(pending))
	pending.purpose = .Import_Files
	pending.dialogs = 1
	testing.expect(t, pending_hard_drive_dialog_active(pending))
	files := [3]cstring {
		cstring("D:\\incoming\\one.txt"),
		cstring("D:\\incoming\\둘.txt"),
		nil,
	}
	pending_hard_drive_dialog_cb(pending, raw_data(files[:]), 0)
	testing.expect(t, pending_hard_drive_dialog_active(pending))
	result, ready := pending_hard_drive_dialog_take(pending)
	testing.expect(t, !pending_hard_drive_dialog_active(pending))
	if testing.expect(t, ready) {
		testing.expect_value(t, result.purpose, host.Hard_Drive_Dialog_Purpose.Import_Files)
		testing.expect(t, result.accepted)
		testing.expect(t, !result.failed)
		testing.expect_value(t, len(result.paths), 2)
		testing.expect_value(t, result.paths[0], "D:\\incoming\\one.txt")
		testing.expect_value(t, result.paths[1], "D:\\incoming\\둘.txt")
	}
	pending_hard_drive_dialog_result_destroy(&result, pending.allocator)
	pending_hard_drive_dialog_release(pending)
}

@(test)
pending_hard_drive_dialog_test_cancel_is_delivered_once :: proc(t: ^testing.T) {
	pending := pending_hard_drive_dialog_create()
	pending.purpose = .Select_Image
	pending.dialogs = 1
	files := [1]cstring{nil}
	pending_hard_drive_dialog_cb(pending, raw_data(files[:]), 0)
	result, ready := pending_hard_drive_dialog_take(pending)
	testing.expect(t, ready)
	testing.expect(t, !result.accepted)
	testing.expect(t, !result.failed)
	testing.expect_value(t, result.diagnostic, "")
	testing.expect_value(t, result.purpose, host.Hard_Drive_Dialog_Purpose.Select_Image)
	_, ready = pending_hard_drive_dialog_take(pending)
	testing.expect(t, !ready)
	pending_hard_drive_dialog_result_destroy(&result, pending.allocator)
	pending_hard_drive_dialog_release(pending)
}

@(test)
pending_hard_drive_dialog_test_filter_contract_matches_sdl :: proc(t: ^testing.T) {
	testing.expect(t, pending_hard_drive_dialog_filter_valid(""))
	testing.expect(t, pending_hard_drive_dialog_filter_valid("*"))
	testing.expect(t, pending_hard_drive_dialog_filter_valid("iso"))
	testing.expect(t, pending_hard_drive_dialog_filter_valid("img;ima"))
	testing.expect(t, pending_hard_drive_dialog_filter_valid("tar.gz"))
	testing.expect(t, !pending_hard_drive_dialog_filter_valid("*.iso"))
	testing.expect(t, !pending_hard_drive_dialog_filter_valid("iso;"))
	testing.expect(t, !pending_hard_drive_dialog_filter_valid(";iso"))
	testing.expect(t, !pending_hard_drive_dialog_filter_valid("iso/img"))
}

@(test)
pending_hard_drive_dialog_test_sdl_error_is_retryable_result :: proc(t: ^testing.T) {
	pending := pending_hard_drive_dialog_create()
	pending.purpose = .Install_ISO
	pending.dialogs = 1
	_ = sdl3.SetError("native picker test failure")
	pending_hard_drive_dialog_cb(pending, nil, 0)
	result, ready := pending_hard_drive_dialog_take(pending)
	testing.expect(t, ready)
	testing.expect(t, !pending_hard_drive_dialog_active(pending))
	testing.expect(t, !result.accepted)
	testing.expect(t, result.failed)
	testing.expect_value(t, result.purpose, host.Hard_Drive_Dialog_Purpose.Install_ISO)
	testing.expect_value(t, result.diagnostic, "native picker test failure")
	pending_hard_drive_dialog_result_destroy(&result, pending.allocator)
	pending_hard_drive_dialog_release(pending)
	_ = sdl3.ClearError()
}

@(test)
pending_hard_drive_dialog_test_invalid_filter_fails_without_sticking_active :: proc(
	t: ^testing.T,
) {
	pending := pending_hard_drive_dialog_create()
	testing.expect(
		t,
		pending_hard_drive_dialog_show(
			pending,
			nil,
			{
				kind           = .Open_File,
				purpose        = .Install_ISO,
				filter_pattern = "*.iso",
			},
		),
	)
	result, ready := pending_hard_drive_dialog_take(pending)
	testing.expect(t, ready)
	testing.expect(t, result.failed)
	testing.expect(t, !result.accepted)
	testing.expect(t, !pending_hard_drive_dialog_active(pending))
	pending_hard_drive_dialog_result_destroy(&result, pending.allocator)
	pending_hard_drive_dialog_release(pending)
}

@(test)
gui_hard_drive_status_test_is_in_process_and_recovery_aware :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	path, path_error := filepath.join({root, "status.img"}, context.temp_allocator)
	moved, moved_error := filepath.join({root, "moved.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil && moved_error == nil) {return}
	testing.expect_value(t, GUI_STATUS_ADAPTER, fat32session.Adapter_Kind.In_Process)
	info, create_error := fat32session.create_image(
		{path = path, capacity_gib = 1},
		.In_Process,
	)
	if !testing.expect_value(t, create_error.code, fat32session.Error_Code.None) {return}
	fat32session.image_info_destroy(&info)
	status, diagnostic := gui_hard_drive_status(path)
	defer delete(diagnostic)
	if !testing.expect_value(t, status, host.Hard_Drive_Status.Ready) {return}
	session, open_error := fat32session.open_machine(path, "gui-status", .In_Process)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	device := fat32session.block_device(session)
	payload: [fat32image.SECTOR_BYTES]u8
	copy(payload[:], "dirty image with matching recovery state")
	if !testing.expect(t, device.write(device.ctx, device.sector_count - 1, payload[:])) {
		_ = fat32session.close(session, .Retain)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.close(session, .Retain).code,
		fat32session.Error_Code.None,
	) {return}
	recovery_diagnostic: string
	status, recovery_diagnostic = gui_hard_drive_status(path)
	defer delete(recovery_diagnostic)
	if !testing.expect_value(t, status, host.Hard_Drive_Status.Ready) {return}
	if !testing.expect_value(t, os.rename(path, moved), os.Error(nil)) {return}
	mismatch_diagnostic: string
	status, mismatch_diagnostic = gui_hard_drive_status(moved)
	defer delete(mismatch_diagnostic)
	testing.expect_value(t, status, host.Hard_Drive_Status.Invalid)
	testing.expect(t, mismatch_diagnostic != "")
	if !testing.expect_value(t, os.rename(moved, path), os.Error(nil)) {return}
	recovered, recovery_error := fat32session.open_machine(path, "gui-status-clean", .In_Process)
	if !testing.expect_value(t, recovery_error.code, fat32session.Error_Code.None) {return}
	testing.expect_value(
		t,
		fat32session.close(recovered, .Commit).code,
		fat32session.Error_Code.None,
	)
}

@(test)
gui_hard_drive_select_test_save_failure_preserves_previous_selection_and_new_image :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	new_path, new_path_error := filepath.join({root, "new.img"}, context.temp_allocator)
	old_path, old_path_error := filepath.join({root, "old.img"}, context.temp_allocator)
	blocked_parent, blocked_error := filepath.join({root, "not-a-directory"}, context.temp_allocator)
	settings_path, settings_error := filepath.join(
		{blocked_parent, "settings.json"},
		context.temp_allocator,
	)
	if !testing.expect(
		t,
		new_path_error == nil && old_path_error == nil && blocked_error == nil &&
		settings_error == nil,
	) {
		return
	}
	info, create_error := fat32session.create_image(
		{path = new_path, capacity_gib = 1},
		.In_Process,
	)
	if !testing.expect_value(t, create_error.code, fat32session.Error_Code.None) {return}
	fat32session.image_info_destroy(&info)
	testing.expect_value(t, os.write_entire_file(blocked_parent, "blocked"), os.Error(nil))
	settings := profile.Settings {
		hard_drive_path = strings.clone(old_path),
	}
	defer profile.settings_destroy(&settings)
	ctx := Vm_Ctx {
		paths = profile.Paths{settings = settings_path},
		hard_drive_path = strings.clone(old_path),
	}
	defer delete(ctx.hard_drive_path)
	menu: host.Menu_State

	testing.expect(
		t,
		!gui_hard_drive_select(
			&ctx,
			&settings,
			&menu,
			new_path,
			false,
			false,
			.In_Process,
		),
	)
	testing.expect_value(t, settings.hard_drive_path, old_path)
	testing.expect_value(t, ctx.hard_drive_path, old_path)
	testing.expect(t, os.exists(new_path))
	validated, validation_error := fat32session.validate_image(new_path, .In_Process)
	defer fat32session.image_info_destroy(&validated)
	testing.expect_value(t, validation_error.code, fat32session.Error_Code.None)
}
