// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

session_test_image :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := fat32image.create({path = path, capacity_gib = 1})
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {return path, false}
	fat32image.info_destroy(&info)
	return path, true
}

@(test)
session_test_clean_pending_state_roundtrips :: proc(t: ^testing.T) {
	state := Wal_State {
		valid      = true,
		epoch      = 9,
		checkpoint = 17,
		phase      = .Clean_Pending,
	}
	for &value, index in state.image_id {value = u8(index * 13 + 1)}
	encoded := state_encode(state)
	decoded := state_decode(encoded[:])
	testing.expect(t, decoded.valid)
	testing.expect_value(t, decoded.epoch, state.epoch)
	testing.expect_value(t, decoded.checkpoint, state.checkpoint)
	testing.expect_value(t, decoded.phase, Wal_State_Phase.Clean_Pending)
	testing.expect_value(t, decoded.image_id, state.image_id)
}

@(test)
session_test_clean_image_with_pending_transition_reopens :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-clean-pending-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "clean-pending.img")
	if !created {return}
	session, open_error := open_in_process(path, "clean-pending-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^In_Process_Implementation)(session.ctx)
	if !testing.expect_value(
		t,
		wal_mark_clean(&impl.wal, impl.sequence).code,
		Error_Code.None,
	) {return}
	if !testing.expect_value(
		t,
		fat32image.close(impl.image, .Clean).code,
		fat32image.Error_Code.None,
	) {return}
	impl.image = nil
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
	validated, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !validated.dirty)
	fat32image.info_destroy(&validated)
	reopened, reopen_error := open_in_process(path, "clean-pending-second")
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None)
	state_root, state_ok := companion_path(path, context.temp_allocator)
	testing.expect(t, state_ok && !os.exists(state_root))
}

@(test)
session_test_in_process_write_checkpoint_reopen_and_cleanup :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-session-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "machine.img")
	if !created {return}
	session, open_error := open_in_process(path, "first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)
	data: [fat32image.SECTOR_BYTES]u8
	for index in 0 ..< len(data) {data[index] = u8(index * 17)}
	lba := device.sector_count - 1
	testing.expect(t, device.write(device.ctx, lba, data[:]))
	barrier_result, barrier_error := barrier(session, .Reset)
	testing.expect_value(t, barrier_error.code, Error_Code.None)
	testing.expect_value(t, barrier_result.sequence, u64(1))
	testing.expect_value(t, barrier_result.durable_sequence, u64(1))
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	state_root, state_ok := companion_path(path, context.temp_allocator)
	testing.expect(t, state_ok)
	testing.expect(t, !os.exists(state_root))
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !info.dirty)
	fat32image.info_destroy(&info)
	reopened, reopen_error := open_in_process(path, "second")
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	readback: [fat32image.SECTOR_BYTES]u8
	device = block_device(reopened)
	testing.expect(t, device.read(device.ctx, lba, readback[:]))
	testing.expect_value(t, string(readback[:]), string(data[:]))
	testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None)
}

@(test)
session_test_compatible_protected_boot_writes_are_acknowledged_without_mutation :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-protected-boot-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "protected.img")
	if !created {return}
	session, open_error := open_in_process(path, "protected-boot")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)

	mbr, proposed_mbr, readback: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, 0, mbr[:]))
	proposed_mbr = mbr
	proposed_mbr[0] = proposed_mbr[0] ~ 0x5A
	testing.expect(t, device.write(device.ctx, 0, proposed_mbr[:]))
	testing.expect(t, device.read(device.ctx, 0, readback[:]))
	testing.expect_value(t, readback, mbr)

	partition_lba := u64(63)
	vbr, proposed_vbr: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, partition_lba, vbr[:]))
	proposed_vbr = vbr
	proposed_vbr[0] = proposed_vbr[0] ~ 0x5A
	proposed_vbr[100] = proposed_vbr[100] ~ 0xA5
	testing.expect(t, device.write(device.ctx, partition_lba, proposed_vbr[:]))
	testing.expect(t, device.read(device.ctx, partition_lba, readback[:]))
	testing.expect_value(t, readback, vbr)

	backup_vbr_lba := partition_lba + 6
	backup_vbr, proposed_backup: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, backup_vbr_lba, backup_vbr[:]))
	proposed_backup = backup_vbr
	proposed_backup[90] = proposed_backup[90] ~ 0x3C
	testing.expect(t, device.write(device.ctx, backup_vbr_lba, proposed_backup[:]))
	testing.expect(t, device.read(device.ctx, backup_vbr_lba, readback[:]))
	testing.expect_value(t, readback, backup_vbr)

	reserved_lba := partition_lba + 2
	reserved, proposed_reserved: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, device.read(device.ctx, reserved_lba, reserved[:]))
	proposed_reserved[0] = 0xF6
	testing.expect(t, device.write(device.ctx, reserved_lba, proposed_reserved[:]))
	testing.expect(t, device.read(device.ctx, reserved_lba, readback[:]))
	testing.expect_value(t, readback, reserved)

	impl := (^In_Process_Implementation)(session.ctx)
	testing.expect_value(t, impl.sequence, u64(0))
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
}

@(test)
session_test_wal_checkpoint_due_has_size_and_sequence_bounds :: proc(t: ^testing.T) {
	wal := Wal {
		offset = WAL_CHECKPOINT_MAX_BYTES - 1,
		state = {checkpoint = 37},
	}
	testing.expect(t, !wal_checkpoint_due(&wal, 37 + WAL_CHECKPOINT_MAX_SEQUENCES - 1))
	testing.expect(t, wal_checkpoint_due(&wal, 37 + WAL_CHECKPOINT_MAX_SEQUENCES))
	wal.offset = WAL_CHECKPOINT_MAX_BYTES
	testing.expect(t, wal_checkpoint_due(&wal, 38))
}

@(test)
session_test_retain_recovers_complete_redo_record :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-retain-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "retained.img")
	if !created {return}
	session, open_error := open_in_process(path, "retained-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)
	data: [fat32image.SECTOR_BYTES]u8
	copy(data[:], "durable redo survives helper failure")
	lba := device.sector_count - 2
	testing.expect(t, device.write(device.ctx, lba, data[:]))
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
	dirty, dirty_error := fat32image.validate(path)
	if !testing.expect_value(t, dirty_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, dirty.dirty)
	fat32image.info_destroy(&dirty)
	recovered, recovery_error := open_in_process(path, "retained-second")
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	impl := (^In_Process_Implementation)(recovered.ctx)
	testing.expect_value(t, impl.sequence, u64(1))
	readback: [fat32image.SECTOR_BYTES]u8
	device = block_device(recovered)
	testing.expect(t, device.read(device.ctx, lba, readback[:]))
	testing.expect_value(t, string(readback[:]), string(data[:]))
	testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None)
}

@(test)
session_test_observe_empty_standard_image :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-observe-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "observe.img")
	if !created {return}
	session, open_error := open_in_process(path, "observe")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	probes := []Probe{{kind = .Stat, path = ""}, {kind = .Stat, path = "Korean/한글.txt"}}
	batch, observe_error := observe(session, probes)
	defer observation_batch_destroy(&batch)
	testing.expect_value(t, observe_error.code, Error_Code.None)
	if !testing.expect_value(t, len(batch.items), 2) {return}
	testing.expect_value(t, batch.items[0].type, Observed_Type.Directory)
	testing.expect_value(t, batch.items[1].type, Observed_Type.Missing)
	testing.expect_value(t, batch.barrier.sequence, batch.barrier.durable_sequence)
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	session = nil
}

@(test)
session_test_nonroot_fat_mismatch_is_pending_until_second_mirror_arrives :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-mirror-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "mirror.img")
	if !created {return}
	session, open_error := open_in_process(path, "mirror")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	impl := (^In_Process_Implementation)(session.ctx)
	device := block_device(session)
	first_lba := u64(impl.image.info.partition_lba) + u64(impl.image.info.reserved_sectors) + 1
	second_lba := first_lba + u64(impl.image.geometry.sectors_per_fat)
	sector: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, first_lba, sector[:])) {return}
	sector[100] = sector[100] ~ 1
	if !testing.expect(t, device.write(device.ctx, first_lba, sector[:])) {return}
	barrier_result, barrier_error := barrier(session, .Observation)
	testing.expect_value(t, barrier_error.code, Error_Code.None)
	testing.expect_value(t, barrier_result.materialization, Materialization.Pending)
	batch, observe_error := observe(session, []Probe{{kind = .Stat, path = ""}})
	defer observation_batch_destroy(&batch)
	testing.expect_value(t, observe_error.code, Error_Code.None)
	testing.expect(t, batch.pending)
	testing.expect_value(t, len(batch.items), 0)
	reset_result, reset_error := barrier(session, .Reset)
	testing.expect_value(t, reset_result.materialization, Materialization.Pending)
	testing.expect_value(t, reset_error.code, Error_Code.Observation_Pending)
	close_error := close(session, .Commit)
	testing.expect_value(t, close_error.code, Error_Code.Observation_Pending)
	if !testing.expect(t, device.write(device.ctx, second_lba, sector[:])) {return}
	materialized, materialize_error := barrier(session, .Reset)
	testing.expect_value(t, materialize_error.code, Error_Code.None)
	testing.expect_value(t, materialized.materialization, Materialization.Materialized)
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	session = nil
}

@(test)
session_test_nonroot_fat_mismatch_restart_fails_closed :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-mirror-restart-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "mirror-restart.img")
	if !created {return}
	session, open_error := open_in_process(path, "mirror-restart-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^In_Process_Implementation)(session.ctx)
	device := block_device(session)
	first_lba := u64(impl.image.info.partition_lba) + u64(impl.image.info.reserved_sectors) + 1
	sector: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, first_lba, sector[:])) {return}
	sector[200] = sector[200] ~ 1
	if !testing.expect(t, device.write(device.ctx, first_lba, sector[:])) {return}
	pending, pending_error := barrier(session, .Observation)
	testing.expect_value(t, pending_error.code, Error_Code.None)
	testing.expect_value(t, pending.materialization, Materialization.Pending)
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
	reopened, reopen_error := open_in_process(path, "mirror-restart-second")
	testing.expect(t, reopened == nil)
	testing.expect_value(t, reopen_error.code, Error_Code.FAT_Invalid)
}

@(test)
session_test_clean_image_rejects_unmatched_companion_without_dirtying_image :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-state-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "state.img")
	if !created {return}
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	testing.expect_value(t, os.make_directory_all(state_root), os.Error(nil))
	session, open_error := open_in_process(path, "mismatch")
	testing.expect(t, session == nil)
	testing.expect_value(t, open_error.code, Error_Code.State_Mismatch)
	info, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	testing.expect(t, !info.dirty)
}

@(test)
session_test_dirty_image_without_active_wal_fails_closed_without_recreation :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-missing-wal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "missing-wal.img")
	if !created {return}
	session, open_error := open_in_process(path, "missing-wal-first")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	wal_path, path_error := filepath.join({state_root, WAL_FILE}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	if !testing.expect_value(t, os.remove(wal_path), os.Error(nil)) {return}

	_, validation_error := validate_image(path, .In_Process)
	testing.expect_value(t, validation_error.code, Error_Code.State_Mismatch)
	reopened, reopen_error := open_in_process(path, "missing-wal-second")
	testing.expect(t, reopened == nil)
	testing.expect_value(t, reopen_error.code, Error_Code.State_Mismatch)
	testing.expect(t, !os.exists(wal_path))
	info, image_error := fat32image.validate(path)
	if !testing.expect_value(t, image_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	testing.expect(t, info.dirty)
}

@(test)
session_test_wal_setup_failure_restores_only_an_originally_clean_marker :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-wal-rollback-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	clean_path, clean_created := session_test_image(t, root, "clean.img")
	if !clean_created {return}
	clean_image, clean_open_error := fat32image.open(clean_path, .Read_Write)
	if !testing.expect_value(t, clean_open_error.code, fat32image.Error_Code.None) {return}
	clean_state_root, clean_state_ok := companion_path(clean_path, context.temp_allocator)
	if !testing.expect(t, clean_state_ok) {return}
	if !testing.expect_value(t, os.make_directory_all(clean_state_root), os.Error(nil)) {return}
	clean_impl := new(In_Process_Implementation)
	clean_impl.allocator = context.allocator
	clean_impl.image = clean_image
	clean_impl.wal.state_root = strings.clone(clean_state_root)
	clean_impl.wal.created_state_root = true
	failure := error_make(.Wal_IO, false, .Not_Started, 0, 0, "injected WAL setup failure")
	returned := in_process_wal_open_failure(clean_impl, false, failure)
	testing.expect_value(t, returned.code, Error_Code.Wal_IO)
	testing.expect(t, clean_impl.image == nil)
	testing.expect(t, !os.exists(clean_state_root))
	in_process_destroy(clean_impl)
	clean_info, clean_validation_error := fat32image.validate(clean_path)
	if !testing.expect_value(
		t,
		clean_validation_error.code,
		fat32image.Error_Code.None,
	) {return}
	testing.expect(t, !clean_info.dirty)
	fat32image.info_destroy(&clean_info)

	dirty_path, dirty_created := session_test_image(t, root, "dirty.img")
	if !dirty_created {return}
	dirty_session, dirty_open_error := open_in_process(dirty_path, "dirty-first")
	if !testing.expect_value(t, dirty_open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(dirty_session, .Retain).code, Error_Code.None) {return}
	dirty_state_root, dirty_state_ok := companion_path(dirty_path, context.temp_allocator)
	if !testing.expect(t, dirty_state_ok) {return}
	dirty_wal_path, dirty_wal_error := filepath.join(
		{dirty_state_root, WAL_FILE},
		context.temp_allocator,
	)
	if !testing.expect(t, dirty_wal_error == nil) {return}
	dirty_image, dirty_image_error := fat32image.open(dirty_path, .Read_Write)
	if !testing.expect_value(t, dirty_image_error.code, fat32image.Error_Code.None) {return}
	dirty_impl := new(In_Process_Implementation)
	dirty_impl.allocator = context.allocator
	dirty_impl.image = dirty_image
	returned = in_process_wal_open_failure(dirty_impl, true, failure)
	testing.expect_value(t, returned.code, Error_Code.Wal_IO)
	testing.expect(t, dirty_impl.image == nil)
	in_process_destroy(dirty_impl)
	dirty_info, dirty_validation_error := fat32image.validate(dirty_path)
	if !testing.expect_value(
		t,
		dirty_validation_error.code,
		fat32image.Error_Code.None,
	) {return}
	defer fat32image.info_destroy(&dirty_info)
	testing.expect(t, dirty_info.dirty)
	testing.expect(t, os.exists(dirty_state_root))
	testing.expect(t, os.exists(dirty_wal_path))
}
