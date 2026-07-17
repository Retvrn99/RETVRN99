// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:testing"

@(test)
session_test_dirty_single_fsinfo_update_recovers_to_coherent_mirrors :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-fsinfo-recovery-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "fsinfo-recovery.img")
	if !created {return}

	first, open_error := open_in_process(path, "fsinfo-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(first)
	vbr, primary: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, 63, vbr[:]))
	primary_lba := u64(63) + u64(get_u16le(vbr[:], 48))
	testing.expect(t, device.read(device.ctx, primary_lba, primary[:]))
	put_u32le(primary[:], 488, 1234)
	put_u32le(primary[:], 492, 10)
	testing.expect(t, device.write(device.ctx, primary_lba, primary[:]))
	testing.expect_value(t, close(first, .Retain).code, Error_Code.None)

	dirty, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, dirty.dirty)
	fat32image.info_destroy(&dirty)

	recovered, recovery_error := open_in_process(path, "fsinfo-second")
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None)
	clean, clean_error := fat32image.validate(path)
	if !testing.expect_value(t, clean_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&clean)
	testing.expect(t, !clean.dirty)
}

@(test)
session_test_reset_materializes_valid_single_fsinfo_update :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-fsinfo-reset-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "fsinfo-reset.img")
	if !created {return}

	session, open_error := open_in_process(path, "fsinfo-reset")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	device := block_device(session)
	vbr, primary: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, 63, vbr[:])) {return}
	primary_lba := u64(63) + u64(get_u16le(vbr[:], 48))
	if !testing.expect(t, device.read(device.ctx, primary_lba, primary[:])) {return}
	put_u32le(primary[:], 488, 1234)
	put_u32le(primary[:], 492, 10)
	if !testing.expect(t, device.write(device.ctx, primary_lba, primary[:])) {return}

	observed, observe_error := barrier(session, .Observation)
	testing.expect_value(t, observe_error.code, Error_Code.None)
	testing.expect_value(t, observed.materialization, Materialization.Materialized)
	reset, reset_error := barrier(session, .Reset)
	testing.expect_value(t, reset_error.code, Error_Code.None)
	testing.expect_value(t, reset.materialization, Materialization.Materialized)
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	session = nil
}

@(test)
session_test_windows_three_sector_boot_run_filters_protected_bytes_atomically :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-boot-run-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "boot-run.img")
	if !created {return}
	session, open_error := open_in_process(path, "boot-run")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)
	partition_lba := u64(63)
	original, proposed, readback: [3 * fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, partition_lba, original[:]))
	proposed = original
	proposed[0] = proposed[0] ~ 0x5A
	proposed[100] = proposed[100] ~ 0xA5
	fsinfo_offset := fat32image.SECTOR_BYTES
	put_u32le(proposed[:], fsinfo_offset + 488, 1234)
	put_u32le(proposed[:], fsinfo_offset + 492, 10)
	for index in 2 * fat32image.SECTOR_BYTES ..< len(proposed) {
		proposed[index] = 0xF6
	}
	testing.expect(t, device.write(device.ctx, partition_lba, proposed[:]))
	testing.expect(t, device.read(device.ctx, partition_lba, readback[:]))
	testing.expect_value(
		t,
		string(readback[:fat32image.SECTOR_BYTES]),
		string(original[:fat32image.SECTOR_BYTES]),
	)
	testing.expect_value(
		t,
		string(readback[fat32image.SECTOR_BYTES:2 * fat32image.SECTOR_BYTES]),
		string(proposed[fat32image.SECTOR_BYTES:2 * fat32image.SECTOR_BYTES]),
	)
	testing.expect_value(
		t,
		string(readback[2 * fat32image.SECTOR_BYTES:]),
		string(original[2 * fat32image.SECTOR_BYTES:]),
	)
	impl := (^In_Process_Implementation)(session.ctx)
	testing.expect_value(t, impl.sequence, u64(1))
	backup_fsinfo_lba :=
		partition_lba + u64(get_u16le(original[:], 50)) + u64(get_u16le(original[:], 48))
	testing.expect(
		t,
		device.write(
			device.ctx,
			backup_fsinfo_lba,
			proposed[fat32image.SECTOR_BYTES:2 * fat32image.SECTOR_BYTES],
		),
	)
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
}
