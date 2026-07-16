// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "core:time"

FAT32_PERFORMANCE_GATE :: #config(FAT32_PERFORMANCE_GATE, false)
PERFORMANCE_REPETITIONS :: 21
PERFORMANCE_WRITES_PER_TRACE :: 5

@(private = "file")
performance_image :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return "", false}
	info, create_error := create_image({path = path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, create_error.code, Error_Code.None) {return "", false}
	image_info_destroy(&info)
	return path, true
}

@(private = "file")
Performance_Timing :: struct {
	write: u64,
	read:  u64,
	total: u64,
}

@(private = "file")
performance_command_pair :: proc(
	session: ^Machine_Session,
	lba: u64,
	payload, readback: []u8,
	round: int,
) -> Performance_Timing {
	device := block_device(session)
	if device.ctx == nil {return {write = max(u64), read = max(u64), total = max(u64)}}
	payload[round % len(payload)] ~= u8(round * 17 + 3)
	total_start := time.tick_now()
	write_start := total_start
	for write_index in 0 ..< PERFORMANCE_WRITES_PER_TRACE {
		payload[(round + write_index * 4093) % len(payload)] ~= u8(write_index * 31 + 11)
		if !device.write(device.ctx, lba, payload) {
			return {write = max(u64), read = max(u64), total = max(u64)}
		}
	}
	write_time := u64(time.tick_since(write_start))
	read_start := time.tick_now()
	if !device.read(device.ctx, lba, readback) {
		return {write = max(u64), read = max(u64), total = max(u64)}
	}
	return {
		write = write_time,
		read = u64(time.tick_since(read_start)),
		total = u64(time.tick_since(total_start)),
	}
}

@(test)
process_adapter_test_paired_command_trace_regression_gate :: proc(t: ^testing.T) {
	if !FAT32_PERFORMANCE_GATE {return}
	context.allocator = context.temp_allocator
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-process-performance-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	left_path, left_created := performance_image(t, root, "in-process.img")
	right_path, right_created := performance_image(t, root, "process.img")
	if !left_created || !right_created {return}
	left, left_error := open_machine(left_path, "performance-in-process", .In_Process)
	if !testing.expect_value(t, left_error.code, Error_Code.None) {return}
	defer if left != nil {_ = close(left, .Retain)}
	right, right_error := open_machine(right_path, "performance-process", .Process)
	if !testing.expect_value(t, right_error.code, Error_Code.None) {return}
	defer if right != nil {_ = close(right, .Retain)}
	left_device := block_device(left)
	right_device := block_device(right)
	if !testing.expect_value(t, right_device.sector_count, left_device.sector_count) {return}
	sectors := u64(MAX_BLOCK_BYTES / fat32image.SECTOR_BYTES)
	lba := left_device.sector_count - sectors
	left_payload := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	right_payload := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	left_read := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	right_read := make([]u8, MAX_BLOCK_BYTES, context.temp_allocator)
	for &value, index in left_payload {value = u8(index * 29 + 7)}
	copy(right_payload, left_payload)
	left_times: [PERFORMANCE_REPETITIONS]u64
	right_times: [PERFORMANCE_REPETITIONS]u64
	left_writes, right_writes: [PERFORMANCE_REPETITIONS]u64
	left_reads, right_reads: [PERFORMANCE_REPETITIONS]u64
	for round in 0 ..< PERFORMANCE_REPETITIONS {
		left_timing, right_timing: Performance_Timing
		if round & 1 == 0 {
			left_timing = performance_command_pair(left, lba, left_payload, left_read, round)
			right_timing = performance_command_pair(right, lba, right_payload, right_read, round)
		} else {
			right_timing = performance_command_pair(right, lba, right_payload, right_read, round)
			left_timing = performance_command_pair(left, lba, left_payload, left_read, round)
		}
		left_times[round] = left_timing.total
		right_times[round] = right_timing.total
		left_writes[round] = left_timing.write
		right_writes[round] = right_timing.write
		left_reads[round] = left_timing.read
		right_reads[round] = right_timing.read
		if !testing.expect_value(t, string(right_read), string(left_read)) {return}
	}
	slice.sort(left_times[:])
	slice.sort(right_times[:])
	slice.sort(left_writes[:])
	slice.sort(right_writes[:])
	slice.sort(left_reads[:])
	slice.sort(right_reads[:])
	left_median := left_times[PERFORMANCE_REPETITIONS / 2]
	right_median := right_times[PERFORMANCE_REPETITIONS / 2]
	fmt.printfln(
		"FAT32 paired five-write/one-read 128 KiB trace median: in-process=%d ns process=%d ns (writes %d/%d, read %d/%d)",
		left_median,
		right_median,
		left_writes[PERFORMANCE_REPETITIONS / 2],
		right_writes[PERFORMANCE_REPETITIONS / 2],
		left_reads[PERFORMANCE_REPETITIONS / 2],
		right_reads[PERFORMANCE_REPETITIONS / 2],
	)
	if !testing.expect(t, left_median != max(u64) && right_median != max(u64)) {return}
	testing.expectf(
		t,
		right_median * 100 <= left_median * 110,
		"Process Adapter median %d ns exceeds the in-process median %d ns by more than 10%%",
		right_median,
		left_median,
	)
	if testing.expect_value(t, close(left, .Commit).code, Error_Code.None) {left = nil}
	if testing.expect_value(t, close(right, .Commit).code, Error_Code.None) {right = nil}
}
