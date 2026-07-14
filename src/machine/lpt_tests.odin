// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_lpt_ready_status_and_decode :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init_lpt1(&lpt)
	status, claimed := lpt_in(&lpt, LPT1_BASE + 1)
	testing.expect(t, claimed)
	testing.expect_value(t, status, LPT_STATUS_IDLE)
	_, claimed = lpt_in(&lpt, LPT1_BASE - 1)
	testing.expect(t, !claimed)
	testing.expect(t, !lpt_out(&lpt, LPT1_BASE + 3, 0))
	testing.expect_value(t, lpt_irq_number(&lpt), u8(7))

	lpt_init_lpt2(&lpt)
	testing.expect_value(t, lpt_irq_number(&lpt), u8(5))
	_, claimed = lpt_in(&lpt, LPT2_BASE + 1)
	testing.expect(t, claimed)
}

@(test)
test_lpt_strobe_has_busy_and_ack_phases :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	_ = lpt_out(&lpt, LPT1_BASE, 'A')
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
	_ = lpt_out(&lpt, LPT1_BASE + 2, 0)
	status, _ := lpt_in(&lpt, LPT1_BASE + 1)
	testing.expect_value(t, status & LPT_STATUS_NOT_BUSY, u8(0))
	deadline, pending := lpt_next_deadline(&lpt)
	testing.expect(t, pending)
	lpt_advance_to(&lpt, deadline - 1)
	testing.expect_value(t, len(lpt_output(&lpt)), 0)
	lpt_advance_to(&lpt, deadline)
	testing.expect_value(t, string(lpt_output(&lpt)), "A")
	status, _ = lpt_in(&lpt, LPT1_BASE + 1)
	testing.expect_value(t, status & LPT_STATUS_NOT_ACK, u8(0))
	lpt_advance(&lpt, LPT_ACK_TICKS)
	status, _ = lpt_in(&lpt, LPT1_BASE + 1)
	testing.expect_value(t, status, LPT_STATUS_IDLE)
}

@(test)
test_lpt_captures_strobe_edges_once :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	_ = lpt_out(&lpt, LPT1_BASE, 'Z')
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE | 0x08)
	lpt_advance(&lpt, lpt_ticks_until_idle(&lpt))
	testing.expect_value(t, string(lpt_output(&lpt)), "Z")
}

@(test)
test_lpt_two_characters_print_in_order :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	values := [?]u8{'H', 'i'}
	for value in values {
		_ = lpt_out(&lpt, LPT1_BASE, value)
		_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
		_ = lpt_out(&lpt, LPT1_BASE + 2, 0)
		lpt_advance(&lpt, lpt_ticks_until_idle(&lpt))
	}
	testing.expect_value(t, string(lpt_output(&lpt)), "Hi")
}

@(test)
test_lpt_irq_is_sampled_at_ack_edge :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	_ = lpt_out(&lpt, LPT1_BASE, 'I')
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_IRQ_ENABLE)
	deadline, pending := lpt_irq_deadline(&lpt)
	testing.expect(t, pending)
	testing.expect(t, !lpt_take_irq(&lpt))
	lpt_advance_to(&lpt, deadline - 1)
	testing.expect(t, !lpt_take_irq(&lpt))
	lpt_advance_to(&lpt, deadline)
	testing.expect(t, lpt_take_irq(&lpt))
	testing.expect(t, !lpt_take_irq(&lpt))
}

@(test)
test_lpt_without_irq_enable_does_not_interrupt :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	_ = lpt_out(&lpt, LPT1_BASE, 'N')
	_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
	lpt_advance(&lpt, lpt_ticks_until_idle(&lpt))
	testing.expect(t, !lpt_take_irq(&lpt))
}

@(test)
test_lpt_batch_invariance :: proc(t: ^testing.T) {
	whole, split: Lpt
	lpt_init(&whole)
	_ = lpt_out(&whole, LPT1_BASE, 'X')
	_ = lpt_out(&whole, LPT1_BASE + 2, LPT_CONTROL_STROBE | LPT_CONTROL_IRQ_ENABLE)
	_ = lpt_out(&whole, LPT1_BASE + 2, LPT_CONTROL_IRQ_ENABLE)
	split = whole
	span := lpt_ticks_until_idle(&whole)
	lpt_advance(&whole, span)
	lpt_advance(&split, LPT_BUSY_TICKS / 2)
	lpt_advance(&split, span - LPT_BUSY_TICKS / 2)
	testing.expect_value(t, string(lpt_output(&whole)), "X")
	testing.expect_value(t, string(lpt_output(&split)), "X")
	testing.expect_value(t, whole.phase, split.phase)
	testing.expect_value(t, whole.now_tick, split.now_tick)
	testing.expect(t, lpt_take_irq(&whole))
	testing.expect(t, lpt_take_irq(&split))
}

@(test)
test_lpt_control_reserved_bits_read_high :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	_ = lpt_out(&lpt, LPT1_BASE + 2, 0xFF)
	control, _ := lpt_in(&lpt, LPT1_BASE + 2)
	testing.expect_value(t, control, u8(0xFF))
}

@(test)
test_lpt_capture_is_bounded :: proc(t: ^testing.T) {
	lpt: Lpt
	lpt_init(&lpt)
	for i in 0 ..< LPT_CAPTURE_CAPACITY + 2 {
		_ = lpt_out(&lpt, LPT1_BASE, u8(i))
		_ = lpt_out(&lpt, LPT1_BASE + 2, LPT_CONTROL_STROBE)
		_ = lpt_out(&lpt, LPT1_BASE + 2, 0)
		lpt_advance(&lpt, lpt_ticks_until_idle(&lpt))
	}
	testing.expect_value(t, len(lpt_output(&lpt)), LPT_CAPTURE_CAPACITY)
	testing.expect_value(t, lpt_output_dropped(&lpt), u64(2))
}
