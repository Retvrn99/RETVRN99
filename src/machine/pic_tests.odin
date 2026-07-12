// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

pic_setup :: proc(p: ^Pic_Pair) { // standard BIOS ICW: base 08h/70h
	pic_out(p, 0x20, 0x11); pic_out(p, 0x21, 0x08); pic_out(p, 0x21, 0x04); pic_out(p, 0x21, 0x01)
	pic_out(p, 0xA0, 0x11); pic_out(p, 0xA1, 0x70); pic_out(p, 0xA1, 0x02); pic_out(p, 0xA1, 0x01)
	pic_out(p, 0x21, 0x00); pic_out(p, 0xA1, 0x00) // unmask everything
}

@(test)
test_pic_irq0_vector :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 0)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x08))
	_, ok2 := pic_ack(&p) // ISR blocks until EOI
	testing.expect(t, !ok2)
	pic_out(&p, 0x20, 0x20) // EOI
	pic_raise(&p, 0)
	_, ok3 := pic_ack(&p)
	testing.expect(t, ok3)
}

@(test)
test_pic_mask_and_cascade :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x21, 0x01) // mask IRQ0
	pic_raise(&p, 0)
	_, ok := pic_ack(&p)
	testing.expect(t, !ok)
	pic_raise(&p, 8) // slave -> vector 0x70
	v, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
	testing.expect_value(t, v, u8(0x70))
}

@(test)
test_pic_specific_eoi :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 3)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x0B))
	pic_out(&p, 0x20, 0x60) // specific EOI for IRQ0: wrong level, ISR3 stays
	testing.expect_value(t, p.master.isr, u8(0x08))
	pic_out(&p, 0x20, 0x63) // specific EOI for IRQ3
	testing.expect_value(t, p.master.isr, u8(0))
	pic_raise(&p, 3) // level usable again
	_, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
}

@(test)
test_pic_rotate_eoi_variants :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 0)
	_, ok := pic_ack(&p)
	testing.expect(t, ok)
	pic_out(&p, 0x20, 0xA0) // rotate on non-specific EOI still clears ISR
	testing.expect_value(t, p.master.isr, u8(0))
	pic_raise(&p, 1)
	_, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
	pic_out(&p, 0x20, 0xE1) // rotate on specific EOI clears the named level
	testing.expect_value(t, p.master.isr, u8(0))
}

// two slave IRQs pending at once: the cascade must stay asserted after the
// first is serviced (level, not a one-shot latch)
@(test)
test_pic_two_slave_irqs :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 12)
	pic_raise(&p, 14)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x74))
	pic_out(&p, 0xA0, 0x20) // slave EOI
	pic_out(&p, 0x20, 0x20) // master EOI
	testing.expect(t, pic_has_pending(&p)) // IRQ14 still queued behind the cascade
	v2, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, u8(0x76))
}

// a slave IRQ latched while masked must surface once the guest unmasks it
@(test)
test_pic_slave_unmask_recovers :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0xA1, 0x40) // mask IRQ14 on the slave
	pic_raise(&p, 14)
	_, ok := pic_ack(&p)
	testing.expect(t, !ok)
	pic_out(&p, 0xA1, 0x00) // unmask
	testing.expect(t, pic_has_pending(&p))
	v, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
	testing.expect_value(t, v, u8(0x76))
}
