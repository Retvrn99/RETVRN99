// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(private = "file")
ps2_test_knock :: proc(m: ^Ps2_Mouse) {
	rates := [3]u8{200, 100, 80}
	for rate in rates {
		_ = ps2_mouse_command(m, 0xF3)
		_ = ps2_mouse_command(m, rate)
	}
}

@(private = "file")
i8042_test_mouse_command :: proc(k: ^I8042, value: u8) {
	i8042_test_write(k, 0x64, 0xD4)
	i8042_test_write(k, 0x60, value)
}

@(private = "file")
i8042_test_enable_mouse :: proc(k: ^I8042) {
	i8042_test_command_byte(k, 0x47)
	i8042_test_mouse_command(k, 0xF4)
	testing_value := i8042_test_read(k)
	_ = testing_value
}

@(test)
test_ps2_mouse_id00_until_magic_knock :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	reply := ps2_mouse_command(&m, 0xF2)
	testing.expect_value(t, reply.bytes[1], u8(0))
	wrong_rates := [3]u8{200, 100, 81}
	for rate in wrong_rates {
		_ = ps2_mouse_command(&m, 0xF3); _ = ps2_mouse_command(&m, rate)
	}
	reply = ps2_mouse_command(&m, 0xF2)
	testing.expect_value(t, reply.bytes[1], u8(0))
	ps2_test_knock(&m)
	reply = ps2_mouse_command(&m, 0xF2)
	testing.expect_value(t, reply.bytes[1], u8(3))
}

@(test)
test_ps2_mouse_reset_returns_to_id00 :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	ps2_test_knock(&m)
	reply := ps2_mouse_command(&m, 0xFF)
	testing.expect_value(t, reply.count, 3)
	testing.expect_value(t, reply.bytes[1], u8(0xAA))
	testing.expect_value(t, reply.bytes[2], u8(0))
	testing.expect_value(t, m.device_id, u8(0))
}

@(test)
test_ps2_mouse_packet_axes_buttons_and_overflow :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 600, -600, PS2_MOUSE_BUTTON_LEFT)
	packet := ps2_mouse_take_packet(&m)
	testing.expect_value(t, packet.bytes[0] & 0xC9, u8(0xC9))
	testing.expect_value(t, packet.bytes[1], u8(0xFF))
	testing.expect_value(t, packet.bytes[2], u8(0xFF))
	packet = ps2_mouse_take_packet(&m)
	testing.expect_value(t, packet.bytes[1], u8(0xFF))
	testing.expect_value(t, packet.bytes[2], u8(0xFF))
}

@(test)
test_ps2_mouse_scaling_2_to_1 :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	_ = ps2_mouse_command(&m, 0xE7)
	ps2_mouse_update(&m, 4, 0, 0)
	packet := ps2_mouse_take_packet(&m)
	testing.expect_value(t, packet.bytes[1], u8(6))
}

@(test)
test_ps2_mouse_button_transitions_stay_ordered :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 0, 0, PS2_MOUSE_BUTTON_LEFT)
	ps2_mouse_update(&m, 0, 0, 0)
	first := ps2_mouse_take_packet(&m)
	second := ps2_mouse_take_packet(&m)
	testing.expect_value(t, first.bytes[0] & 7, PS2_MOUSE_BUTTON_LEFT)
	testing.expect_value(t, second.bytes[0] & 7, u8(0))
}

@(test)
test_ps2_mouse_full_queue_preserves_queued_button_edges :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	for i in 0 ..< PS2_MOUSE_EVENT_CAPACITY {
		buttons := i & 1 == 0 ? PS2_MOUSE_BUTTON_LEFT : u8(0)
		ps2_mouse_update(&m, 0, 0, buttons)
	}
	last := (m.event_head + m.event_count - 1) % len(m.events)
	last_buttons := m.events[last].buttons
	ps2_mouse_update(&m, 0, 0, PS2_MOUSE_BUTTON_LEFT)
	testing.expect_value(t, m.event_count, PS2_MOUSE_EVENT_CAPACITY)
	testing.expect_value(t, m.events[last].buttons, last_buttons)
	testing.expect_value(t, m.dropped_edges, u64(1))

	for _ in 0 ..< PS2_MOUSE_EVENT_CAPACITY {_ = ps2_mouse_take_packet(&m)}
	final := ps2_mouse_take_packet(&m)
	testing.expect_value(t, final.bytes[0] & 7, PS2_MOUSE_BUTTON_LEFT)
}

@(test)
test_ps2_mouse_motion_accumulates_until_sample :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 2, 1, 0)
	ps2_mouse_update(&m, 3, 2, 0)
	packet := ps2_mouse_take_packet(&m)
	testing.expect_value(t, packet.bytes[1], u8(5))
	testing.expect_value(t, packet.bytes[2], u8(0xFD))
}

@(test)
test_ps2_mouse_selected_sample_rate_controls_deadline :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	_ = ps2_mouse_command(&m, 0xF3); _ = ps2_mouse_command(&m, 200)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update(&m, 1, 0, 0)
	wait, ok := ps2_mouse_next_deadline_ns(&m)
	testing.expect(t, ok)
	testing.expect_value(t, wait, u64(5_000_000))
	testing.expect(t, !ps2_mouse_advance(&m, wait - 1))
	testing.expect(t, ps2_mouse_advance(&m, 1))
}

@(test)
test_ps2_mouse_intellimouse_wheel_packet :: proc(t: ^testing.T) {
	m: Ps2_Mouse
	ps2_mouse_init(&m)
	ps2_test_knock(&m)
	_ = ps2_mouse_command(&m, 0xF4)
	ps2_mouse_update_wheel(&m, 0, 0, -1, 0)
	packet := ps2_mouse_take_packet(&m)
	testing.expect_value(t, packet.count, 4)
	testing.expect_value(t, packet.bytes[3], u8(0x0F))
}

@(test)
test_i8042_mouse_waits_for_sample_then_serial_wire :: proc(t: ^testing.T) {
	lines: I8042_Test_Lines
	k: I8042
	i8042_test_init(&k, &lines)
	i8042_test_enable_mouse(&k)
	i8042_mouse(&k, 5, 3, PS2_MOUSE_BUTTON_LEFT)
	sample := ps2_mouse_sample_interval_ns(&k.mouse)
	i8042_advance(&k, sample - 1)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_advance(&k, 1 + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x21))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x29))
	testing.expect_value(t, lines.irq12_high, 2)
	testing.expect_value(t, lines.irq12_low, 2)
}

@(test)
test_i8042_keyboard_stale_reread_is_not_hijacked_by_mouse :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_enable_mouse(&k)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	i8042_mouse(&k, 2, 0, 0)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	i8042_advance(&k, ps2_mouse_sample_interval_ns(&k.mouse) + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x21))
}

@(test)
test_i8042_mouse_packet_bytes_never_overwrite_unread_output :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_enable_mouse(&k)
	i8042_mouse(&k, 5, 3, 0)
	i8042_advance(&k, ps2_mouse_sample_interval_ns(&k.mouse) + I8042_DEVICE_BYTE_NS)
	i8042_advance(&k, 5 * I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x28))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(5))
}

@(test)
test_i8042_mouse_remote_read_data :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_mouse_command(&k, 0xF0)
	testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	i8042_mouse(&k, 7, -4, 0)
	i8042_test_mouse_command(&k, 0xEB)
	testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	testing.expect_value(t, i8042_test_read(&k), u8(0x08))
	testing.expect_value(t, i8042_test_read(&k), u8(7))
	testing.expect_value(t, i8042_test_read(&k), u8(4))
}

@(test)
test_i8042_aux_disable_holds_serial_bytes :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_enable_mouse(&k)
	i8042_test_write(&k, 0x64, 0xA7)
	i8042_mouse(&k, 4, 0, 0)
	i8042_advance(&k, ps2_mouse_sample_interval_ns(&k.mouse) + 5 * I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_test_write(&k, 0x64, 0xA8)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x21))
}
