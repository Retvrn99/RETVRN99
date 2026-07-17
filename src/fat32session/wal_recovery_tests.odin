// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

wal_recovery_test_seed :: proc(
	t: ^testing.T,
	path: string,
	checkpoint_before_tail: bool,
) -> bool {
	session, open_error := open_machine(path, "wal-seed", .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return false}
	device := block_device(session)
	for record_index in 0 ..< 3 {
		payload: [fat32image.SECTOR_BYTES]u8
		for &value, byte_index in payload {
			value = u8(record_index * 37 + byte_index * 11)
		}
		lba := device.sector_count - u64(8 - record_index)
		if !testing.expect(t, device.write(device.ctx, lba, payload[:])) {
			_ = close(session, .Retain)
			return false
		}
		if checkpoint_before_tail && record_index == 0 {
			result, barrier_error := barrier(session, .Block_Flush)
			if !testing.expect_value(t, barrier_error.code, Error_Code.None) ||
			   !testing.expect_value(t, result.sequence, u64(1)) {
				_ = close(session, .Retain)
				return false
			}
		}
	}
	if checkpoint_before_tail {
		impl := (^In_Process_Implementation)(session.ctx)
		if !testing.expect_value(
			t,
			fat32image.sync(impl.image).code,
			fat32image.Error_Code.None,
		) ||
		   !testing.expect_value(
			t,
			state_save(&impl.wal, .Open, impl.sequence).code,
			Error_Code.None,
		) {
			_ = close(session, .Retain)
			return false
		}
	}
	return testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
}

wal_recovery_test_remove_middle_record :: proc(t: ^testing.T, image_path: string) -> bool {
	root, root_ok := companion_path(image_path, context.temp_allocator)
	if !testing.expect(t, root_ok) {return false}
	path, path_error := filepath.join({root, WAL_FILE}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return false}
	file, open_error := os.open(path, {.Read, .Write, .Sync})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return false}
	defer os.close(file)
	record_bytes := WAL_HEADER_BYTES + fat32image.SECTOR_BYTES
	expected_size := i64(3 * record_bytes)
	size, size_error := os.file_size(file)
	if !testing.expect_value(t, size_error, os.Error(nil)) ||
	   !testing.expect_value(t, size, expected_size) {return false}
	data := make([]u8, int(size), context.temp_allocator)
	if !testing.expect(t, file_read_exact_at(file, data, 0)) {return false}
	if !testing.expect(t, file_write_exact_at(file, data[:record_bytes], 0)) ||
	   !testing.expect(
		t,
		file_write_exact_at(
			file,
			data[2 * record_bytes:3 * record_bytes],
			i64(record_bytes),
		),
	   ) ||
	   !testing.expect_value(
		t,
		os.truncate(file, i64(2 * record_bytes)),
		os.Error(nil),
	   ) ||
	   !testing.expect_value(t, os.sync(file), os.Error(nil)) {return false}
	return true
}

@(test)
wal_recovery_test_rejects_sequence_gap_through_both_adapters :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-wal-gap-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	adapters := [?]Adapter_Kind{.In_Process, .Process}
	for adapter, index in adapters {
		path, created := session_test_image(
			t,
			root,
			fmt.tprintf("gap-%d.img", index),
		)
		if !created || !wal_recovery_test_seed(t, path, false) {return}
		if !wal_recovery_test_remove_middle_record(t, path) {return}
		session, recovery_error := open_machine(path, "wal-gap", adapter)
		if session != nil {_ = close(session, .Retain)}
		testing.expect_value(t, recovery_error.code, Error_Code.Recovery_Failed)
		testing.expect_value(t, recovery_error.outcome, Operation_Outcome.Retained)
		state_root, state_ok := companion_path(path, context.temp_allocator)
		testing.expect(t, state_ok && os.exists(state_root))
	}
}

@(test)
wal_recovery_test_accepts_contiguous_retained_checkpoint_prefix :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-wal-prefix-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	adapters := [?]Adapter_Kind{.In_Process, .Process}
	for adapter, index in adapters {
		path, created := session_test_image(
			t,
			root,
			fmt.tprintf("prefix-%d.img", index),
		)
		if !created || !wal_recovery_test_seed(t, path, true) {return}
		session, recovery_error := open_machine(path, "wal-prefix", adapter)
		if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
		result, barrier_error := barrier(session, .Block_Flush)
		if !testing.expect_value(t, barrier_error.code, Error_Code.None) {return}
		testing.expect_value(t, result.sequence, u64(3))
		testing.expect_value(t, result.durable_sequence, u64(3))
		testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	}
}
