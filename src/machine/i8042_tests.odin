// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_i8042 :: proc(t: ^testing.T) {
	irqs := 0
	kc: I8042
	i8042_init(&kc, &irqs, proc(ctx: rawptr) { (^int)(ctx)^ += 1 })
	i8042_out(&kc, 0x64, 0xAA)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x55))
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x01) // enable IRQ1
	i8042_key(&kc, 0x1E) // 'A' make
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(1))
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x1E))
	testing.expect_value(t, irqs, 1)
	i8042_out(&kc, 0x60, 0xED)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFA))
	i8042_out(&kc, 0x60, 0x07) // LEDs
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFA))
}

@(test)
test_i8042_irq_per_byte :: proc(t: ^testing.T) {
	irqs := 0
	kc: I8042
	i8042_init(&kc, &irqs, proc(ctx: rawptr) { (^int)(ctx)^ += 1 })
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x01) // enable IRQ1
	i8042_key(&kc, 0x1E)
	i8042_key(&kc, 0x9E)
	testing.expect_value(t, irqs, 1) // only empty->non-empty fired so far
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x1E))
	testing.expect_value(t, irqs, 2) // byte still queued: IRQ1 re-pulsed
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x9E))
	testing.expect_value(t, irqs, 2) // FIFO drained: no further IRQ
}

@(test)
test_i8042_a20 :: proc(t: ^testing.T) {
	kc: I8042
	i8042_init(&kc, nil, nil)
	testing.expect_value(t, i8042_in(&kc, 0x92) & 2, u8(0))
	i8042_out(&kc, 0x92, 0x02)
	testing.expect_value(t, i8042_in(&kc, 0x92) & 2, u8(2)) // A20 bit persists
	i8042_out(&kc, 0x64, 0xD1)
	i8042_out(&kc, 0x60, 0x00) // output port: A20 off
	testing.expect_value(t, i8042_in(&kc, 0x92) & 2, u8(0))
}
