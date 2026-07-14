// SPDX-License-Identifier: GPL-3.0-only
package machine

// i8042 behavior adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

I8042_CONTROLLER_INPUT_NS :: u64(20_000)
I8042_DEVICE_BYTE_NS      :: u64(1_000_000)
I8042_AUX_BYTE_NS         :: I8042_DEVICE_BYTE_NS
I8042_HOST_KEY_BYTE_NS    :: u64(10_000_000)
I8042_QUEUE_CAPACITY      :: 128
I8042_COMMAND_TRANSLATE   :: u8(0x40)

I8042_Expect :: enum u8 {
	None,
	Cmd_Byte,
	Out_Port,
	Kbd_Output,
	Aux_Output,
	Aux_Device,
}

I8042_Kbd_Expect :: enum u8 {
	None,
	Led_Byte,
	Rate_Byte,
	Scan_Set,
}

I8042_Reset_Source :: enum u8 {
	None,
	Controller_Pulse,
	Output_Port,
	Fast_A20,
}

I8042_Byte_Queue :: struct {
	bytes: [I8042_QUEUE_CAPACITY]u8,
	head, count: int,
}

I8042_Pending_Input :: struct {
	valid, command: bool,
	value:          u8,
}

I8042_Diagnostics :: struct {
	queued, keyboard_queued, auxiliary_queued: int,
	scheduled_key_bytes:                       int,
	output_full, output_aux, input_busy:        bool,
	keyboard_scanning:                         bool,
	keyboard_scan_set:                         u8,
	command_byte:                              u8,
	now_ns:                                    u64,
	next_deadline_ns:                           u64,
	has_deadline:                               bool,
}

I8042 :: struct {
	kbd_queue, aux_queue, host_key_queue: I8042_Byte_Queue,
	output:               u8,
	output_valid:         bool,
	output_full:          bool,
	output_aux:           bool,
	cmd_byte:             u8,
	expect:               I8042_Expect,
	pending_input:        I8042_Pending_Input,
	input_wait_ns:        u64,
	last_input_command:   bool,
	system_flag:          bool,
	serial_active:        bool,
	serial_ready:         bool,
	serial_wait_ns:       u64,
	now_ns:               u64,
	a20:                  bool,
	a20_kbc:              bool,
	a20_fast:             bool,
	output_port:          u8,
	mouse:                Ps2_Mouse,
	kbd_expect:           I8042_Kbd_Expect,
	kbd_scanning:         bool,
	kbd_scan_set:         u8,
	kbd_leds:             u8,
	kbd_typematic:        u8,
	kbd_last_tx:          u8,
	kbd_last_tx_valid:    bool,
	key_sequence:         [6]u8,
	key_sequence_count:   int,
	held:                 [16]u8,
	held_ext:             [16]u8,
	repeat_active:        bool,
	repeat_extended:      bool,
	repeat_code:          u8,
	repeat_wait_ns:       u64,
	host_key_wait_ns:     u64,
	mouse_due:            bool,
	ctx:                  rawptr,
	irq1:                 proc(ctx: rawptr),
	irq12:                proc(ctx: rawptr),
	irq1_lower:           proc(ctx: rawptr),
	irq12_lower:          proc(ctx: rawptr),
	irq1_asserted:        bool,
	irq12_asserted:       bool,
	reset_source:         I8042_Reset_Source,
	reset:                proc(ctx: rawptr),
	a20_control:          proc(ctx: rawptr, enabled: bool) -> bool,
}

@(private = "file")
i8042_request_reset :: proc(k: ^I8042, source: I8042_Reset_Source) {
	k.reset_source = source
	if k.reset != nil {k.reset(k.ctx)}
}

@(private = "file")
i8042_queue_push :: proc(q: ^I8042_Byte_Queue, value: u8) -> bool {
	if q.count == len(q.bytes) {return false}
	q.bytes[(q.head + q.count) % len(q.bytes)] = value
	q.count += 1
	return true
}

@(private = "file")
i8042_queue_push_front :: proc(q: ^I8042_Byte_Queue, value: u8) -> bool {
	if q.count == len(q.bytes) {return false}
	q.head = (q.head + len(q.bytes) - 1) % len(q.bytes)
	q.bytes[q.head] = value
	q.count += 1
	return true
}

@(private = "file")
i8042_queue_pop :: proc(q: ^I8042_Byte_Queue) -> (u8, bool) {
	if q.count == 0 {return 0, false}
	value := q.bytes[q.head]
	q.head = (q.head + 1) % len(q.bytes)
	q.count -= 1
	return value, true
}

i8042_init :: proc(
	k: ^I8042,
	ctx: rawptr,
	irq1: proc(ctx: rawptr),
	irq12: proc(ctx: rawptr) = nil,
	reset: proc(ctx: rawptr) = nil,
	a20_control: proc(ctx: rawptr, enabled: bool) -> bool = nil,
) {
	k^ = {}
	k.a20 = true
	k.a20_fast = true
	k.output_port = 0x01
	k.system_flag = true
	k.kbd_scanning = true
	k.kbd_scan_set = 2
	k.kbd_typematic = 0x2B
	k.ctx = ctx
	k.irq1 = irq1
	k.irq12 = irq12
	k.reset = reset
	k.a20_control = a20_control
	ps2_mouse_init(&k.mouse)
}

i8042_set_irq_lower_callbacks :: proc(
	k: ^I8042,
	irq1_lower: proc(ctx: rawptr),
	irq12_lower: proc(ctx: rawptr),
) {
	k.irq1_lower = irq1_lower
	k.irq12_lower = irq12_lower
}

@(private = "file")
i8042_update_irq_lines :: proc(k: ^I8042) {
	want_irq1 := k.output_full && !k.output_aux && k.cmd_byte & 0x01 != 0
	want_irq12 := k.output_full && k.output_aux && k.cmd_byte & 0x02 != 0
	if want_irq1 != k.irq1_asserted {
		k.irq1_asserted = want_irq1
		if want_irq1 {
			if k.irq1 != nil {k.irq1(k.ctx)}
		} else if k.irq1_lower != nil {k.irq1_lower(k.ctx)}
	}
	if want_irq12 != k.irq12_asserted {
		k.irq12_asserted = want_irq12
		if want_irq12 {
			if k.irq12 != nil {k.irq12(k.ctx)}
		} else if k.irq12_lower != nil {k.irq12_lower(k.ctx)}
	}
}

i8042_irq1_level :: proc(k: ^I8042) -> bool {return k.irq1_asserted}
i8042_irq12_level :: proc(k: ^I8042) -> bool {return k.irq12_asserted}

i8042_diagnostics :: proc(k: ^I8042) -> I8042_Diagnostics {
	next, has_next := i8042_next_deadline_ns(k)
	return {
		queued = k.kbd_queue.count + k.aux_queue.count + (k.output_full ? 1 : 0),
		keyboard_queued = k.kbd_queue.count,
		auxiliary_queued = k.aux_queue.count,
		scheduled_key_bytes = k.host_key_queue.count,
		output_full = k.output_full,
		output_aux = k.output_full && k.output_aux,
		input_busy = k.pending_input.valid,
		keyboard_scanning = k.kbd_scanning,
		keyboard_scan_set = k.kbd_scan_set,
		command_byte = k.cmd_byte,
		now_ns = k.now_ns,
		next_deadline_ns = next,
		has_deadline = has_next,
	}
}

@(private = "file")
i8042_apply_a20 :: proc(k: ^I8042) -> bool {
	enabled := k.a20_kbc || k.a20_fast
	if k.a20 == enabled {return true}
	if k.a20_control != nil && !k.a20_control(k.ctx, enabled) {return false}
	k.a20 = enabled
	return true
}

@(private = "file")
i8042_set_kbc_a20 :: proc(k: ^I8042, enabled: bool) -> bool {
	if k.a20_kbc == enabled {return true}
	old := k.a20_kbc
	k.a20_kbc = enabled
	if !i8042_apply_a20(k) {
		k.a20_kbc = old
		return false
	}
	if enabled {k.output_port |= 0x02} else {k.output_port &~= 0x02}
	return true
}

@(private = "file")
i8042_set_fast_a20 :: proc(k: ^I8042, enabled: bool) -> bool {
	if k.a20_fast == enabled {return true}
	old := k.a20_fast
	k.a20_fast = enabled
	if !i8042_apply_a20(k) {
		k.a20_fast = old
		return false
	}
	return true
}

@(private = "file")
i8042_eligible_device_byte :: proc(k: ^I8042) -> bool {
	return k.cmd_byte & 0x10 == 0 && k.kbd_queue.count > 0 ||
	       k.cmd_byte & 0x20 == 0 && k.aux_queue.count > 0
}

@(private = "file")
i8042_schedule_serial :: proc(k: ^I8042) {
	if k.output_full || k.serial_active || k.serial_ready || !i8042_eligible_device_byte(k) {return}
	k.serial_active = true
	k.serial_wait_ns = I8042_DEVICE_BYTE_NS
}

@(private = "file")
i8042_set_output :: proc(k: ^I8042, value: u8, aux: bool) {
	k.output = value
	k.output_valid = true
	k.output_full = true
	k.output_aux = aux
	i8042_update_irq_lines(k)
}

@(private = "file")
i8042_controller_output :: proc(k: ^I8042, value: u8, aux: bool = false) {
	if k.output_full {
		if k.output_aux {_ = i8042_queue_push_front(&k.aux_queue, k.output)} else {_ = i8042_queue_push_front(&k.kbd_queue, k.output)}
		k.output_full = false
		i8042_update_irq_lines(k)
	}
	i8042_set_output(k, value, aux)
}

@(private = "file")
i8042_latch_serial :: proc(k: ^I8042) {
	if k.output_full {k.serial_ready = true; return}
	value: u8
	ok, aux := false, false
	if k.cmd_byte & 0x10 == 0 && k.kbd_queue.count > 0 {
		value, ok = i8042_queue_pop(&k.kbd_queue)
	} else if k.cmd_byte & 0x20 == 0 && k.aux_queue.count > 0 {
		value, ok = i8042_queue_pop(&k.aux_queue)
		aux = ok
	}
	if !ok {k.serial_ready = false; return}
	k.serial_ready = false
	if aux {
		ps2_mouse_note_tx(&k.mouse, value)
	} else {
		k.kbd_last_tx = value
		k.kbd_last_tx_valid = true
	}
	i8042_set_output(k, value, aux)
}

@(private = "file")
i8042_queue_mouse_reply :: proc(k: ^I8042, reply: Ps2_Mouse_Reply) {
	for i in 0 ..< reply.count {_ = i8042_queue_push(&k.aux_queue, reply.bytes[i])}
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_queue_mouse_packet :: proc(k: ^I8042) {
	packet_size := k.mouse.device_id == 3 ? 4 : 3
	if len(k.aux_queue.bytes) - k.aux_queue.count < packet_size {
		k.mouse.sample_scheduled = true
		k.mouse.sample_wait_ns = ps2_mouse_sample_interval_ns(&k.mouse)
		return
	}
	packet := ps2_mouse_take_packet(&k.mouse)
	for i in 0 ..< packet.count {_ = i8042_queue_push(&k.aux_queue, packet.bytes[i])}
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_queue_keyboard :: proc(k: ^I8042, values: ..u8) {
	for value in values {_ = i8042_queue_push(&k.kbd_queue, value)}
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_keyboard_defaults :: proc(k: ^I8042) {
	k.kbd_leds = 0
	k.kbd_typematic = 0x2B
	k.kbd_scan_set = 2
	k.kbd_expect = .None
	k.key_sequence_count = 0
	k.repeat_active = false
	k.held = {}
	k.held_ext = {}
}

i8042_typematic_delay_ns :: proc(k: ^I8042) -> u64 {
	return u64(((k.kbd_typematic >> 5) & 3) + 1) * 250_000_000
}

i8042_typematic_period_ns :: proc(k: ^I8042) -> u64 {
	a := u64(k.kbd_typematic & 7)
	b := u64((k.kbd_typematic >> 3) & 3)
	return ((8 + a) * (u64(1) << b) * 1_000_000_000 + 239) / 240
}

@(private = "file")
i8042_set1_to_set2 :: proc(code: u8) -> (u8, bool) {
	switch code {
	case 0x01: return 0x76, true
	case 0x02: return 0x16, true
	case 0x03: return 0x1E, true
	case 0x04: return 0x26, true
	case 0x05: return 0x25, true
	case 0x06: return 0x2E, true
	case 0x07: return 0x36, true
	case 0x08: return 0x3D, true
	case 0x09: return 0x3E, true
	case 0x0A: return 0x46, true
	case 0x0B: return 0x45, true
	case 0x0C: return 0x4E, true
	case 0x0D: return 0x55, true
	case 0x0E: return 0x66, true
	case 0x0F: return 0x0D, true
	case 0x10: return 0x15, true
	case 0x11: return 0x1D, true
	case 0x12: return 0x24, true
	case 0x13: return 0x2D, true
	case 0x14: return 0x2C, true
	case 0x15: return 0x35, true
	case 0x16: return 0x3C, true
	case 0x17: return 0x43, true
	case 0x18: return 0x44, true
	case 0x19: return 0x4D, true
	case 0x1A: return 0x54, true
	case 0x1B: return 0x5B, true
	case 0x1C: return 0x5A, true
	case 0x1D: return 0x14, true
	case 0x1E: return 0x1C, true
	case 0x1F: return 0x1B, true
	case 0x20: return 0x23, true
	case 0x21: return 0x2B, true
	case 0x22: return 0x34, true
	case 0x23: return 0x33, true
	case 0x24: return 0x3B, true
	case 0x25: return 0x42, true
	case 0x26: return 0x4B, true
	case 0x27: return 0x4C, true
	case 0x28: return 0x52, true
	case 0x29: return 0x0E, true
	case 0x2A: return 0x12, true
	case 0x2B: return 0x5D, true
	case 0x2C: return 0x1A, true
	case 0x2D: return 0x22, true
	case 0x2E: return 0x21, true
	case 0x2F: return 0x2A, true
	case 0x30: return 0x32, true
	case 0x31: return 0x31, true
	case 0x32: return 0x3A, true
	case 0x33: return 0x41, true
	case 0x34: return 0x49, true
	case 0x35: return 0x4A, true
	case 0x36: return 0x59, true
	case 0x37: return 0x7C, true
	case 0x38: return 0x11, true
	case 0x39: return 0x29, true
	case 0x3A: return 0x58, true
	case 0x3B: return 0x05, true
	case 0x3C: return 0x06, true
	case 0x3D: return 0x04, true
	case 0x3E: return 0x0C, true
	case 0x3F: return 0x03, true
	case 0x40: return 0x0B, true
	case 0x41: return 0x83, true
	case 0x42: return 0x0A, true
	case 0x43: return 0x01, true
	case 0x44: return 0x09, true
	case 0x45: return 0x77, true
	case 0x46: return 0x7E, true
	case 0x47: return 0x6C, true
	case 0x48: return 0x75, true
	case 0x49: return 0x7D, true
	case 0x4A: return 0x7B, true
	case 0x4B: return 0x6B, true
	case 0x4C: return 0x73, true
	case 0x4D: return 0x74, true
	case 0x4E: return 0x79, true
	case 0x4F: return 0x69, true
	case 0x50: return 0x72, true
	case 0x51: return 0x7A, true
	case 0x52: return 0x70, true
	case 0x53: return 0x71, true
	case 0x57: return 0x78, true
	case 0x58: return 0x07, true
	case 0x5B: return 0x1F, true
	case 0x5C: return 0x27, true
	case 0x5D: return 0x2F, true
	}
	return 0, false
}

@(private = "file")
i8042_queue_key_bytes :: proc(k: ^I8042, bytes: []u8) {
	if len(bytes) > len(k.kbd_queue.bytes) - k.kbd_queue.count {return}
	for value in bytes {_ = i8042_queue_push(&k.kbd_queue, value)}
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_emit_key :: proc(k: ^I8042, code: u8, extended, is_break: bool) {
	if !k.kbd_scanning {return}
	if k.kbd_scan_set == 1 || k.cmd_byte & I8042_COMMAND_TRANSLATE != 0 {
		needed := extended ? 2 : 1
		if needed > len(k.kbd_queue.bytes) - k.kbd_queue.count {return}
		if extended {_ = i8042_queue_push(&k.kbd_queue, 0xE0)}
		_ = i8042_queue_push(&k.kbd_queue, code | (is_break ? u8(0x80) : 0))
		i8042_schedule_serial(k)
		return
	}
	set2, mapped := i8042_set1_to_set2(code)
	if !mapped {return}
	needed := 1 + (extended ? 1 : 0) + (is_break ? 1 : 0)
	if needed > len(k.kbd_queue.bytes) - k.kbd_queue.count {return}
	if extended {_ = i8042_queue_push(&k.kbd_queue, 0xE0)}
	if is_break {_ = i8042_queue_push(&k.kbd_queue, 0xF0)}
	_ = i8042_queue_push(&k.kbd_queue, set2)
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_emit_print_screen :: proc(k: ^I8042, is_break: bool) {
	if !k.kbd_scanning {return}
	if k.kbd_scan_set == 1 || k.cmd_byte & I8042_COMMAND_TRANSLATE != 0 {
		make_sequence := [4]u8{0xE0, 0x2A, 0xE0, 0x37}
		break_sequence := [4]u8{0xE0, 0xB7, 0xE0, 0xAA}
		i8042_queue_key_bytes(k, is_break ? break_sequence[:] : make_sequence[:])
		return
	}
	make_sequence := [4]u8{0xE0, 0x12, 0xE0, 0x7C}
	break_sequence := [6]u8{0xE0, 0xF0, 0x7C, 0xE0, 0xF0, 0x12}
	i8042_queue_key_bytes(k, is_break ? break_sequence[:] : make_sequence[:])
}

@(private = "file")
i8042_emit_pause :: proc(k: ^I8042) {
	if !k.kbd_scanning {return}
	if k.kbd_scan_set == 1 || k.cmd_byte & I8042_COMMAND_TRANSLATE != 0 {
		sequence := [6]u8{0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5}
		i8042_queue_key_bytes(k, sequence[:])
		return
	}
	sequence := [8]u8{0xE1, 0x14, 0x77, 0xE1, 0xF0, 0x14, 0xF0, 0x77}
	i8042_queue_key_bytes(k, sequence[:])
}

@(private = "file")
i8042_repeatable_key :: proc(code: u8, extended: bool) -> bool {
	if extended {return code != 0x1D && code != 0x37 && code != 0x38}
	switch code {
	case 0x1D, 0x2A, 0x36, 0x38, 0x3A, 0x45, 0x46: return false
	case: return true
	}
}

@(private = "file")
i8042_held_set :: proc(k: ^I8042, code: u8, extended, held: bool) -> bool {
	bytes := extended ? &k.held_ext : &k.held
	index := int(code >> 3)
	bit := u8(1) << (code & 7)
	was_held := bytes[index] & bit != 0
	if held {bytes[index] |= bit} else {bytes[index] &~= bit}
	return was_held
}

@(private = "file")
i8042_keyboard_byte :: proc(k: ^I8042, value: u8) {
	if k.kbd_expect != .None {
		switch k.kbd_expect {
		case .Led_Byte:
			k.kbd_leds = value & 7
			i8042_queue_keyboard(k, 0xFA)
		case .Rate_Byte:
			k.kbd_typematic = value & 0x7F
			i8042_queue_keyboard(k, 0xFA)
		case .Scan_Set:
			if value == 0 {
				i8042_queue_keyboard(k, 0xFA, k.kbd_scan_set)
			} else if value == 1 || value == 2 {
				k.kbd_scan_set = value
				i8042_queue_keyboard(k, 0xFA)
			} else {
				i8042_queue_keyboard(k, 0xFE)
			}
		case .None:
		}
		k.kbd_expect = .None
		return
	}

	switch value {
	case 0xFF:
		i8042_keyboard_defaults(k)
		k.kbd_scanning = true
		i8042_queue_keyboard(k, 0xFA, 0xAA)
	case 0xFE:
		i8042_queue_keyboard(k, k.kbd_last_tx_valid ? k.kbd_last_tx : 0xFE)
	case 0xF6:
		i8042_keyboard_defaults(k)
		k.kbd_scanning = true
		i8042_queue_keyboard(k, 0xFA)
	case 0xF5:
		i8042_keyboard_defaults(k)
		k.kbd_scanning = false
		i8042_queue_keyboard(k, 0xFA)
	case 0xF4:
		k.kbd_scanning = true
		i8042_queue_keyboard(k, 0xFA)
	case 0xF3:
		k.kbd_expect = .Rate_Byte
		i8042_queue_keyboard(k, 0xFA)
	case 0xF2:
		i8042_queue_keyboard(k, 0xFA, 0xAB, 0x83)
	case 0xF0:
		k.kbd_expect = .Scan_Set
		i8042_queue_keyboard(k, 0xFA)
	case 0xEE:
		i8042_queue_keyboard(k, 0xEE)
	case 0xED:
		k.kbd_expect = .Led_Byte
		i8042_queue_keyboard(k, 0xFA)
	case 0xF7 ..= 0xFD:
		i8042_queue_keyboard(k, 0xFE)
	case:
		i8042_queue_keyboard(k, 0xFE)
	}
}

@(private = "file")
i8042_process_command :: proc(k: ^I8042, value: u8) {
	switch value {
	case 0x20: i8042_controller_output(k, k.cmd_byte)
	case 0x60: k.expect = .Cmd_Byte
	case 0xA7: k.cmd_byte |= 0x20; i8042_update_irq_lines(k)
	case 0xA8: k.cmd_byte &~= 0x20; i8042_update_irq_lines(k)
	case 0xA9: i8042_controller_output(k, 0x00)
	case 0xAA: k.system_flag = true; k.cmd_byte |= 0x04; i8042_controller_output(k, 0x55)
	case 0xAB: i8042_controller_output(k, 0x00)
	case 0xAD: k.cmd_byte |= 0x10; i8042_update_irq_lines(k)
	case 0xAE: k.cmd_byte &~= 0x10; i8042_update_irq_lines(k)
	case 0xC0: i8042_controller_output(k, 0xA0)
	case 0xD0: i8042_controller_output(k, k.output_port)
	case 0xD1: k.expect = .Out_Port
	case 0xD2: k.expect = .Kbd_Output
	case 0xD3: k.expect = .Aux_Output
	case 0xD4: k.expect = .Aux_Device
	case 0xDD: _ = i8042_set_kbc_a20(k, false)
	case 0xDF: _ = i8042_set_kbc_a20(k, true)
	case 0xE0: i8042_controller_output(k, 0x03)
	case:
		if value >= 0xF0 && value & 1 == 0 {i8042_request_reset(k, .Controller_Pulse)}
	}
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_process_data :: proc(k: ^I8042, value: u8) {
	switch k.expect {
	case .Cmd_Byte:
		k.cmd_byte = value
		k.system_flag = value & 0x04 != 0
		i8042_update_irq_lines(k)
	case .Out_Port:
		_ = i8042_set_kbc_a20(k, value & 2 != 0)
		k.output_port = value &~ 2 | (k.a20_kbc ? 2 : 0)
		if value & 1 == 0 {i8042_request_reset(k, .Output_Port)}
	case .Kbd_Output:
		i8042_controller_output(k, value)
	case .Aux_Output:
		i8042_controller_output(k, value, true)
	case .Aux_Device:
		i8042_queue_mouse_reply(k, ps2_mouse_command(&k.mouse, value))
	case .None:
		i8042_keyboard_byte(k, value)
	}
	k.expect = .None
	i8042_schedule_serial(k)
}

@(private = "file")
i8042_process_input :: proc(k: ^I8042) {
	input := k.pending_input
	k.pending_input.valid = false
	if input.command {i8042_process_command(k, input.value)} else {i8042_process_data(k, input.value)}
}

@(private = "file")
i8042_typematic_fire :: proc(k: ^I8042) {
	if !k.repeat_active || !k.kbd_scanning {k.repeat_active = false; return}
	i8042_emit_key(k, k.repeat_code, k.repeat_extended, false)
	k.repeat_wait_ns = i8042_typematic_period_ns(k)
}

@(private = "file")
i8042_service_due :: proc(k: ^I8042) {
	if k.pending_input.valid && k.input_wait_ns == 0 {i8042_process_input(k)}
	if k.host_key_queue.count > 0 && k.host_key_wait_ns == 0 {
		value, _ := i8042_queue_pop(&k.host_key_queue)
		i8042_key(k, value)
		if k.host_key_queue.count > 0 {k.host_key_wait_ns = I8042_HOST_KEY_BYTE_NS}
	}
	if k.repeat_active && k.repeat_wait_ns == 0 {i8042_typematic_fire(k)}
	if k.mouse_due {k.mouse_due = false; i8042_queue_mouse_packet(k)}
	if k.serial_active && k.serial_wait_ns == 0 {
		k.serial_active = false
		k.serial_ready = true
	}
	if k.serial_ready && !k.output_full {i8042_latch_serial(k)}
	i8042_schedule_serial(k)
}

i8042_next_deadline_ns :: proc(k: ^I8042) -> (u64, bool) {
	if k.serial_ready && !k.output_full {return 0, true}
	next := ~u64(0)
	if k.pending_input.valid {next = min(next, k.input_wait_ns)}
	if k.host_key_queue.count > 0 {next = min(next, k.host_key_wait_ns)}
	if k.serial_active {next = min(next, k.serial_wait_ns)}
	if k.repeat_active {next = min(next, k.repeat_wait_ns)}
	if mouse_next, ok := ps2_mouse_next_deadline_ns(&k.mouse); ok {next = min(next, mouse_next)}
	return next, next != ~u64(0)
}

i8042_next_deadline :: proc(k: ^I8042) -> (u64, bool) {
	if delta, ok := i8042_next_deadline_ns(k); ok {return k.now_ns + delta, true}
	return 0, false
}

@(private = "file")
i8042_elapse :: proc(k: ^I8042, ns: u64) {
	if k.pending_input.valid {k.input_wait_ns -= min(k.input_wait_ns, ns)}
	if k.host_key_queue.count > 0 {
		k.host_key_wait_ns -= min(k.host_key_wait_ns, ns)
	}
	if k.serial_active {k.serial_wait_ns -= min(k.serial_wait_ns, ns)}
	if k.repeat_active {k.repeat_wait_ns -= min(k.repeat_wait_ns, ns)}
	if ps2_mouse_advance(&k.mouse, ns) {k.mouse_due = true}
	k.now_ns += ns
}

i8042_advance :: proc(k: ^I8042, ns: u64) {
	remaining := ns
	for {
		i8042_service_due(k)
		next, ok := i8042_next_deadline_ns(k)
		if !ok {k.now_ns += remaining; return}
		if next > remaining {i8042_elapse(k, remaining); return}
		i8042_elapse(k, next)
		remaining -= next
		i8042_service_due(k)
		if remaining == 0 {return}
	}
}

i8042_advance_to :: proc(k: ^I8042, now_ns: u64) {
	if now_ns > k.now_ns {i8042_advance(k, now_ns - k.now_ns)}
}

@(private = "file")
i8042_process_host_key :: proc(k: ^I8042, code: u8, extended, is_break: bool) {
	was_held := i8042_held_set(k, code, extended, !is_break)
	if is_break {
		if k.repeat_active && k.repeat_code == code && k.repeat_extended == extended {k.repeat_active = false}
	} else if was_held {
		return
	} else if i8042_repeatable_key(code, extended) {
		k.repeat_active = true
		k.repeat_code = code
		k.repeat_extended = extended
		k.repeat_wait_ns = i8042_typematic_delay_ns(k)
	}
	i8042_emit_key(k, code, extended, is_break)
}

@(private = "file")
i8042_process_host_print_screen :: proc(k: ^I8042, is_break: bool) {
	code := u8(0x37)
	was_held := i8042_held_set(k, code, true, !is_break)
	if !is_break && was_held {return}
	if is_break && k.repeat_active && k.repeat_code == code && k.repeat_extended {
		k.repeat_active = false
	}
	i8042_emit_print_screen(k, is_break)
}

i8042_key :: proc(k: ^I8042, scancode: u8) {
	if k.key_sequence_count == 0 {
		if scancode == 0xE0 || scancode == 0xE1 {
			k.key_sequence[0] = scancode
			k.key_sequence_count = 1
			return
		}
		i8042_process_host_key(k, scancode & 0x7F, false, scancode & 0x80 != 0)
		return
	}

	if k.key_sequence[0] == 0xE1 {
		expected := [6]u8{0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5}
		index := k.key_sequence_count
		if index >= len(k.key_sequence) || scancode != expected[index] {
			k.key_sequence_count = 0
			i8042_key(k, scancode)
			return
		}
		k.key_sequence[index] = scancode
		k.key_sequence_count += 1
		if k.key_sequence_count == len(expected) {
			k.key_sequence_count = 0
			i8042_emit_pause(k)
		}
		return
	}

	switch k.key_sequence_count {
	case 1:
		k.key_sequence[1] = scancode
		k.key_sequence_count = 2
		if scancode != 0x2A && scancode != 0xB7 {
			k.key_sequence_count = 0
			i8042_process_host_key(k, scancode & 0x7F, true, scancode & 0x80 != 0)
		}
	case 2:
		if scancode != 0xE0 {
			k.key_sequence_count = 0
			i8042_key(k, scancode)
			return
		}
		k.key_sequence[2] = scancode
		k.key_sequence_count = 3
	case 3:
		first_code := k.key_sequence[1]
		valid := first_code == 0x2A && scancode == 0x37 ||
		         first_code == 0xB7 && scancode == 0xAA
		k.key_sequence_count = 0
		if valid {
			i8042_process_host_print_screen(k, first_code == 0xB7)
		} else {
			i8042_key(k, scancode)
		}
	}
}

i8042_schedule_keys :: proc(k: ^I8042, scancodes: []u8) -> bool {
	if k == nil || len(scancodes) == 0 {return false}
	if len(scancodes) > len(k.host_key_queue.bytes) - k.host_key_queue.count {return false}
	was_empty := k.host_key_queue.count == 0
	for scancode in scancodes {_ = i8042_queue_push(&k.host_key_queue, scancode)}
	if was_empty {
		k.host_key_wait_ns = 0
		i8042_service_due(k)
	}
	return true
}

i8042_mouse :: proc(k: ^I8042, dx, dy: i32, buttons: u8) {
	ps2_mouse_update(&k.mouse, dx, dy, buttons)
}

i8042_mouse_wheel :: proc(k: ^I8042, wheel: i32) {
	ps2_mouse_update_wheel(&k.mouse, 0, 0, wheel, k.mouse.buttons)
}

i8042_in :: proc(k: ^I8042, port: u16) -> u8 {
	switch port {
	case 0x60:
		value := k.output_valid ? k.output : 0
		if k.output_full {
			k.output_full = false
			i8042_update_irq_lines(k)
			i8042_schedule_serial(k)
		}
		return value
	case 0x64:
		status: u8
		if k.output_full {status |= 0x01}
		if k.pending_input.valid {status |= 0x02}
		if k.system_flag {status |= 0x04}
		if k.last_input_command {status |= 0x08}
		if k.output_full && k.output_aux {status |= 0x20}
		return status
	case 0x92:
		return k.a20_fast ? 0x02 : 0x00
	}
	return 0xFF
}

i8042_out :: proc(k: ^I8042, port: u16, value: u8) {
	switch port {
	case 0x60, 0x64:
		if k.pending_input.valid {return}
		k.pending_input = I8042_Pending_Input{valid = true, command = port == 0x64, value = value}
		k.input_wait_ns = I8042_CONTROLLER_INPUT_NS
		k.last_input_command = port == 0x64
	case 0x92:
		_ = i8042_set_fast_a20(k, value & 2 != 0)
		if value & 1 != 0 {i8042_request_reset(k, .Fast_A20)}
	}
}
