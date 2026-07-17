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
