// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

// Register-level vectors adapted from IzarraVM's opl_test.rs at commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

opl3_test_write :: proc(opl: ^Opl3, index, value: u8) {
	opl3_write_register(opl, 0, index, value)
}

opl3_test_write_secondary :: proc(opl: ^Opl3, index, value: u8) {
	opl3_write_register(opl, 1, index, value)
}

opl3_test_program_channel0 :: proc(opl: ^Opl3, control: u8 = 0x01, modulator_level: u8 = 0x3F) {
	opl3_test_write(opl, 0x20, 0x01)
	opl3_test_write(opl, 0x23, 0x21)
	opl3_test_write(opl, 0x40, modulator_level)
	opl3_test_write(opl, 0x43, 0x00)
	opl3_test_write(opl, 0x60, 0xF0)
	opl3_test_write(opl, 0x63, 0xF0)
	opl3_test_write(opl, 0x80, 0x08)
	opl3_test_write(opl, 0x83, 0x08)
	opl3_test_write(opl, 0xC0, control)
	opl3_test_write(opl, 0xA0, 0x00)
	opl3_test_write(opl, 0xB0, 0x20 | (4 << 2) | 0x02)
}

opl3_test_peak_left :: proc(opl: ^Opl3, count: int) -> i32 {
	peak: i32
	for _ in 0 ..< count {
		frame, produced := opl3_render_sample(opl)
		if !produced {continue}
		peak = max(peak, abs(i32(frame.left)))
	}
	return peak
}

@(test)
test_opl3_waveform_gating_and_stereo_matrix :: proc(t: ^testing.T) {
	has_negative := proc(new_mode: bool) -> bool {
		opl: Opl3
		opl3_init(&opl)
		opl3_test_write(&opl, 0x01, 0x20)
		if new_mode {opl3_test_write_secondary(&opl, 0x05, 0x01)}
		opl3_test_write(&opl, 0x20, 0x01)
		opl3_test_write(&opl, 0x40, 0x00)
		opl3_test_write(&opl, 0x60, 0xF0)
		opl3_test_write(&opl, 0x63, 0x00)
		opl3_test_write(&opl, 0xE0, 0x06)
		opl3_test_write(&opl, 0xC0, 0x31)
		opl3_test_write(&opl, 0xA0, 0x00)
		opl3_test_write(&opl, 0xB0, 0x20 | (4 << 2) | 0x02)
		for _ in 0 ..< 256 {
			frame, _ := opl3_render_sample(&opl)
			if frame.left < 0 {return true}
		}
		return false
	}
	testing.expect(t, !has_negative(false))
	testing.expect(t, has_negative(true))

	controls := [6]u8{0x11, 0x21, 0x41, 0x81, 0x31, 0x01}
	expect_left := [6]bool{true, false, true, false, true, false}
	expect_right := [6]bool{false, true, false, true, true, false}
	for control, index in controls {
		opl: Opl3
		opl3_init(&opl)
		opl3_test_write_secondary(&opl, 0x05, 0x01)
		opl3_test_program_channel0(&opl, control)
		left_peak, right_peak: i32
		for _ in 0 ..< 256 {
			frame, _ := opl3_render_sample(&opl)
			left_peak = max(left_peak, abs(i32(frame.left)))
			right_peak = max(right_peak, abs(i32(frame.right)))
		}
		testing.expect_value(t, left_peak > 1000, expect_left[index])
		testing.expect_value(t, right_peak > 1000, expect_right[index])
	}
}

@(test)
test_opl3_new_mode_waveforms_ignore_legacy_wse :: proc(t: ^testing.T) {
	legacy: Opl3
	opl3_init(&legacy)
	opl3_test_write(&legacy, 0xE0, 0x07)
	opl3_load_operator(&legacy, 0, 0)
	testing.expect_value(t, legacy.operators[0].waveform, u8(0))
	opl3_test_write(&legacy, 0x01, 0x20)
	opl3_load_operator(&legacy, 0, 0)
	testing.expect_value(t, legacy.operators[0].waveform, u8(3))

	new_mode: Opl3
	opl3_init(&new_mode)
	opl3_test_write_secondary(&new_mode, 0x05, 0x01)
	opl3_test_write(&new_mode, 0xE0, 0x07)
	opl3_load_operator(&new_mode, 0, 0)
	testing.expect_value(t, new_mode.operators[0].waveform, u8(7))
}

opl3_test_setup_channel3 :: proc(opl: ^Opl3) {
	opl3_test_write_secondary(opl, 0x05, 0x01)
	opl3_test_write(opl, 0x2B, 0x21)
	opl3_test_write(opl, 0x4B, 0x00)
	opl3_test_write(opl, 0x6B, 0xF0)
	opl3_test_write(opl, 0x8B, 0x00)
	opl3_test_write(opl, 0xA3, 0x00)
	opl3_test_write(opl, 0xC3, 0x31)
	opl3_test_write(opl, 0xB3, 0x20 | (4 << 2) | 0x02)
}

@(test)
test_opl3_four_op_pair_owns_secondary_channel :: proc(t: ^testing.T) {
	two_op: Opl3
	opl3_init(&two_op)
	opl3_test_setup_channel3(&two_op)
	testing.expect(t, opl3_test_peak_left(&two_op, 256) > 1000)

	four_op: Opl3
	opl3_init(&four_op)
	opl3_test_setup_channel3(&four_op)
	opl3_test_write_secondary(&four_op, 0x04, 0x01)
	testing.expect_value(t, opl3_test_peak_left(&four_op, 256), i32(0))
}

opl3_test_four_op_signature :: proc(first, second: u8) -> u64 {
	opl: Opl3
	opl3_init(&opl)
	opl3_test_write_secondary(&opl, 0x05, 0x01)
	opl3_test_write_secondary(&opl, 0x04, 0x01)
	slots := [4]u8{0, 3, 8, 11}
	for slot in slots {
		opl3_test_write(&opl, 0x20 + slot, 0x01)
		opl3_test_write(&opl, 0x40 + slot, 0x00)
		opl3_test_write(&opl, 0x60 + slot, 0xF0)
		opl3_test_write(&opl, 0x80 + slot, 0x00)
	}
	opl3_test_write(&opl, 0xA0, 0x00)
	opl3_test_write(&opl, 0xC0, 0x30 | first)
	opl3_test_write(&opl, 0xC3, 0x30 | second)
	opl3_test_write(&opl, 0xB0, 0x20 | (4 << 2) | 0x02)
	hash := u64(14_695_981_039_346_656_037)
	for _ in 0 ..< 128 {
		frame, _ := opl3_render_sample(&opl)
		hash ~= u64(u16(frame.left))
		hash *= 1_099_511_628_211
	}
	return hash
}

@(test)
test_opl3_four_op_output_uses_secondary_stereo_route :: proc(t: ^testing.T) {
	for algorithm in 0 ..< 4 {
		opl: Opl3
		opl3_init(&opl)
		opl3_test_write_secondary(&opl, 0x05, 0x01)
		opl3_test_write_secondary(&opl, 0x04, 0x01)
		slots := [4]u8{0, 3, 8, 11}
		for slot in slots {
			opl3_test_write(&opl, 0x20 + slot, 0x01)
			opl3_test_write(&opl, 0x40 + slot, 0x00)
			opl3_test_write(&opl, 0x60 + slot, 0xF0)
			opl3_test_write(&opl, 0x80 + slot, 0x00)
		}
		opl3_test_write(&opl, 0xC0, 0x10 | u8(algorithm >> 1))
		opl3_test_write(&opl, 0xC3, 0x20 | u8(algorithm & 1))
		opl3_test_write(&opl, 0xA0, 0x00)
		opl3_test_write(&opl, 0xB0, 0x20 | (4 << 2) | 0x02)
		left_peak, right_peak: i32
		for _ in 0 ..< 256 {
			frame, _ := opl3_render_sample(&opl)
			left_peak = max(left_peak, abs(i32(frame.left)))
			right_peak = max(right_peak, abs(i32(frame.right)))
		}
		testing.expect_value(t, left_peak, i32(0))
		testing.expect(t, right_peak > 1000)
	}
}

@(test)
test_opl3_same_tick_key_edges_retrigger_melodic_four_op_and_rhythm :: proc(t: ^testing.T) {
	melodic: Opl3
	opl3_init(&melodic)
	opl3_test_write_secondary(&melodic, 0x05, 0x01)
	opl3_test_write_secondary(&melodic, 0x04, 0x01)
	opl3_test_write(&melodic, 0xB0, 0x20)
	indices := [4]int{0, 3, 6, 9}
	for index in indices {melodic.operators[index].phase = 1234}
	opl3_test_write(&melodic, 0xB0, 0x00)
	for index in indices {
		testing.expect(t, !melodic.operators[index].key_on)
		testing.expect_value(t, melodic.operators[index].eg_state, Opl3_Eg_State.RELEASE)
	}
	opl3_test_write(&melodic, 0xB0, 0x20)
	for index in indices {
		testing.expect(t, melodic.operators[index].key_on)
		testing.expect_value(t, melodic.operators[index].phase, u32(0))
		testing.expect_value(t, melodic.operators[index].eg_state, Opl3_Eg_State.ATTACK)
	}
	opl3_test_write(&melodic, 0xB3, 0x00)
	for index in indices {testing.expect(t, melodic.operators[index].key_on)}

	rhythm: Opl3
	opl3_init(&rhythm)
	opl3_test_write(&rhythm, 0xBD, 0x21)
	rhythm.operators[OPL3_RHYTHM_HH].phase = 5678
	opl3_test_write(&rhythm, 0xBD, 0x20)
	testing.expect(t, !rhythm.operators[OPL3_RHYTHM_HH].key_on)
	opl3_test_write(&rhythm, 0xBD, 0x21)
	testing.expect(t, rhythm.operators[OPL3_RHYTHM_HH].key_on)
	testing.expect_value(t, rhythm.operators[OPL3_RHYTHM_HH].phase, u32(0))
	testing.expect_value(t, rhythm.operators[OPL3_RHYTHM_HH].eg_state, Opl3_Eg_State.ATTACK)
}

@(test)
test_opl3_noise_uses_23_bit_ymf262_polynomial :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	opl3_advance_noise(&opl)
	testing.expect_value(t, opl.noise, u32(0x40_0181))
	opl3_advance_noise(&opl)
	testing.expect_value(t, opl.noise, u32(0x60_0141))
}

@(test)
test_opl3_idle_global_clock_catches_up_without_audio_events :: proc(t: ^testing.T) {
	reference := u32(1)
	for _ in 0 ..< int(OPL3_NATIVE_HZ) {
		if reference & 1 != 0 {reference ~= 0x80_0302}
		reference >>= 1
	}

	opl: Opl3
	opl3_init(&opl)
	opl3_advance_control_to(&opl, AUDIO_MASTER_CLOCK_HZ)
	testing.expect(t, !opl.sample_scheduled)
	testing.expect_value(t, opl.global_sample_index, OPL3_NATIVE_HZ)
	testing.expect_value(t, opl.eg_counter, u32(OPL3_NATIVE_HZ))
	testing.expect_value(t, opl.noise, reference)

	opl3_test_write(&opl, 0xB0, 0x20)
	deadline, pending := opl3_sample_deadline(&opl)
	testing.expect(t, pending)
	testing.expect(t, deadline > opl.now_tick)
}

@(test)
test_opl3_four_op_algorithms_have_distinct_signatures :: proc(t: ^testing.T) {
	signatures := [4]u64 {
		opl3_test_four_op_signature(0, 0),
		opl3_test_four_op_signature(0, 1),
		opl3_test_four_op_signature(1, 0),
		opl3_test_four_op_signature(1, 1),
	}
	for value, index in signatures {
		for other_index in index + 1 ..< len(signatures) {
			testing.expect(t, value != signatures[other_index])
		}
	}
}

opl3_test_loud_rhythm_operator :: proc(opl: ^Opl3, slot: u8) {
	opl3_test_write(opl, 0x20 + slot, 0x21)
	opl3_test_write(opl, 0x40 + slot, 0x00)
	opl3_test_write(opl, 0x60 + slot, 0xF0)
	opl3_test_write(opl, 0x80 + slot, 0x00)
}

@(test)
test_opl3_rhythm_keys_and_replaces_melodic_channels :: proc(t: ^testing.T) {
	rhythm: Opl3
	opl3_init(&rhythm)
	rhythm_slots := [6]u8{16, 17, 18, 19, 20, 21}
	for slot in rhythm_slots {
		opl3_test_loud_rhythm_operator(&rhythm, slot)
	}
	for channel in 6 ..= 8 {
		opl3_test_write(&rhythm, u8(0xA0 + channel), 0x00)
		opl3_test_write(&rhythm, u8(0xB0 + channel), (4 << 2) | 0x02)
	}
	opl3_test_write(&rhythm, 0xBD, 0x3F)
	testing.expect(t, opl3_test_peak_left(&rhythm, 1024) > 1000)

	melodic: Opl3
	opl3_init(&melodic)
	opl3_test_loud_rhythm_operator(&melodic, 19)
	opl3_test_write(&melodic, 0xA6, 0x00)
	opl3_test_write(&melodic, 0xC6, 0x00)
	opl3_test_write(&melodic, 0xB6, 0x20 | (4 << 2) | 0x02)
	testing.expect(t, opl3_test_peak_left(&melodic, 256) > 1000)

	replaced: Opl3
	opl3_init(&replaced)
	opl3_test_loud_rhythm_operator(&replaced, 19)
	opl3_test_write(&replaced, 0xA6, 0x00)
	opl3_test_write(&replaced, 0xC6, 0x00)
	opl3_test_write(&replaced, 0xB6, 0x20 | (4 << 2) | 0x02)
	opl3_test_write(&replaced, 0xBD, 0x20)
	testing.expect_value(t, opl3_test_peak_left(&replaced, 256), i32(0))
}

@(test)
test_opl3_release_tail_keeps_native_scheduler_alive :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	opl3_test_program_channel0(&opl)
	for _ in 0 ..< 8 {
		_, _ = opl3_render_sample(&opl)
	}
	opl3_test_write(&opl, 0xB0, (4 << 2) | 0x02)
	_, pending_after_key_off := opl3_sample_deadline(&opl)
	testing.expect(t, pending_after_key_off)
	produced := 0
	for _ in 0 ..< 30_000 {
		_, ok := opl3_render_sample(&opl)
		if !ok {break}
		produced += 1
	}
	_, pending_after_release := opl3_sample_deadline(&opl)
	testing.expect(t, produced > 0)
	testing.expect(t, !pending_after_release)
	testing.expect_value(t, opl.operators[3].eg_level, u16(0x1FF))
}

@(test)
test_opl3_silent_key_transition_is_consumed_before_sleep :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	opl3_test_write(&opl, 0x23, 0x21)
	opl3_test_write(&opl, 0x63, 0x00)
	opl3_test_write(&opl, 0x83, 0x08)
	opl3_test_write(&opl, 0xC0, 0x01)
	opl3_test_write(&opl, 0xA0, 0x00)
	opl3_test_write(&opl, 0xB0, 0x20 | (4 << 2) | 0x02)
	_, _ = opl3_render_sample(&opl)
	testing.expect_value(t, opl.operators[3].eg_state, Opl3_Eg_State.ATTACK)

	opl3_test_write(&opl, 0xB0, (4 << 2) | 0x02)
	_, pending := opl3_sample_deadline(&opl)
	testing.expect(t, pending)
	_, _ = opl3_render_sample(&opl)
	testing.expect_value(t, opl.operators[3].eg_state, Opl3_Eg_State.RELEASE)

	opl3_test_write(&opl, 0xB0, 0x20 | (4 << 2) | 0x02)
	_, _ = opl3_render_sample(&opl)
	testing.expect_value(t, opl.operators[3].phase, u32(8192))
}

@(test)
test_opl3_render_stream_has_stable_crc :: proc(t: ^testing.T) {
	opl: Opl3
	opl3_init(&opl)
	opl3_test_write_secondary(&opl, 0x05, 0x01)
	opl3_test_program_channel0(&opl, 0x31, 0x00)
	hash := u64(14_695_981_039_346_656_037)
	for _ in 0 ..< 512 {
		frame, produced := opl3_render_sample(&opl)
		testing.expect(t, produced)
		hash ~= u64(u16(frame.left)) | u64(u16(frame.right)) << 16
		hash *= 1_099_511_628_211
	}
	testing.expect_value(t, hash, u64(467_340_903_749_134_207))
}
