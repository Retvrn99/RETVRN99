// SPDX-License-Identifier: GPL-3.0-only
package machine

// Controlador de teclado i8042 + puerta A20 (puerto 0x92)

I8042_Expect :: enum u8 {
	None,
	Cmd_Byte, // tras comando 0x60
	Out_Port, // tras comando 0xD1
	Led_Byte, // tras 0xED al dispositivo
	Rate_Byte, // tras 0xF3 al dispositivo
}

I8042 :: struct {
	fifo:       [32]u8,
	head, tail: int, // anillo: head=lectura, tail=escritura
	count:      int,
	cmd_byte:   u8,
	expect:     I8042_Expect,
	a20:        bool,
	kbd_off:    bool,
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
	if k.count == len(k.fifo) { return } // lleno: se descarta
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
	return v
}

// tecla del anfitrión (scancode set 1)
i8042_key :: proc(k: ^I8042, scancode: u8) {
	if k.kbd_off { return }
	i8042_push(k, scancode)
}

i8042_in :: proc(k: ^I8042, port: u16) -> u8 {
	switch port {
	case 0x60: return i8042_pop(k)
	case 0x64: return k.count > 0 ? 0x01 : 0x00 // bit0 datos listos, bit1 siempre 0
	case 0x92: return k.a20 ? 0x02 : 0x00
	}
	return 0xFF
}

i8042_out :: proc(k: ^I8042, port: u16, v: u8) {
	switch port {
	case 0x64: // comandos del controlador
		switch v {
		case 0x20: i8042_push(k, k.cmd_byte)
		case 0x60: k.expect = .Cmd_Byte
		case 0xAA: i8042_push(k, 0x55) // autotest
		case 0xAB: i8042_push(k, 0x00) // test de interfaz
		case 0xAD: k.kbd_off = true
		case 0xAE: k.kbd_off = false
		case 0xD1: k.expect = .Out_Port
		case 0xFE: if k.reset != nil { k.reset(k.ctx) }
		}
	case 0x60: // datos: continuación o comando al dispositivo
		switch k.expect {
		case .Cmd_Byte:
			k.cmd_byte = v
			k.expect = .None
		case .Out_Port:
			k.a20 = v & 2 != 0
			k.expect = .None
		case .Led_Byte, .Rate_Byte:
			i8042_push(k, 0xFA)
			k.expect = .None
		case .None:
			switch v {
			case 0xFF: i8042_push(k, 0xFA); i8042_push(k, 0xAA) // reset del teclado
			case 0xED: i8042_push(k, 0xFA); k.expect = .Led_Byte
			case 0xF3: i8042_push(k, 0xFA); k.expect = .Rate_Byte
			case:      i8042_push(k, 0xFA) // 0xF4/0xF5 y demás: ACK
			}
		}
	case 0x92:
		k.a20 = v & 2 != 0
		if v & 1 != 0 && k.reset != nil { k.reset(k.ctx) } // reinicio rápido
	}
}
