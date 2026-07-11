// SPDX-License-Identifier: GPL-3.0-only
package machine

Pic :: struct {
	irr, isr, imr, base: u8,
	icw_step:            u8, // 0=ready, 1..3 during init
	read_isr:            bool,
}

Pic_Pair :: struct { master, slave: Pic }

pic_chip_out :: proc(p: ^Pic, cmd: bool, v: u8) {
	if cmd {
		if v & 0x10 != 0 { p.icw_step = 1; p.imr = 0; p.isr = 0; p.irr = 0; return } // ICW1
		if v == 0x20 { // non-specific EOI: clears the highest-priority ISR bit
			for i in u8(0) ..< 8 do if p.isr & (1 << i) != 0 { p.isr &~= 1 << i; break }
			return
		}
		if v == 0x0A { p.read_isr = false }
		if v == 0x0B { p.read_isr = true }
		return
	}
	switch p.icw_step {
	case 1: p.base = v; p.icw_step = 2
	case 2: p.icw_step = 3
	case 3: p.icw_step = 0
	case:   p.imr = v // OCW1
	}
}

pic_chip_in :: proc(p: ^Pic, cmd: bool) -> u8 {
	if cmd { return p.read_isr ? p.isr : p.irr }
	return p.imr
}

pic_out :: proc(pp: ^Pic_Pair, port: u16, v: u8) {
	switch port {
	case 0x20: pic_chip_out(&pp.master, true, v)
	case 0x21: pic_chip_out(&pp.master, false, v)
	case 0xA0: pic_chip_out(&pp.slave, true, v)
	case 0xA1: pic_chip_out(&pp.slave, false, v)
	}
}

pic_in :: proc(pp: ^Pic_Pair, port: u16) -> u8 {
	switch port {
	case 0x20: return pic_chip_in(&pp.master, true)
	case 0x21: return pic_chip_in(&pp.master, false)
	case 0xA0: return pic_chip_in(&pp.slave, true)
	case 0xA1: return pic_chip_in(&pp.slave, false)
	}
	return 0xFF
}

pic_raise :: proc(pp: ^Pic_Pair, irq: u8) {
	if irq < 8 { pp.master.irr |= 1 << irq } else {
		pp.slave.irr |= 1 << (irq - 8)
		pp.master.irr |= 1 << 2 // cascade
	}
}

pic_chip_pending :: proc(p: ^Pic) -> (u8, bool) {
	avail := p.irr &~ p.imr
	for i in u8(0) ..< 8 {
		bit := u8(1) << i
		if p.isr & bit != 0 { return 0, false } // higher-priority IRQ in service
		if avail & bit != 0 { return i, true }
	}
	return 0, false
}

// returns the vector if an IRQ is ready and marks it in service
pic_ack :: proc(pp: ^Pic_Pair) -> (u8, bool) {
	i, ok := pic_chip_pending(&pp.master)
	if !ok { return 0, false }
	if i == 2 {
		j, ok2 := pic_chip_pending(&pp.slave)
		if !ok2 { pp.master.irr &~= 1 << 2; return 0, false }
		pp.slave.irr &~= 1 << j; pp.slave.isr |= 1 << j
		pp.master.irr &~= 1 << 2; pp.master.isr |= 1 << 2
		return pp.slave.base + j, true
	}
	pp.master.irr &~= 1 << i; pp.master.isr |= 1 << i
	return pp.master.base + i, true
}

pic_has_pending :: proc(pp: ^Pic_Pair) -> bool {
	_, ok := pic_chip_pending(&pp.master)
	return ok
}
