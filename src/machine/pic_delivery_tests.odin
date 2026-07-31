// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_machine_pic_delivery_commits_queued_offer_exactly_once :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	pic_setup(&m.platform.pic)
	pic_raise(&m.platform.pic, 0)
	offer, ok := pic_interrupt_preview(&m.platform.pic)
	if !testing.expect(t, ok) {return}
	m.pic_offer_queued = true
	m.pic_queued_offer = offer
	m.pic_queue_count = 1

	testing.expect(t, machine_irq_delivered(m, offer.vector))
	testing.expect(t, !m.pic_offer_queued)
	testing.expect_value(t, m.pic_delivery_count, u64(1))
	testing.expect_value(t, m.inj_count[offer.vector], u64(1))
	testing.expect_value(t, m.platform.pic.master.irr, u8(0))
	testing.expect_value(t, m.platform.pic.master.isr, u8(1))
	testing.expect(t, !machine_irq_delivered(m, offer.vector))
	testing.expect_value(t, m.pic_delivery_count, u64(1))
	testing.expect_value(t, m.inj_count[offer.vector], u64(1))
}
