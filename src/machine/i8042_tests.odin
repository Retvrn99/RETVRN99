// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

I8042_Test_Lines :: struct {
	irq1_high, irq1_low:   int,
	irq12_high, irq12_low: int,
	resets:                int,
}

i8042_test_init :: proc(k: ^I8042, lines: ^I8042_Test_Lines = nil) {
	i8042_init(
		k,
		lines,
		proc(ctx: rawptr) {if ctx != nil {(^I8042_Test_Lines)(ctx).irq1_high += 1}},
		proc(ctx: rawptr) {if ctx != nil {(^I8042_Test_Lines)(ctx).irq12_high += 1}},
		proc(ctx: rawptr) {if ctx != nil {(^I8042_Test_Lines)(ctx).resets += 1}},
	)
	k.cmd_byte |= I8042_COMMAND_TRANSLATE
	i8042_set_irq_lower_callbacks(
		k,
		proc(ctx: rawptr) {if ctx != nil {(^I8042_Test_Lines)(ctx).irq1_low += 1}},
		proc(ctx: rawptr) {if ctx != nil {(^I8042_Test_Lines)(ctx).irq12_low += 1}},
	)
}

i8042_test_write :: proc(k: ^I8042, port: u16, value: u8) {
	i8042_out(k, port, value)
	i8042_advance(k, I8042_CONTROLLER_INPUT_NS)
}

i8042_test_read :: proc(k: ^I8042) -> u8 {
	for i in 0 ..< 32 {
		if i8042_in(k, 0x64) & 1 != 0 {return i8042_in(k, 0x60)}
		if wait, ok := i8042_next_deadline_ns(k); ok {i8042_advance(k, max(wait, u64(1)))} else {break}
	}
	return i8042_in(k, 0x60)
}

i8042_test_command_byte :: proc(k: ^I8042, value: u8) {
	i8042_test_write(k, 0x64, 0x60)
	i8042_test_write(k, 0x60, value)
}

i8042_test_expect_bytes :: proc(t: ^testing.T, k: ^I8042, expected: []u8) {
	for value in expected {testing.expect_value(t, i8042_test_read(k), value)}
}

i8042_test_select_scan_set :: proc(t: ^testing.T, k: ^I8042, set: u8) -> u8 {
	i8042_test_write(k, 0x60, 0xF0)
	testing.expect_value(t, i8042_test_read(k), u8(0xFA))
	i8042_test_write(k, 0x60, set)
	return i8042_test_read(k)
}

@(test)
test_i8042_controller_input_is_timed :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_out(&k, 0x64, 0xAA)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x0A, u8(0x0A))
	i8042_advance(&k, I8042_CONTROLLER_INPUT_NS - 1)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_advance(&k, 1)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x55))
}

@(test)
test_i8042_busy_input_rejects_second_write :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_out(&k, 0x92, 0x00)
	i8042_out(&k, 0x64, 0xD1)
	i8042_out(&k, 0x60, 0x03)
	i8042_advance(&k, I8042_CONTROLLER_INPUT_NS)
	testing.expect(t, !k.a20)
	i8042_test_write(&k, 0x60, 0x03)
	testing.expect(t, k.a20)
}

@(test)
test_i8042_keyboard_byte_uses_serial_deadline :: proc(t: ^testing.T) {
	lines: I8042_Test_Lines
	k: I8042
	i8042_test_init(&k, &lines)
	i8042_test_command_byte(&k, 0x05)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS - 1)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_advance(&k, 1)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1C))
	testing.expect_value(t, lines.irq1_high, 1)
}

@(test)
test_i8042_port60_rereads_stale_byte :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_key(&k, 0x2A)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x2A))
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x2A))
	i8042_key(&k, 0xAA)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0xAA))
}

@(test)
test_i8042_port60_lowers_irq_immediately :: proc(t: ^testing.T) {
	lines: I8042_Test_Lines
	k: I8042
	i8042_test_init(&k, &lines)
	i8042_test_command_byte(&k, 0x05)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect(t, i8042_irq1_level(&k))
	_ = i8042_in(&k, 0x60)
	testing.expect(t, !i8042_irq1_level(&k))
	testing.expect_value(t, lines.irq1_low, 1)
}

@(test)
test_i8042_second_keyboard_byte_waits_another_millisecond :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_key(&k, 0x1E)
	i8042_key(&k, 0x9E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS - 1)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_advance(&k, 1)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x9E))
}

@(test)
test_i8042_keyboard_priority_over_auxiliary :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_command_byte(&k, 0x07)
	i8042_test_write(&k, 0x64, 0xD4)
	i8042_test_write(&k, 0x60, 0xF2)
	i8042_key(&k, 0x44)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x01))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x09))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x21))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0xFA))
}

@(test)
test_i8042_controller_disable_holds_scancodes :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_write(&k, 0x64, 0xAD)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, 5 * I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_test_write(&k, 0x64, 0xAE)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
}

@(test)
test_i8042_keyboard_device_replies :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_write(&k, 0x60, 0xEE)
	testing.expect_value(t, i8042_test_read(&k), u8(0xEE))
	i8042_test_write(&k, 0x60, 0xF2)
	testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	testing.expect_value(t, i8042_test_read(&k), u8(0xAB))
	testing.expect_value(t, i8042_test_read(&k), u8(0x83))
	i8042_test_write(&k, 0x60, 0xFF)
	testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	testing.expect_value(t, i8042_test_read(&k), u8(0xAA))
}

@(test)
test_i8042_keyboard_configuration_roundtrips :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_write(&k, 0x60, 0xED); testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	i8042_test_write(&k, 0x60, 0x07); testing.expect_value(t, i8042_test_read(&k), u8(0xFA))
	testing.expect_value(t, k.kbd_leds, u8(7))
	i8042_test_write(&k, 0x60, 0xF0); _ = i8042_test_read(&k)
	i8042_test_write(&k, 0x60, 0x01); _ = i8042_test_read(&k)
	i8042_test_write(&k, 0x60, 0xF0); _ = i8042_test_read(&k)
	i8042_test_write(&k, 0x60, 0x00); _ = i8042_test_read(&k)
	testing.expect_value(t, i8042_test_read(&k), u8(1))
	i8042_test_write(&k, 0x60, 0xF3); _ = i8042_test_read(&k)
	i8042_test_write(&k, 0x60, 0x00); _ = i8042_test_read(&k)
	testing.expect_value(t, k.kbd_typematic, u8(0))
}

@(test)
test_i8042_scan_sets_and_controller_translation :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_command_byte(&k, 0x04)
	testing.expect_value(t, i8042_test_select_scan_set(t, &k, 2), u8(0xFA))
	i8042_key(&k, 0x1E)
	i8042_key(&k, 0x9E)
	i8042_key(&k, 0xE0); i8042_key(&k, 0x48)
	i8042_key(&k, 0xE0); i8042_key(&k, 0xC8)
	set2 := [8]u8{0x1C, 0xF0, 0x1C, 0xE0, 0x75, 0xE0, 0xF0, 0x75}
	i8042_test_expect_bytes(t, &k, set2[:])

	i8042_test_command_byte(&k, 0x44)
	i8042_key(&k, 0x1E); i8042_key(&k, 0x9E)
	i8042_key(&k, 0xE0); i8042_key(&k, 0x48)
	i8042_key(&k, 0xE0); i8042_key(&k, 0xC8)
	translated := [6]u8{0x1E, 0x9E, 0xE0, 0x48, 0xE0, 0xC8}
	i8042_test_expect_bytes(t, &k, translated[:])

	i8042_test_command_byte(&k, 0x04)
	testing.expect_value(t, i8042_test_select_scan_set(t, &k, 1), u8(0xFA))
	i8042_key(&k, 0x1E); i8042_key(&k, 0x9E)
	set1 := [2]u8{0x1E, 0x9E}
	i8042_test_expect_bytes(t, &k, set1[:])

	testing.expect_value(t, i8042_test_select_scan_set(t, &k, 3), u8(0xFE))
	testing.expect_value(t, k.kbd_scan_set, u8(1))
	i8042_test_write(&k, 0x60, 0xF7)
	testing.expect_value(t, i8042_test_read(&k), u8(0xFE))
	testing.expect_value(t, i8042_test_select_scan_set(t, &k, 0), u8(0xFA))
	testing.expect_value(t, i8042_test_read(&k), u8(1))
}

@(test)
test_i8042_typematic_uses_current_wire_format :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_command_byte(&k, 0x04)
	k.kbd_typematic = 0
	i8042_key(&k, 0x1E)
	testing.expect_value(t, i8042_test_read(&k), u8(0x1C))
	i8042_advance(&k, i8042_typematic_delay_ns(&k) + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1C))

	i8042_test_command_byte(&k, 0x44)
	i8042_advance(&k, i8042_typematic_period_ns(&k) + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	i8042_key(&k, 0x9E)
	testing.expect_value(t, i8042_test_read(&k), u8(0x9E))
}

@(test)
test_i8042_print_screen_and_pause_follow_selected_set :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_command_byte(&k, 0x04)
	print_make := [4]u8{0xE0, 0x2A, 0xE0, 0x37}
	print_break := [4]u8{0xE0, 0xB7, 0xE0, 0xAA}
	pause := [6]u8{0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5}
	for value in print_make {i8042_key(&k, value)}
	set2_print_make := [4]u8{0xE0, 0x12, 0xE0, 0x7C}
	i8042_test_expect_bytes(t, &k, set2_print_make[:])
	for value in print_break {i8042_key(&k, value)}
	set2_print_break := [6]u8{0xE0, 0xF0, 0x7C, 0xE0, 0xF0, 0x12}
	i8042_test_expect_bytes(t, &k, set2_print_break[:])
	for value in pause {i8042_key(&k, value)}
	set2_pause := [8]u8{0xE1, 0x14, 0x77, 0xE1, 0xF0, 0x14, 0xF0, 0x77}
	i8042_test_expect_bytes(t, &k, set2_pause[:])
	testing.expect(t, !k.repeat_active)

	i8042_test_command_byte(&k, 0x44)
	for value in print_make {i8042_key(&k, value)}
	i8042_test_expect_bytes(t, &k, print_make[:])
	for value in print_break {i8042_key(&k, value)}
	i8042_test_expect_bytes(t, &k, print_break[:])
	for value in pause {i8042_key(&k, value)}
	i8042_test_expect_bytes(t, &k, pause[:])

	i8042_test_command_byte(&k, 0x04)
	i8042_key(&k, 0xE0); i8042_key(&k, 0x2A); i8042_key(&k, 0x1E)
	testing.expect_value(t, i8042_test_read(&k), u8(0x1C))
}

@(test)
test_i8042_guest_typematic_delay_and_rate :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	k.kbd_typematic = 0
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	_ = i8042_in(&k, 0x60)
	delay := i8042_typematic_delay_ns(&k)
	i8042_advance(&k, delay - I8042_DEVICE_BYTE_NS - 1)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
	i8042_advance(&k, 1 + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	_ = i8042_in(&k, 0x60)
	period := i8042_typematic_period_ns(&k)
	i8042_advance(&k, period + I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
	i8042_key(&k, 0x9E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x9E))
	i8042_advance(&k, 2 * period)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
}

@(test)
test_i8042_duplicate_host_make_is_not_guest_typematic :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_key(&k, 0x1E)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	_ = i8042_in(&k, 0x60)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x64) & 1, u8(0))
}

@(test)
test_i8042_extended_key_repeat_keeps_prefix :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	k.kbd_typematic = 0
	i8042_key(&k, 0xE0); i8042_key(&k, 0x48)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0xE0))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x48))
	i8042_advance(&k, i8042_typematic_delay_ns(&k) - I8042_DEVICE_BYTE_NS)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0xE0))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x48))
}

@(test)
test_i8042_a20_and_reset_are_timed :: proc(t: ^testing.T) {
	lines: I8042_Test_Lines
	k: I8042
	i8042_test_init(&k, &lines)
	i8042_test_write(&k, 0x64, 0xD1)
	i8042_test_write(&k, 0x60, 0x03)
	i8042_out(&k, 0x92, 0x00)
	testing.expect(t, k.a20 && k.a20_kbc && !k.a20_fast)
	i8042_test_write(&k, 0x64, 0xD1)
	i8042_out(&k, 0x60, 0x01)
	i8042_advance(&k, I8042_CONTROLLER_INPUT_NS - 1)
	testing.expect(t, k.a20)
	i8042_advance(&k, 1)
	testing.expect(t, !k.a20)
	i8042_out(&k, 0x64, 0xFE)
	testing.expect_value(t, lines.resets, 0)
	i8042_advance(&k, I8042_CONTROLLER_INPUT_NS)
	testing.expect_value(t, lines.resets, 1)
	testing.expect_value(t, k.reset_source, I8042_Reset_Source.Controller_Pulse)
	i8042_out(&k, 0x92, 0x03)
	testing.expect(t, k.a20)
	testing.expect_value(t, lines.resets, 2)
	testing.expect_value(t, k.reset_source, I8042_Reset_Source.Fast_A20)
}

@(test)
test_i8042_a20_sources_are_independent_and_ored :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	testing.expect(t, k.a20 && !k.a20_kbc && k.a20_fast)
	testing.expect_value(t, i8042_in(&k, 0x92), u8(0x02))

	i8042_test_write(&k, 0x64, 0xD1)
	i8042_test_write(&k, 0x60, 0x03)
	i8042_out(&k, 0x92, 0x00)
	testing.expect(t, k.a20 && k.a20_kbc && !k.a20_fast)
	testing.expect_value(t, i8042_in(&k, 0x92), u8(0x00))

	i8042_test_write(&k, 0x64, 0xD1)
	i8042_test_write(&k, 0x60, 0x01)
	testing.expect(t, !k.a20 && !k.a20_kbc && !k.a20_fast)

	i8042_out(&k, 0x92, 0x02)
	testing.expect(t, k.a20 && !k.a20_kbc && k.a20_fast)
}

@(test)
test_i8042_controller_injected_output_sources :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_test_write(&k, 0x64, 0xD2); i8042_test_write(&k, 0x60, 0x44)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x01))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x44))
	i8042_test_write(&k, 0x64, 0xD3); i8042_test_write(&k, 0x60, 0x55)
	testing.expect_value(t, i8042_in(&k, 0x64) & 0x21, u8(0x21))
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x55))
}

@(test)
test_i8042_deadline_and_batch_invariance :: proc(t: ^testing.T) {
	a, b: I8042
	i8042_test_init(&a)
	i8042_test_init(&b)
	i8042_out(&a, 0x60, 0xEE)
	i8042_out(&b, 0x60, 0xEE)
	deadline, ok := i8042_next_deadline(&a)
	testing.expect(t, ok)
	testing.expect_value(t, deadline, I8042_CONTROLLER_INPUT_NS)
	total := I8042_CONTROLLER_INPUT_NS + I8042_DEVICE_BYTE_NS
	i8042_advance(&a, total)
	i8042_advance(&b, 7_000)
	i8042_advance(&b, I8042_CONTROLLER_INPUT_NS - 7_000)
	i8042_advance(&b, 333_333)
	i8042_advance(&b, I8042_DEVICE_BYTE_NS - 333_333)
	testing.expect_value(t, i8042_in(&a, 0x60), u8(0xEE))
	testing.expect_value(t, i8042_in(&b, 0x60), u8(0xEE))
	testing.expect_value(t, a.now_ns, b.now_ns)
}

@(test)
test_i8042_unread_output_is_preserved_for_controller_response :: proc(t: ^testing.T) {
	k: I8042
	i8042_test_init(&k)
	i8042_key(&k, 0x1E)
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	i8042_test_write(&k, 0x64, 0xAA)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x55))
	i8042_advance(&k, I8042_DEVICE_BYTE_NS)
	testing.expect_value(t, i8042_in(&k, 0x60), u8(0x1E))
}
