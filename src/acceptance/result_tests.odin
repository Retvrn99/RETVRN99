// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:encoding/json"

Result_Test_Disk :: struct {
	stop_reason: string `json:"stop_reason"`,
}

@(test)
acceptance_result_test_round_trip_shape_is_bounded_and_path_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, temp_error := os.temp_directory(context.temp_allocator)
	testing.expect(t, temp_error == nil)
	dir, directory_error := os.make_directory_temp(base, "retvrn99_result_*", context.temp_allocator)
	testing.expect(t, directory_error == nil)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "nested", "result.json"})
	result := Result {
		stop_reason = .Test_Exit,
		exit_code = 0,
		test_exit_code = 7,
		master_ticks = 6600,
		wall_milliseconds = 2,
		cpu_mode = "GSW-886",
		reset_count = 1,
		irq_injections = 42,
		dma_units = 9,
		modeled_io = 100,
		passive_io = 3,
		unclassified_io = 0,
		unclassified_mmio = 2,
		frame_crc = 0x12345678,
		installation_milestone = "first_reboot",
	}
	result.reset_history[0] = "guest_reset"
	result.reset_history_count = 1
	result.workload_hashes[0] = {
		name = "doom-shareware",
		sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	}
	result.workload_hash_count = 1
	testing.expect_value(t, result_save(path, &result), Result_Diagnostic.None)
	result.wall_milliseconds = 3
	testing.expect_value(t, result_save(path, &result), Result_Diagnostic.None)
	payload, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	text := string(payload)
	testing.expect(t, len(payload) <= RESULT_MAX_BYTES)
	testing.expect(t, strings.contains(text, `"stop_reason": "test_exit"`))
	testing.expect(t, strings.contains(text, `"installation_milestone": "first_reboot"`))
	testing.expect(t, strings.contains(text, `"unclassified_mmio": 2`))
	testing.expect(t, strings.contains(text, `"scheduler_dispatches": 0`))
	testing.expect(t, !strings.contains(text, "WIN98SE.ISO"))
	disk: Result_Test_Disk
	testing.expect(t, json.unmarshal(payload, &disk) == nil)
	testing.expect_value(t, disk.stop_reason, "test_exit")
}

@(test)
acceptance_result_test_counts_and_labels_are_clamped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_result_bound_*", context.temp_allocator)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "result.json"})
	long := "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxééé"
	result := Result{stop_reason = .Timeout, cpu_mode = long}
	result.reset_history_count = 999
	result.workload_hash_count = 999
	for i in 0 ..< RESULT_MAX_RESETS {result.reset_history[i] = long}
	for i in 0 ..< RESULT_MAX_HASHES {
		result.workload_hashes[i] = {
			name = long,
			sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		}
	}
	testing.expect_value(t, result_save(path, &result), Result_Diagnostic.None)
	payload, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, len(payload) <= RESULT_MAX_BYTES)
	testing.expect(t, !strings.contains(string(payload), long))
	disk: Result_Test_Disk
	testing.expect(t, json.unmarshal(payload, &disk) == nil)
}

@(test)
acceptance_result_test_rejects_invalid_workload_identity :: proc(t: ^testing.T) {
	result := Result{workload_hash_count = 1}
	result.workload_hashes[0] = {name = "doom", sha256 = "abcd"}
	testing.expect_value(t, result_save("result.json", &result), Result_Diagnostic.Invalid_Data)
}
