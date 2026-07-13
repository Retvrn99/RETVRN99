// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_ps2_mouse_identification_and_configuration :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)

	reply := ps2_mouse_command(&m, 0xF2)
	testing.expect_value(t, reply.count, 2)
	testing.expect_value(t, reply.bytes[0], u8(0xFA))
	testing.expect_value(t, reply.bytes[1], u8(0x00))

	_ = ps2_mouse_command(&m, 0xF3)
	_ = ps2_mouse_command(&m, 200)
	_ = ps2_mouse_command(&m, 0xE8)
	_ = ps2_mouse_command(&m, 3)
	_ = ps2_mouse_command(&m, 0xE7)
	_ = ps2_mouse_command(&m, 0xF0)
	_ = ps2_mouse_command(&m, 0xF4)
	reply = ps2_mouse_command(&m, 0xE9)
	testing.expect_value(t, reply.count, 4)
	testing.expect_value(t, reply.bytes[0], u8(0xFA))
	testing.expect_value(t, reply.bytes[1] & 0x70, u8(0x70))
	testing.expect_value(t, reply.bytes[2], u8(3))
	testing.expect_value(t, reply.bytes[3], u8(200))

	reply = ps2_mouse_command(&m, 0xFF)
	testing.expect_value(t, reply.count, 3)
	testing.expect_value(t, reply.bytes[0], u8(0xFA))
	testing.expect_value(t, reply.bytes[1], u8(0xAA))
	testing.expect_value(t, reply.bytes[2], u8(0x00))
	testing.expect_value(t, m.mode, Ps2_Mouse_Mode.Stream)
	testing.expect(t, !m.reporting)
}

@(test)
test_ps2_mouse_packet_axes_and_buttons :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 12, -5, PS2_MOUSE_BUTTON_LEFT | PS2_MOUSE_BUTTON_MIDDLE)
	packet := ps2_mouse_packet(&m)
	testing.expect_value(t, packet[0], u8(0x0D))
	testing.expect_value(t, packet[1], u8(12))
	testing.expect_value(t, packet[2], u8(5))

	ps2_mouse_update(&m, -2, 7, PS2_MOUSE_BUTTON_RIGHT)
	packet = ps2_mouse_packet(&m)
	testing.expect_value(t, packet[0], u8(0x3A))
	testing.expect_value(t, packet[1], u8(0xFE))
	testing.expect_value(t, packet[2], u8(0xF9))
}

@(test)
test_ps2_mouse_packet_overflow_and_scaling :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 600, -600, 0)
	packet := ps2_mouse_packet(&m)
	testing.expect_value(t, packet[0] & 0xC0, u8(0xC0))
	testing.expect_value(t, packet[1], u8(0xFF))
	testing.expect_value(t, packet[2], u8(0xFF))
	testing.expect_value(t, m.pending_x, i64(345))
	testing.expect_value(t, m.pending_y, i64(345))
	packet = ps2_mouse_packet(&m)
	testing.expect_value(t, packet[1], u8(0xFF))
	testing.expect_value(t, packet[2], u8(0xFF))
	testing.expect_value(t, m.pending_x, i64(90))
	testing.expect_value(t, m.pending_y, i64(90))
	_ = ps2_mouse_packet(&m)

	_ = ps2_mouse_command(&m, 0xE7)
	ps2_mouse_update(&m, 4, 0, 0)
	packet = ps2_mouse_packet(&m)
	testing.expect_value(t, packet[1], u8(6))
}

@(test)
test_i8042_mouse_stream_and_aux_disable :: proc(t: ^testing.T) {
	irqs := 0
	kc: I8042
	i8042_init(&kc, &irqs, nil, proc(ctx: rawptr) {(^int)(ctx)^ += 1})
	i8042_out(&kc, 0x64, 0x60); i8042_out(&kc, 0x60, 0x02)
	i8042_out(&kc, 0x64, 0xD4); i8042_out(&kc, 0x60, 0xF4)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFA))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)

	i8042_mouse(&kc, 5, 3, PS2_MOUSE_BUTTON_LEFT)
	testing.expect_value(t, i8042_in(&kc, 0x64), u8(0x21))
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x29))
	testing.expect_value(t, i8042_in(&kc, 0x64), u8(0x00))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(5))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFD))

	i8042_out(&kc, 0x64, 0xA7)
	i8042_mouse(&kc, 4, 0, PS2_MOUSE_BUTTON_LEFT)
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(0))
	i8042_out(&kc, 0x64, 0xA8)
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x64), u8(0x21))
	testing.expect(t, irqs >= 3)
}

@(test)
test_i8042_mouse_remote_read_data :: proc(t: ^testing.T) {
	kc: I8042
	i8042_init(&kc, nil, nil)
	i8042_out(&kc, 0x64, 0xD4); i8042_out(&kc, 0x60, 0xF0)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFA))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	i8042_mouse(&kc, 7, -4, 0)
	testing.expect_value(t, i8042_in(&kc, 0x64) & 1, u8(0))
	i8042_out(&kc, 0x64, 0xD4); i8042_out(&kc, 0x60, 0xEB)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0xFA))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(0x08))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(7))
	i8042_advance(&kc, I8042_AUX_BYTE_NS)
	testing.expect_value(t, i8042_in(&kc, 0x60), u8(4))
}
