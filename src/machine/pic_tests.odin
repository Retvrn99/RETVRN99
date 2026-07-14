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

@(private = "file")
pic_setup_level :: proc(p: ^Pic_Pair) {
	pic_out(p, 0x20, 0x19); pic_out(p, 0x21, 0x08); pic_out(p, 0x21, 0x04); pic_out(p, 0x21, 0x01)
	pic_out(p, 0xA0, 0x19); pic_out(p, 0xA1, 0x70); pic_out(p, 0xA1, 0x02); pic_out(p, 0xA1, 0x01)
}

@(private = "file")
pic_setup_sfnm :: proc(p: ^Pic_Pair) {
	pic_out(p, 0x20, 0x11); pic_out(p, 0x21, 0x08); pic_out(p, 0x21, 0x04); pic_out(p, 0x21, 0x11)
	pic_out(p, 0xA0, 0x11); pic_out(p, 0xA1, 0x70); pic_out(p, 0xA1, 0x02); pic_out(p, 0xA1, 0x01)
}

@(test)
test_pic_preview_is_transactional :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 3)
	epoch, irr, isr := p.epoch, p.master.irr, p.master.isr
	token, ok := pic_interrupt_preview(&p)
	testing.expect(t, ok)
	testing.expect_value(t, token.vector, u8(0x0B))
	testing.expect_value(t, p.epoch, epoch)
	testing.expect_value(t, p.master.irr, irr)
	testing.expect_value(t, p.master.isr, isr)
	testing.expect(t, pic_interrupt_commit(&p, token))
	testing.expect_value(t, p.master.irr, u8(0))
	testing.expect_value(t, p.master.isr, u8(0x08))
	testing.expect(t, !pic_interrupt_commit(&p, token))
}

@(test)
test_pic_deferred_offer_can_be_replaced :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 4)
	stale, _ := pic_offer(&p)
	pic_raise(&p, 1)
	testing.expect(t, !pic_commit(&p, stale))
	fresh, ok := pic_offer(&p)
	testing.expect(t, ok)
	testing.expect_value(t, fresh.vector, u8(0x09))
	testing.expect(t, pic_commit(&p, fresh))
}

@(test)
test_pic_poll_acknowledges_request :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 3)
	pic_out(&p, 0x20, 0x0C)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0x83))
	testing.expect_value(t, p.master.irr, u8(0))
	testing.expect_value(t, p.master.isr, u8(0x08))
	testing.expect_value(t, pic_in(&p, 0x20), u8(0))
}

@(test)
test_pic_poll_without_request_returns_zero :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x20, 0x0C)
	testing.expect_value(t, pic_in(&p, 0x21), u8(0))
	testing.expect_value(t, p.master.isr, u8(0))
}

@(test)
test_pic_ocw3_read_selection :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 5)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0x20))
	pic_out(&p, 0x20, 0x0B)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0))
	_, _ = pic_ack(&p)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0x20))
	pic_out(&p, 0x20, 0x0A)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0))
}

@(test)
test_pic_special_mask_mode :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 2)
	_, _ = pic_ack(&p)
	pic_raise(&p, 4)
	testing.expect(t, !pic_has_pending(&p))
	pic_out(&p, 0x20, 0x68)
	testing.expect(t, !pic_has_pending(&p))
	pic_out(&p, 0x21, 0x04)
	testing.expect(t, pic_has_pending(&p))
	pic_out(&p, 0x20, 0x48)
	token, ok := pic_offer(&p)
	testing.expect(t, ok)
	testing.expect_value(t, token.kind, Pic_Interrupt_Kind.Spurious_Master)
	testing.expect_value(t, token.vector, u8(0x0F))
	testing.expect(t, pic_commit(&p, token))
	testing.expect(t, !pic_has_pending(&p))
}

@(test)
test_pic_set_priority_rotates_resolution :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x20, 0xC4)
	testing.expect_value(t, p.master.lowest, u8(4))
	pic_raise(&p, 2)
	pic_raise(&p, 6)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x0E))
}

@(test)
test_pic_non_specific_eoi_uses_rotated_priority :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x20, 0xC4)
	p.master.isr = 0x21
	pic_out(&p, 0x20, 0x20)
	testing.expect_value(t, p.master.isr, u8(0x01))
}

@(test)
test_pic_auto_eoi_and_rotation :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_out(&p, 0x20, 0x11); pic_out(&p, 0x21, 0x08); pic_out(&p, 0x21, 0x04); pic_out(&p, 0x21, 0x03)
	pic_out(&p, 0x20, 0x80)
	pic_raise(&p, 3)
	_, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.master.isr, u8(0))
	testing.expect_value(t, p.master.lowest, u8(3))
	pic_out(&p, 0x20, 0x00)
	testing.expect(t, !p.master.auto_rotate)
}

@(test)
test_pic_edge_line_requires_new_rising_edge :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_set_irq_level(&p, 3, true)
	_, _ = pic_ack(&p)
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, !pic_has_pending(&p))
	pic_set_irq_level(&p, 3, true)
	testing.expect(t, !pic_has_pending(&p))
	pic_set_irq_level(&p, 3, false)
	pic_set_irq_level(&p, 3, true)
	testing.expect(t, pic_has_pending(&p))
}

@(test)
test_pic_held_level_reasserts_after_eoi :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup_level(&p)
	pic_set_irq_level(&p, 4, true)
	_, _ = pic_ack(&p)
	testing.expect(t, !pic_has_pending(&p))
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, pic_has_pending(&p))
	pic_set_irq_level(&p, 4, false)
	_, _ = pic_ack(&p)
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, !pic_has_pending(&p))
}

@(test)
test_pic_elcr_masks_reserved_lines :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x4D0, 0xFF)
	pic_out(&p, 0x4D1, 0xFF)
	testing.expect_value(t, pic_in(&p, 0x4D0), u8(0xF8))
	testing.expect_value(t, pic_in(&p, 0x4D1), u8(0xDE))
}

@(test)
test_pic_elcr_level_line_reasserts :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x4D0, 1 << 5)
	pic_set_irq_level(&p, 5, true)
	_, _ = pic_ack(&p)
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, pic_has_pending(&p))
	pic_set_irq_level(&p, 5, false)
	token, ok := pic_offer(&p)
	testing.expect(t, ok)
	testing.expect_value(t, token.kind, Pic_Interrupt_Kind.Spurious_Master)
}

@(test)
test_pic_spurious_master_irq7 :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x4D0, 1 << 3)
	pic_set_irq_level(&p, 3, true)
	pic_set_irq_level(&p, 3, false)
	token, ok := pic_offer(&p)
	testing.expect(t, ok)
	testing.expect_value(t, token.kind, Pic_Interrupt_Kind.Spurious_Master)
	testing.expect_value(t, token.vector, u8(0x0F))
	testing.expect(t, pic_commit(&p, token))
	testing.expect_value(t, p.master.isr, u8(0))
}

@(test)
test_pic_spurious_slave_irq15 :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 9)
	pic_out(&p, 0xA1, 0x02)
	token, ok := pic_offer(&p)
	testing.expect(t, ok)
	testing.expect_value(t, token.kind, Pic_Interrupt_Kind.Spurious_Slave)
	testing.expect_value(t, token.vector, u8(0x77))
	testing.expect(t, pic_commit(&p, token))
	testing.expect_value(t, p.master.isr, u8(0x04))
	testing.expect_value(t, p.slave.isr, u8(0))
}

@(test)
test_pic_custom_cascade_route :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_out(&p, 0x20, 0x11); pic_out(&p, 0x21, 0x08); pic_out(&p, 0x21, 0x20); pic_out(&p, 0x21, 0x01)
	pic_out(&p, 0xA0, 0x11); pic_out(&p, 0xA1, 0x70); pic_out(&p, 0xA1, 0x05); pic_out(&p, 0xA1, 0x01)
	pic_raise(&p, 9)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x71))
	testing.expect_value(t, p.master.isr, u8(0x20))
}

@(test)
test_pic_sfnm_allows_higher_slave_preemption :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup_sfnm(&p)
	pic_raise(&p, 9)
	_, _ = pic_ack(&p)
	pic_raise(&p, 8)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x70))
	testing.expect_value(t, p.slave.isr, u8(0x03))
}

@(test)
test_pic_fully_nested_blocks_second_slave :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 9)
	_, _ = pic_ack(&p)
	pic_raise(&p, 8)
	testing.expect(t, !pic_has_pending(&p))
}

@(test)
test_pic_sfnm_master_poll_matches_offer :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup_sfnm(&p)
	pic_raise(&p, 9)
	_, _ = pic_ack(&p)
	pic_raise(&p, 8)
	pic_out(&p, 0x20, 0x0C)
	testing.expect_value(t, pic_in(&p, 0x20), u8(0x82))
}

@(test)
test_pic_single_mode_skips_icw3 :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_out(&p, 0x20, 0x13)
	pic_out(&p, 0x21, 0x0B)
	testing.expect_value(t, p.master.init, Pic_Init_Stage.Expect_ICW4)
	pic_out(&p, 0x21, 0x03)
	testing.expect_value(t, p.master.init, Pic_Init_Stage.Ready)
	testing.expect_value(t, p.master.base, u8(0x08))
	testing.expect(t, p.master.auto_eoi)
}

@(test)
test_pic_deliverable_checks_cascade_mask :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	testing.expect(t, pic_irq_deliverable(&p, 14))
	pic_out(&p, 0x21, 0x04)
	testing.expect(t, !pic_irq_deliverable(&p, 14))
	pic_out(&p, 0x21, 0x00)
	pic_out(&p, 0xA1, 0x40)
	testing.expect(t, !pic_irq_deliverable(&p, 14))
}

@(test)
test_pic_higher_priority_preempts_in_service_irq :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 5)
	_, _ = pic_ack(&p)
	pic_raise(&p, 1)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x09))
	testing.expect_value(t, p.master.isr, u8(0x22))
}

@(test)
test_pic_held_slave_level_reasserts_cascade :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup_level(&p)
	pic_set_irq_level(&p, 12, true)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x74))
	pic_out(&p, 0xA0, 0x20)
	testing.expect(t, !pic_has_pending(&p))
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, pic_has_pending(&p))
	pic_set_irq_level(&p, 12, false)
}

@(test)
test_pic_auto_eoi_reasserts_held_level :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_out(&p, 0x20, 0x19); pic_out(&p, 0x21, 0x08); pic_out(&p, 0x21, 0x04); pic_out(&p, 0x21, 0x03)
	pic_set_irq_level(&p, 5, true)
	_, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.master.isr, u8(0))
	testing.expect_value(t, p.master.irr, u8(0x20))
	testing.expect(t, pic_has_pending(&p))
}

@(test)
test_pic_icw_modes_are_recorded :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_out(&p, 0x20, 0x19)
	pic_out(&p, 0x21, 0x2F)
	pic_out(&p, 0x21, 0x04)
	pic_out(&p, 0x21, 0x1F)
	testing.expect_value(t, p.master.base, u8(0x28))
	testing.expect(t, p.master.level_triggered)
	testing.expect(t, p.master.mode_8086)
	testing.expect(t, p.master.auto_eoi)
	testing.expect(t, p.master.buffered)
	testing.expect(t, p.master.is_master)
	testing.expect(t, p.master.sfnm)
}

@(test)
test_pic_elcr_slave_level_reasserts_cascade :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_out(&p, 0x4D1, 1 << 4)
	pic_set_irq_level(&p, 12, true)
	_, ok := pic_ack(&p)
	testing.expect(t, ok)
	pic_out(&p, 0xA0, 0x20)
	testing.expect(t, !pic_has_pending(&p))
	pic_out(&p, 0x20, 0x20)
	testing.expect(t, pic_has_pending(&p))
	pic_set_irq_level(&p, 12, false)
}
