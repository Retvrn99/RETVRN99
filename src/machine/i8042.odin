// SPDX-License-Identifier: GPL-3.0-only
package machine

// i8042 keyboard/mouse controller + A20 gate (port 0x92)

I8042_AUX_BYTE_NS :: u64(1_000_000)

I8042_Expect :: enum u8 {
	None,
	Cmd_Byte,
	Out_Port,
	Kbd_Output,
	Aux_Output,
	Aux_Device,
	Led_Byte,
	Rate_Byte,
}

I8042_Output :: struct {
	value: u8,
	aux:   bool,
}

I8042 :: struct {
	fifo:       [64]I8042_Output,
	head, tail: int,
	count:      int,
	aux_wait_ns: u64,
	cmd_byte:   u8, // IRQ1/IRQ12 enables in bits 0/1; port disables in bits 4/5
	expect:     I8042_Expect,
	a20:        bool,
	pend:       [16]u8,
	pend_n:     int,
	mouse:      Ps2_Mouse,
	ctx:        rawptr,
	irq1:       proc(ctx: rawptr),
	irq12:      proc(ctx: rawptr),
	reset:      proc(ctx: rawptr),
	a20_control: proc(ctx: rawptr, enabled: bool) -> bool,
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
	k.ctx = ctx
	k.irq1 = irq1
	k.irq12 = irq12
	k.reset = reset
	k.a20_control = a20_control
	ps2_mouse_init(&k.mouse)
}

@(private = "file")
i8042_set_a20 :: proc(k: ^I8042, enabled: bool) {
	if k.a20 == enabled {return}
	if k.a20_control != nil && !k.a20_control(k.ctx, enabled) {return}
	k.a20 = enabled
}

@(private = "file")
i8042_raise_head :: proc(k: ^I8042) {
	if k.count == 0 {return}
	entry := k.fifo[k.head]
	if entry.aux {
		if k.aux_wait_ns > 0 {return}
		if k.cmd_byte & 0x02 != 0 && k.irq12 != nil {k.irq12(k.ctx)}
	} else {
		if k.cmd_byte & 0x01 != 0 && k.irq1 != nil {k.irq1(k.ctx)}
	}
}

@(private = "file")
i8042_push :: proc(k: ^I8042, value: u8, aux: bool = false) {
	if k.count == len(k.fifo) {return}
	was_empty := k.count == 0
	k.fifo[k.tail] = I8042_Output {
		value = value,
		aux   = aux,
	}
	k.tail = (k.tail + 1) % len(k.fifo)
	k.count += 1
	if aux {ps2_mouse_note_tx(&k.mouse, value)}
	if was_empty {i8042_raise_head(k)}
}

@(private = "file")
i8042_push_mouse_reply :: proc(k: ^I8042, reply: Ps2_Mouse_Reply) {
	if reply.count > len(k.fifo) - k.count {return}
	for i in 0 ..< reply.count {i8042_push(k, reply.bytes[i], true)}
}

@(private = "file")
i8042_flush_mouse :: proc(k: ^I8042) {
	if k.cmd_byte & 0x20 != 0 || !ps2_mouse_stream_ready(&k.mouse) {return}
	if len(k.fifo) - k.count < 3 {return}
	packet := ps2_mouse_packet(&k.mouse)
	for value in packet {i8042_push(k, value, true)}
}

@(private = "file")
i8042_pop :: proc(k: ^I8042) -> u8 {
	if k.count == 0 {return 0}
	entry := k.fifo[k.head]
	if entry.aux && k.aux_wait_ns > 0 {return 0}
	value := entry.value
	k.head = (k.head + 1) % len(k.fifo)
	k.count -= 1
	if entry.aux {k.aux_wait_ns = I8042_AUX_BYTE_NS}
	i8042_flush_mouse(k)
	if k.count > 0 {
		if !k.fifo[k.head].aux {k.aux_wait_ns = 0}
		i8042_raise_head(k)
	}
	return value
}

i8042_advance :: proc(k: ^I8042, ns: u64) {
	if k.aux_wait_ns == 0 {return}
	if ns < k.aux_wait_ns {
		k.aux_wait_ns -= ns
		return
	}
	k.aux_wait_ns = 0
	i8042_raise_head(k)
}

// host key (scancode set 1)
i8042_key :: proc(k: ^I8042, scancode: u8) {
	if k.cmd_byte & 0x10 != 0 {
		if k.pend_n < len(k.pend) {k.pend[k.pend_n] = scancode; k.pend_n += 1}
		return
	}
	i8042_push(k, scancode)
}

// host mouse delta; positive host Y points down
i8042_mouse :: proc(k: ^I8042, dx, dy: i32, buttons: u8) {
	ps2_mouse_update(&k.mouse, dx, dy, buttons)
	i8042_flush_mouse(k)
}

@(private = "file")
i8042_flush_pending :: proc(k: ^I8042) {
	for i in 0 ..< k.pend_n {i8042_push(k, k.pend[i])}
	k.pend_n = 0
}

i8042_in :: proc(k: ^I8042, port: u16) -> u8 {
	switch port {
	case 0x60:
		return i8042_pop(k)
	case 0x64:
		if k.count == 0 || k.fifo[k.head].aux && k.aux_wait_ns > 0 {return 0}
		return k.fifo[k.head].aux ? 0x21 : 0x01
	case 0x92:
		return k.a20 ? 0x02 : 0x00
	}
	return 0xFF
}

i8042_out :: proc(k: ^I8042, port: u16, value: u8) {
	switch port {
	case 0x64:
		switch value {
		case 0x20:
			i8042_push(k, k.cmd_byte)
		case 0x60:
			k.expect = .Cmd_Byte
		case 0xA7:
			k.cmd_byte |= 0x20
		case 0xA8:
			k.cmd_byte &~= 0x20
			i8042_flush_mouse(k)
		case 0xA9:
			i8042_push(k, 0x00)
		case 0xAA:
			i8042_push(k, 0x55)
		case 0xAB:
			i8042_push(k, 0x00)
		case 0xAD:
			k.cmd_byte |= 0x10
		case 0xAE:
			k.cmd_byte &~= 0x10
			i8042_flush_pending(k)
		case 0xD0:
			i8042_push(k, k.a20 ? 0x03 : 0x01)
		case 0xD1:
			k.expect = .Out_Port
		case 0xD2:
			k.expect = .Kbd_Output
		case 0xD3:
			k.expect = .Aux_Output
		case 0xD4:
			k.expect = .Aux_Device
		case 0xFE:
			if k.reset != nil {k.reset(k.ctx)}
		}
	case 0x60:
		switch k.expect {
		case .Cmd_Byte:
			old_cmd := k.cmd_byte
			had_output := k.count > 0
			old_head_aux := had_output && k.fifo[k.head].aux
			k.cmd_byte = value
			k.expect = .None
			if k.cmd_byte & 0x10 == 0 {i8042_flush_pending(k)}
			if k.cmd_byte & 0x20 == 0 {i8042_flush_mouse(k)}
			if had_output && k.count > 0 {
				new_irq := old_head_aux ? k.cmd_byte & 0x02 : k.cmd_byte & 0x01
				old_irq := old_head_aux ? old_cmd & 0x02 : old_cmd & 0x01
				if new_irq != 0 && old_irq == 0 {i8042_raise_head(k)}
			}
		case .Out_Port:
			i8042_set_a20(k, value & 2 != 0)
			k.expect = .None
			if value & 1 == 0 && k.reset != nil {k.reset(k.ctx)}
		case .Kbd_Output:
			k.expect = .None
			i8042_push(k, value)
		case .Aux_Output:
			k.expect = .None
			i8042_push(k, value, true)
		case .Aux_Device:
			k.expect = .None
			i8042_push_mouse_reply(k, ps2_mouse_command(&k.mouse, value))
		case .Led_Byte, .Rate_Byte:
			i8042_push(k, 0xFA)
			k.expect = .None
		case .None:
			switch value {
			case 0xFF:
				i8042_push(k, 0xFA)
				i8042_push(k, 0xAA)
			case 0xED:
				i8042_push(k, 0xFA)
				k.expect = .Led_Byte
			case 0xF3:
				i8042_push(k, 0xFA)
				k.expect = .Rate_Byte
			case:
				i8042_push(k, 0xFA)
			}
		}
	case 0x92:
		i8042_set_a20(k, value & 2 != 0)
		if value & 1 != 0 && k.reset != nil {k.reset(k.ctx)}
	}
}
