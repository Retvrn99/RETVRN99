// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(private = "file")
recovery_test_write_sector :: proc(path: string, lba: u64, data: []u8) -> bool {
	if len(data) != fat32image.SECTOR_BYTES {return false}
	file, open_error := os.open(path, {.Read, .Write, .Sync})
	if open_error != nil {return false}
	ok :=
		file_write_exact_at(file, data, i64(lba * fat32image.SECTOR_BYTES)) && os.sync(file) == nil
	close_error := os.close(file)
	return ok && close_error == nil
}

@(private = "file")
recovery_test_import_file :: proc(
	t: ^testing.T,
	session: ^Edit_Session,
	host_path, guest_path: string,
) -> bool {
	if !testing.expect_value(
		t,
		edit_begin_import_file(session, host_path, guest_path).code,
		Error_Code.None,
	) {
		return false
	}
	for {
		progress, step_error := edit_job_step(session)
		if !testing.expect_value(t, step_error.code, Error_Code.None) {return false}
		if progress.state == .Complete {return true}
		if !testing.expect(t, progress.state != .Failed && progress.state != .Cancelled) {
			return false
		}
	}
}

@(test)
recovery_hardening_test_clean_machine_prepared_state_is_not_stranded :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-machine-prepared-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "prepared.img")
	if !created {return}
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	image, open_error := fat32image.open_staged(path)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	wal: Wal
	if !testing.expect_value(
		t,
		wal_prepare(&wal, path, image.info.image_id, false).code,
		Error_Code.None,
	) {
		_ = fat32image.close(image, .Retain)
		wal_close(&wal)
		return
	}
	testing.expect_value(t, wal.state.phase, Wal_State_Phase.Prepared)
	if !testing.expect_value(
		t,
		fat32image.close(image, .Retain).code,
		fat32image.Error_Code.None,
	) {
		wal_close(&wal)
		return
	}
	state_root := strings.clone(wal.state_root, context.temp_allocator)
	wal_close(&wal)
	clean, clean_error := fat32image.validate(path)
	if !testing.expect_value(t, clean_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !clean.dirty)
	fat32image.info_destroy(&clean)
	testing.expect(t, os.exists(state_root))
	reopened, reopen_error := open_in_process(path, "prepared-reopen")
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None) {return}
	testing.expect(t, !os.exists(state_root))
}

@(test)
recovery_hardening_test_machine_wal_repairs_torn_primary_fsinfo :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-machine-torn-fsinfo-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "torn-fsinfo.img")
	if !created {return}
	session, open_error := open_in_process(path, "torn-fsinfo-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	device := block_device(session)
	vbr, fsinfo: [fat32image.SECTOR_BYTES]u8
	partition_lba := u64(63)
	if !testing.expect(t, device.read(device.ctx, partition_lba, vbr[:])) {return}
	fsinfo_lba := partition_lba + u64(get_u16le(vbr[:], 48))
	if !testing.expect(t, device.read(device.ctx, fsinfo_lba, fsinfo[:])) {return}
	put_u32le(fsinfo[:], 488, 1234)
	put_u32le(fsinfo[:], 492, 10)
	if !testing.expect(t, device.write(device.ctx, fsinfo_lba, fsinfo[:])) {return}
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	session = nil
	torn := fsinfo
	for &value in torn[:256] {value = 0}
	if !testing.expect(t, recovery_test_write_sector(path, fsinfo_lba, torn[:])) {return}
	_, strict_error := fat32image.validate(path)
	testing.expect_value(t, strict_error.code, fat32image.Error_Code.Invalid_FAT32)
	recovery_info, recovery_validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, recovery_validation_error.code, Error_Code.None) {return}
	testing.expect(t, recovery_info.dirty)
	image_info_destroy(&recovery_info)
	recovered, recovery_error := open_in_process(path, "torn-fsinfo-second")
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None) {return}
	clean, clean_error := fat32image.validate(path)
	if !testing.expect_value(t, clean_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&clean)
	testing.expect(t, !clean.dirty)
}

@(test)
recovery_hardening_test_recovery_fails_closed_when_wal_cannot_repair_backup_vbr :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-unrepaired-backup-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "unrepaired.img")
	if !created {return}
	session, open_error := open_in_process(path, "unrepaired-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	device := block_device(session)
	payload: [fat32image.SECTOR_BYTES]u8
	copy(payload[:], "unrelated acknowledged payload")
	if !testing.expect(t, device.write(device.ctx, device.sector_count - 1, payload[:])) {return}
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	session = nil
	file, file_error := os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	vbr, backup: [fat32image.SECTOR_BYTES]u8
	read_ok := file_read_exact_at(file, vbr[:], i64(63 * fat32image.SECTOR_BYTES))
	backup_lba := u64(63) + u64(get_u16le(vbr[:], 50))
	read_ok =
		read_ok && file_read_exact_at(file, backup[:], i64(backup_lba * fat32image.SECTOR_BYTES))
	_ = os.close(file)
	if !testing.expect(t, read_ok) {return}
	backup[20] = backup[20] ~ 0xA5
	if !testing.expect(t, recovery_test_write_sector(path, backup_lba, backup[:])) {return}
	recovered, recovery_error := open_in_process(path, "unrepaired-second")
	testing.expect(t, recovered == nil)
	testing.expect_value(t, recovery_error.code, Error_Code.FAT_Invalid)
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok && os.exists(state_root)) {return}
	wal_path, wal_path_error := filepath.join({state_root, WAL_FILE}, context.temp_allocator)
	testing.expect(t, wal_path_error == nil && os.exists(wal_path))
	recovery_info, validation_error := fat32image.validate_recovery(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&recovery_info)
	testing.expect(t, recovery_info.dirty)
}

@(test)
recovery_hardening_test_edit_intent_repairs_torn_backup_vbr :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-torn-backup-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "torn-backup.img")
	if !created {return}
	source, source_error := filepath.join({root, "io.sys"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {return}
	if !testing.expect_value(t, os.write_entire_file(source, "boot payload"), os.Error(nil)) {
		return
	}
	session, open_error := open_edit(path, "torn-backup-first", 0xA110, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = edit_close_retain(session)}
	if !recovery_test_import_file(t, session, source, "IO.SYS") {
		_ = edit_close_retain(session)
		return
	}
	io_sys, stat_error := edit_stat(session, "IO.SYS")
	if !testing.expect_value(t, stat_error.code, Error_Code.None) {return}
	_, patch_error := edit_patch_boot_loader(session, io_sys.first_cluster)
	if !testing.expect_value(t, patch_error.code, Error_Code.None) {return}
	_, begin_error := edit_begin_apply(session)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	progress, step_error := edit_step_apply(session)
	if !testing.expect_value(t, step_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, progress.state, Edit_Apply_State.Applying) {return}
	if !testing.expect_value(t, edit_close_retain(session).code, Error_Code.None) {return}
	session = nil
	file, file_error := os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	vbr, backup: [fat32image.SECTOR_BYTES]u8
	read_ok := file_read_exact_at(file, vbr[:], i64(63 * fat32image.SECTOR_BYTES))
	backup_lba := u64(63) + u64(get_u16le(vbr[:], 50))
	read_ok =
		read_ok && file_read_exact_at(file, backup[:], i64(backup_lba * fat32image.SECTOR_BYTES))
	_ = os.close(file)
	if !testing.expect(t, read_ok) {return}
	backup[20] = backup[20] ~ 0x5A
	if !testing.expect(t, recovery_test_write_sector(path, backup_lba, backup[:])) {return}
	_, strict_error := fat32image.validate(path)
	testing.expect_value(t, strict_error.code, fat32image.Error_Code.Invalid_FAT32)
	recovered, recovery_error := open_edit(path, "torn-backup-second", 0xA110, .In_Process)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	defer if recovered != nil {_ = edit_close_retain(recovered)}
	io_sys, stat_error = edit_stat(recovered, "IO.SYS")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, io_sys.exists && io_sys.size == u64(len("boot payload")))
	if !testing.expect_value(t, edit_finish(recovered, false).code, Error_Code.None) {return}
	recovered = nil
	clean, clean_error := fat32image.validate(path)
	if !testing.expect_value(t, clean_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&clean)
	testing.expect(t, !clean.dirty)
}

@(test)
recovery_hardening_test_process_startup_crashes_recover_without_acknowledged_writes :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-startup-crash-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	machine_phases := [2]Crash_Phase{.Machine_State_Prepared, .Machine_Marker_Dirty}
	for phase, index in machine_phases {
		path, created := session_test_image(
			t,
			root,
			index == 0 ? "machine-prepared.img" : "machine-dirty.img",
		)
		if !created {return}
		session, open_error := open_process_configured(
			path,
			"machine-startup-crash",
			crash_phase_name(phase),
		)
		testing.expect(t, session == nil)
		if !testing.expect_value(t, open_error.code, Error_Code.Transport_Lost) {return}
		recovered, recovery_error := open_machine(path, "machine-startup-recover", .In_Process)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None) {return}
		state_root, state_ok := companion_path(path, context.temp_allocator)
		testing.expect(t, state_ok && !os.exists(state_root))
	}
	edit_phases := [2]Crash_Phase{.Edit_Owner_Prepared, .Edit_Marker_Dirty}
	for phase, index in edit_phases {
		path, created := session_test_image(
			t,
			root,
			index == 0 ? "edit-prepared.img" : "edit-dirty.img",
		)
		if !created {return}
		session, open_error := open_edit_process_configured(
			path,
			"edit-startup-crash",
			0,
			crash_phase_name(phase),
		)
		testing.expect(t, session == nil)
		if !testing.expect_value(t, open_error.code, Error_Code.Transport_Lost) {return}
		recovered, recovery_error := open_edit(path, "edit-startup-recover", 0, .In_Process)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_finish(recovered, false).code, Error_Code.None) {return}
		state_root, state_ok := companion_path(path, context.temp_allocator)
		testing.expect(t, state_ok && !os.exists(state_root))
	}
}
