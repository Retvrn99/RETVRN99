// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "core:os"
import "machine"

console_input_apply :: proc(
	m: ^machine.Machine,
	action: acceptance.Input_Action,
	reset_count: u32,
	phase_ms: i64,
) {
	fmt.printfln(
		"input script: %v reset=%d phase=%dms",
		action.kind,
		reset_count,
		phase_ms,
	)
	switch action.kind {
	case .Key, .Key_While_Setup_Page:
		keys := action.key
		before := machine.i8042_diagnostics(&m.platform.kbd)
		if !machine.machine_key_sequence(m, keys[:int(action.key_n)]) {
			fmt.eprintln("input script: keyboard schedule is full")
		} else {
			after := machine.i8042_diagnostics(&m.platform.kbd)
			fmt.printfln(
				"input script: keyboard scanning=%t set=%d command=%02x output=%t queued=%d scheduled=%d->%d",
				before.keyboard_scanning,
				before.keyboard_scan_set,
				before.command_byte,
				before.output_full,
				before.keyboard_queued,
				before.scheduled_key_bytes,
				after.scheduled_key_bytes,
			)
		}
	case .Mouse_Move, .Mouse_Buttons:
		machine.machine_mouse(m, action.dx, action.dy, action.buttons)
	case .Mouse_Wheel:
		machine.machine_mouse_wheel(m, action.wheel, action.buttons)
	case .Snapshot:
		console_dump_frame(action.path, machine.machine_display_frame(m))
	case .Memory_Snapshot:
		if err := os.write_entire_file(action.path, m.vm.ram); err != nil {
			fmt.eprintfln("input script: cannot write memory snapshot %s", action.path)
		}
	case .Dump_State:
		dump_state(m)
	case .Reset:
		machine.machine_reset_control_write(m, 0xCF9, 1, 0x06)
	case .Wait_Frame, .Wait_Stable, .Wait_Change, .Wait_Memory, .Wait_Setup_Page:
		unreachable()
	}
}
