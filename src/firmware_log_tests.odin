// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:strings"
import "core:testing"

Firmware_Test_Output :: struct {
	lines: [dynamic]string,
}

firmware_test_emit :: proc(ctx: rawptr, line: string) {
	out := (^Firmware_Test_Output)(ctx)
	append(&out.lines, strings.clone(line))
}

firmware_test_output_destroy :: proc(out: ^Firmware_Test_Output) {
	for line in out.lines {delete(line)}
	delete(out.lines)
	out^ = {}
}

firmware_test_bytes :: proc(value: string) -> []u8 {
	return transmute([]u8)value
}

@(test)
firmware_log_test_collapses_complete_duplicate_lines :: proc(t: ^testing.T) {
	log: Firmware_Log
	out: Firmware_Test_Output
	defer firmware_log_destroy(&log)
	defer firmware_test_output_destroy(&out)

	firmware_log_consume(&log, firmware_test_bytes("same\r\nsa"), &out, firmware_test_emit)
	firmware_log_consume(&log, firmware_test_bytes("me\nsame\n"), &out, firmware_test_emit)
	testing.expect_value(t, len(out.lines), 1)
	testing.expect_value(t, out.lines[0], "same")

	firmware_log_consume(&log, firmware_test_bytes("next\n"), &out, firmware_test_emit)
	testing.expect_value(t, len(out.lines), 3)
	testing.expect_value(t, out.lines[1], "last firmware line repeated 2 additional times")
	testing.expect_value(t, out.lines[2], "next")
}

@(test)
firmware_log_test_flushes_partial_line_and_repeat_count :: proc(t: ^testing.T) {
	log: Firmware_Log
	out: Firmware_Test_Output
	defer firmware_log_destroy(&log)
	defer firmware_test_output_destroy(&out)

	firmware_log_consume(&log, firmware_test_bytes("tail\ntail\ntail"), &out, firmware_test_emit)
	testing.expect_value(t, len(out.lines), 1)
	firmware_log_flush(&log, &out, firmware_test_emit)
	testing.expect_value(t, len(out.lines), 2)
	testing.expect_value(t, out.lines[0], "tail")
	testing.expect_value(t, out.lines[1], "last firmware line repeated 2 additional times")

	firmware_log_consume(&log, firmware_test_bytes("tail\n"), &out, firmware_test_emit)
	testing.expect_value(t, len(out.lines), 3)
	testing.expect_value(t, out.lines[2], "tail")
}

@(test)
firmware_log_test_duplicate_run_has_bounded_output :: proc(t: ^testing.T) {
	log: Firmware_Log
	out: Firmware_Test_Output
	defer firmware_log_destroy(&log)
	defer firmware_test_output_destroy(&out)

	for _ in 0 ..< 4096 {
		firmware_log_consume(&log, firmware_test_bytes("fault\n"), &out, firmware_test_emit)
	}
	testing.expect_value(t, len(out.lines), 1)
	testing.expect_value(t, log.repetitions, u64(4095))
}

@(test)
firmware_log_test_device_log_owns_and_bounds_lines :: proc(t: ^testing.T) {
	shared: Shared
	defer vm_log_destroy(&shared)

	source := make([]u8, len("owned"))
	defer delete(source)
	copy(source, "owned")
	vm_log(&shared, string(source))
	source[0] = 'X'
	testing.expect_value(t, shared.log_lines[0], "owned")

	for i in 0 ..< MAX_LOG_LINES + 5 {
		vm_log(&shared, fmt.tprintf("line-%d", i))
	}
	testing.expect_value(t, len(shared.log_lines), MAX_LOG_LINES)
	testing.expect_value(t, shared.log_lines[0], "line-5")
	testing.expect_value(
		t,
		shared.log_lines[len(shared.log_lines) - 1],
		fmt.tprintf("line-%d", MAX_LOG_LINES + 4),
	)
}
