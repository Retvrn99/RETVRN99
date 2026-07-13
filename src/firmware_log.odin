// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:strings"
import "machine"

Firmware_Log :: struct {
	raw:         [dynamic]u8,
	partial:     [dynamic]u8,
	last_line:   string,
	has_last:    bool,
	repetitions: u64,
}

firmware_log_destroy :: proc(log: ^Firmware_Log) {
	delete(log.raw)
	delete(log.partial)
	delete(log.last_line)
	log^ = {}
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
	fmt.printfln("seabios: %s", line)
	shared := (^Shared)(ctx)
	if shared != nil {vm_log(shared, fmt.tprintf("seabios: %s", line))}
}

firmware_log_drain :: proc(log: ^Firmware_Log, m: ^machine.Machine, shared: ^Shared) {
	clear(&log.raw)
	machine.machine_drain_dbg(m, &log.raw)
	firmware_log_consume(log, log.raw[:], shared, firmware_log_host_emit)
}

firmware_log_host_flush :: proc(log: ^Firmware_Log, shared: ^Shared) {
	firmware_log_flush(log, shared, firmware_log_host_emit)
}
