// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

@(private = "file")
edit_machine_recovery_dirty_primary_fsinfo :: proc(
	t: ^testing.T,
	path, session_id: string,
) -> bool {
	machine, open_error := open_machine(path, session_id, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return false}
	device := block_device(machine)
	vbr, primary: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, 63, vbr[:])) {return false}
	primary_lba := u64(63) + u64(get_u16le(vbr[:], 48))
	if !testing.expect(t, device.read(device.ctx, primary_lba, primary[:])) {return false}
	put_u32le(primary[:], 488, 1234)
	put_u32le(primary[:], 492, 10)
	if !testing.expect(t, device.write(device.ctx, primary_lba, primary[:])) {return false}
	return testing.expect_value(t, close(machine, .Retain).code, Error_Code.None)
}

@(private = "file")
edit_machine_recovery_expect_clean_fsinfo :: proc(t: ^testing.T, path: string) -> bool {
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {
		return false
	}
	defer fat32image.info_destroy(&info)
	if !testing.expect(t, !info.dirty) {return false}
	image, open_error := fat32image.open(path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return false}
	defer fat32image.close(image, .Retain)
	vbr, primary, backup: [fat32image.SECTOR_BYTES]u8
	partition := u64(info.partition_lba)
	if !testing.expect_value(
		t,
		fat32image.block_read(image, partition, vbr[:]).code,
		fat32image.Error_Code.None,
	) {return false}
	primary_lba := partition + u64(get_u16le(vbr[:], 48))
	backup_lba := partition + u64(get_u16le(vbr[:], 50)) + u64(get_u16le(vbr[:], 48))
	if !testing.expect_value(
		t,
		fat32image.block_read(image, primary_lba, primary[:]).code,
		fat32image.Error_Code.None,
	) {return false}
	if !testing.expect_value(
		t,
		fat32image.block_read(image, backup_lba, backup[:]).code,
		fat32image.Error_Code.None,
	) {return false}
	return testing.expect(t, slice.equal(primary[:], backup[:]))
}

@(test)
edit_machine_recovery_test_open_edit_recovers_machine_wal_and_primary_fsinfo :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-machine-wal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	adapters := [2]Adapter_Kind{Adapter_Kind.In_Process, Adapter_Kind.Process}
	for adapter, index in adapters {
		path, created := session_test_image(t, root, index == 0 ? "in-process.img" : "process.img")
		if !created {return}
		if !edit_machine_recovery_dirty_primary_fsinfo(t, path, "machine-retained") {
			return
		}
		requested_transaction := u64(0xA110_0000 + index)
		edit, open_error := open_edit(path, "edit-after-machine", requested_transaction, adapter)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		if !testing.expect_value(t, edit_transaction_id(edit), requested_transaction) {
			_ = edit_close_retain(edit)
			return
		}
		if !testing.expect_value(t, edit_finish(edit, false).code, Error_Code.None) {
			return
		}
		if !edit_machine_recovery_expect_clean_fsinfo(t, path) {return}
	}
}

@(test)
edit_machine_recovery_test_invalid_machine_wal_fails_closed :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-invalid-machine-wal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "invalid-machine.img")
	if !created {return}
	machine, open_error := open_machine(path, "invalid-machine", .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(machine, .Retain).code, Error_Code.None) {return}
	state_root, root_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, root_ok) {return}
	wal_path, path_error := filepath.join({state_root, WAL_FILE}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	if !testing.expect_value(t, os.remove(wal_path), os.Error(nil)) {return}
	edit, edit_error := open_edit(path, "must-not-fallback", 0, .In_Process)
	testing.expect(t, edit == nil)
	testing.expect_value(t, edit_error.code, Error_Code.State_Mismatch)
	testing.expect(t, os.exists(state_root))
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	testing.expect(t, info.dirty)
}

@(test)
edit_machine_recovery_test_ambiguous_owner_state_fails_closed :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-ambiguous-state-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "ambiguous.img")
	if !created {return}
	edit, open_error := open_edit(path, "ambiguous-owner", 0, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, edit_close_retain(edit).code, Error_Code.None) {return}
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	state_root, root_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, root_ok) {return}
	state := Wal_State {
		valid    = true,
		epoch    = 1,
		image_id = info.image_id,
		phase    = .Open,
	}
	encoded := state_encode(state)
	state_path, state_path_error := filepath.join({state_root, "state.b"}, context.temp_allocator)
	if !testing.expect(t, state_path_error == nil) {return}
	if !testing.expect_value(t, os.write_entire_file(state_path, encoded[:]), os.Error(nil)) {
		return
	}
	reopened, reopen_error := open_edit(path, "ambiguous-reopen", 0, .In_Process)
	testing.expect(t, reopened == nil)
	testing.expect_value(t, reopen_error.code, Error_Code.State_Mismatch)
	testing.expect(t, os.exists(state_root))
}

@(test)
edit_machine_recovery_test_process_transport_loss_does_not_fallback :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-machine-transport-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "transport.img")
	if !created {return}
	machine, open_error := open_machine(path, "transport-machine", .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(machine, .Retain).code, Error_Code.None) {return}
	edit, edit_error := open_edit_process_configured(
		path,
		"transport-edit",
		0,
		crash_phase_name(.Image_Synced),
	)
	testing.expect(t, edit == nil)
	if !testing.expect_value(t, edit_error.code, Error_Code.Transport_Lost) {return}
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, info.dirty)
	fat32image.info_destroy(&info)
	recovered, recovery_error := open_edit(path, "explicit-recovery", 0, .In_Process)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, edit_finish(recovered, false).code, Error_Code.None) {return}
	edit_machine_recovery_expect_clean_fsinfo(t, path)
}
