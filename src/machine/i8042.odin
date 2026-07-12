// SPDX-License-Identifier: GPL-3.0-only
package machine

// i8042 keyboard controller + A20 gate (port 0x92)

I8042_Expect :: enum u8 {
	None,
	Cmd_Byte, // after command 0x60
	Out_Port, // after command 0xD1
	Aux_Byte, // after command 0xD4: no aux device, byte discarded
	Led_Byte, // after 0xED to the device
	Rate_Byte, // after 0xF3 to the device
}

I8042 :: struct {
	fifo:       [32]u8,
	head, tail: int, // ring: head=read, tail=write
	count:      int,
	cmd_byte:   u8, // bit0 IRQ1 enable, bit4 keyboard disable (0xAD/0xAE map here)
	expect:     I8042_Expect,
	a20:        bool,
	pend:       [16]u8, // keyboard-side buffer while CTR bit 4 inhibits the port
	pend_n:     int,
	ctx:        rawptr,
	irq1:       proc(ctx: rawptr),
	reset:      proc(ctx: rawptr),
}

i8042_init :: proc(k: ^I8042, ctx: rawptr, irq1: proc(ctx: rawptr), reset: proc(ctx: rawptr) = nil) {
	k^ = {}
	k.ctx = ctx
	k.irq1 = irq1
	k.reset = reset
}

@(private = "file")
i8042_push :: proc(k: ^I8042, v: u8) {
	if k.count == len(k.fifo) { return } // full: dropped
	was_empty := k.count == 0
	k.fifo[k.tail] = v
	k.tail = (k.tail + 1) % len(k.fifo)
	k.count += 1
	if was_empty && k.cmd_byte & 1 != 0 && k.irq1 != nil { k.irq1(k.ctx) }
}

@(private = "file")
i8042_pop :: proc(k: ^I8042) -> u8 {
	if k.count == 0 { return 0 }
	v := k.fifo[k.head]
	k.head = (k.head + 1) % len(k.fifo)
	k.count -= 1
	// real 8042 keeps OBF asserted: re-pulse IRQ1 while bytes remain queued
	if k.count > 0 && k.cmd_byte & 1 != 0 && k.irq1 != nil { k.irq1(k.ctx) }
	return v
}

// host key (scancode set 1)
i8042_key :: proc(k: ^I8042, scancode: u8) {
	if k.cmd_byte & 0x10 != 0 { // disabled: hold for retransmission on enable
		if k.pend_n < len(k.pend) { k.pend[k.pend_n] = scancode; k.pend_n += 1 }
		return
	}
	i8042_push(k, scancode)
}

// deliver scancodes held while the keyboard port was disabled
@(private = "file")
i8042_flush_pending :: proc(k: ^I8042) {
	for i in 0 ..< k.pend_n { i8042_push(k, k.pend[i]) }
	k.pend_n = 0
}

i8042_in :: proc(k: ^I8042, port: u16) -> u8 {
	switch port {
	case 0x60: return i8042_pop(k)
	case 0x64: return k.count > 0 ? 0x01 : 0x00 // bit0 data ready, bit1 always 0
	case 0x92: return k.a20 ? 0x02 : 0x00
	}
	return 0xFF
}

i8042_out :: proc(k: ^I8042, port: u16, v: u8) {
	switch port {
	case 0x64: // controller commands
		switch v {
		case 0x20: i8042_push(k, k.cmd_byte)
		case 0x60: k.expect = .Cmd_Byte
		case 0xA7, 0xA8: // aux port disable/enable: no aux device in M1
		case 0xA9: i8042_push(k, 0xFF) // aux interface test: absent
		case 0xAA: i8042_push(k, 0x55) // self test
		case 0xAB: i8042_push(k, 0x00) // interface test
		case 0xAD: k.cmd_byte |= 0x10 // disable = CTR bit 4
		case 0xAE: k.cmd_byte &~= 0x10; i8042_flush_pending(k)
		case 0xD0: i8042_push(k, k.a20 ? 0x03 : 0x01) // output port: bit1 A20, bit0 no-reset
		case 0xD1: k.expect = .Out_Port
		case 0xD4: k.expect = .Aux_Byte
		case 0xFE: if k.reset != nil { k.reset(k.ctx) }
		}
	case 0x60: // data: continuation or device command
		switch k.expect {
		case .Cmd_Byte:
			k.cmd_byte = v
			k.expect = .None
			if k.cmd_byte & 0x10 == 0 { i8042_flush_pending(k) }
		case .Out_Port:
			k.a20 = v & 2 != 0
			k.expect = .None
		case .Aux_Byte: // no aux device: parameter swallowed
			k.expect = .None
		case .Led_Byte, .Rate_Byte:
			i8042_push(k, 0xFA)
			k.expect = .None
		case .None:
			switch v {
			case 0xFF: i8042_push(k, 0xFA); i8042_push(k, 0xAA) // keyboard reset
			case 0xED: i8042_push(k, 0xFA); k.expect = .Led_Byte
			case 0xF3: i8042_push(k, 0xFA); k.expect = .Rate_Byte
			case:      i8042_push(k, 0xFA) // 0xF4/0xF5 and the rest: ACK
			}
		}
	case 0x92:
		k.a20 = v & 2 != 0
		if v & 1 != 0 && k.reset != nil { k.reset(k.ctx) } // fast reset
	}
}
