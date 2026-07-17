// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

// Deterministic vectors adapted from IzarraVM's opl_test.rs at commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

opl3_test_operator :: proc(waveform: u8 = 0) -> Opl3_Operator {
	operator: Opl3_Operator
	opl3_operator_init(&operator)
	opl3_operator_set_frequency(&operator, 0x200, 4)
	operator.multiple = 1
	operator.waveform = waveform
	return operator
}

@(test)
test_opl3_rom_and_key_scale_tables_match_known_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, opl3_logsin(0), u16(2137))
	testing.expect_value(t, opl3_logsin(255), u16(0))
	testing.expect_value(t, opl3_exp_lookup(0), i32(4084))
	testing.expect_value(t, opl3_exp_lookup(0x1FF << 3), i32(0))
	expected := [16]u16{0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64}
	for value, index in expected {
		testing.expect_value(t, opl3_ksl_table[index], value)
	}
}

@(test)
test_opl3_ksl_encoding_and_measured_note_select :: proc(t: ^testing.T) {
	operator := opl3_test_operator()
	operator.fnum = 0x3FF
	operator.block = 7
	operator.key_scale_level = 1
	ksl_3db := opl3_operator_ksl_attenuation(&operator)
	operator.key_scale_level = 2
	ksl_1_5db := opl3_operator_ksl_attenuation(&operator)
	operator.key_scale_level = 3
	ksl_6db := opl3_operator_ksl_attenuation(&operator)
	testing.expect_value(t, ksl_3db, u16(896))
	testing.expect_value(t, ksl_1_5db, u16(448))
	testing.expect_value(t, ksl_6db, u16(1792))
	testing.expect_value(t, ksl_3db, ksl_1_5db * 2)
	testing.expect_value(t, ksl_6db, ksl_3db * 2)

	operator.fnum = 0x200
	operator.block = 4
	testing.expect_value(t, opl3_operator_key_scale_number(&operator, false), u8(9))
	testing.expect_value(t, opl3_operator_key_scale_number(&operator, true), u8(8))
}

@(test)
test_opl3_waveform_seven_reverses_negative_attenuation_ramp :: proc(t: ^testing.T) {
	positive_end, positive_negative, positive_audible := opl3_waveform_attenuation(0x1FF, 7)
	negative_start, negative_start_sign, negative_start_audible := opl3_waveform_attenuation(
		0x200,
		7,
	)
	negative_end, negative_end_sign, negative_end_audible := opl3_waveform_attenuation(0x3FF, 7)

	testing.expect_value(t, positive_end, u16(0x1FF << 3))
	testing.expect(t, !positive_negative && positive_audible)
	testing.expect_value(t, negative_start, u16(0x1FF << 3))
	testing.expect(t, negative_start_sign && negative_start_audible)
	testing.expect_value(t, negative_end, u16(0))
	testing.expect(t, negative_end_sign && negative_end_audible)
}

@(test)
test_opl3_operator_phase_and_vibrato_depth :: proc(t: ^testing.T) {
	operator := opl3_test_operator()
	opl3_operator_advance_phase(&operator, 0, false)
	testing.expect_value(t, operator.phase, u32(8192))
	for _ in 1 ..< 128 {
		opl3_operator_advance_phase(&operator, 0, false)
	}
	testing.expect_value(t, operator.phase, u32(0))

	expected := [5]u32{8192, 8224, 8256, 8128, 8224}
	phases := [5]u8{0, 1, 2, 6, 2}
	depths := [5]bool{true, true, true, true, false}
	for value, index in expected {
		vibrato := opl3_test_operator()
		vibrato.vibrato = true
		opl3_operator_advance_phase(&vibrato, phases[index], depths[index])
		testing.expect_value(t, vibrato.phase, value)
	}
}

@(test)
test_opl3_square_wave_and_feedback_vectors :: proc(t: ^testing.T) {
	square := opl3_test_operator(6)
	for index in 0 ..< 128 {
		expected: i32 = index < 64 ? 4084 : -4084
		testing.expect_value(t, opl3_operator_sample(&square, 0), expected)
		opl3_operator_advance_phase(&square, 0, false)
	}

	plain := opl3_test_operator()
	fed := opl3_test_operator()
	fed.feedback = 7
	different := false
	for _ in 0 ..< 256 {
		plain_sample := opl3_operator_render_feedback(&plain, 0)
		fed_sample := opl3_operator_render_feedback(&fed, 0)
		different = different || plain_sample != fed_sample
		testing.expect(t, abs(fed_sample) <= 4200)
		opl3_operator_advance_phase(&plain, 0, false)
		opl3_operator_advance_phase(&fed, 0, false)
	}
	testing.expect(t, different)
}

@(test)
test_opl3_operator_envelope_attack_decay_and_release :: proc(t: ^testing.T) {
	operator := opl3_test_operator()
	operator.attack = 15
	operator.decay = 12
	operator.sustain = 8
	operator.release = 8
	operator.sustained = true
	operator.key_on = true
	for counter in 1 ..= 2000 {
		opl3_operator_advance_envelope(&operator, u32(counter), false)
	}
	testing.expect_value(t, operator.eg_level, u16(0x80))
	testing.expect_value(t, operator.eg_state, Opl3_Eg_State.SUSTAIN)

	operator.key_on = false
	for counter in 2001 ..= 22_000 {
		opl3_operator_advance_envelope(&operator, u32(counter), false)
	}
	testing.expect_value(t, operator.eg_level, u16(0x1FF))
	testing.expect_value(t, operator.eg_state, Opl3_Eg_State.RELEASE)

	frozen := opl3_test_operator()
	frozen.key_on = true
	for counter in 1 ..= 5000 {
		opl3_operator_advance_envelope(&frozen, u32(counter), false)
	}
	testing.expect_value(t, frozen.eg_level, u16(0x1FF))
}
