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

// the disable state is bit 4 of the command byte: 0xAD sets it, 0xAE clears
// it, and a command-byte write with bit 4 clear re-enables the keyboard
// (MS-DOS 7 IO.SYS sends 0xAD during init and re-enables only via the CTR).
// Scancodes arriving while disabled are held (the real keyboard buffers
// while its clock line is inhibited) and delivered on re-enable.
@(test)
test_i8042_disable_via_cmd_byte :: proc(t: ^testing.T) {
	irqs := 0
	kc: I8042
	i8042_init(&kc, &irqs, proc(ctx: rawptr) { (^int)(ctx)^ += 1 })
	i8042_out(&kc, 0x64, 0xAD) // disable keyboard
	i8042_key(&kc, 0x1E)
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(0)) // held, not readable
	i8042_out(&kc, 0x64, 0x20) // read CTR: bit 4 reflects the disable
	testing.expect_value(t, i8042_in(&kc, 0x60) & 0x10, u8(0x10))
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x01) // CTR: IRQ1 on, kbd enabled
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(1)) // held byte flushed
	testing.expect_value(t, irqs, 1)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x1E))
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x71) // CTR with bit 4: disabled
	i8042_key(&kc, 0x9E)
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(0))
	i8042_out(&kc, 0x64, 0xAE) // enable again: the break code arrives
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x9E))
}

// no aux (PS/2 mouse) device in M1: 0xD4 swallows its parameter instead of
// misparsing it as a keyboard command, probes fail cleanly, and 0xD0
// returns the synthesized output port
@(test)
test_i8042_aux_absent :: proc(t: ^testing.T) {
	irqs := 0
	kc: I8042
	i8042_init(&kc, &irqs, proc(ctx: rawptr) { (^int)(ctx)^ += 1 })
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x01) // enable IRQ1
	i8042_out(&kc, 0x64, 0xD4) // write to aux
	i8042_out(&kc, 0x60, 0xF4) // parameter: must not become a keyboard ACK
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(0))
	testing.expect_value(t, irqs, 0)
	i8042_out(&kc, 0x64, 0xA9) // aux interface test
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFF)) // absent
	i8042_out(&kc, 0x64, 0xA7) // aux disable/enable: accepted no-ops
	i8042_out(&kc, 0x64, 0xA8)
	i8042_out(&kc, 0x92, 0x02) // A20 on
	i8042_out(&kc, 0x64, 0xD0) // read output port
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x03)) // bit1 A20, bit0 no-reset
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
