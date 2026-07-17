// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

Edit_Adoption_Test_Snapshot :: struct {
	primary_lba: u64,
	backup_lba:  u64,
	marker_lba:  u64,
	image_id:    fat32image.Image_Id,
	primary:     [fat32image.SECTOR_BYTES]u8,
	backup:      [fat32image.SECTOR_BYTES]u8,
	marker:      [fat32image.SECTOR_BYTES]u8,
}

@(private = "file")
edit_adoption_test_sector_read :: proc(file: ^os.File, lba: u64, data: []u8) -> bool {
	return len(data) == fat32image.SECTOR_BYTES &&
		file_read_exact_at(file, data, i64(lba * fat32image.SECTOR_BYTES))
}

@(private = "file")
edit_adoption_test_sector_write :: proc(file: ^os.File, lba: u64, data: []u8) -> bool {
	return len(data) == fat32image.SECTOR_BYTES &&
		file_write_exact_at(file, data, i64(lba * fat32image.SECTOR_BYTES))
}

@(private = "file")
edit_adoption_test_externalize :: proc(
	t: ^testing.T,
	path: string,
	unenroll: bool,
) -> (
	Edit_Adoption_Test_Snapshot,
	bool,
) {
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return {}, false}
	defer fat32image.info_destroy(&info)
	snapshot := Edit_Adoption_Test_Snapshot {
		primary_lba = u64(info.partition_lba),
		marker_lba  = u64(info.marker_sector),
		image_id    = info.image_id,
	}
	file, open_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return {}, false}
	if !edit_adoption_test_sector_read(file, snapshot.primary_lba, snapshot.primary[:]) {
		_ = os.close(file)
		return {}, false
	}
	snapshot.backup_lba = snapshot.primary_lba + u64(get_u16le(snapshot.primary[:], 50))
	if !edit_adoption_test_sector_read(file, snapshot.backup_lba, snapshot.backup[:]) ||
	   !edit_adoption_test_sector_read(file, snapshot.marker_lba, snapshot.marker[:]) {
		_ = os.close(file)
		return {}, false
	}
	copy(snapshot.primary[3:11], "MSDOS5.0")
	copy(snapshot.primary[71:82], "NO NAME    ")
	for &octet in snapshot.primary[90:510] {octet = 0}
	snapshot.primary[90] = 0xfa
	snapshot.primary[91] = 0xf4
	copy(snapshot.backup[:], snapshot.primary[:])
	if unenroll {
		for &octet in snapshot.marker {octet = 0}
		snapshot.image_id = {}
	} else {
		flags := get_u32le(snapshot.marker[:], 12) & ~u32(2)
		put_u32le(snapshot.marker[:], 12, flags)
		put_u32le(snapshot.marker[:], 56, 0)
		put_u32le(snapshot.marker[:], 56, hash.crc32(snapshot.marker[:]))
	}
	ok :=
		edit_adoption_test_sector_write(file, snapshot.primary_lba, snapshot.primary[:]) &&
		edit_adoption_test_sector_write(file, snapshot.backup_lba, snapshot.backup[:]) &&
		edit_adoption_test_sector_write(file, snapshot.marker_lba, snapshot.marker[:]) &&
		os.sync(file) == nil
	close_error := os.close(file)
	if !testing.expect(t, ok) || !testing.expect_value(t, close_error, os.Error(nil)) {
		return {}, false
	}
	standard, standard_error := fat32image.validate(path)
	if !testing.expect_value(t, standard_error.code, fat32image.Error_Code.None) {return {}, false}
	if unenroll {
		testing.expect(t, !standard.enrolled)
	} else {
		testing.expect(t, standard.enrolled && standard.image_id == info.image_id)
	}
	testing.expect(t, !standard.retvrn99_format && !standard.dirty)
	fat32image.info_destroy(&standard)
	return snapshot, true
}

@(private = "file")
edit_adoption_test_create :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return path, false}
	fat32image.info_destroy(&info)
	return path, true
}

@(test)
edit_adoption_test_unmarked_discard_restores_vbr_and_marker_byte_identically :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-discard-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, create_ok := edit_adoption_test_create(t, root, "standard.img")
	if !create_ok {return}
	before, external_ok := edit_adoption_test_externalize(t, path, true)
	if !external_ok {return}
	session, open_error := open_edit(path, "adoption-discard", 0, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	adoption, adoption_error := edit_adopt_image(session)
	if !testing.expect_value(t, adoption_error.code, Error_Code.None) {return}
	testing.expect(t, adoption.staged)
	testing.expect_value(t, edit_changed_sector_count(session), u64(2))
	if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
	file, file_error := os.open(path, {.Read})
	if !testing.expect_value(t, file_error, os.Error(nil)) {return}
	after: Edit_Adoption_Test_Snapshot
	read_ok :=
		edit_adoption_test_sector_read(file, before.primary_lba, after.primary[:]) &&
		edit_adoption_test_sector_read(file, before.backup_lba, after.backup[:]) &&
		edit_adoption_test_sector_read(file, before.marker_lba, after.marker[:])
	close_error := os.close(file)
	if !testing.expect(t, read_ok) || !testing.expect_value(t, close_error, os.Error(nil)) {return}
	testing.expect_value(t, after.primary, before.primary)
	testing.expect_value(t, after.backup, before.backup)
	testing.expect_value(t, after.marker, before.marker)
	validated, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !validated.enrolled && !validated.retvrn99_format && !validated.dirty)
	fat32image.info_destroy(&validated)
}

@(test)
edit_adoption_test_enrolled_discard_and_apply_cancel_restore_every_protected_byte :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-cancel-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	variants := [?]bool{false, true}
	for cancel_apply, index in variants {
		path, create_ok := edit_adoption_test_create(
			t,
			root,
			fmt.tprintf("enrolled-%d.img", index),
		)
		if !create_ok {return}
		before, external_ok := edit_adoption_test_externalize(t, path, false)
		if !external_ok {return}
		session, open_error := open_edit(path, "adoption-cancel", 0, .In_Process)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		_, adoption_error := edit_adopt_image(session)
		if !testing.expect_value(t, adoption_error.code, Error_Code.None) {return}
		if cancel_apply {
			progress, begin_error := edit_begin_apply(session)
			if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
			testing.expect(t, progress.cancellable)
			if !testing.expect_value(t, edit_cancel_apply(session).code, Error_Code.None) {return}
		}
		if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
		file, file_error := os.open(path, {.Read})
		if !testing.expect_value(t, file_error, os.Error(nil)) {return}
		after: Edit_Adoption_Test_Snapshot
		read_ok :=
			edit_adoption_test_sector_read(file, before.primary_lba, after.primary[:]) &&
			edit_adoption_test_sector_read(file, before.backup_lba, after.backup[:]) &&
			edit_adoption_test_sector_read(file, before.marker_lba, after.marker[:])
		_ = os.close(file)
		if !testing.expect(t, read_ok) {return}
		testing.expect_value(t, after.primary, before.primary)
		testing.expect_value(t, after.backup, before.backup)
		testing.expect_value(t, after.marker, before.marker)
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, validated.enrolled && !validated.retvrn99_format && !validated.dirty)
		testing.expect_value(t, validated.image_id, before.image_id)
		fat32image.info_destroy(&validated)
	}
}

@(test)
edit_adoption_test_apply_preserves_external_bpb_and_enrolls_only_on_success :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-apply-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	variants := [?]bool{true, false}
	for unenroll in variants {
		name := unenroll ? "unmarked.img" : "enrolled.img"
		path, create_ok := edit_adoption_test_create(t, root, name)
		if !create_ok {return}
		before, external_ok := edit_adoption_test_externalize(t, path, unenroll)
		if !external_ok {return}
		session, open_error := open_edit(path, name, 0, .In_Process)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		adoption, adoption_error := edit_adopt_image(session)
		if !testing.expect_value(t, adoption_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_finish(session, true).code, Error_Code.None) {return}
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, validated.enrolled && validated.retvrn99_format && !validated.dirty)
		testing.expect_value(t, validated.image_id, adoption.image_identity)
		if !unenroll {testing.expect_value(t, validated.image_id, before.image_id)}
		file, file_error := os.open(path, {.Read})
		if !testing.expect_value(t, file_error, os.Error(nil)) {return}
		primary, backup: [fat32image.SECTOR_BYTES]u8
		read_ok :=
			edit_adoption_test_sector_read(file, before.primary_lba, primary[:]) &&
			edit_adoption_test_sector_read(file, before.backup_lba, backup[:])
		close_error := os.close(file)
		if !testing.expect(t, read_ok) || !testing.expect_value(t, close_error, os.Error(nil)) {return}
		testing.expect(t, slice.equal(primary[11:67], before.primary[11:67]))
		testing.expect_value(t, backup, primary)
		fat32image.info_destroy(&validated)
	}
}

@(test)
edit_adoption_test_process_matches_in_process :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-process-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_ok := edit_adoption_test_create(t, root, "in-process.img")
	right_path, right_ok := edit_adoption_test_create(t, root, "process.img")
	if !left_ok || !right_ok {return}
	left_before, left_external := edit_adoption_test_externalize(t, left_path, true)
	right_before, right_external := edit_adoption_test_externalize(t, right_path, true)
	if !left_external || !right_external {return}
	left, left_error := open_edit(left_path, "adoption-in-process", 0, .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	right, right_error := open_edit(right_path, "adoption-process", 0, .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {
		_ = edit_finish(left, false)
		return
	}
	left_adoption, left_adoption_error := edit_adopt_image(left)
	right_adoption, right_adoption_error := edit_adopt_image(right)
	if !testing.expect_value(t, right_adoption_error.code, left_adoption_error.code) ||
	   !testing.expect_value(t, left_adoption_error.code, Error_Code.None) {
		return
	}
	testing.expect_value(t, right_adoption.staged, left_adoption.staged)
	testing.expect_value(t, edit_changed_sector_count(right), edit_changed_sector_count(left))
	if !testing.expect_value(t, edit_finish(left, true).code, Error_Code.None) ||
	   !testing.expect_value(t, edit_finish(right, true).code, Error_Code.None) {
		return
	}
	left_info, left_validation := fat32image.validate(left_path)
	right_info, right_validation := fat32image.validate(right_path)
	if !testing.expect_value(t, left_validation.code, fat32image.Error_Code.None) ||
	   !testing.expect_value(t, right_validation.code, fat32image.Error_Code.None) {
		return
	}
	defer fat32image.info_destroy(&left_info)
	defer fat32image.info_destroy(&right_info)
	testing.expect(t, left_info.retvrn99_format && right_info.retvrn99_format)
	left_file, left_file_error := os.open(left_path, {.Read})
	right_file, right_file_error := os.open(right_path, {.Read})
	if !testing.expect_value(t, left_file_error, os.Error(nil)) ||
	   !testing.expect_value(t, right_file_error, os.Error(nil)) {
		return
	}
	left_vbr, right_vbr: [fat32image.SECTOR_BYTES]u8
	read_ok :=
		edit_adoption_test_sector_read(left_file, left_before.primary_lba, left_vbr[:]) &&
		edit_adoption_test_sector_read(right_file, right_before.primary_lba, right_vbr[:])
	_ = os.close(left_file)
	_ = os.close(right_file)
	if !testing.expect(t, read_ok) {return}
	testing.expect(t, slice.equal(left_vbr[:67], right_vbr[:67]))
	testing.expect(t, slice.equal(left_vbr[71:], right_vbr[71:]))
}

@(test)
edit_adoption_test_every_pre_apply_crash_phase_recovers :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-crash-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	phases := [?]Crash_Phase{
		.Edit_Adoption_Evidence,
		.Edit_Adoption_Owner,
		.Edit_Adoption_Staged,
	}
	for phase, index in phases {
		path, create_ok := edit_adoption_test_create(
			t,
			root,
			fmt.tprintf("crash-%d-%s.img", index, crash_phase_name(phase)),
		)
		if !create_ok {return}
		_, external_ok := edit_adoption_test_externalize(t, path, true)
		if !external_ok {return}
		crashing, open_error := open_edit_process_configured(
			path,
			"adoption-crash",
			0,
			crash_phase_name(phase),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		_, adoption_error := edit_adopt_image(crashing)
		testing.expect(t, adoption_error.code != .None)
		_ = edit_close_retain(crashing)
		recovered, recovery_error := open_edit(
			path,
			fmt.tprintf("adoption-recovery-%d", index),
			0,
			.In_Process,
		)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
		adoption, retry_error := edit_adopt_image(recovered)
		if !testing.expect_value(t, retry_error.code, Error_Code.None) {return}
		testing.expect(t, adoption.staged)
		if !testing.expect_value(t, edit_finish(recovered, true).code, Error_Code.None) {return}
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, validated.enrolled && validated.retvrn99_format && !validated.dirty)
		fat32image.info_destroy(&validated)
	}
}

@(test)
edit_adoption_test_apply_crash_phases_complete_one_valid_layout :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-adoption-apply-crash-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	phases := [?]Crash_Phase{
		.Edit_Intent_Durable,
		.Edit_Image_Synced,
		.Edit_Clean_Pending,
		.Edit_Marker_Clean,
	}
	for phase, index in phases {
		path, create_ok := edit_adoption_test_create(
			t,
			root,
			fmt.tprintf("apply-crash-%d.img", index),
		)
		if !create_ok {return}
		before, external_ok := edit_adoption_test_externalize(t, path, true)
		if !external_ok {return}
		crashing, open_error := open_edit_process_configured(
			path,
			"adoption-apply-crash",
			0,
			crash_phase_name(phase),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		_, adoption_error := edit_adopt_image(crashing)
		if !testing.expect_value(t, adoption_error.code, Error_Code.None) {return}
		apply_error := edit_finish(crashing, true)
		testing.expect(t, apply_error.code != .None)
		_ = edit_close_retain(crashing)
		recovered, recovery_error := open_edit(
			path,
			fmt.tprintf("adoption-apply-recovery-%d", index),
			0,
			.In_Process,
		)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
		_, retry_error := edit_adopt_image(recovered)
		if !testing.expect_value(t, retry_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_finish(recovered, true).code, Error_Code.None) {return}
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, validated.enrolled && validated.retvrn99_format && !validated.dirty)
		file, file_error := os.open(path, {.Read})
		if !testing.expect_value(t, file_error, os.Error(nil)) {return}
		primary, backup: [fat32image.SECTOR_BYTES]u8
		read_ok :=
			edit_adoption_test_sector_read(file, before.primary_lba, primary[:]) &&
			edit_adoption_test_sector_read(file, before.backup_lba, backup[:])
		_ = os.close(file)
		testing.expect(t, read_ok && primary == backup)
		testing.expect(t, slice.equal(primary[11:67], before.primary[11:67]))
		fat32image.info_destroy(&validated)
	}
}

@(test)
edit_adoption_test_preintent_owner_crash_discards_unenrolled_apply_and_adoption :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-preintent-discard-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	variants := [2]bool{false, true}
	for adopt, index in variants {
		path, create_ok := edit_adoption_test_create(
			t,
			root,
			fmt.tprintf("preintent-%d.img", index),
		)
		if !create_ok {return}
		before, external_ok := edit_adoption_test_externalize(t, path, true)
		if !external_ok {return}
		crashing, open_error := open_edit_process_configured(
			path,
			fmt.tprintf("preintent-first-%d", index),
			0,
			crash_phase_name(.Edit_Owner_Applying),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if adopt {
			adoption, adoption_error := edit_adopt_image(crashing)
			if !testing.expect_value(t, adoption_error.code, Error_Code.None) ||
			   !testing.expect(t, adoption.staged) {
				_ = edit_close_retain(crashing)
				return
			}
		} else if !testing.expect_value(
			t,
			edit_mkdir(crashing, "PENDING").code,
			Error_Code.None,
		) {
			_ = edit_close_retain(crashing)
			return
		}
		finish_error := edit_finish(crashing, true)
		if !testing.expect_value(t, finish_error.code, Error_Code.Transport_Lost) {
			if finish_error.code != .None {_ = edit_close_retain(crashing)}
			return
		}
		if !testing.expect_value(t, edit_close_retain(crashing).code, Error_Code.None) {return}
		reopened, reopen_error := open_edit(
			path,
			fmt.tprintf("preintent-second-%d", index),
			0,
			.Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None) {return}
		file, file_error := os.open(path, {.Read})
		if !testing.expect_value(t, file_error, os.Error(nil)) {return}
		after: Edit_Adoption_Test_Snapshot
		read_ok :=
			edit_adoption_test_sector_read(file, before.primary_lba, after.primary[:]) &&
			edit_adoption_test_sector_read(file, before.backup_lba, after.backup[:]) &&
			edit_adoption_test_sector_read(file, before.marker_lba, after.marker[:])
		close_error := os.close(file)
		if !testing.expect(t, read_ok) ||
		   !testing.expect_value(t, close_error, os.Error(nil)) {
			return
		}
		testing.expect_value(t, after.primary, before.primary)
		testing.expect_value(t, after.backup, before.backup)
		testing.expect_value(t, after.marker, before.marker)
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, !validated.enrolled && !validated.retvrn99_format && !validated.dirty)
		fat32image.info_destroy(&validated)
		state_root, state_ok := companion_path(path, context.temp_allocator)
		if !testing.expect(t, state_ok && !os.exists(state_root)) {return}
	}
}
