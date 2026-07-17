// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_discard_test_read_fsinfo_pair :: proc(
	path: string,
	primary_lba, backup_lba: u64,
	primary, backup: []u8,
) -> bool {
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return false}
	ok :=
		file_read_exact_at(file, primary, i64(primary_lba * fat32image.SECTOR_BYTES)) &&
		file_read_exact_at(file, backup, i64(backup_lba * fat32image.SECTOR_BYTES))
	return os.close(file) == nil && ok
}

@(test)
edit_unenrolled_discard_test_noop_restores_marker_sector_byte_for_byte :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp(
		"",
		"retvrn99-unenrolled-discard-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	defer os.remove_all(directory)
	path, path_error := filepath.join({directory, "compatible.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	created, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
	marker_sector := created.marker_sector
	fat32image.info_destroy(&created)
	file, open_error := os.open(path, {.Read, .Write})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	marker_offset := i64(u64(marker_sector) * fat32image.SECTOR_BYTES)
	original: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, file_write_exact_at(file, original[:], marker_offset)) ||
	   !testing.expect_value(t, os.sync(file), os.Error(nil)) ||
	   !testing.expect_value(t, os.close(file), os.Error(nil)) {
		return
	}
	compatible, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !compatible.enrolled)
	fat32image.info_destroy(&compatible)

	session, edit_error := open_edit(path, "unenrolled-noop-discard", 0, .In_Process)
	if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
	file, open_error = os.open(path, {.Read})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	after: [fat32image.SECTOR_BYTES]u8
	read_ok := file_read_exact_at(file, after[:], marker_offset)
	close_error := os.close(file)
	if !testing.expect(t, read_ok) || !testing.expect_value(t, close_error, os.Error(nil)) {return}
	testing.expect_value(t, after, original)
	validated, final_error := fat32image.validate(path)
	if !testing.expect_value(t, final_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !validated.enrolled && !validated.dirty)
	fat32image.info_destroy(&validated)
	state_root, state_ok := companion_path(path, context.temp_allocator)
	testing.expect(t, state_ok && !os.exists(state_root))
}

@(test)
edit_discard_test_divergent_fsinfo_pair_is_byte_identical_after_both_adapters :: proc(
	t: ^testing.T,
) {
	directory, directory_error := os.make_directory_temp(
		"",
		"retvrn99-edit-fsinfo-discard-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, directory_error, os.Error(nil)) {return}
	defer os.remove_all(directory)
	adapters := [2]Adapter_Kind{.In_Process, .Process}
	for adapter, index in adapters {
		path, path_error := filepath.join(
			{directory, fmt.tprintf("divergent-%d.img", index)},
			context.temp_allocator,
		)
		if !testing.expect(t, path_error == nil) {return}
		created, create_error := fat32image.create({path = path, capacity_gib = 1})
		if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return}
		partition_lba := u64(created.partition_lba)
		fat32image.info_destroy(&created)
		file, open_error := os.open(path, {.Read, .Write})
		if !testing.expect_value(t, open_error, os.Error(nil)) {return}
		vbr, primary: [fat32image.SECTOR_BYTES]u8
		if !testing.expect(t, file_read_exact_at(
			file,
			vbr[:],
			i64(partition_lba * fat32image.SECTOR_BYTES),
		)) {
			_ = os.close(file)
			return
		}
		primary_lba := partition_lba + u64(get_u16le(vbr[:], 48))
		backup_lba :=
			partition_lba + u64(get_u16le(vbr[:], 50)) + u64(get_u16le(vbr[:], 48))
		if !testing.expect(t, file_read_exact_at(
			file,
			primary[:],
			i64(primary_lba * fat32image.SECTOR_BYTES),
		)) {
			_ = os.close(file)
			return
		}
		put_u32le(primary[:], 488, 1234)
		put_u32le(primary[:], 492, 10)
		write_ok :=
			file_write_exact_at(
				file,
				primary[:],
				i64(primary_lba * fat32image.SECTOR_BYTES),
			) &&
			os.sync(file) == nil
		close_error := os.close(file)
		if !testing.expect(t, write_ok) ||
		   !testing.expect_value(t, close_error, os.Error(nil)) {
			return
		}
		before_primary, before_backup: [fat32image.SECTOR_BYTES]u8
		if !testing.expect(t, edit_discard_test_read_fsinfo_pair(
			path,
			primary_lba,
			backup_lba,
			before_primary[:],
			before_backup[:],
		)) ||
		   !testing.expect(t, before_primary != before_backup) {
			return
		}
		session, edit_error := open_edit(
			path,
			fmt.tprintf("fsinfo-discard-%d", index),
			0,
			adapter,
		)
		if !testing.expect_value(t, edit_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
		after_primary, after_backup: [fat32image.SECTOR_BYTES]u8
		if !testing.expect(t, edit_discard_test_read_fsinfo_pair(
			path,
			primary_lba,
			backup_lba,
			after_primary[:],
			after_backup[:],
		)) {
			return
		}
		testing.expect_value(t, after_primary, before_primary)
		testing.expect_value(t, after_backup, before_backup)
		validated, validation_error := fat32image.validate(path)
		if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
		testing.expect(t, !validated.dirty)
		fat32image.info_destroy(&validated)
		state_root, state_ok := companion_path(path, context.temp_allocator)
		if !testing.expect(t, state_ok && !os.exists(state_root)) {return}
	}
}
