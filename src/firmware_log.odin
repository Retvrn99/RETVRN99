// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:strings"
import "machine"

FIRMWARE_HISTORY_LINES :: 256

Firmware_Log :: struct {
	raw:         [dynamic]u8,
	partial:     [dynamic]u8,
	last_line:   string,
	has_last:    bool,
	repetitions: u64,
	live_stdout: bool,
	history:     [FIRMWARE_HISTORY_LINES]string,
	history_count: u64,
}

Firmware_Emit_Context :: struct {
	shared: ^Shared,
	live_stdout: bool,
	log: ^Firmware_Log,
}

firmware_log_destroy :: proc(log: ^Firmware_Log) {
	delete(log.raw)
	delete(log.partial)
	delete(log.last_line)
	for line in log.history {delete(line)}
	log^ = {}
}

firmware_log_record :: proc(log: ^Firmware_Log, line: string) {
	if log == nil {return}
	index := int(log.history_count % FIRMWARE_HISTORY_LINES)
	delete(log.history[index])
	log.history[index] = strings.clone(line)
	log.history_count += 1
}

firmware_log_recent :: proc(log: ^Firmware_Log, maximum_lines := FIRMWARE_HISTORY_LINES) -> string {
	if log == nil || maximum_lines <= 0 {return ""}
	count := int(min(log.history_count, u64(FIRMWARE_HISTORY_LINES)))
	count = min(count, maximum_lines)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	start := log.history_count - u64(count)
	for i in 0 ..< count {
		index := int((start + u64(i)) % FIRMWARE_HISTORY_LINES)
		strings.write_string(&b, log.history[index])
		strings.write_byte(&b, '\n')
	}
	return strings.clone(strings.to_string(b))
}

firmware_log_emit_repetitions :: proc(
	log: ^Firmware_Log,
	ctx: rawptr,
	emit: proc(ctx: rawptr, line: string),
) {
	if log.repetitions == 0 {return}
	emit(ctx, fmt.tprintf("last firmware line repeated %d additional times", log.repetitions))
	log.repetitions = 0
}

firmware_log_complete_line :: proc(
	log: ^Firmware_Log,
	line: string,
	ctx: rawptr,
	emit: proc(ctx: rawptr, line: string),
) {
	if log.has_last && line == log.last_line {
		log.repetitions += 1
		return
	}
	firmware_log_emit_repetitions(log, ctx, emit)
	delete(log.last_line)
	log.last_line = strings.clone(line)
	log.has_last = true
	emit(ctx, line)
}

firmware_log_consume :: proc(
	log: ^Firmware_Log,
	bytes: []u8,
	ctx: rawptr,
	emit: proc(ctx: rawptr, line: string),
) {
	for ch in bytes {
		switch ch {
		case '\n':
			firmware_log_complete_line(log, string(log.partial[:]), ctx, emit)
			clear(&log.partial)
		case '\r':
		case:
			append(&log.partial, ch)
		}
	}
}

firmware_log_flush :: proc(
	log: ^Firmware_Log,
	ctx: rawptr,
	emit: proc(ctx: rawptr, line: string),
) {
	if len(log.partial) > 0 {
		firmware_log_complete_line(log, string(log.partial[:]), ctx, emit)
		clear(&log.partial)
	}
	firmware_log_emit_repetitions(log, ctx, emit)
	delete(log.last_line)
	log.last_line = ""
	log.has_last = false
}

firmware_log_host_emit :: proc(ctx: rawptr, line: string) {
	emit := (^Firmware_Emit_Context)(ctx)
	firmware_log_record(emit.log, line)
	if emit.live_stdout {fmt.printfln("seabios: %s", line)}
	if emit.shared != nil {vm_log(emit.shared, fmt.tprintf("seabios: %s", line))}
}

firmware_log_drain :: proc(log: ^Firmware_Log, m: ^machine.Machine, shared: ^Shared) {
	clear(&log.raw)
	machine.machine_drain_dbg(m, &log.raw)
	emit := Firmware_Emit_Context{shared = shared, live_stdout = log.live_stdout, log = log}
	firmware_log_consume(log, log.raw[:], &emit, firmware_log_host_emit)
}

firmware_log_host_flush :: proc(log: ^Firmware_Log, shared: ^Shared) {
	emit := Firmware_Emit_Context{shared = shared, live_stdout = log.live_stdout, log = log}
	firmware_log_flush(log, &emit, firmware_log_host_emit)
}
