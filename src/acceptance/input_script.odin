// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

INPUT_SCRIPT_KEY_BYTES :: 8

Input_Action_Kind :: enum {
	Key,
	Key_While_Setup_Page,
	Mouse_Move,
	Mouse_Buttons,
	Mouse_Wheel,
	Snapshot,
	Memory_Snapshot,
	Dump_State,
	Wait_Frame,
	Wait_Stable,
	Wait_Change,
	Wait_Memory,
	Wait_Setup_Page,
	Reset,
}

Setup_Page :: enum u8 {
	User_Info,
	Eula,
	Product_Key,
	Finish,
}

Input_Action :: struct {
	kind:         Input_Action_Kind,
	after_reset:  u32,
	at_ms:        i64,
	key:          [INPUT_SCRIPT_KEY_BYTES]u8,
	key_n:        u8,
	dx, dy:       i32,
	buttons:      u8,
	wheel:        i32,
	path:         string,
	frame_crc:    u32,
	stable_ms:    i64,
	memory_gpa:   u64,
	memory_value: u64,
	memory_mask:  u64,
	memory_size:  u8,
	setup_page:   Setup_Page,
	repeat_ms:    i64,
}

Input_Script :: struct {
	actions:      [dynamic]Input_Action,
	cursor:       int,
	timing_reset: u32,
	delay_ms:     i64,
	setup_page_gpa: u64,
	setup_page_gpa_valid: bool,
	setup_page_scan_cursor: int,
	retry_active: bool,
	retry_next_ms: i64,
	memory_sample_valid: bool,
	memory_sample_cursor: int,
	memory_sample_match: bool,
}

Input_Script_Diagnostic :: enum {
	None,
	Read_Failed,
	Invalid_Syntax,
	Invalid_Number,
	Invalid_Key,
	Invalid_Reset_Order,
}

input_script_destroy :: proc(script: ^Input_Script) {
	if script == nil {return}
	for action in script.actions {delete(action.path)}
	delete(script.actions)
	script^ = {}
}

input_script_load :: proc(path: string) -> (Input_Script, Input_Script_Diagnostic) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {return {}, .Read_Failed}
	defer delete(data)
	return input_script_parse(string(data))
}

input_script_setup_page_parse :: proc(name: string) -> (Setup_Page, bool) {
	switch name {
	case "user":
		return .User_Info, true
	case "eula":
		return .Eula, true
	case "product":
		return .Product_Key, true
	case "finish":
		return .Finish, true
	case:
		return {}, false
	}
}

input_script_parse :: proc(text: string) -> (Input_Script, Input_Script_Diagnostic) {
	script: Input_Script
	after_reset: u32
	at_ms: i64
	rest := text
	for raw_line in strings.split_lines_iterator(&rest) {
		line := raw_line
		if comment := strings.index_byte(line, '#'); comment >= 0 {line = line[:comment]}
		line = strings.trim_space(line)
		if line == "" {continue}
		fields, err := strings.fields(line, context.temp_allocator)
		if err != nil {input_script_destroy(&script); return {}, .Invalid_Syntax}
		defer delete(fields, context.temp_allocator)
		command := fields[0]
		switch command {
		case "wait":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			value, ok := strconv.parse_int(fields[1], 10)
			if !ok || value < 0 || i64(value) > max(i64) - at_ms {
				input_script_destroy(&script)
				return {}, .Invalid_Number
			}
			at_ms += i64(value)
		case "after-reset":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			value, ok := strconv.parse_int(fields[1], 10)
			if !ok || value < int(after_reset) || value > int(max(u32)) {
				input_script_destroy(&script)
				return {}, value < int(after_reset) ? .Invalid_Reset_Order : .Invalid_Number
			}
			after_reset = u32(value)
			at_ms = 0
		case "key":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			key, key_n, ok := input_script_key(fields[1])
			if !ok {input_script_destroy(&script); return {}, .Invalid_Key}
			append(
				&script.actions,
				Input_Action {
					kind = .Key,
					after_reset = after_reset,
					at_ms = at_ms,
					key = key,
					key_n = key_n,
				},
			)
		case "type":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			for byte in transmute([]u8)fields[1] {
				key, key_n, ok := input_script_ascii_key(byte)
				if !ok {input_script_destroy(&script); return {}, .Invalid_Key}
				append(
					&script.actions,
					Input_Action {
						kind = .Key,
						after_reset = after_reset,
						at_ms = at_ms,
						key = key,
						key_n = key_n,
					},
				)
				at_ms += 50
			}
		case "mouse":
			if len(fields) != 4 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			dx, dx_ok := strconv.parse_int(fields[1], 10)
			dy, dy_ok := strconv.parse_int(fields[2], 10)
			buttons, buttons_ok := strconv.parse_int(fields[3], 10)
			if !dx_ok || !dy_ok || !buttons_ok || buttons < 0 || buttons > 7 {
				input_script_destroy(&script); return {}, .Invalid_Number
			}
			append(
				&script.actions,
				Input_Action {
					kind = .Mouse_Move,
					after_reset = after_reset,
					at_ms = at_ms,
					dx = i32(dx),
					dy = i32(dy),
					buttons = u8(buttons),
				},
			)
		case "buttons":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			buttons, ok := strconv.parse_int(fields[1], 10)
			if !ok ||
			   buttons < 0 ||
			   buttons > 7 {input_script_destroy(&script); return {}, .Invalid_Number}
			append(
				&script.actions,
				Input_Action {
					kind = .Mouse_Buttons,
					after_reset = after_reset,
					at_ms = at_ms,
					buttons = u8(buttons),
				},
			)
		case "wheel":
			if len(fields) != 3 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			wheel, wheel_ok := strconv.parse_int(fields[1], 10)
			buttons, buttons_ok := strconv.parse_int(fields[2], 10)
			if !wheel_ok || !buttons_ok || buttons < 0 || buttons > 7 {
				input_script_destroy(&script); return {}, .Invalid_Number
			}
			append(
				&script.actions,
				Input_Action {
					kind = .Mouse_Wheel,
					after_reset = after_reset,
					at_ms = at_ms,
					wheel = i32(wheel),
					buttons = u8(buttons),
				},
			)
		case "snapshot":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			append(
				&script.actions,
				Input_Action {
					kind = .Snapshot,
					after_reset = after_reset,
					at_ms = at_ms,
					path = strings.clone(fields[1]),
				},
			)
		case "key-while-setup-page":
			if len(fields) != 3 && len(fields) != 4 {
				input_script_destroy(&script); return {}, .Invalid_Syntax
			}
			page, page_ok := input_script_setup_page_parse(fields[1])
			key, key_n, key_ok := input_script_key(fields[2])
			repeat_ms := 1_000
			repeat_ok := true
			if len(fields) == 4 {repeat_ms, repeat_ok = strconv.parse_int(fields[3], 10)}
			if !page_ok || !key_ok {
				input_script_destroy(&script)
				return {}, !page_ok ? .Invalid_Syntax : .Invalid_Key
			}
			if !repeat_ok || repeat_ms <= 0 {
				input_script_destroy(&script); return {}, .Invalid_Number
			}
			append(
				&script.actions,
				Input_Action {
					kind = .Key_While_Setup_Page,
					after_reset = after_reset,
					at_ms = at_ms,
					key = key,
					key_n = key_n,
					setup_page = page,
					repeat_ms = i64(repeat_ms),
				},
			)
		case "snapshot-memory":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			append(
				&script.actions,
				Input_Action {
					kind = .Memory_Snapshot,
					after_reset = after_reset,
					at_ms = at_ms,
					path = strings.clone(fields[1]),
				},
			)
		case "dump-state":
			if len(fields) != 1 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			append(
				&script.actions,
				Input_Action{kind = .Dump_State, after_reset = after_reset, at_ms = at_ms},
			)
		case "reset":
			if len(fields) != 1 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			append(
				&script.actions,
				Input_Action{kind = .Reset, after_reset = after_reset, at_ms = at_ms},
			)
		case "wait-frame":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			value, ok := strconv.parse_uint(fields[1], 0)
			if !ok ||
			   value > uint(max(u32)) {input_script_destroy(&script); return {}, .Invalid_Number}
			append(
				&script.actions,
				Input_Action {
					kind = .Wait_Frame,
					after_reset = after_reset,
					at_ms = at_ms,
					frame_crc = u32(value),
				},
			)
		case "wait-stable", "wait-change":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			value, ok := strconv.parse_int(fields[1], 10)
			if !ok || value < 0 {input_script_destroy(&script); return {}, .Invalid_Number}
			kind := command == "wait-stable" ? Input_Action_Kind.Wait_Stable : .Wait_Change
			append(
				&script.actions,
				Input_Action {
					kind = kind,
					after_reset = after_reset,
					at_ms = at_ms,
					stable_ms = i64(value),
				},
			)
		case "wait-memory":
			if len(fields) != 4 && len(fields) != 5 {
				input_script_destroy(&script); return {}, .Invalid_Syntax
			}
			gpa, gpa_ok := strconv.parse_uint(fields[1], 0)
			size, size_ok := strconv.parse_uint(fields[2], 0)
			value, value_ok := strconv.parse_uint(fields[3], 0)
			if !gpa_ok ||
			   !size_ok ||
			   !value_ok ||
			   (size != 1 && size != 2 && size != 4 && size != 8) {
				input_script_destroy(&script); return {}, .Invalid_Number
			}
			value_mask := size == 8 ? uint(max(u64)) : (uint(1) << (size * 8)) - 1
			mask := value_mask
			if len(fields) == 5 {
				mask, value_ok = strconv.parse_uint(fields[4], 0)
				if !value_ok {input_script_destroy(&script); return {}, .Invalid_Number}
			}
			if value > value_mask || mask > value_mask {
				input_script_destroy(&script)
				return {}, .Invalid_Number
			}
			append(
				&script.actions,
				Input_Action {
					kind = .Wait_Memory,
					after_reset = after_reset,
					at_ms = at_ms,
					memory_gpa = u64(gpa),
					memory_value = u64(value),
					memory_mask = u64(mask),
					memory_size = u8(size),
				},
			)
		case "wait-setup-page":
			if len(fields) != 2 {input_script_destroy(&script); return {}, .Invalid_Syntax}
			page, ok := input_script_setup_page_parse(fields[1])
			if !ok {input_script_destroy(&script); return {}, .Invalid_Syntax}
			append(
				&script.actions,
				Input_Action {
					kind = .Wait_Setup_Page,
					after_reset = after_reset,
					at_ms = at_ms,
					setup_page = page,
				},
			)
		case:
			input_script_destroy(&script)
			return {}, .Invalid_Syntax
		}
	}
	return script, .None
}

input_script_drain :: proc(
	script: ^Input_Script,
	reset_count: u32,
	phase_ms: i64,
	frame_crc: u32,
	visual_ready: bool,
	memory_ready: bool,
	out: []Input_Action,
) -> int {
	if script == nil || len(out) == 0 {return 0}
	n := 0
	barrier_ready := visual_ready
	memory_barrier_ready := memory_ready
	for script.cursor < len(script.actions) && n < len(out) {
		action := script.actions[script.cursor]
		if action.after_reset > reset_count {break}
		if action.after_reset == reset_count &&
		   input_script_effective_time(script, action) > phase_ms {
			break
		}
		if action.kind == .Wait_Frame {
			if action.frame_crc != frame_crc {break}
			input_script_rebase_after_barrier(script, action, phase_ms)
			script.cursor += 1
			continue
		}
		if action.kind == .Wait_Stable || action.kind == .Wait_Change {
			if !barrier_ready {break}
			input_script_rebase_after_barrier(script, action, phase_ms)
			script.cursor += 1
			barrier_ready = false
			continue
		}
		if action.kind == .Key_While_Setup_Page {
			if !script.memory_sample_valid || script.memory_sample_cursor != script.cursor {break}
			if !script.memory_sample_match {
				input_script_rebase_after_barrier(script, action, phase_ms)
				script.cursor += 1
				script.retry_active = false
				script.memory_sample_valid = false
				continue
			}
			if !script.retry_active {
				script.retry_active = true
				script.retry_next_ms = input_script_effective_time(script, action)
			}
			if phase_ms < script.retry_next_ms {break}
			out[n] = action
			n += 1
			script.retry_next_ms = phase_ms + action.repeat_ms
			script.memory_sample_valid = false
			break
		}
		if action.kind == .Wait_Memory || action.kind == .Wait_Setup_Page {
			if !memory_barrier_ready {break}
			input_script_rebase_after_barrier(script, action, phase_ms)
			script.cursor += 1
			memory_barrier_ready = false
			continue
		}
		out[n] = action
		n += 1
		script.cursor += 1
	}
	return n
}

input_script_memory_matches :: proc(
	script: ^Input_Script,
	reset_count: u32,
	phase_ms: i64,
	memory: []u8,
) -> bool {
	if script == nil || script.cursor >= len(script.actions) {return false}
	action := script.actions[script.cursor]
	if (action.kind != .Wait_Memory &&
	   action.kind != .Wait_Setup_Page &&
	   action.kind != .Key_While_Setup_Page) ||
	   action.after_reset > reset_count {
		return false
	}
	if action.after_reset == reset_count &&
	   input_script_effective_time(script, action) > phase_ms {
		return false
	}
	if action.kind == .Key_While_Setup_Page {
		matched := input_script_setup_page_still_matches(script, action.setup_page, memory)
		script.memory_sample_valid = true
		script.memory_sample_cursor = script.cursor
		script.memory_sample_match = matched
		return matched
	}
	if action.kind == .Wait_Setup_Page {
		return input_script_setup_page_matches(script, action.setup_page, memory)
	}
	size := u64(action.memory_size)
	if size == 0 ||
	   action.memory_gpa > u64(len(memory)) ||
	   size > u64(len(memory)) - action.memory_gpa {
		return false
	}
	value: u64
	for i in 0 ..< int(action.memory_size) {
		value |= u64(memory[int(action.memory_gpa) + i]) << (8 * uint(i))
	}
	return value & action.memory_mask == action.memory_value & action.memory_mask
}

@(private = "file")
input_script_setup_page_still_matches :: proc(
	script: ^Input_Script,
	page: Setup_Page,
	memory: []u8,
) -> bool {
	if script == nil {return false}
	if !script.setup_page_gpa_valid {
		return input_script_setup_page_matches(script, page, memory)
	}
	signature := [8]u8{0x10, 0x01, u8(page), 0x00, 0xff, 0xff, 0x60, 0x03}
	gpa := int(script.setup_page_gpa)
	return gpa >= 0 &&
	       gpa + len(signature) <= len(memory) &&
	       slice.equal(memory[gpa:gpa + len(signature)], signature[:])
}

@(private = "file")
input_script_setup_page_matches :: proc(
	script: ^Input_Script,
	page: Setup_Page,
	memory: []u8,
) -> bool {
	signature := [8]u8{0x10, 0x01, u8(page), 0x00, 0xff, 0xff, 0x60, 0x03}
	if script.setup_page_gpa_valid {
		gpa := int(script.setup_page_gpa)
		if gpa >= 0 &&
		   gpa + len(signature) <= len(memory) &&
		   slice.equal(memory[gpa:gpa + len(signature)], signature[:]) {
			return true
		}
		script.setup_page_gpa_valid = false
		script.setup_page_scan_cursor = 0
	}
	if len(memory) < len(signature) {return false}
	start := script.setup_page_scan_cursor
	if start < 0 || start >= len(memory) {start = 0}
	end := min(start + 8 * 1024 * 1024, len(memory))
	offset := strings.index(string(memory[start:end]), string(signature[:]))
	if offset < 0 {
		script.setup_page_scan_cursor = end == len(memory) ? 0 : end - len(signature) + 1
		return false
	}
	script.setup_page_gpa = u64(start + offset)
	script.setup_page_gpa_valid = true
	return true
}

input_script_visual_due :: proc(
	script: ^Input_Script,
	reset_count: u32,
	phase_ms: i64,
) -> (
	stable_ms: i64,
	require_change: bool,
	ok: bool,
) {
	if script == nil || script.cursor >= len(script.actions) {return}
	action := script.actions[script.cursor]
	if action.kind != .Wait_Stable && action.kind != .Wait_Change {return}
	if action.after_reset > reset_count {return}
	if action.after_reset == reset_count &&
	   input_script_effective_time(script, action) > phase_ms {
		return
	}
	return action.stable_ms, action.kind == .Wait_Change, true
}

input_script_frame_due :: proc(script: ^Input_Script, reset_count: u32, phase_ms: i64) -> bool {
	if script == nil || script.cursor >= len(script.actions) {return false}
	action := script.actions[script.cursor]
	if action.kind != .Wait_Frame || action.after_reset > reset_count {return false}
	return(
		action.after_reset < reset_count ||
		input_script_effective_time(script, action) <= phase_ms \
	)
}

@(private = "file")
input_script_effective_time :: proc(script: ^Input_Script, action: Input_Action) -> i64 {
	if script != nil && script.timing_reset == action.after_reset {
		return action.at_ms + script.delay_ms
	}
	return action.at_ms
}

@(private = "file")
input_script_rebase_after_barrier :: proc(
	script: ^Input_Script,
	action: Input_Action,
	phase_ms: i64,
) {
	if script.timing_reset != action.after_reset {
		script.timing_reset = action.after_reset
		script.delay_ms = 0
	}
	if phase_ms > action.at_ms + script.delay_ms {
		script.delay_ms = phase_ms - action.at_ms
	}
}

@(private)
input_script_key :: proc(name: string) -> ([INPUT_SCRIPT_KEY_BYTES]u8, u8, bool) {
	code: u8
	extended := false
	switch name {
	case "ctrl-escape", "ctrl-esc":
		return [INPUT_SCRIPT_KEY_BYTES]u8{0x1d, 0x01, 0x81, 0x9d, 0, 0, 0, 0}, 4, true
	case "underscore-es":
		// Spanish Win9x layouts place '-'/'_' on the physical US '/' key.
		return [INPUT_SCRIPT_KEY_BYTES]u8{0x2a, 0x35, 0xb5, 0xaa, 0, 0, 0, 0}, 4, true
	case "ctrl-alt-delete", "ctrl-alt-del":
		return [INPUT_SCRIPT_KEY_BYTES]u8{0x1d, 0x38, 0xe0, 0x53, 0xe0, 0xd3, 0xb8, 0x9d}, 8, true
	case "escape":
		code = 0x01
	case "backspace":
		code = 0x0e
	case "tab":
		code = 0x0f
	case "enter":
		code = 0x1c
	case "space":
		code = 0x39
	case "comma":
		code = 0x33
	case "period", "dot":
		code = 0x34
	case "up":
		code, extended = 0x48, true
	case "pageup":
		code, extended = 0x49, true
	case "left":
		code, extended = 0x4b, true
	case "right":
		code, extended = 0x4d, true
	case "end":
		code, extended = 0x4f, true
	case "down":
		code, extended = 0x50, true
	case "pagedown":
		code, extended = 0x51, true
	case "insert":
		code, extended = 0x52, true
	case "delete":
		code, extended = 0x53, true
	case:
		return {}, 0, false
	}
	if extended {
		return [INPUT_SCRIPT_KEY_BYTES]u8{0xe0, code, 0xe0, code | 0x80, 0, 0, 0, 0}, 4, true
	}
	key: [INPUT_SCRIPT_KEY_BYTES]u8
	key[0] = code
	key[1] = code | 0x80
	return key, 2, true
}

@(private)
input_script_ascii_key :: proc(byte: u8) -> ([INPUT_SCRIPT_KEY_BYTES]u8, u8, bool) {
	code: u8
	switch byte {
	case '1' ..= '9':
		code = 0x02 + byte - '1'
	case '0':
		code = 0x0b
	case 'a', 'A':
		code = 0x1e
	case 'b', 'B':
		code = 0x30
	case 'c', 'C':
		code = 0x2e
	case 'd', 'D':
		code = 0x20
	case 'e', 'E':
		code = 0x12
	case 'f', 'F':
		code = 0x21
	case 'g', 'G':
		code = 0x22
	case 'h', 'H':
		code = 0x23
	case 'i', 'I':
		code = 0x17
	case 'j', 'J':
		code = 0x24
	case 'k', 'K':
		code = 0x25
	case 'l', 'L':
		code = 0x26
	case 'm', 'M':
		code = 0x32
	case 'n', 'N':
		code = 0x31
	case 'o', 'O':
		code = 0x18
	case 'p', 'P':
		code = 0x19
	case 'q', 'Q':
		code = 0x10
	case 'r', 'R':
		code = 0x13
	case 's', 'S':
		code = 0x1f
	case 't', 'T':
		code = 0x14
	case 'u', 'U':
		code = 0x16
	case 'v', 'V':
		code = 0x2f
	case 'w', 'W':
		code = 0x11
	case 'x', 'X':
		code = 0x2d
	case 'y', 'Y':
		code = 0x15
	case 'z', 'Z':
		code = 0x2c
	case '-':
		code = 0x0c
	case '_':
		code = 0x0c
	case:
		return {}, 0, false
	}
	if byte >= 'A' && byte <= 'Z' || byte == '_' {
		return [INPUT_SCRIPT_KEY_BYTES]u8{0x2a, code, code | 0x80, 0xaa, 0, 0, 0, 0}, 4, true
	}
	return [INPUT_SCRIPT_KEY_BYTES]u8{code, code | 0x80, 0, 0, 0, 0, 0, 0}, 2, true
}
