// SPDX-License-Identifier: GPL-3.0-only
package audio

// Operator, envelope, phase, feedback and modulation behavior adapted from
// IzarraVM commit b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

Opl3_Eg_State :: enum u8 {
	ATTACK,
	DECAY,
	SUSTAIN,
	RELEASE,
}

Opl3_Operator :: struct {
	phase:            u32,
	fnum:             u16,
	block:            u8,
	multiple:         u8,
	waveform:         u8,
	total_level:      u8,
	key_scale_level:  u8,
	feedback:         u8,
	feedback_history: [2]i32,
	tremolo:          bool,
	vibrato:          bool,
	attack:           u8,
	decay:            u8,
	sustain:          u8,
	release:          u8,
	sustained:        bool,
	key_scale_rate:   bool,
	key_on:           bool,
	eg_level:         u16,
	eg_state:         Opl3_Eg_State,
}

opl3_operator_init :: proc(operator: ^Opl3_Operator) {
	operator^ = {}
	operator.eg_level = 0x1FF
	operator.eg_state = .RELEASE
}

opl3_operator_set_frequency :: proc(operator: ^Opl3_Operator, fnum: u16, block: u8) {
	operator.fnum = fnum & 0x3FF
	operator.block = block & 7
}

opl3_operator_set_key :: proc(operator: ^Opl3_Operator, key_on: bool) {
	if operator.key_on == key_on {return}
	operator.key_on = key_on
	if key_on {
		operator.phase = 0
		operator.eg_state = .ATTACK
	} else if operator.eg_state != .RELEASE {
		operator.eg_state = .RELEASE
	}
}

opl3_operator_ksl_attenuation :: proc(operator: ^Opl3_Operator) -> u16 {
	if operator.key_scale_level == 0 {return 0}
	base := i32(opl3_ksl_table[operator.fnum >> 6]) - 8 * (8 - i32(operator.block))
	if base < 0 {base = 0}
	shifts := [4]u32{8, 1, 2, 0}
	units := u32(base) >> shifts[operator.key_scale_level]
	return u16(units << 5)
}

opl3_operator_phase_increment :: proc(operator: ^Opl3_Operator, fnum: u32) -> u32 {
	return ((fnum << operator.block) * OPL3_MULTIPLE_X2[operator.multiple]) >> 1
}

opl3_operator_advance_phase :: proc(
	operator: ^Opl3_Operator,
	vibrato_phase: u8,
	deep_vibrato: bool,
) {
	fnum := i32(operator.fnum)
	if operator.vibrato {
		half_shift: u32 = deep_vibrato ? 8 : 9
		peak_shift: u32 = deep_vibrato ? 7 : 8
		half := i32(operator.fnum) >> half_shift
		peak := i32(operator.fnum) >> peak_shift
		switch vibrato_phase {
		case 1, 3:
			fnum += half
		case 2:
			fnum += peak
		case 5, 7:
			fnum -= half
		case 6:
			fnum -= peak
		}
	}
	fnum = clamp(fnum, 0, 0x3FF)
	operator.phase =
		(operator.phase + opl3_operator_phase_increment(operator, u32(fnum))) & 0x000F_FFFF
}

opl3_operator_eg_attenuation :: proc(operator: ^Opl3_Operator) -> u16 {
	return operator.eg_level << 3
}

opl3_operator_key_scale_number :: proc(operator: ^Opl3_Operator, note_select: bool) -> u8 {
	// Real YMF262 silicon selects the opposite F-number bits to the data sheet.
	bit_index: u32 = note_select ? 8 : 9
	bit := (operator.fnum >> bit_index) & 1
	return (operator.block << 1) | u8(bit)
}

opl3_operator_effective_rate :: proc(operator: ^Opl3_Operator, rate: u8, note_select: bool) -> u8 {
	if rate == 0 {return 0}
	key_scale_number := opl3_operator_key_scale_number(operator, note_select)
	offset := operator.key_scale_rate ? key_scale_number : key_scale_number >> 2
	return min(4 * rate + offset, u8(63))
}

opl3_operator_sustain_target :: proc(operator: ^Opl3_Operator) -> u16 {
	return operator.sustain == 0x0F ? u16(0x1F0) : u16(operator.sustain) << 4
}

opl3_operator_advance_envelope :: proc(operator: ^Opl3_Operator, counter: u32, note_select: bool) {
	if operator.key_on && operator.eg_state == .RELEASE {
		operator.eg_state = .ATTACK
		operator.phase = 0
	} else if !operator.key_on && operator.eg_state != .RELEASE {
		operator.eg_state = .RELEASE
	}

	rate: u8
	switch operator.eg_state {
	case .ATTACK:
		rate = operator.attack
	case .DECAY:
		rate = operator.decay
	case .SUSTAIN:
		if operator.sustained {return}
		rate = operator.release
	case .RELEASE:
		rate = operator.release
	}
	effective_rate := opl3_operator_effective_rate(operator, rate, note_select)
	increment := opl3_eg_increment(effective_rate, counter)

	switch operator.eg_state {
	case .ATTACK:
		if effective_rate >= 60 {
			operator.eg_level = 0
		} else {
			for _ in 0 ..< int(increment) {
				if operator.eg_level == 0 {break}
				operator.eg_level -= (operator.eg_level >> 3) + 1
			}
		}
		if operator.eg_level == 0 {operator.eg_state = .DECAY}
	case .DECAY:
		operator.eg_level = min(operator.eg_level + increment, u16(0x1FF))
		target := opl3_operator_sustain_target(operator)
		if operator.eg_level >= target {
			operator.eg_level = target
			operator.eg_state = .SUSTAIN
		}
	case .SUSTAIN, .RELEASE:
		operator.eg_level = min(operator.eg_level + increment, u16(0x1FF))
	}
}

opl3_operator_sample_modulated :: proc(
	operator: ^Opl3_Operator,
	phase_modulation: i32,
	extra_attenuation: u16,
) -> i32 {
	attenuation :=
		u32(operator.total_level) * 32 +
		u32(opl3_operator_ksl_attenuation(operator)) +
		u32(extra_attenuation)
	position := u32((i32(operator.phase >> 10) + phase_modulation) & 0x3FF)
	return opl3_waveform_output(position, operator.waveform, attenuation)
}

opl3_operator_sample :: proc(operator: ^Opl3_Operator, extra_attenuation: u16) -> i32 {
	return opl3_operator_sample_modulated(operator, 0, extra_attenuation)
}

opl3_operator_render_feedback :: proc(operator: ^Opl3_Operator, extra_attenuation: u16) -> i32 {
	modulation: i32
	if operator.feedback != 0 {
		modulation =
			(operator.feedback_history[0] + operator.feedback_history[1]) >>
			(9 - operator.feedback)
	}
	output := opl3_operator_sample_modulated(operator, modulation, extra_attenuation)
	operator.feedback_history = {output, operator.feedback_history[0]}
	return output
}

opl3_operator_percussion_sample :: proc(
	operator: ^Opl3_Operator,
	extra_attenuation: u16,
	positive: bool,
) -> i32 {
	attenuation :=
		u32(operator.total_level) * 32 +
		u32(opl3_operator_ksl_attenuation(operator)) +
		u32(extra_attenuation)
	magnitude := opl3_exp_lookup(attenuation)
	return positive ? magnitude : -magnitude
}

opl3_operator_audible :: proc(operator: ^Opl3_Operator) -> bool {
	return operator.eg_level < 0x1FF
}
