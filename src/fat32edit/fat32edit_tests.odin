// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32fs "../fat32fs"
import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_test_open :: proc(
	t: ^testing.T,
) -> (
	directory, state, path: string,
	image: ^fat32image.Image,
	ok: bool,
) {
	directory_value, directory_error := os.make_directory_temp(
		"",
		"retvrn99-fat32edit-*",
		context.temp_allocator,
	)
	directory = directory_value
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	path_value, path_error := filepath.join({directory, "drive.img"}, context.temp_allocator)
	path = path_value
	if !testing.expect(t, path_error == nil) {return}
	state, path_error = filepath.join(
		{directory, ".drive.img.retvrn99-fat32"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	created, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	fat32image.info_destroy(&created)
	image_value, open_error := fat32image.open(path, .Read_Write)
	image = image_value
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	ok = true
	return
}

@(private = "file")
edit_test_session :: proc(
	t: ^testing.T,
	image: ^fat32image.Image,
	state: string,
) -> (
	Edit_Session,
	bool,
) {
	base := fat32image.block_device(image)
	owner := fat32image.edit_block_device(image)
	session, edit_error := open(
		base,
		state,
		0,
		{ctx = owner.ctx, write = owner.write, flush = owner.flush},
	)
	return session, testing.expect_value(t, edit_error.code, Error_Code.None)
}

@(private = "file")
edit_test_sector :: proc(
	t: ^testing.T,
	image: ^fat32image.Image,
	lba: u64,
) -> (
	result: [SECTOR_BYTES]u8,
) {
	testing.expect_value(
		t,
		fat32image.block_read(image, lba, result[:]).code,
		fat32image.Error_Code.None,
	)
	return
}

@(test)
fat32edit_test_discard_never_changes_base_sectors :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	base_volume, volume_error := fat32fs.open(fat32image.block_device(image))
	if !testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {return}
	fat_lba := base_volume.info.fat_lba
	root_lba :=
		base_volume.info.data_lba +
		u64(base_volume.info.root_cluster - 2) * u64(base_volume.info.sectors_per_cluster)
	before_fat := edit_test_sector(t, image, fat_lba)
	before_root := edit_test_sector(t, image, root_lba)
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	if !testing.expect_value(t, mkdir(&session, "Games").code, Error_Code.None) {return}
	testing.expect(t, has_changes(&session))
	during_fat := edit_test_sector(t, image, fat_lba)
	during_root := edit_test_sector(t, image, root_lba)
	testing.expect_value(t, during_fat, before_fat)
	testing.expect_value(t, during_root, before_root)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	after_fat := edit_test_sector(t, image, fat_lba)
	after_root := edit_test_sector(t, image, root_lba)
	testing.expect_value(t, after_fat, before_fat)
	testing.expect_value(t, after_root, before_root)
	edit_directory, edit_path_error := filepath.join({state, "edit"}, context.temp_allocator)
	testing.expect(t, edit_path_error == nil && !os.exists(edit_directory))
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_korean_lfn_import_apply_and_readback :: proc(t: ^testing.T) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "source.bin"}, context.temp_allocator)
	content := []u8{0x52, 0x45, 0x54, 0x56, 0x52, 0x4E, 0x39, 0x39}
	if !testing.expect_value(t, os.write_entire_file(source, content), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	if !testing.expect_value(t, mkdir(&session, "테스트").code, Error_Code.None) {return}
	job, begin_error := begin_import_file(&session, source, "테스트/안녕하세요.txt")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	defer job_destroy(&job)
	for progress := job_step(&job);
	    progress.state == .Pending || progress.state == .Running;
	    progress = job_step(&job) {}
	testing.expect_value(t, job.state, Job_State.Complete)
	page, list_error := list(&session, "테스트", 0, 16)
	if !testing.expect_value(t, list_error.code, Error_Code.None) {return}
	defer fat32fs.page_destroy(&page)
	if testing.expect_value(t, len(page.entries), 1) {
		testing.expect_value(t, page.entries[0].name, "안녕하세요.txt")
	}
	testing.expect_value(t, apply(&session).code, Error_Code.None)
	if !testing.expect_value(
		t,
		fat32image.close(image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	read_image, open_error := fat32image.open(path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	volume, fat_error := fat32fs.open(fat32image.block_device(read_image))
	if testing.expect_value(t, fat_error.code, fat32fs.Error_Code.None) {
		readback, read_error := fat32fs.read_range(&volume, "테스트/안녕하세요.txt", 0, 32)
		if testing.expect_value(t, read_error.code, fat32fs.Error_Code.None) {
			testing.expect_value(t, string(readback.data), string(content))
			fat32fs.read_result_destroy(&readback)
		}
	}
	testing.expect_value(t, fat32image.close(read_image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_case_and_short_alias_collisions_are_rejected :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	testing.expect_value(t, mkdir(&session, "Games").code, Error_Code.None)
	testing.expect_value(t, mkdir(&session, "games").code, Error_Code.Name_Collision)
	testing.expect_value(t, mkdir(&session, "Long Folder").code, Error_Code.None)
	testing.expect_value(t, mkdir(&session, "LONG_F~1").code, Error_Code.Name_Collision)
	testing.expect_value(t, mkdir(&session, "../escape").code, Error_Code.Invalid_Path)
	testing.expect_value(t, mkdir(&session, "BAD?.TXT").code, Error_Code.Invalid_Path)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_replace_resolves_generated_short_alias_collision :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "source.bin"}, context.temp_allocator)
	if !testing.expect_value(
		t,
		os.write_entire_file(source, []u8{1, 2, 3}),
		os.Error(nil),
	) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	first, first_error := begin_import_file(&session, source, "Folder 000.txt")
	if !testing.expect_value(t, first_error.code, Error_Code.None) {return}
	for first.state != .Complete && first.state != .Failed {_ = job_step(&first)}
	if !testing.expect_value(t, first.state, Job_State.Complete) {return}
	job_destroy(&first)
	_, collision_error := begin_import_file(&session, source, "Folder 001.txt")
	testing.expect_value(t, collision_error.code, Error_Code.Name_Collision)
	replacement, replace_error := begin_import_file(&session, source, "Folder 001.txt", true)
	if !testing.expect_value(t, replace_error.code, Error_Code.None) {return}
	for replacement.state != .Complete && replacement.state != .Failed {
		_ = job_step(&replacement)
	}
	if !testing.expect_value(t, replacement.state, Job_State.Complete) {return}
	job_destroy(&replacement)
	old_info, old_error := stat(&session, "Folder 000.txt")
	new_info, new_error := stat(&session, "Folder 001.txt")
	testing.expect_value(t, old_error.code, Error_Code.None)
	testing.expect(t, !old_info.exists)
	testing.expect_value(t, new_error.code, Error_Code.None)
	testing.expect(t, new_info.exists && !new_info.is_directory)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(private = "file")
edit_test_read_file :: proc(
	t: ^testing.T,
	session: ^Edit_Session,
	path: string,
	expected: string,
) -> bool {
	result, read_error := read_range(session, path, 0, u64(len(expected)))
	if !testing.expect_value(t, read_error.code, Error_Code.None) {return false}
	defer fat32fs.read_result_destroy(&result)
	return testing.expect_value(t, string(result.data), string(expected))
}

@(private = "file")
edit_test_import_complete :: proc(
	t: ^testing.T,
	session: ^Edit_Session,
	host_source, guest_destination: string,
	replace := false,
) -> bool {
	job, begin_error := begin_import_file(session, host_source, guest_destination, replace)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return false}
	for job.state != .Complete && job.state != .Failed {_ = job_step(&job)}
	ok := testing.expect_value(t, job.state, Job_State.Complete)
	job_destroy(&job)
	return ok
}

@(private = "file")
edit_test_read_image_file :: proc(
	t: ^testing.T,
	image_path, guest_path: string,
	expected: string,
) -> bool {
	image, open_error := fat32image.open(image_path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return false}
	defer fat32image.close(image, .Clean)
	volume, volume_error := fat32fs.open(fat32image.block_device(image))
	if !testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {return false}
	result, read_error := fat32fs.read_range(&volume, guest_path, 0, u64(len(expected)))
	if !testing.expect_value(t, read_error.code, fat32fs.Error_Code.None) {return false}
	defer fat32fs.read_result_destroy(&result)
	return testing.expect_value(t, string(result.data), string(expected))
}

@(test)
fat32edit_test_replace_source_disappearance_preserves_original_through_apply :: proc(
	t: ^testing.T,
) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "replace.bin"}, context.temp_allocator)
	original := "original-data"
	if !testing.expect_value(t, os.write_entire_file(source, original), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	if !edit_test_import_complete(t, &session, source, "KEEP.BIN") {return}
	if !testing.expect_value(t, os.remove(source), os.Error(nil)) {return}
	_, begin_error := begin_import_file(&session, source, "KEEP.BIN", true)
	testing.expect_value(t, begin_error.code, Error_Code.Host_Path_Unsafe)
	if !edit_test_read_file(t, &session, "KEEP.BIN", original) {return}
	if !testing.expect_value(t, apply(&session).code, Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32image.close(image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	edit_test_read_image_file(t, path, "KEEP.BIN", original)
}

@(test)
fat32edit_test_replace_mid_read_failure_preserves_original_through_apply :: proc(t: ^testing.T) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "replace.bin"}, context.temp_allocator)
	original := "original-data"
	if !testing.expect_value(t, os.write_entire_file(source, original), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	if !edit_test_import_complete(t, &session, source, "KEEP.BIN") {return}
	replacement := make([]u8, MAX_TRANSFER_BYTES * 2 + 17, context.temp_allocator)
	for &value, index in replacement {value = u8(index * 31)}
	if !testing.expect_value(t, os.write_entire_file(source, replacement), os.Error(nil)) {return}
	job, begin_error := begin_import_file(&session, source, "KEEP.BIN", true)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	first := job_step(&job)
	if !testing.expect_value(t, first.state, Job_State.Running) {return}
	held_source, _ := filepath.join({directory, "held-replace.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.rename(source, held_source), os.Error(nil)) {return}
	if !testing.expect_value(t, os.write_entire_file(source, []u8{}), os.Error(nil)) {return}
	failed := job_step(&job)
	testing.expect_value(t, failed.state, Job_State.Failed)
	testing.expect_value(t, job_error(&job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	if !edit_test_read_file(t, &session, "KEEP.BIN", original) {return}
	if !testing.expect_value(t, apply(&session).code, Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32image.close(image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	edit_test_read_image_file(t, path, "KEEP.BIN", original)
}

@(test)
fat32edit_test_verified_open_rejects_snapshot_to_open_replacement :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp(
		"",
		"retvrn99-host-identity-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "source.bin"}, context.temp_allocator)
	held, _ := filepath.join({directory, "held.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(source, "first"), os.Error(nil)) {return}
	expected, snapshot_ok := platform_host_snapshot(source, .Regular)
	if !testing.expect(t, snapshot_ok) {return}
	if !testing.expect_value(t, os.rename(source, held), os.Error(nil)) {return}
	if !testing.expect_value(t, os.write_entire_file(source, "second"), os.Error(nil)) {return}
	file, open_ok := platform_host_open(source, .Regular, expected)
	testing.expect(t, !open_ok && file == nil)
}

@(test)
fat32edit_test_tree_directory_change_after_open_is_rejected :: proc(t: ^testing.T) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	host_tree, _ := filepath.join({directory, "host-tree"}, context.temp_allocator)
	late_file, _ := filepath.join({host_tree, "late.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(host_tree), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	job, begin_error := begin_import_tree(&session, host_tree, "TREE")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, os.write_entire_file(late_file, "late"), os.Error(nil)) {return}
	failed := job_step(&job)
	testing.expect_value(t, failed.state, Job_State.Failed)
	testing.expect_value(t, job_error(&job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	guest_info, stat_error := stat(&session, "TREE")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, !guest_info.exists)
	if !testing.expect_value(t, apply(&session).code, Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32image.close(image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	read_image, open_error := fat32image.open(path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	volume, volume_error := fat32fs.open(fat32image.block_device(read_image))
	if testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {
		persisted, persisted_error := fat32fs.stat(&volume, "TREE")
		testing.expect_value(t, persisted_error.code, fat32fs.Error_Code.None)
		testing.expect(t, !persisted.exists)
	}
	testing.expect_value(t, fat32image.close(read_image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_replace_post_open_size_change_preserves_original_through_apply :: proc(
	t: ^testing.T,
) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "replace.bin"}, context.temp_allocator)
	original := "original-data"
	if !testing.expect_value(t, os.write_entire_file(source, original), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	if !edit_test_import_complete(t, &session, source, "KEEP.BIN") {return}
	replacement := make([]u8, MAX_TRANSFER_BYTES + 17, context.temp_allocator)
	for &value, index in replacement {value = u8(index * 17)}
	if !testing.expect_value(t, os.write_entire_file(source, replacement), os.Error(nil)) {return}
	job, begin_error := begin_import_file(&session, source, "KEEP.BIN", true)
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	mutator, mutator_error := os.open(source, {.Write})
	if !testing.expect_value(t, mutator_error, os.Error(nil)) {return}
	truncate_error := os.truncate(mutator, i64(len(replacement) - 1))
	_ = os.close(mutator)
	if !testing.expect_value(t, truncate_error, os.Error(nil)) {return}
	failed := job_step(&job)
	testing.expect_value(t, failed.state, Job_State.Failed)
	testing.expect_value(t, job_error(&job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	if !edit_test_read_file(t, &session, "KEEP.BIN", original) {return}
	if !testing.expect_value(t, apply(&session).code, Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32image.close(image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	edit_test_read_image_file(t, path, "KEEP.BIN", original)
}

@(test)
fat32edit_test_linux_import_and_tree_reparse_or_special_sources_are_rejected :: proc(
	t: ^testing.T,
) {
	when ODIN_OS != .Linux {return}
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	target_file, _ := filepath.join({directory, "target.bin"}, context.temp_allocator)
	file_link, _ := filepath.join({directory, "file-link.bin"}, context.temp_allocator)
	target_tree, _ := filepath.join({directory, "target-tree"}, context.temp_allocator)
	tree_link, _ := filepath.join({directory, "tree-link"}, context.temp_allocator)
	host_tree, _ := filepath.join({directory, "host-tree"}, context.temp_allocator)
	child_link, _ := filepath.join({host_tree, "child-link.bin"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(target_file, "target"), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory_all(target_tree), os.Error(nil)) ||
	   !testing.expect_value(t, os.make_directory_all(host_tree), os.Error(nil)) ||
	   !testing.expect_value(t, os.symlink(target_file, file_link), os.Error(nil)) ||
	   !testing.expect_value(t, os.symlink(target_tree, tree_link), os.Error(nil)) ||
	   !testing.expect_value(t, os.symlink(target_file, child_link), os.Error(nil)) {
		return
	}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	_, file_error := begin_import_file(&session, file_link, "FILELINK.BIN")
	testing.expect_value(t, file_error.code, Error_Code.Host_Path_Unsafe)
	_, device_error := begin_import_file(&session, "/dev/null", "DEVICE.BIN")
	testing.expect_value(t, device_error.code, Error_Code.Host_Path_Unsafe)
	_, root_error := begin_import_tree(&session, tree_link, "ROOTLINK")
	testing.expect_value(t, root_error.code, Error_Code.Host_Path_Unsafe)
	job, begin_error := begin_import_tree(&session, host_tree, "TREE")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	for job.state != .Complete && job.state != .Failed {_ = job_step(&job)}
	testing.expect_value(t, job.state, Job_State.Failed)
	testing.expect_value(t, job_error(&job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&job).code, Error_Code.Cancelled)
	job_destroy(&job)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_durable_intent_recovers_idempotently :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	testing.expect_value(t, mkdir(&session, "RECOVER").code, Error_Code.None)
	transaction := transaction_id(&session)
	testing.expect(t, transaction != 0)
	testing.expect_value(t, write_apply_intent(session.impl).code, Error_Code.None)
	testing.expect_value(t, close_retain(&session).code, Error_Code.None)
	recovered, recover_ok := edit_test_session(t, image, state)
	if !recover_ok {return}
	info, stat_error := stat(&recovered, "RECOVER")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, info.exists && info.is_directory)
	testing.expect(t, transaction_id(&recovered) != transaction)
	testing.expect_value(t, discard(&recovered).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_large_import_is_bounded_to_step_buffer :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "large.bin"}, context.temp_allocator)
	file, create_error := os.open(source, {.Read, .Write, .Create, .Excl})
	if !testing.expect_value(t, create_error, os.Error(nil)) {return}
	large_bytes := i64(MAX_TRANSFER_BYTES * 3 + 37)
	testing.expect_value(t, os.truncate(file, large_bytes), os.Error(nil))
	testing.expect_value(t, os.close(file), os.Error(nil))
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	job, begin_error := begin_import_file(&session, source, "LARGE.BIN")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	defer job_destroy(&job)
	previous: u64
	steps := 0
	for job.state != .Complete && job.state != .Failed {
		progress := job_step(&job)
		testing.expect(t, progress.completed_bytes - previous <= MAX_TRANSFER_BYTES)
		previous = progress.completed_bytes
		steps += 1
	}
	testing.expect_value(t, job.state, Job_State.Complete)
	testing.expect(t, steps >= 4)
	testing.expect_value(t, job.total_bytes, u64(large_bytes))
	info, stat_error := stat(&session, "LARGE.BIN")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect_value(t, info.size, u64(large_bytes))
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_active_jobs_gate_mutation_and_export_pins_one_file_reader :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	source, _ := filepath.join({directory, "reader-source.bin"}, context.temp_allocator)
	file, create_error := os.open(source, {.Read, .Write, .Create, .Excl})
	if !testing.expect_value(t, create_error, os.Error(nil)) {return}
	large_bytes := i64(MAX_TRANSFER_BYTES * 3 + 37)
	if !testing.expect_value(t, os.truncate(file, large_bytes), os.Error(nil)) ||
	   !testing.expect_value(t, os.close(file), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	job, begin_error := begin_import_file(&session, source, "READER.BIN")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	testing.expect_value(t, mkdir(&session, "BLOCKED").code, Error_Code.Invalid_State)
	_, second_job_error := begin_remove_recursive(&session, "READER.BIN")
	testing.expect_value(t, second_job_error.code, Error_Code.Invalid_State)
	_, apply_error := begin_apply(&session)
	testing.expect_value(t, apply_error.code, Error_Code.Invalid_State)
	testing.expect_value(t, close_retain(&session).code, Error_Code.Invalid_State)
	testing.expect_value(t, discard(&session).code, Error_Code.Invalid_State)
	for job.state != .Complete && job.state != .Failed {_ = job_step(&job)}
	if !testing.expect_value(t, job.state, Job_State.Complete) {return}
	job_destroy(&job)
	testing.expect_value(t, mkdir(&session, "AFTER").code, Error_Code.None)

	exported, _ := filepath.join({directory, "reader-export.bin"}, context.temp_allocator)
	export_job, export_error := begin_export_file(&session, "READER.BIN", exported)
	if !testing.expect_value(t, export_error.code, Error_Code.None) {return}
	testing.expect(t, export_job.reader.active)
	testing.expect_value(t, export_job.reader.total, u64(large_bytes))
	testing.expect_value(
		t,
		rename(&session, "READER.BIN", "MOVED.BIN").code,
		Error_Code.Invalid_State,
	)
	progress := job_step(&export_job)
	if !testing.expect_value(t, progress.state, Job_State.Running) {return}
	testing.expect_value(t, export_job.reader.offset, u64(MAX_TRANSFER_BYTES))
	session.impl.volume.mutation_epoch += 1
	failed_progress := job_step(&export_job)
	testing.expect_value(t, failed_progress.state, Job_State.Failed)
	testing.expect_value(t, job_error(&export_job).code, Error_Code.Invalid_State)
	job_destroy(&export_job)
	testing.expect(t, !os.exists(exported))
	testing.expect_value(t, mkdir(&session, "UNBLOCKED").code, Error_Code.None)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_tree_import_rename_export_and_recursive_delete :: proc(t: ^testing.T) {
	directory, state, _, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	host_tree, _ := filepath.join({directory, "host-tree"}, context.temp_allocator)
	host_child, _ := filepath.join({host_tree, "자료"}, context.temp_allocator)
	host_file, _ := filepath.join({host_child, "게임.txt"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(host_child), os.Error(nil)) {return}
	content := []u8{1, 3, 3, 7}
	if !testing.expect_value(t, os.write_entire_file(host_file, content), os.Error(nil)) {return}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	job, begin_error := begin_import_tree(&session, host_tree, "가져오기")
	if !testing.expect_value(t, begin_error.code, Error_Code.None) {return}
	for job.state != .Complete && job.state != .Failed {_ = job_step(&job)}
	testing.expect_value(t, job.state, Job_State.Complete)
	job_destroy(&job)
	testing.expect_value(
		t,
		rename(&session, "가져오기/자료/게임.txt", "가져오기/자료/이름변경.txt").code,
		Error_Code.None,
	)
	exported, _ := filepath.join({directory, "exported.txt"}, context.temp_allocator)
	export_job, export_error := begin_export_file(
		&session,
		"가져오기/자료/이름변경.txt",
		exported,
	)
	if !testing.expect_value(t, export_error.code, Error_Code.None) {return}
	for export_job.state != .Complete && export_job.state != .Failed {_ = job_step(&export_job)}
	testing.expect_value(t, export_job.state, Job_State.Complete)
	job_destroy(&export_job)
	exported_bytes, read_error := os.read_entire_file(exported, context.temp_allocator)
	if testing.expect_value(t, read_error, os.Error(nil)) {
		testing.expect_value(t, string(exported_bytes), string(content))
	}
	testing.expect_value(t, remove_recursive(&session, "가져오기").code, Error_Code.None)
	removed, stat_error := stat(&session, "가져오기")
	testing.expect_value(t, stat_error.code, Error_Code.None)
	testing.expect(t, !removed.exists)
	testing.expect_value(t, discard(&session).code, Error_Code.None)
	testing.expect_value(t, fat32image.close(image, .Clean).code, fat32image.Error_Code.None)
}

@(test)
fat32edit_test_cancelled_and_failed_tree_replace_preserve_original_through_apply :: proc(
	t: ^testing.T,
) {
	directory, state, path, image, ok := edit_test_open(t)
	if !ok {return}
	defer os.remove_all(directory)
	defer if image != nil {_ = fat32image.close(image, .Clean)}
	original_tree, _ := filepath.join({directory, "original-tree"}, context.temp_allocator)
	original_file, _ := filepath.join({original_tree, "ORIGINAL.TXT"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(original_tree), os.Error(nil)) ||
	   !testing.expect_value(t, os.write_entire_file(original_file, "original"), os.Error(nil)) {
		return
	}
	session, session_ok := edit_test_session(t, image, state)
	if !session_ok {return}
	defer if session.impl != nil {_ = discard(&session)}
	original_job, original_error := begin_import_tree(&session, original_tree, "TREE")
	if !testing.expect_value(t, original_error.code, Error_Code.None) {return}
	for original_job.state != .Complete && original_job.state != .Failed {
		_ = job_step(&original_job)
	}
	if !testing.expect_value(t, original_job.state, Job_State.Complete) {
		_ = job_cancel(&original_job)
		job_destroy(&original_job)
		return
	}
	job_destroy(&original_job)

	replacement_tree, _ := filepath.join({directory, "replacement-tree"}, context.temp_allocator)
	first_file, _ := filepath.join({replacement_tree, "FIRST.TXT"}, context.temp_allocator)
	second_file, _ := filepath.join({replacement_tree, "SECOND.TXT"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(replacement_tree), os.Error(nil)) {return}
	if !testing.expect_value(t, os.write_entire_file(first_file, "first"), os.Error(nil)) ||
	   !testing.expect_value(t, os.write_entire_file(second_file, "second"), os.Error(nil)) {
		return
	}
	cancelled_job, cancelled_error := begin_import_tree(&session, replacement_tree, "TREE", true)
	if !testing.expect_value(t, cancelled_error.code, Error_Code.None) {return}
	for cancelled_job.items_completed < 1 &&
	    cancelled_job.state != .Complete &&
	    cancelled_job.state != .Failed {
		_ = job_step(&cancelled_job)
	}
	cancelled_boundary_ok :=
		testing.expect_value(t, cancelled_job.items_completed, u64(1)) &&
		testing.expect_value(t, cancelled_job.state, Job_State.Running)
	cancelled_original_visible := false
	if cancelled_boundary_ok {
		cancelled_original_visible = edit_test_read_file(
			t,
			&session,
			"TREE/ORIGINAL.TXT",
			"original",
		)
		first_info, first_stat_error := stat(&session, "TREE/FIRST.TXT")
		second_info, second_stat_error := stat(&session, "TREE/SECOND.TXT")
		testing.expect_value(t, first_stat_error.code, Error_Code.None)
		testing.expect_value(t, second_stat_error.code, Error_Code.None)
		testing.expect(t, !first_info.exists && !second_info.exists)
	}
	testing.expect_value(t, job_cancel(&cancelled_job).code, Error_Code.Cancelled)
	job_destroy(&cancelled_job)
	if !cancelled_boundary_ok || !cancelled_original_visible {return}
	if !edit_test_read_file(t, &session, "TREE/ORIGINAL.TXT", "original") {return}

	failed_job, failed_error := begin_import_tree(&session, replacement_tree, "TREE", true)
	if !testing.expect_value(t, failed_error.code, Error_Code.None) {return}
	for failed_job.items_completed < 1 &&
	    failed_job.state != .Complete &&
	    failed_job.state != .Failed {
		_ = job_step(&failed_job)
	}
	failed_boundary_ok :=
		testing.expect_value(t, failed_job.items_completed, u64(1)) &&
		testing.expect_value(t, failed_job.state, Job_State.Running)
	failed_original_visible := false
	if failed_boundary_ok {
		failed_original_visible = edit_test_read_file(
			t,
			&session,
			"TREE/ORIGINAL.TXT",
			"original",
		)
	}
	if !failed_boundary_ok || !failed_original_visible {
		_ = job_cancel(&failed_job)
		job_destroy(&failed_job)
		return
	}
	late_file, _ := filepath.join({replacement_tree, "LATE.TXT"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(late_file, "late"), os.Error(nil)) {
		_ = job_cancel(&failed_job)
		job_destroy(&failed_job)
		return
	}
	failed := job_step(&failed_job)
	testing.expect_value(t, failed.state, Job_State.Failed)
	testing.expect_value(t, job_error(&failed_job).code, Error_Code.Host_Path_Unsafe)
	testing.expect_value(t, job_cancel(&failed_job).code, Error_Code.Cancelled)
	job_destroy(&failed_job)
	if !edit_test_read_file(t, &session, "TREE/ORIGINAL.TXT", "original") {return}
	if !testing.expect_value(t, os.remove(late_file), os.Error(nil)) {return}

	completed_job, completed_error := begin_import_tree(&session, replacement_tree, "TREE", true)
	if !testing.expect_value(t, completed_error.code, Error_Code.None) {return}
	for completed_job.state != .Complete && completed_job.state != .Failed {
		_ = job_step(&completed_job)
	}
	completed_ok := testing.expect_value(t, completed_job.state, Job_State.Complete)
	job_destroy(&completed_job)
	if !completed_ok {return}
	original_info, original_stat_error := stat(&session, "TREE/ORIGINAL.TXT")
	testing.expect_value(t, original_stat_error.code, Error_Code.None)
	testing.expect(t, !original_info.exists)
	if !edit_test_read_file(t, &session, "TREE/FIRST.TXT", "first") ||
	   !edit_test_read_file(t, &session, "TREE/SECOND.TXT", "second") {
		return
	}
	if !testing.expect_value(t, apply(&session).code, Error_Code.None) {return}
	image_close_error := fat32image.close(image, .Clean)
	image = nil
	if !testing.expect_value(t, image_close_error.code, fat32image.Error_Code.None) {
		return
	}
	if !edit_test_read_image_file(t, path, "TREE/FIRST.TXT", "first") ||
	   !edit_test_read_image_file(t, path, "TREE/SECOND.TXT", "second") {
		return
	}
	read_image, open_error := fat32image.open(path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.close(read_image, .Clean)
	volume, volume_error := fat32fs.open(fat32image.block_device(read_image))
	if !testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {return}
	persisted_original, stat_error := fat32fs.stat(&volume, "TREE/ORIGINAL.TXT")
	testing.expect_value(t, stat_error.code, fat32fs.Error_Code.None)
	testing.expect(t, !persisted_original.exists)
}
