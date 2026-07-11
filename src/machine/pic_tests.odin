// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

pic_setup :: proc(p: ^Pic_Pair) { // ICW estándar de BIOS: base 08h/70h
	pic_out(p, 0x20, 0x11); pic_out(p, 0x21, 0x08); pic_out(p, 0x21, 0x04); pic_out(p, 0x21, 0x01)
	pic_out(p, 0xA0, 0x11); pic_out(p, 0xA1, 0x70); pic_out(p, 0xA1, 0x02); pic_out(p, 0xA1, 0x01)
	pic_out(p, 0x21, 0x00); pic_out(p, 0xA1, 0x00) // desenmascarar todo
}

@(test)
test_pic_irq0_vector :: proc(t: ^testing.T) {
	p: Pic_Pair
	pic_setup(&p)
	pic_raise(&p, 0)
	v, ok := pic_ack(&p)
	testing.expect(t, ok)
	testing.expect_value(t, v, u8(0x08))
	_, ok2 := pic_ack(&p) // ISR bloquea hasta EOI
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
	pic_out(&p, 0x21, 0x01) // enmascarar IRQ0
	pic_raise(&p, 0)
	_, ok := pic_ack(&p)
	testing.expect(t, !ok)
	pic_raise(&p, 8) // esclavo → vector 0x70
	v, ok2 := pic_ack(&p)
	testing.expect(t, ok2)
	testing.expect_value(t, v, u8(0x70))
}
