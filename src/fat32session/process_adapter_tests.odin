// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:time"

process_test_launch :: proc(t: ^testing.T) -> (^Process_Implementation, bool) {
	helper, helper_error := process_helper_path(context.temp_allocator)
	if !testing.expect_value(t, helper_error.code, Error_Code.None) {return nil, false}
	child_input, parent_request, input_error := os.pipe()
	if !testing.expect_value(t, input_error, os.Error(nil)) {return nil, false}
	parent_response, child_output, output_error := os.pipe()
	if output_error != nil {
		_ = os.close(child_input)
		_ = os.close(parent_request)
		testing.expect_value(t, output_error, os.Error(nil))
		return nil, false
	}
	if !testing.expect(t, process_pipe_parent_ends_secure(parent_request, parent_response)) {
		_ = os.close(child_input)
		_ = os.close(parent_request)
		_ = os.close(parent_response)
		_ = os.close(child_output)
		return nil, false
	}
	process, launch_error := os.process_start(
		os.Process_Desc {
			working_dir = filepath.dir(helper),
			command = []string{helper, "--pipe"},
			stdin = child_input,
			stdout = child_output,
		},
	)
	_ = os.close(child_input)
	_ = os.close(child_output)
	if launch_error != nil {
		_ = os.close(parent_request)
		_ = os.close(parent_response)
		testing.expect_value(t, launch_error, os.Error(nil))
		return nil, false
	}
	impl := new(Process_Implementation)
	impl.allocator = context.allocator
	impl.request = parent_request
	impl.response = parent_response
	impl.process = process
	impl.launched = true
	return impl, true
}

process_test_wait :: proc(
	t: ^testing.T,
	impl: ^Process_Implementation,
	expected_exit_code: int,
) -> bool {
	if impl == nil || !impl.launched {return false}
	state, wait_error := os.process_wait(impl.process, 5 * time.Second)
	if wait_error != nil {
		_ = os.process_kill(impl.process)
		_, _ = os.process_wait(impl.process)
		impl.launched = false
		testing.expect_value(t, wait_error, os.Error(nil))
		return false
	}
	impl.launched = false
	return(
		testing.expect(t, state.exited) &&
		testing.expect_value(t, state.exit_code, expected_exit_code) \
	)
}

process_test_wait_terminal :: proc(
	t: ^testing.T,
	session: ^Machine_Session,
) -> (
	Session_Error,
	bool,
) {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		err, terminal := session_terminal_error(session)
		if terminal {return err, true}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, false)
	return {}, false
}

process_test_close_request :: proc(impl: ^Process_Implementation) {
	if impl == nil || impl.request == nil {return}
	_ = os.close(impl.request)
	impl.request = nil
}

process_test_header :: proc(
	kind: Protocol_Kind,
	request_id: u64,
	payload: []u8,
) -> (
	header: [PROTOCOL_HEADER_BYTES]u8,
) {
	put_u32le(header[:], 0, PROTOCOL_MAGIC)
	put_u16le(header[:], 4, PROTOCOL_VERSION)
	put_u16le(header[:], 6, u16(kind))
	put_u32le(header[:], 8, u32(len(payload)))
	put_u64le(header[:], 16, request_id)
	put_u32le(header[:], 12, protocol_frame_checksum(header[:], payload))
	return
}

process_test_write_fragmented :: proc(file: ^os.File, data: []u8) -> bool {
	if len(data) == 0 {return true}
	steps := [?]int{1, 2, 5, 11, 23}
	offset := 0
	for step in steps {
		if offset >= len(data) {break}
		end := min(offset + step, len(data))
		if !protocol_write_exact(file, data[offset:end]) {return false}
		offset = end
		time.sleep(time.Millisecond)
	}
	return offset == len(data) || protocol_write_exact(file, data[offset:])
}

process_test_expect_image_info_equal :: proc(t: ^testing.T, actual, expected: ^Image_Info) {
	testing.expect_value(t, actual.path, expected.path)
	testing.expect_value(t, actual.image_id, expected.image_id)
	testing.expect_value(t, actual.sector_count, expected.sector_count)
	testing.expect_value(t, actual.partition_lba, expected.partition_lba)
	testing.expect_value(t, actual.partition_sectors, expected.partition_sectors)
	testing.expect_value(t, actual.sectors_per_cluster, expected.sectors_per_cluster)
	testing.expect_value(t, actual.reserved_sectors, expected.reserved_sectors)
	testing.expect_value(t, actual.marker_sector, expected.marker_sector)
	testing.expect_value(t, actual.sparse, expected.sparse)
	testing.expect_value(t, actual.enrolled, expected.enrolled)
	testing.expect_value(t, actual.retvrn99_format, expected.retvrn99_format)
	testing.expect_value(t, actual.dirty, expected.dirty)
}

process_test_expect_observe_rejected_equally :: proc(
	t: ^testing.T,
	left, right: ^Machine_Session,
	probes: []Probe,
	expected: Error_Code,
) {
	right_impl := (^Process_Implementation)(right.ctx)
	request_before := right_impl.request_id
	left_batch, left_error := observe(left, probes)
	right_batch, right_error := observe(right, probes)
	observation_batch_destroy(&left_batch)
	observation_batch_destroy(&right_batch)
	testing.expect_value(t, left_error.code, expected)
	testing.expect_value(t, right_error.code, left_error.code)
	testing.expect_value(t, right_error.retryable, left_error.retryable)
	testing.expect_value(t, right_error.outcome, left_error.outcome)
	testing.expect_value(t, right_impl.request_id, request_before)
}

@(test)
process_adapter_test_completed_cleanup_warning_releases_server_session_and_exits :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-completed-close-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "completed.img")
	if !created {return}
	session, open_error := open_machine(path, "completed-process", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^Process_Implementation)(session.ctx)
	defer {
		if session != nil {
			session.ctx = nil
			free(session)
		}
		if impl != nil {process_destroy(impl)}
	}
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	blocker, blocker_error := filepath.join(
		{state_root, "unowned-cleanup-blocker.bin"},
		context.temp_allocator,
	)
	if !testing.expect(t, blocker_error == nil) ||
	   !testing.expect_value(t, os.write_entire_file(blocker, "preserve me"), os.Error(nil)) {
		return
	}
	close_error := process_close(impl, .Commit)
	testing.expect_value(t, close_error.code, Error_Code.Wal_IO)
	testing.expect_value(t, close_error.outcome, Operation_Outcome.Completed)
	if !process_test_wait(t, impl, 0) {return}
	validated, validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	testing.expect(t, !validated.dirty)
	image_info_destroy(&validated)
}

process_test_stage_fat_mirror_mismatch :: proc(
	t: ^testing.T,
	session: ^Machine_Session,
) -> (u64, u64, [fat32image.SECTOR_BYTES]u8, bool) {
	device := block_device(session)
	vbr: [fat32image.SECTOR_BYTES]u8
	partition_lba := u64(63)
	if !testing.expect(t, device.read(device.ctx, partition_lba, vbr[:])) {
		return 0, 0, {}, false
	}
	partition_lba = u64(get_u32le(vbr[:], 28))
	first_fat_lba := partition_lba + u64(get_u16le(vbr[:], 14)) + 1
	second_fat_lba := first_fat_lba + u64(get_u32le(vbr[:], 36))
	sector: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, first_fat_lba, sector[:])) {
		return 0, 0, {}, false
	}
	sector[100] = sector[100] ~ 1
	if !testing.expect(t, device.write(device.ctx, first_fat_lba, sector[:])) {
		return 0, 0, {}, false
	}
	return first_fat_lba, second_fat_lba, sector, true
}

@(test)
process_adapter_test_create_validate_and_korean_path :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-korean-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, path_error := filepath.join(
		{root, "한국어 하드 디스크", "윈도우 98.img"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	testing.expect_value(t, os.make_directory_all(filepath.dir(path)), os.Error(nil))
	created, create_error := create_image(
		Create_Image_Request{path = path, capacity_gib = 1},
		.Process,
	)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return}
	defer image_info_destroy(&created)
	testing.expect(t, created.retvrn99_format)
	process_info, process_error := validate_image(path, .Process)
	if !testing.expect_value(t, process_error.code, Error_Code.None) {return}
	defer image_info_destroy(&process_info)
	in_process_info, in_process_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, in_process_error.code, Error_Code.None) {return}
	defer image_info_destroy(&in_process_info)
	process_test_expect_image_info_equal(t, &created, &in_process_info)
	process_test_expect_image_info_equal(t, &process_info, &in_process_info)

	missing, missing_error := filepath.join({root, "없는 이미지.img"}, context.temp_allocator)
	if !testing.expect(t, missing_error == nil) {return}
	_, direct_missing := validate_image(missing, .In_Process)
	_, helper_missing := validate_image(missing, .Process)
	testing.expect_value(t, helper_missing.code, direct_missing.code)
	testing.expect_value(t, helper_missing.retryable, direct_missing.retryable)
	testing.expect_value(t, helper_missing.outcome, direct_missing.outcome)
}

@(test)
process_adapter_test_validation_rejects_dirty_image_moved_without_companion :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-dirty-move-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "dirty.img")
	if !created {return}
	moved, moved_error := filepath.join({root, "moved.img"}, context.temp_allocator)
	if !testing.expect(t, moved_error == nil) {return}
	session, open_error := open_machine(path, "dirty-move", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)
	payload: [fat32image.SECTOR_BYTES]u8
	copy(payload[:], "dirty image move requires its companion state")
	if !testing.expect(t, device.write(device.ctx, device.sector_count - 1, payload[:])) {
		_ = close(session, .Retain)
		return
	}
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	direct, direct_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, direct_error.code, Error_Code.None) {return}
	testing.expect(t, direct.dirty)
	image_info_destroy(&direct)
	helper, helper_error := validate_image(path, .Process)
	if !testing.expect_value(t, helper_error.code, Error_Code.None) {return}
	testing.expect(t, helper.dirty)
	image_info_destroy(&helper)
	if !testing.expect_value(t, os.rename(path, moved), os.Error(nil)) {return}
	_, direct_mismatch := validate_image(moved, .In_Process)
	_, helper_mismatch := validate_image(moved, .Process)
	testing.expect_value(t, direct_mismatch.code, Error_Code.State_Mismatch)
	testing.expect_value(t, helper_mismatch.code, direct_mismatch.code)
	original_state, original_state_ok := companion_path(path, context.temp_allocator)
	moved_state, moved_state_ok := companion_path(moved, context.temp_allocator)
	if !testing.expect(t, original_state_ok && moved_state_ok) {return}
	if !testing.expect_value(
		t,
		os.rename(original_state, moved_state),
		os.Error(nil),
	) {return}
	moved_info, moved_validation_error := validate_image(moved, .Process)
	if !testing.expect_value(
		t,
		moved_validation_error.code,
		Error_Code.None,
	) {return}
	testing.expect(t, moved_info.dirty)
	image_info_destroy(&moved_info)
	recovered, recovery_error := open_machine(moved, "dirty-move-recover", .Process)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None)
}

@(test)
process_adapter_test_block_trace_matches_in_process :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-trace-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_path_error := filepath.join({root, "in-process.img"}, context.temp_allocator)
	right_path, right_path_error := filepath.join({root, "process.img"}, context.temp_allocator)
	if !testing.expect(t, left_path_error == nil && right_path_error == nil) {return}
	left_info, left_create_error := create_image({path = left_path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, left_create_error.code, Error_Code.None) {return}
	image_info_destroy(&left_info)
	right_info, right_create_error := create_image(
		{path = right_path, capacity_gib = 1},
		.In_Process,
	)
	if !testing.expect_value(t, right_create_error.code, Error_Code.None) {return}
	image_info_destroy(&right_info)
	left, left_open_error := open_machine(left_path, "trace-in-process", .In_Process)
	if !testing.expect_value(t, left_open_error.code, Error_Code.None) {return}
	defer if left != nil {_ = close(left, .Retain)}
	right, right_open_error := open_machine(right_path, "trace-process", .Process)
	if !testing.expect_value(t, right_open_error.code, Error_Code.None) {return}
	defer if right != nil {_ = close(right, .Retain)}
	left_device := block_device(left)
	right_device := block_device(right)
	if !testing.expect_value(t, right_device.sector_count, left_device.sector_count) {return}
	start_lba := left_device.sector_count - u64(MAX_BLOCK_BYTES / fat32image.SECTOR_BYTES)
	payload := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	for &value, index in payload {value = u8(index * 29 + 7)}
	right_impl := (^Process_Implementation)(right.ctx)
	request_before := right_impl.request_id
	testing.expect(t, left_device.write(left_device.ctx, start_lba, payload))
	testing.expect(t, right_device.write(right_device.ctx, start_lba, payload))
	testing.expect_value(t, right_impl.request_id, request_before + 1)
	last_sector: [fat32image.SECTOR_BYTES]u8
	for &value, index in last_sector {value = u8(index * 11 + 3)}
	request_before = right_impl.request_id
	testing.expect(
		t,
		left_device.write(left_device.ctx, left_device.sector_count - 1, last_sector[:]),
	)
	testing.expect(
		t,
		right_device.write(right_device.ctx, right_device.sector_count - 1, last_sector[:]),
	)
	testing.expect_value(t, right_impl.request_id, request_before + 1)
	left_read := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	right_read := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	request_before = right_impl.request_id
	testing.expect(t, left_device.read(left_device.ctx, start_lba, left_read))
	testing.expect(t, right_device.read(right_device.ctx, start_lba, right_read))
	testing.expect_value(t, right_impl.request_id, request_before + 1)
	testing.expect_value(t, string(right_read), string(left_read))
	over_bound := make([]u8, MAX_BLOCK_BYTES + fat32image.SECTOR_BYTES, context.temp_allocator)
	request_before = right_impl.request_id
	testing.expect(t, !right_device.write(right_device.ctx, start_lba, over_bound))
	testing.expect(t, !right_device.read(right_device.ctx, start_lba, over_bound))
	testing.expect_value(t, right_impl.request_id, request_before)
	testing.expect(t, session_ready(right))
	left_barrier, left_barrier_error := barrier(left, .Reset)
	right_barrier, right_barrier_error := barrier(right, .Reset)
	testing.expect_value(t, right_barrier_error.code, left_barrier_error.code)
	testing.expect_value(t, right_barrier, left_barrier)
	testing.expect_value(t, right_barrier.sequence, u64(2))
	testing.expect_value(t, right_barrier.durable_sequence, u64(2))
	left_observation, left_observe_error := observe(left, []Probe{{kind = .Stat, path = ""}})
	defer observation_batch_destroy(&left_observation)
	right_observation, right_observe_error := observe(right, []Probe{{kind = .Stat, path = ""}})
	defer observation_batch_destroy(&right_observation)
	testing.expect_value(t, right_observe_error.code, left_observe_error.code)
	if testing.expect_value(t, len(right_observation.items), len(left_observation.items)) &&
	   len(right_observation.items) == 1 {
		testing.expect_value(t, right_observation.items[0].type, left_observation.items[0].type)
		testing.expect_value(t, right_observation.items[0].size, left_observation.items[0].size)
	}
	testing.expect_value(t, right_observation.barrier, left_observation.barrier)
	testing.expect_value(t, close(left, .Commit).code, Error_Code.None)
	left = nil
	testing.expect_value(t, close(right, .Commit).code, Error_Code.None)
	right = nil
}

@(test)
process_adapter_test_observation_preallocation_bounds_match_in_process :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-observation-bounds-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_created := session_test_image(t, root, "observe-left.img")
	right_path, right_created := session_test_image(t, root, "observe-right.img")
	if !left_created || !right_created {return}
	left, left_error := open_machine(left_path, "observe-bounds-left", .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	defer if left != nil {_ = close(left, .Retain)}
	right, right_error := open_machine(right_path, "observe-bounds-right", .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {return}
	defer if right != nil {_ = close(right, .Retain)}
	process_test_expect_observe_rejected_equally(t, left, right, nil, .Invalid_Argument)
	too_many := make([]Probe, MAX_OBSERVATION_PROBES + 1, context.temp_allocator)
	for &probe in too_many {probe = {
			kind = .Stat,
			path = "",
		}}
	process_test_expect_observe_rejected_equally(t, left, right, too_many, .Frame_Too_Large)
	long_path_data := make([]u8, MAX_OBSERVATION_PATH_BYTES + 1, context.temp_allocator)
	for &value in long_path_data {value = 'A'}
	process_test_expect_observe_rejected_equally(
		t,
		left,
		right,
		[]Probe{{kind = .Stat, path = string(long_path_data)}},
		.Frame_Too_Large,
	)
	process_test_expect_observe_rejected_equally(
		t,
		left,
		right,
		[]Probe {
			{kind = .Read_Range, path = "ONE.BIN", length = MAX_OBSERVATION_BYTES},
			{kind = .Read_Tail, path = "TWO.BIN", length = 1},
		},
		.Frame_Too_Large,
	)
	process_test_expect_observe_rejected_equally(
		t,
		left,
		right,
		[]Probe{{kind = Probe_Kind(255), path = ""}},
		.Invalid_Argument,
	)
	testing.expect(t, session_ready(left))
	testing.expect(t, session_ready(right))
	testing.expect_value(t, close(left, .Commit).code, Error_Code.None)
	left = nil
	testing.expect_value(t, close(right, .Commit).code, Error_Code.None)
	right = nil
}

@(test)
process_adapter_test_observation_pending_has_no_stale_items_in_either_adapter :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-observation-pending-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_created := session_test_image(t, root, "pending-left.img")
	right_path, right_created := session_test_image(t, root, "pending-right.img")
	if !left_created || !right_created {return}
	left, left_error := open_machine(left_path, "pending-left", .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	defer if left != nil {_ = close(left, .Retain)}
	right, right_error := open_machine(right_path, "pending-right", .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {return}
	defer if right != nil {_ = close(right, .Retain)}
	_, left_second_fat, left_sector, left_staged := process_test_stage_fat_mirror_mismatch(
		t,
		left,
	)
	_, right_second_fat, right_sector, right_staged := process_test_stage_fat_mirror_mismatch(
		t,
		right,
	)
	if !left_staged || !right_staged {return}
	probes := []Probe{{kind = .Read_Tail, path = "SETUPLOG.TXT", length = 4096}}
	left_batch, left_observe_error := observe(left, probes)
	defer observation_batch_destroy(&left_batch)
	right_batch, right_observe_error := observe(right, probes)
	defer observation_batch_destroy(&right_batch)
	testing.expect_value(t, left_observe_error.code, Error_Code.None)
	testing.expect_value(t, right_observe_error.code, left_observe_error.code)
	testing.expect(t, left_batch.pending)
	testing.expect_value(t, right_batch.pending, left_batch.pending)
	testing.expect_value(t, left_batch.barrier.materialization, Materialization.Pending)
	testing.expect_value(t, right_batch.barrier, left_batch.barrier)
	testing.expect_value(t, len(left_batch.items), 0)
	testing.expect_value(t, len(right_batch.items), 0)
	left_device := block_device(left)
	right_device := block_device(right)
	testing.expect(t, left_device.write(left_device.ctx, left_second_fat, left_sector[:]))
	testing.expect(t, right_device.write(right_device.ctx, right_second_fat, right_sector[:]))
	testing.expect_value(t, close(left, .Commit).code, Error_Code.None)
	left = nil
	testing.expect_value(t, close(right, .Commit).code, Error_Code.None)
	right = nil
}

@(test)
process_adapter_test_sustained_writes_checkpoint_wal_without_extra_requests :: proc(
	t: ^testing.T,
) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-sustained-wal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "sustained.img")
	if !created {return}
	session, open_error := open_machine(path, "sustained-wal", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	device := block_device(session)
	payload := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	for &value, index in payload {value = u8(index * 31 + 5)}
	lba := device.sector_count - u64(len(payload) / fat32image.SECTOR_BYTES)
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	wal_path, wal_path_error := filepath.join({state_root, WAL_FILE}, context.temp_allocator)
	if !testing.expect(t, wal_path_error == nil) {return}
	record_bytes := i64(MAX_BLOCK_BYTES + WAL_HEADER_BYTES)
	write_count := int(WAL_CHECKPOINT_MAX_BYTES / record_bytes) + 8
	impl := (^Process_Implementation)(session.ctx)
	request_id := impl.request_id
	maximum_acknowledged_wal: i64
	for write_index in 0 ..< write_count {
		payload[0] = u8(write_index)
		if !testing.expect(t, device.write(device.ctx, lba, payload)) {return}
		request_id += 1
		testing.expect_value(t, impl.request_id, request_id)
		info, stat_error := os.stat(wal_path, context.temp_allocator)
		if !testing.expect_value(t, stat_error, os.Error(nil)) {return}
		maximum_acknowledged_wal = max(maximum_acknowledged_wal, info.size)
		os.file_info_delete(info, context.temp_allocator)
	}
	testing.expect(t, maximum_acknowledged_wal < WAL_CHECKPOINT_MAX_BYTES)
	testing.expect_value(t, impl.sequence, u64(write_count))
	testing.expect(t, impl.durable_sequence > 0)
	testing.expect(t, impl.durable_sequence < impl.sequence)
	testing.expect_value(t, close(session, .Commit).code, Error_Code.None)
	session = nil
}

@(test)
process_adapter_test_close_exits_helper_cleanly :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-close-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "close.img")
	if !created {return}
	session, open_error := open_machine(path, "clean-close", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	impl := (^Process_Implementation)(session.ctx)
	close_error := process_close(impl, .Commit)
	if !testing.expect_value(t, close_error.code, Error_Code.None) {return}
	testing.expect(t, process_test_wait(t, impl, 0))
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
	session = nil
}

@(test)
process_adapter_test_orphan_pipe_close_commits_acknowledged_write :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-orphan-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "orphan.img")
	if !created {return}
	session, open_error := open_machine(path, "orphan-first", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	defer if session != nil {_ = close(session, .Retain)}
	device := block_device(session)
	payload: [fat32image.SECTOR_BYTES]u8
	copy(payload[:], "acknowledged data survives parent request-pipe closure")
	lba := device.sector_count - 3
	if !testing.expect(t, device.write(device.ctx, lba, payload[:])) {return}
	impl := (^Process_Implementation)(session.ctx)
	testing.expect_value(t, impl.sequence, u64(1))
	process_test_close_request(impl)
	testing.expect(t, process_test_wait(t, impl, 3))
	impl.closed = true
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
	session = nil
	validated, validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
	testing.expect(t, !validated.dirty)
	image_info_destroy(&validated)
	reopened, reopen_error := open_machine(path, "orphan-second", .In_Process)
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	defer if reopened != nil {_ = close(reopened, .Retain)}
	readback: [fat32image.SECTOR_BYTES]u8
	reopened_device := block_device(reopened)
	testing.expect(t, reopened_device.read(reopened_device.ctx, lba, readback[:]))
	testing.expect_value(t, string(readback[:]), string(payload[:]))
	testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None)
	reopened = nil
}

@(test)
process_adapter_test_live_helper_exit_is_terminal_session_health :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-health-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "health.img")
	if !created {return}
	session, open_error := open_machine(path, "helper-health", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^Process_Implementation)(session.ctx)
	if !testing.expect_value(t, os.process_kill(impl.process), os.Error(nil)) {return}
	health_error, terminal := process_test_wait_terminal(t, session)
	if !terminal {return}
	testing.expect_value(t, health_error.code, Error_Code.Transport_Lost)
	testing.expect_value(t, health_error.outcome, Operation_Outcome.Uncertain)
	testing.expect(t, !session_ready(session))
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
}

@(test)
process_adapter_test_terminal_helper_storage_errors_freeze_parent :: proc(t: ^testing.T) {
	codes := [?]Error_Code{.Wal_IO, .Image_IO, .Protected_Write}
	for code in codes {
		impl := Process_Implementation {
			sequence         = 5,
			durable_sequence = 3,
		}
		err := error_make(code, false, .Uncertain, 7, 6, "terminal helper failure")
		returned := process_helper_fail(&impl, {.Error, .Terminal}, err)
		testing.expect_value(t, returned.code, code)
		testing.expect(t, impl.frozen)
		testing.expect_value(t, impl.last_error.code, code)
		testing.expect_value(t, impl.sequence, u64(7))
		testing.expect_value(t, impl.durable_sequence, u64(6))
	}
	impl := Process_Implementation {
		sequence         = 9,
		durable_sequence = 8,
	}
	pending := error_make(.Observation_Pending, true, .Retained, 9, 8, "pending")
	returned := process_helper_fail(&impl, {.Error}, pending)
	testing.expect_value(t, returned.code, Error_Code.Observation_Pending)
	testing.expect(t, !impl.frozen)
}

@(test)
process_adapter_test_protected_write_freezes_parent_with_helper_error :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-protected-terminal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "protected-terminal.img")
	if !created {return}
	session, open_error := open_machine(path, "protected-terminal", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	device := block_device(session)
	mbr: [fat32image.SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, 0, mbr[:])) {return}
	mbr[446] = mbr[446] ~ 0x80
	testing.expect(t, !device.write(device.ctx, 0, mbr[:]))
	terminal_error, terminal := session_terminal_error(session)
	testing.expect(t, terminal)
	testing.expect_value(t, terminal_error.code, Error_Code.Protected_Write)
	testing.expect(t, !session_ready(session))
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	recovered, recovery_error := open_machine(path, "protected-recovery", .Process)
	if !testing.expect_value(t, recovery_error.code, Error_Code.None) {return}
	testing.expect_value(t, close(recovered, .Commit).code, Error_Code.None)
}

@(test)
process_adapter_test_dirty_image_without_active_wal_is_never_recreated :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-missing-wal-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "missing-wal.img")
	if !created {return}
	session, open_error := open_machine(path, "missing-wal-first", .Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, close(session, .Retain).code, Error_Code.None) {return}
	state_root, state_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, state_ok) {return}
	wal_path, path_error := filepath.join({state_root, WAL_FILE}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	if !testing.expect_value(t, os.remove(wal_path), os.Error(nil)) {return}

	_, validation_error := validate_image(path, .Process)
	testing.expect_value(t, validation_error.code, Error_Code.State_Mismatch)
	reopened, reopen_error := open_machine(path, "missing-wal-second", .Process)
	testing.expect(t, reopened == nil)
	testing.expect_value(t, reopen_error.code, Error_Code.State_Mismatch)
	testing.expect(t, !os.exists(wal_path))
	info, image_error := fat32image.validate(path)
	if !testing.expect_value(t, image_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&info)
	testing.expect(t, info.dirty)
}

@(test)
process_adapter_test_every_machine_crash_phase_recovers_in_subprocess :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-crash-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	phases := [?]Crash_Phase {
		.Wal_Appended,
		.Image_Applied,
		.Image_Synced,
		.Checkpoint_Saved,
		.Wal_Truncated,
		.State_Clean,
	}
	for phase, index in phases {
		path, created := session_test_image(t, root, fmt.tprintf("crash-%d.img", index))
		if !created {return}
		session, open_error := open_process_configured(
			path,
			fmt.tprintf("crash-first-%d", index),
			crash_phase_name(phase),
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
		device := block_device(session)
		payload: [fat32image.SECTOR_BYTES]u8
		for &value, byte_index in payload {
			value = u8(index * 31 + byte_index * 7 + 3)
		}
		lba := device.sector_count - 1
		write_acknowledged := device.write(device.ctx, lba, payload[:])
		if phase == .Wal_Appended || phase == .Image_Applied {
			if !testing.expect(t, !write_acknowledged) {return}
		} else {
			if !testing.expect(t, write_acknowledged) {return}
			close_error := close(session, .Commit)
			if !testing.expect_value(t, close_error.code, Error_Code.Transport_Lost) {return}
		}
		health_error, terminal := process_test_wait_terminal(t, session)
		if !terminal {return}
		testing.expect_value(t, health_error.code, Error_Code.Transport_Lost)
		testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
		reopened, reopen_error := open_machine(
			path,
			fmt.tprintf("crash-second-%d", index),
			.Process,
		)
		if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
		readback: [fat32image.SECTOR_BYTES]u8
		reopened_device := block_device(reopened)
		testing.expect(t, reopened_device.read(reopened_device.ctx, lba, readback[:]))
		testing.expect_value(t, readback, payload)
		if !testing.expect_value(t, close(reopened, .Commit).code, Error_Code.None) {return}
		state_root, state_ok := companion_path(path, context.temp_allocator)
		testing.expect(t, state_ok && !os.exists(state_root))
		validated, validation_error := validate_image(path, .In_Process)
		if !testing.expect_value(t, validation_error.code, Error_Code.None) {return}
		testing.expect(t, !validated.dirty)
		image_info_destroy(&validated)
	}
}

@(test)
process_adapter_test_protocol_fragmented_and_incomplete_pipe_io :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-fragment-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	impl, launched := process_test_launch(t)
	if !launched {return}
	defer process_destroy(impl)
	payload_text, path_error := filepath.join(
		{root, "분할", "없는 이미지.img"},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	payload := transmute([]u8)payload_text
	header := process_test_header(.Validate, 1, payload)
	testing.expect(t, process_test_write_fragmented(impl.request, header[:]))
	testing.expect(t, process_test_write_fragmented(impl.request, payload))
	response, response_error := protocol_read_frame(impl.response, context.temp_allocator)
	if !testing.expect_value(t, response_error.code, Error_Code.None) {return}
	defer protocol_frame_destroy(&response, context.temp_allocator)
	testing.expect(t, .Error in response.flags)
	testing.expect_value(t, protocol_error_decode(response.payload).code, Error_Code.Image_Missing)
	shutdown_error := protocol_write_frame(
		impl.request,
		Protocol_Frame{kind = u16(Protocol_Kind.Shutdown), request_id = 2},
	)
	if !testing.expect_value(t, shutdown_error.code, Error_Code.None) {return}
	shutdown, shutdown_read_error := protocol_read_frame(impl.response, context.temp_allocator)
	if !testing.expect_value(t, shutdown_read_error.code, Error_Code.None) {return}
	protocol_frame_destroy(&shutdown, context.temp_allocator)
	testing.expect(t, process_test_wait(t, impl, 0))

	incomplete, incomplete_launched := process_test_launch(t)
	if !incomplete_launched {return}
	defer process_destroy(incomplete)
	incomplete_payload: [8]u8
	incomplete_header := process_test_header(.Validate, 1, incomplete_payload[:])
	testing.expect(t, protocol_write_exact(incomplete.request, incomplete_header[:]))
	testing.expect(t, protocol_write_exact(incomplete.request, incomplete_payload[:3]))
	process_test_close_request(incomplete)
	testing.expect(t, process_test_wait(t, incomplete, 3))
}

@(test)
process_adapter_test_protocol_version_length_and_request_order :: proc(t: ^testing.T) {
	wrong_version, version_launched := process_test_launch(t)
	if !version_launched {return}
	defer process_destroy(wrong_version)
	version_header := process_test_header(.Shutdown, 1, nil)
	put_u16le(version_header[:], 4, PROTOCOL_VERSION + 1)
	put_u32le(version_header[:], 12, 0)
	put_u32le(version_header[:], 12, protocol_frame_checksum(version_header[:], nil))
	testing.expect(t, protocol_write_exact(wrong_version.request, version_header[:]))
	testing.expect(t, process_test_wait(t, wrong_version, 3))

	bad_length, length_launched := process_test_launch(t)
	if !length_launched {return}
	defer process_destroy(bad_length)
	length_header := process_test_header(.Write, 1, nil)
	put_u32le(length_header[:], 8, PROTOCOL_MAX_PAYLOAD + 1)
	put_u32le(length_header[:], 12, 0)
	put_u32le(length_header[:], 12, protocol_frame_checksum(length_header[:], nil))
	testing.expect(t, protocol_write_exact(bad_length.request, length_header[:]))
	testing.expect(t, process_test_wait(t, bad_length, 3))

	bad_order, order_launched := process_test_launch(t)
	if !order_launched {return}
	defer process_destroy(bad_order)
	order_write_error := protocol_write_frame(
		bad_order.request,
		Protocol_Frame{kind = u16(Protocol_Kind.Shutdown), request_id = 2},
	)
	if !testing.expect_value(t, order_write_error.code, Error_Code.None) {return}
	order_response, order_read_error := protocol_read_frame(
		bad_order.response,
		context.temp_allocator,
	)
	if !testing.expect_value(t, order_read_error.code, Error_Code.None) {return}
	defer protocol_frame_destroy(&order_response, context.temp_allocator)
	testing.expect_value(t, order_response.request_id, u64(2))
	testing.expect_value(
		t,
		order_response.kind,
		u16(Protocol_Kind.Shutdown) | PROTOCOL_RESPONSE_BIT,
	)
	testing.expect(t, .Error in order_response.flags)
	testing.expect_value(
		t,
		protocol_error_decode(order_response.payload).code,
		Error_Code.Protocol_Order,
	)
	testing.expect(t, process_test_wait(t, bad_order, 4))
}

@(test)
process_adapter_test_invalid_machine_enums_have_no_server_side_effects :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-invalid-enum-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "machine.img")
	if !created {return}
	impl, launched := process_test_launch(t)
	if !launched {return}
	defer process_destroy(impl)

	session_id := "invalid-enum-session"
	open_payload := make(
		[]u8,
		8 + len(path) + len(session_id),
		context.temp_allocator,
	)
	put_u32le(open_payload, 0, u32(len(path)))
	put_u32le(open_payload, 4, u32(len(session_id)))
	copy(open_payload[8:], transmute([]u8)path)
	copy(open_payload[8 + len(path):], transmute([]u8)session_id)
	open_error := protocol_write_frame(
		impl.request,
		Protocol_Frame {
			kind       = u16(Protocol_Kind.Open_Machine),
			request_id = 1,
			payload    = open_payload,
		},
	)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	opened, opened_error := protocol_read_frame(impl.response, context.temp_allocator)
	if !testing.expect_value(t, opened_error.code, Error_Code.None) {return}
	if !testing.expect(t, .Error not_in opened.flags) {
		protocol_frame_destroy(&opened, context.temp_allocator)
		return
	}
	protocol_frame_destroy(&opened, context.temp_allocator)

	invalid_requests := [?]struct {
		kind: Protocol_Kind,
		value: u8,
	}{
		{.Barrier, u8(Barrier_Reason.Clean_Close) + 1},
		{.Close, u8(Close_Mode.Retain) + 1},
	}
	for request, index in invalid_requests {
		request_error := protocol_write_frame(
			impl.request,
			Protocol_Frame {
				kind       = u16(request.kind),
				request_id = u64(index + 2),
				payload    = []u8{request.value},
			},
		)
		if !testing.expect_value(t, request_error.code, Error_Code.None) {return}
		response, response_error := protocol_read_frame(
			impl.response,
			context.temp_allocator,
		)
		if !testing.expect_value(t, response_error.code, Error_Code.None) {return}
		if !testing.expect(t, .Error in response.flags) {
			protocol_frame_destroy(&response, context.temp_allocator)
			return
		}
		err := protocol_error_decode(response.payload)
		protocol_frame_destroy(&response, context.temp_allocator)
		testing.expect_value(t, err.code, Error_Code.Protocol_Malformed)
		testing.expect_value(t, err.outcome, Operation_Outcome.Not_Started)
	}

	barrier_error := protocol_write_frame(
		impl.request,
		Protocol_Frame {
			kind       = u16(Protocol_Kind.Barrier),
			request_id = 4,
			payload    = []u8{u8(Barrier_Reason.Block_Flush)},
		},
	)
	if !testing.expect_value(t, barrier_error.code, Error_Code.None) {return}
	barrier_response, barrier_read_error := protocol_read_frame(
		impl.response,
		context.temp_allocator,
	)
	if !testing.expect_value(t, barrier_read_error.code, Error_Code.None) {return}
	if !testing.expect(t, .Error not_in barrier_response.flags) {
		protocol_frame_destroy(&barrier_response, context.temp_allocator)
		return
	}
	_, barrier_valid := protocol_barrier_decode(barrier_response.payload)
	protocol_frame_destroy(&barrier_response, context.temp_allocator)
	if !testing.expect(t, barrier_valid) {return}

	close_error := protocol_write_frame(
		impl.request,
		Protocol_Frame {
			kind       = u16(Protocol_Kind.Close),
			request_id = 5,
			payload    = []u8{u8(Close_Mode.Retain)},
		},
	)
	if !testing.expect_value(t, close_error.code, Error_Code.None) {return}
	close_response, close_read_error := protocol_read_frame(
		impl.response,
		context.temp_allocator,
	)
	if !testing.expect_value(t, close_read_error.code, Error_Code.None) {return}
	testing.expect(t, .Error not_in close_response.flags)
	protocol_frame_destroy(&close_response, context.temp_allocator)
	testing.expect(t, process_test_wait(t, impl, 0))
}
