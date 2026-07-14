// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "profile"
import "vga"

@(test)
console_acceptance_test_reset_history_owns_bounded_reasons :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	result: acceptance.Result
	reason := strings.clone("guest reset")
	console_result_record_reset(&result, reason)
	bytes := transmute([]u8)reason
	bytes[0] = 'X'
	testing.expect_value(t, result.reset_history[0], "guest reset")
	for _ in 0 ..< acceptance.RESULT_MAX_RESETS + 4 {
		console_result_record_reset(&result, "more")
	}
	testing.expect_value(t, result.reset_count, u64(acceptance.RESULT_MAX_RESETS + 5))
	testing.expect_value(t, result.reset_history_count, acceptance.RESULT_MAX_RESETS)
	delete(reason)
	console_result_destroy(&result)
}

@(test)
console_acceptance_test_artifact_setup_logs_are_bounded_and_path_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_console_artifact_*", context.temp_allocator)
	defer os.remove_all(dir)
	windows, _ := filepath.join({dir, "WINDOWS"})
	testing.expect(t, os.make_directory_all(windows) == nil)
	log_path, _ := filepath.join({windows, "SETUPLOG.TXT"})
	payload := make([]u8, CONSOLE_ARTIFACT_LOG_BYTES + 4096, context.temp_allocator)
	for &byte in payload {byte = 'x'}
	testing.expect(t, os.write_entire_file(log_path, payload) == nil)
	paths := profile.Paths{c_drive = dir}
	result := acceptance.Result{
		stop_reason = .Strict_IO_Failure,
		exit_code = 2,
		unclassified_io = 3,
		unclassified_mmio = 4,
	}
	diagnostics := console_artifact_diagnostics(&result, nil, "firmware-tail", &paths)
	defer delete(diagnostics)
	testing.expect(t, strings.contains(diagnostics, "unclassified=3 mmio=4"))
	testing.expect(t, strings.contains(diagnostics, "setup-log C:\\WINDOWS\\SETUPLOG.TXT"))
	testing.expect(t, strings.contains(diagnostics, "last 32768 of 36864 bytes"))
	testing.expect(t, strings.contains(diagnostics, "firmware-tail"))
	testing.expect(t, !strings.contains(diagnostics, dir))
	testing.expect(t, len(diagnostics) < CONSOLE_ARTIFACT_LOG_BYTES + 2048)
}

@(test)
console_acceptance_test_configuration_failure_writes_requested_outputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_console_config_*", context.temp_allocator)
	defer os.remove_all(dir)
	result_path, _ := filepath.join({dir, "result.json"})
	artifacts, _ := filepath.join({dir, "artifacts"})
	options := acceptance.Options{result_json = result_path, artifacts = artifacts}
	testing.expect_value(
		t,
		console_acceptance_configuration_error(&options, nil, .GSW_886, "isolated failure"),
		1,
	)
	result_data, result_error := os.read_entire_file(result_path, context.temp_allocator)
	testing.expect(t, result_error == nil)
	testing.expect(t, strings.contains(string(result_data), `"stop_reason": "configuration_error"`))
	diagnostics_path, _ := filepath.join({artifacts, "diagnostics.txt"})
	diagnostics, diagnostics_error := os.read_entire_file(diagnostics_path, context.temp_allocator)
	testing.expect(t, diagnostics_error == nil)
	testing.expect(t, strings.contains(string(diagnostics), "configuration=isolated failure"))
}

@(test)
console_acceptance_test_periodic_frame_change_is_not_guest_activity :: proc(t: ^testing.T) {
	previous: u64
	frame := vga.Display_Frame{
		content_generation = 10,
		guest_activity_generation = 4,
	}
	testing.expect(t, !console_acceptance_observe_display_activity(&previous, &frame))
	testing.expect_value(t, previous, u64(4))
	frame.content_generation += 1
	testing.expect(t, !console_acceptance_observe_display_activity(&previous, &frame))
	frame.guest_activity_generation += 1
	testing.expect(t, console_acceptance_observe_display_activity(&previous, &frame))
}
