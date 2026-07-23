// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:os"
import "core:time"

RETVRN99_TEST_CONTROL :: #config(RETVRN99_TEST_CONTROL, false)
INPUT_CONTROL_MAX_FILE_BYTES :: 64 * 1024
INPUT_CONTROL_MAX_ACTIONS :: 4096
INPUT_CONTROL_MAX_DURATION_MS :: i64(15 * 60 * 1000)
INPUT_CONTROL_ACTIONS_PER_TICK :: 64
INPUT_CONTROL_MOUSE_DELTA_LIMIT :: i32(32767)
INPUT_CONTROL_WHEEL_LIMIT :: i32(127)

Input_Control_Diagnostic :: enum u8 {
	None,
	Read_Failed,
	Unsafe_File,
	File_Too_Large,
	Invalid_Script,
	Empty_Script,
	Too_Many_Actions,
	Duration_Too_Long,
	Unsupported_Action,
	Reset_Relative_Action,
	Mouse_Out_Of_Range,
	Mouse_Buttons_Held,
}

Input_Control_State :: enum u8 {
	Disabled,
	Waiting,
	Running,
	Completed,
	Failed,
}

Input_Control_Failure :: enum u8 {
	None,
	Lifecycle_Changed,
	Frozen,
}

Input_Control_Enqueue_Result :: enum u8 {
	Accepted,
	Backpressure,
	Lifecycle_Changed,
}

Input_Control_Machine_State :: struct {
	running:    bool,
	paused:     bool,
	frozen:     bool,
	generation: u64,
}

Input_Control_Enqueue_Proc :: #type proc(
	ctx: rawptr,
	action: acceptance.Input_Action,
	generation: u64,
) -> Input_Control_Enqueue_Result

Input_Control :: struct {
	script:     acceptance.Input_Script,
	state:      Input_Control_State,
	failure:    Input_Control_Failure,
	generation: u64,
	elapsed:    time.Duration,
	last_tick:  time.Tick,
	buttons:    u8,
}

input_control_destroy :: proc(control: ^Input_Control) {
	if control == nil {return}
	acceptance.input_script_destroy(&control.script)
	control^ = {}
}

input_control_validate :: proc(script: ^acceptance.Input_Script) -> Input_Control_Diagnostic {
	if script == nil || len(script.actions) == 0 {return .Empty_Script}
	if len(script.actions) > INPUT_CONTROL_MAX_ACTIONS {return .Too_Many_Actions}
	buttons: u8
	buttons_held := false
	buttons_released := false
	for action in script.actions {
		if action.after_reset != 0 {return .Reset_Relative_Action}
		if action.at_ms < 0 || action.at_ms > INPUT_CONTROL_MAX_DURATION_MS {
			return .Duration_Too_Long
		}
		#partial switch action.kind {
		case .Key:
			if action.key_n == 0 || int(action.key_n) > len(action.key) {
				return .Unsupported_Action
			}
		case .Mouse_Move:
			if action.dx < -INPUT_CONTROL_MOUSE_DELTA_LIMIT ||
			   action.dx > INPUT_CONTROL_MOUSE_DELTA_LIMIT ||
			   action.dy < -INPUT_CONTROL_MOUSE_DELTA_LIMIT ||
			   action.dy > INPUT_CONTROL_MOUSE_DELTA_LIMIT {
				return .Mouse_Out_Of_Range
			}
			buttons = action.buttons
			if buttons != 0 {
				buttons_held = true
				buttons_released = false
			}
		case .Mouse_Buttons:
			buttons = action.buttons
			if buttons == 0 {
				buttons_released = true
			} else {
				buttons_held = true
				buttons_released = false
			}
		case .Mouse_Wheel:
			if action.wheel < -INPUT_CONTROL_WHEEL_LIMIT ||
			   action.wheel > INPUT_CONTROL_WHEEL_LIMIT {
				return .Mouse_Out_Of_Range
			}
			buttons = action.buttons
			if buttons != 0 {
				buttons_held = true
				buttons_released = false
			}
		case:
			return .Unsupported_Action
		}
	}
	if buttons != 0 || buttons_held && !buttons_released {return .Mouse_Buttons_Held}
	return .None
}

input_control_adopt :: proc(
	control: ^Input_Control,
	script: ^acceptance.Input_Script,
) -> Input_Control_Diagnostic {
	if control == nil || script == nil {return .Invalid_Script}
	diagnostic := input_control_validate(script)
	if diagnostic != .None {return diagnostic}
	input_control_destroy(control)
	control.script = script^
	script^ = {}
	control.state = .Waiting
	return .None
}

input_control_load :: proc(control: ^Input_Control, path: string) -> Input_Control_Diagnostic {
	if control == nil || path == "" {return .Read_Failed}
	path_info, path_error := os.lstat(path, context.temp_allocator)
	if path_error != nil {return .Read_Failed}
	defer os.file_info_delete(path_info, context.temp_allocator)
	if path_info.type != .Regular {return .Unsafe_File}
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return .Read_Failed}
	defer os.close(file)
	info, info_error := os.fstat(file, context.temp_allocator)
	if info_error != nil {return .Read_Failed}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular {return .Unsafe_File}
	if info.size < 0 || info.size > INPUT_CONTROL_MAX_FILE_BYTES {return .File_Too_Large}
	data := make([]u8, int(info.size), context.temp_allocator)
	if len(data) > 0 {
		read, read_error := os.read_full(file, data)
		if read_error != nil || read != len(data) {return .Read_Failed}
	}
	extra: [1]u8
	extra_read, _ := os.read(file, extra[:])
	if extra_read != 0 {return .File_Too_Large}
	script, script_diagnostic := acceptance.input_script_parse(string(data))
	if script_diagnostic != .None {
		acceptance.input_script_destroy(&script)
		return .Invalid_Script
	}
	diagnostic := input_control_adopt(control, &script)
	acceptance.input_script_destroy(&script)
	return diagnostic
}

input_control_fail :: proc(control: ^Input_Control, failure: Input_Control_Failure) {
	if control == nil {return}
	control.state = .Failed
	control.failure = failure
	control.last_tick = {}
}

input_control_note_action :: proc(
	control: ^Input_Control,
	action: acceptance.Input_Action,
) {
	#partial switch action.kind {
	case .Mouse_Move, .Mouse_Buttons, .Mouse_Wheel:
		control.buttons = action.buttons
	case:
	}
}

input_control_tick :: proc(
	control: ^Input_Control,
	machine_state: Input_Control_Machine_State,
	now: time.Tick,
	enqueue: Input_Control_Enqueue_Proc,
	ctx: rawptr = nil,
) -> Input_Control_State {
	if control == nil || enqueue == nil {return .Disabled}
	if control.state == .Disabled ||
	   control.state == .Completed ||
	   control.state == .Failed {
		return control.state
	}
	if machine_state.frozen {
		input_control_fail(control, .Frozen)
		return control.state
	}
	if !machine_state.running {
		if control.state == .Running {input_control_fail(control, .Lifecycle_Changed)}
		return control.state
	}
	if control.state == .Waiting {
		if machine_state.generation == 0 {
			input_control_fail(control, .Lifecycle_Changed)
			return control.state
		}
		control.state = .Running
		control.generation = machine_state.generation
		control.last_tick = now
	} else if machine_state.generation != control.generation {
		input_control_fail(control, .Lifecycle_Changed)
		return control.state
	}
	if machine_state.paused {
		if control.last_tick != (time.Tick{}) {
			control.elapsed += max(time.Duration(0), time.tick_diff(control.last_tick, now))
		}
		control.last_tick = {}
		return control.state
	}
	if control.last_tick == (time.Tick{}) {
		control.last_tick = now
	} else {
		control.elapsed += max(time.Duration(0), time.tick_diff(control.last_tick, now))
		control.last_tick = now
	}
	elapsed_ms := i64(control.elapsed / time.Millisecond)
	processed := 0
	for control.script.cursor < len(control.script.actions) &&
	    processed < INPUT_CONTROL_ACTIONS_PER_TICK {
		action := control.script.actions[control.script.cursor]
		if action.at_ms > elapsed_ms {break}
		result := enqueue(ctx, action, control.generation)
		if result == .Backpressure {break}
		if result == .Lifecycle_Changed {
			input_control_fail(control, .Lifecycle_Changed)
			return control.state
		}
		input_control_note_action(control, action)
		control.script.cursor += 1
		processed += 1
	}
	if control.script.cursor == len(control.script.actions) {
		control.state = .Completed
		control.last_tick = {}
	}
	return control.state
}
