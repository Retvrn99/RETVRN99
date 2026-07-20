// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

// Port and routing vectors adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

@(test)
test_opl3_adlib_timer_detection_and_reset :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	_ = opl3_write_port(&opl, 0x388, 0x02)
	_ = opl3_write_port(&opl, 0x389, 0xFF)
	_ = opl3_write_port(&opl, 0x388, 0x04)
	_ = opl3_write_port(&opl, 0x389, 0x01)
	opl3_advance_control_to(&opl, OPL3_TIMER1_TICKS - 1)
	testing.expect_value(t, opl3_status(&opl), u8(0))
	opl3_advance_control_to(&opl, OPL3_TIMER1_TICKS)
	testing.expect_value(t, opl3_status(&opl), u8(0xC0))
	_ = opl3_write_port(&opl, 0x388, 0x04)
	_ = opl3_write_port(&opl, 0x389, 0x80)
	testing.expect_value(t, opl3_status(&opl), u8(0))
}

@(test)
test_opl3_address_latch_captures_a1_and_data_ports_alias :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)

	_ = opl3_write_port(&opl, 0x38A, 0x20)
	_ = opl3_write_port(&opl, 0x389, 0x55)
	testing.expect_value(t, opl.registers[0][0x20], u8(0x55))
	testing.expect_value(t, opl.registers[1][0x20], u8(0))

	_ = opl3_write_port(&opl, 0x38A, 0x05)
	_ = opl3_write_port(&opl, 0x389, 0x01)
	testing.expect(t, opl3_enabled(&opl))
	_ = opl3_write_port(&opl, 0x38A, 0x20)
	_ = opl3_write_port(&opl, 0x389, 0x66)
	testing.expect_value(t, opl.registers[1][0x20], u8(0x66))

	_ = opl3_write_port(&opl, 0x388, 0x21)
	_ = opl3_write_port(&opl, 0x38B, 0x77)
	testing.expect_value(t, opl.registers[0][0x21], u8(0x77))
}

@(test)
test_opl3_new_mode_routes_a_tone_to_selected_stereo_side :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	_ = opl3_write_port(&opl, 0x38A, 0x05)
	_ = opl3_write_port(&opl, 0x38B, 0x01)
	_ = opl3_write_port(&opl, 0x388, 0x43)
	_ = opl3_write_port(&opl, 0x389, 0x00)
	_ = opl3_write_port(&opl, 0x388, 0x60)
	_ = opl3_write_port(&opl, 0x389, 0xF0)
	_ = opl3_write_port(&opl, 0x388, 0x63)
	_ = opl3_write_port(&opl, 0x389, 0xF0)
	_ = opl3_write_port(&opl, 0x388, 0xC0)
	_ = opl3_write_port(&opl, 0x389, 0x10)
	_ = opl3_write_port(&opl, 0x388, 0xA0)
	_ = opl3_write_port(&opl, 0x389, 0x80)
	_ = opl3_write_port(&opl, 0x388, 0xB0)
	_ = opl3_write_port(&opl, 0x389, 0x31)

	nonzero := false
	for _ in 0 ..< 8 {
		frame, produced := opl3_render_sample(&opl)
		testing.expect(t, produced)
		nonzero = nonzero || frame.left != 0
		testing.expect_value(t, frame.right, i16(0))
	}
	testing.expect(t, nonzero)
}

@(test)
test_opl3_sample_deadline_makes_strict_progress :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	opl3_write_register(&opl, 0, 0xB0, 0x20)
	previous := opl.now_tick
	for _ in 0 ..< int(OPL3_NATIVE_HZ * 2) {
		deadline, pending := opl3_sample_deadline(&opl)
		if !testing.expect(t, pending) || !testing.expect(t, deadline > previous) {return}
		_, produced := opl3_render_sample(&opl)
		if !testing.expect(t, produced) {return}
		previous = deadline
	}
	testing.expect_value(t, opl.global_sample_index, OPL3_NATIVE_HZ * 2)
	testing.expect_value(t, opl.now_tick, u64(0))
}

@(test)
test_gsw_sound_large_opl_advance_finishes_past_target :: proc(t: ^testing.T) {
	g: Gsw_Sound
	gsw_sound_init(&g)
	opl3_write_register(&g.opl3, 0, 0xB0, 0x20)
	target := AUDIO_MASTER_CLOCK_HZ * 2
	gsw_sound_advance_to(&g, target, {})
	testing.expect_value(t, g.opl3.now_tick, target)
	testing.expect_value(t, g.opl3.global_sample_index, OPL3_NATIVE_HZ * 2)
	deadline, pending := opl3_sample_deadline(&g.opl3)
	testing.expect(t, pending)
	testing.expect(t, deadline > target)
}

@(test)
test_opl3_noise_maximum_jump_matches_lfsr_period :: proc(t: ^testing.T) {
	period := u64((u32(1) << 23) - 1)
	reduced := ~u64(0) % period
	reference := u32(1)
	for _ in 0 ..< int(reduced) {
		if reference & 1 != 0 {reference ~= 0x80_0302}
		reference >>= 1
	}
	testing.expect_value(t, opl3_advance_noise_steps(1, ~u64(0)), reference)
}
