// SPDX-License-Identifier: GPL-3.0-only
package machine

// 8259A behavior adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

Pic_Init_Stage :: enum u8 {
	Ready,
	Expect_ICW2,
	Expect_ICW3,
	Expect_ICW4,
}

Pic :: struct {
	irr, asserted, isr, imr: u8,
	base, icw3:              u8,
	init:                    Pic_Init_Stage,
	expect_icw4, single:     bool,
	level_triggered:         bool,
	auto_eoi, buffered:      bool,
	is_master, mode_8086:    bool,
	read_isr, poll_pending:  bool,
	special_mask, sfnm:      bool,
	lowest:                  u8,
	auto_rotate:             bool,
	elcr:                    u8,
}

Pic_Interrupt_Kind :: enum u8 {
	Master,
	Slave,
	Spurious_Master,
	Spurious_Slave,
}

Pic_Interrupt_Offer :: struct {
	vector:                u8,
	master_irq, slave_irq: u8,
	kind:                  Pic_Interrupt_Kind,
	epoch:                 u64,
}

Pic_Irq_Source :: enum u8 {
	Pci_Pirq,
}

Pic_Pair :: struct {
	master, slave:    Pic,
	epoch:            u64,
	master_int_latch: bool,
	direct_asserted:  u16,
	source_asserted:  [16]u8,
}

PIC_ELCR_MASTER_MASK :: u8(0xF8)
PIC_ELCR_SLAVE_MASK :: u8(0xDE)

@(private = "file")
pic_chip_level_mode :: proc(p: ^Pic, irq: u8) -> bool {
	return p.level_triggered || p.elcr & (u8(1) << irq) != 0
}

@(private = "file")
pic_chip_set_input :: proc(p: ^Pic, irq: u8, asserted: bool) {
	bit := u8(1) << irq
	was_asserted := p.asserted & bit != 0
	if asserted {
		p.asserted |= bit
		if pic_chip_level_mode(p, irq) || !was_asserted {p.irr |= bit}
	} else {
		p.asserted &~= bit
		if pic_chip_level_mode(p, irq) {p.irr &~= bit}
	}
}

@(private = "file")
pic_chip_priority_irq :: proc(p: ^Pic, slot: u8) -> u8 {
	return (p.lowest + 1 + slot) & 7
}

@(private = "file")
pic_chip_highest_isr :: proc(p: ^Pic) -> (u8, bool) {
	for slot in u8(0) ..< 8 {
		irq := pic_chip_priority_irq(p, slot)
		if p.isr & (u8(1) << irq) != 0 {return irq, true}
	}
	return 0, false
}

@(private = "file")
pic_chip_pending :: proc(p: ^Pic, cascade_exempt: int = -1) -> (u8, bool) {
	requests := p.irr &~ p.imr
	for slot in u8(0) ..< 8 {
		irq := pic_chip_priority_irq(p, slot)
		bit := u8(1) << irq
		if p.isr & bit != 0 && int(irq) != cascade_exempt {
			if p.special_mask && p.imr & bit != 0 {continue}
			return 0, false
		}
		if requests & bit != 0 {return irq, true}
	}
	return 0, false
}

@(private = "file")
pic_chip_clear_isr :: proc(p: ^Pic, irq: u8) {
	bit := u8(1) << irq
	if p.isr & bit == 0 {return}
	p.isr &~= bit
	if pic_chip_level_mode(p, irq) && p.asserted & bit != 0 {p.irr |= bit}
}

@(private = "file")
pic_chip_set_in_service :: proc(p: ^Pic, irq: u8) {
	bit := u8(1) << irq
	p.irr &~= bit
	p.isr |= bit
	if p.auto_eoi {
		pic_chip_clear_isr(p, irq)
		if p.auto_rotate {p.lowest = irq}
	}
}

@(private = "file")
pic_chip_eoi :: proc(p: ^Pic, value: u8) {
	level := value & 7
	switch value >> 5 {
	case 0b000:
		p.auto_rotate = false
	case 0b001:
		if irq, ok := pic_chip_highest_isr(p); ok {pic_chip_clear_isr(p, irq)}
	case 0b011:
		pic_chip_clear_isr(p, level)
	case 0b100:
		p.auto_rotate = true
	case 0b101:
		if irq, ok := pic_chip_highest_isr(p); ok {
			pic_chip_clear_isr(p, irq)
			p.lowest = irq
		}
	case 0b110:
		p.lowest = level
	case 0b111:
		pic_chip_clear_isr(p, level)
		p.lowest = level
	case:
	}
}

@(private = "file")
pic_chip_command :: proc(p: ^Pic, value: u8) {
	if value & 0x10 != 0 {
		p.irr = 0
		p.isr = 0
		p.imr = 0
		p.read_isr = false
		p.poll_pending = false
		p.special_mask = false
		p.lowest = 7
		p.auto_rotate = false
		p.auto_eoi = false
		p.buffered = false
		p.is_master = false
		p.mode_8086 = false
		p.sfnm = false
		p.expect_icw4 = value & 0x01 != 0
		p.single = value & 0x02 != 0
		p.level_triggered = value & 0x08 != 0
		if p.level_triggered {p.irr = p.asserted}
		p.init = .Expect_ICW2
		return
	}
	if value & 0x08 != 0 {
		if value & 0x02 != 0 {p.read_isr = value & 0x01 != 0}
		if value & 0x04 != 0 {p.poll_pending = true}
		if value & 0x40 != 0 {p.special_mask = value & 0x20 != 0}
		return
	}
	pic_chip_eoi(p, value)
}

@(private = "file")
pic_chip_data :: proc(p: ^Pic, value: u8) {
	switch p.init {
	case .Expect_ICW2:
		p.base = value & 0xF8
		if !p.single {p.init = .Expect_ICW3} else if p.expect_icw4 {p.init = .Expect_ICW4} else {p.init = .Ready}
	case .Expect_ICW3:
		p.icw3 = value
		p.init = p.expect_icw4 ? .Expect_ICW4 : .Ready
	case .Expect_ICW4:
		p.mode_8086 = value & 0x01 != 0
		p.auto_eoi = value & 0x02 != 0
		p.is_master = value & 0x04 != 0
		p.buffered = value & 0x08 != 0
		p.sfnm = value & 0x10 != 0
		p.init = .Ready
	case .Ready:
		p.imr = value
	}
}

@(private = "file")
pic_master_cascade_exempt :: proc(pp: ^Pic_Pair) -> int {
	pin := pp.slave.icw3 & 7
	if pp.master.sfnm && pp.master.icw3 & (u8(1) << pin) != 0 {return int(pin)}
	return -1
}

@(private = "file")
pic_sync_cascade :: proc(pp: ^Pic_Pair) {
	pin := pp.slave.icw3 & 7
	_, pending := pic_chip_pending(&pp.slave)
	pic_chip_set_input(&pp.master, pin, pending)
}

@(private = "file")
pic_master_pending :: proc(pp: ^Pic_Pair) -> (u8, bool) {
	return pic_chip_pending(&pp.master, pic_master_cascade_exempt(pp))
}

@(private = "file")
pic_after_mutation :: proc(pp: ^Pic_Pair) {
	pic_sync_cascade(pp)
	if _, pending := pic_master_pending(pp); pending {pp.master_int_latch = true}
	pp.epoch += 1
}

@(private = "file")
pic_chip_set_elcr :: proc(p: ^Pic, value, writable: u8) {
	old := p.elcr
	p.elcr = value & writable
	new_level := p.elcr &~ old
	p.irr |= new_level & p.asserted
}

@(private = "file")
pic_chip_poll :: proc(p: ^Pic, cascade_exempt: int = -1) -> u8 {
	p.poll_pending = false
	if irq, ok := pic_chip_pending(p, cascade_exempt); ok {
		pic_chip_set_in_service(p, irq)
		return 0x80 | irq
	}
	return 0
}

pic_out :: proc(pp: ^Pic_Pair, port: u16, value: u8) {
	switch port {
	case 0x20:
		if value & 0x10 != 0 {pp.master_int_latch = false}
		pic_chip_command(&pp.master, value)
	case 0x21:
		pic_chip_data(&pp.master, value)
	case 0xA0:
		pic_chip_command(&pp.slave, value)
	case 0xA1:
		old_pin := pp.slave.icw3 & 7
		pic_chip_data(&pp.slave, value)
		new_pin := pp.slave.icw3 & 7
		if old_pin != new_pin {pic_chip_set_input(&pp.master, old_pin, false)}
	case 0x4D0:
		pic_chip_set_elcr(&pp.master, value, PIC_ELCR_MASTER_MASK)
	case 0x4D1:
		pic_chip_set_elcr(&pp.slave, value, PIC_ELCR_SLAVE_MASK)
	case:
		return
	}
	pic_after_mutation(pp)
}

pic_in :: proc(pp: ^Pic_Pair, port: u16) -> u8 {
	switch port {
	case 0x20, 0x21:
		if pp.master.poll_pending {
			value := pic_chip_poll(&pp.master, pic_master_cascade_exempt(pp))
			pp.master_int_latch = false
			pic_after_mutation(pp)
			return value
		}
		return port == 0x20 ? (pp.master.read_isr ? pp.master.isr : pp.master.irr) : pp.master.imr
	case 0xA0, 0xA1:
		if pp.slave.poll_pending {
			value := pic_chip_poll(&pp.slave)
			pic_after_mutation(pp)
			return value
		}
		return port == 0xA0 ? (pp.slave.read_isr ? pp.slave.isr : pp.slave.irr) : pp.slave.imr
	case 0x4D0:
		return pp.master.elcr
	case 0x4D1:
		return pp.slave.elcr
	}
	return 0xFF
}

pic_raise :: proc(pp: ^Pic_Pair, irq: u8) {
	if irq >= 16 {return}
	if irq < 8 {pp.master.irr |= u8(1) << irq} else {pp.slave.irr |= u8(1) << (irq - 8)}
	pic_after_mutation(pp)
}

@(private = "file")
pic_refresh_external_line :: proc(pp: ^Pic_Pair, irq: u8) {
	bit := u16(1) << irq
	asserted := pp.direct_asserted & bit != 0 || pp.source_asserted[irq] != 0
	if irq < 8 {
		pic_chip_set_input(&pp.master, irq, asserted)
	} else {
		pic_chip_set_input(&pp.slave, irq - 8, asserted)
	}
}

pic_set_irq_level :: proc(pp: ^Pic_Pair, irq: u8, asserted: bool) {
	if irq >= 16 {return}
	bit := u16(1) << irq
	if asserted {pp.direct_asserted |= bit} else {pp.direct_asserted &~= bit}
	pic_refresh_external_line(pp, irq)
	pic_after_mutation(pp)
}

pic_set_irq_source_level :: proc(pp: ^Pic_Pair, irq: u8, source: Pic_Irq_Source, asserted: bool) {
	if irq >= 16 {return}
	source_bit := u8(1) << u8(source)
	if asserted {pp.source_asserted[irq] |= source_bit} else {pp.source_asserted[irq] &~= source_bit}
	pic_refresh_external_line(pp, irq)
	pic_after_mutation(pp)
}

pic_lower :: proc(pp: ^Pic_Pair, irq: u8) {
	pic_set_irq_level(pp, irq, false)
}

pic_irq_unmasked :: proc(pp: ^Pic_Pair, irq: u8) -> bool {
	if irq >= 16 {return false}
	if irq < 8 {return pp.master.imr & (u8(1) << irq) == 0}
	return pp.slave.imr & (u8(1) << (irq - 8)) == 0
}

pic_irq_deliverable :: proc(pp: ^Pic_Pair, irq: u8) -> bool {
	if !pic_irq_unmasked(pp, irq) {return false}
	if irq < 8 {return true}
	pin := pp.slave.icw3 & 7
	return pp.master.imr & (u8(1) << pin) == 0
}

pic_latch_interrupt :: proc(pp: ^Pic_Pair) -> bool {
	if _, ok := pic_master_pending(pp); !ok {return false}
	if !pp.master_int_latch {
		pp.master_int_latch = true
		pp.epoch += 1
	}
	return true
}

pic_offer :: proc(pp: ^Pic_Pair) -> (Pic_Interrupt_Offer, bool) {
	master_irq, master_ok := pic_master_pending(pp)
	if !master_ok {
		if pp.master_int_latch {
			return Pic_Interrupt_Offer {
					vector = pp.master.base | 7,
					master_irq = 7,
					kind = .Spurious_Master,
					epoch = pp.epoch,
				},
				true
		}
		return {}, false
	}
	offer := Pic_Interrupt_Offer {
		vector     = pp.master.base | master_irq,
		master_irq = master_irq,
		epoch      = pp.epoch,
	}
	pin := pp.slave.icw3 & 7
	if pp.master.icw3 & (u8(1) << master_irq) == 0 || master_irq != pin {
		offer.kind = .Master
		return offer, true
	}
	if slave_irq, slave_ok := pic_chip_pending(&pp.slave); slave_ok {
		offer.kind = .Slave
		offer.slave_irq = slave_irq
		offer.vector = pp.slave.base | slave_irq
	} else {
		offer.kind = .Spurious_Slave
		offer.slave_irq = 7
		offer.vector = pp.slave.base | 7
	}
	return offer, true
}

Pic_Interrupt_Token :: Pic_Interrupt_Offer

pic_interrupt_preview :: proc(pp: ^Pic_Pair) -> (Pic_Interrupt_Token, bool) {
	return pic_offer(pp)
}

pic_commit :: proc(pp: ^Pic_Pair, offer: Pic_Interrupt_Offer) -> bool {
	if offer.epoch != pp.epoch {return false}
	pp.master_int_latch = false
	switch offer.kind {
	case .Master:
		pic_chip_set_in_service(&pp.master, offer.master_irq)
	case .Slave:
		pic_chip_set_in_service(&pp.master, offer.master_irq)
		pic_chip_set_in_service(&pp.slave, offer.slave_irq)
	case .Spurious_Slave:
		pic_chip_set_in_service(&pp.master, offer.master_irq)
	case .Spurious_Master:
	}
	pic_after_mutation(pp)
	return true
}

pic_interrupt_commit :: proc(pp: ^Pic_Pair, token: Pic_Interrupt_Token) -> bool {
	return pic_commit(pp, token)
}

pic_ack :: proc(pp: ^Pic_Pair) -> (u8, bool) {
	if offer, ok := pic_offer(pp); ok && pic_commit(pp, offer) {return offer.vector, true}
	return 0, false
}

pic_has_pending :: proc(pp: ^Pic_Pair) -> bool {
	if _, ok := pic_master_pending(pp); ok {return true}
	return pp.master_int_latch
}
