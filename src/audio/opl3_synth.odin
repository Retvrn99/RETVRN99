// SPDX-License-Identifier: GPL-3.0-only
package audio

// Channel topology, LFO, rhythm and stereo synthesis adapted from IzarraVM
// commit b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

OPL3_OPERATOR_SLOT := [18]u8{0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21}
OPL3_FOUR_OP_PRIMARY := [6]u8{0, 1, 2, 9, 10, 11}
OPL3_TREMOLO_PERIOD :: u32(13_437)

OPL3_RHYTHM_BD_MOD :: 12
OPL3_RHYTHM_BD_CAR :: 15
OPL3_RHYTHM_HH :: 13
OPL3_RHYTHM_TT :: 14
OPL3_RHYTHM_SD :: 16
OPL3_RHYTHM_CY :: 17

opl3_channel_operators :: proc(channel: int) -> (int, int) {
	local := channel % 9
	base := (channel / 9) * 18 + (local / 3) * 6 + local % 3
	return base, base + 3
}

opl3_four_op_primary :: proc(channel: int, mask: u8) -> bool {
	for primary, bit in OPL3_FOUR_OP_PRIMARY {
		if channel == int(primary) {return mask & (u8(1) << u8(bit)) != 0}
	}
	return false
}

opl3_four_op_secondary :: proc(channel: int, mask: u8) -> bool {
	if channel < 3 {return false}
	return opl3_four_op_primary(channel - 3, mask)
}

opl3_four_op_mask :: proc(opl: ^Opl3) -> u8 {
	return opl3_enabled(opl) ? opl.registers[1][0x04] & 0x3F : 0
}

opl3_rhythm_enabled :: proc(opl: ^Opl3) -> bool {
	return opl.registers[0][0xBD] & 0x20 != 0
}

opl3_sync_key_states :: proc(opl: ^Opl3) {
	desired: [36]bool
	channel_count := opl3_enabled(opl) ? 18 : 9
	four_op_mask := opl3_four_op_mask(opl)
	rhythm := opl3_rhythm_enabled(opl)
	for channel in 0 ..< channel_count {
		if rhythm && channel >= 6 && channel <= 8 {continue}
		if opl3_four_op_secondary(channel, four_op_mask) {continue}
		bank := channel / 9
		local := channel % 9
		key_on := opl.registers[bank][0xB0 + local] & 0x20 != 0
		op1, op2 := opl3_channel_operators(channel)
		desired[op1], desired[op2] = key_on, key_on
		if opl3_four_op_primary(channel, four_op_mask) {
			op3, op4 := opl3_channel_operators(channel + 3)
			desired[op3], desired[op4] = key_on, key_on
		}
	}
	if rhythm {
		control := opl.registers[0][0xBD]
		desired[OPL3_RHYTHM_BD_MOD] = control & 0x10 != 0
		desired[OPL3_RHYTHM_BD_CAR] = control & 0x10 != 0
		desired[OPL3_RHYTHM_SD] = control & 0x08 != 0
		desired[OPL3_RHYTHM_TT] = control & 0x04 != 0
		desired[OPL3_RHYTHM_CY] = control & 0x02 != 0
		desired[OPL3_RHYTHM_HH] = control & 0x01 != 0
	}
	for key_on, index in desired {
		opl3_operator_set_key(&opl.operators[index], key_on)
	}
}

opl3_tremolo_attenuation :: proc(opl: ^Opl3) -> u16 {
	position := opl.eg_counter % OPL3_TREMOLO_PERIOD
	half := OPL3_TREMOLO_PERIOD / 2
	rise := position < half ? position : OPL3_TREMOLO_PERIOD - position
	peak: u32 = opl.registers[0][0xBD] & 0x80 != 0 ? 204 : 43
	return u16(rise * peak / half)
}

opl3_vibrato_phase :: proc(opl: ^Opl3) -> u8 {
	return u8((opl.eg_counter >> 10) & 7)
}

opl3_operator_attenuation :: proc(opl: ^Opl3, operator_index: int) -> u16 {
	operator := &opl.operators[operator_index]
	attenuation := opl3_operator_eg_attenuation(operator)
	if operator.tremolo {attenuation += opl3_tremolo_attenuation(opl)}
	return attenuation
}

opl3_channel_pan :: proc(opl: ^Opl3, channel: int) -> (bool, bool) {
	if !opl3_enabled(opl) {return true, true}
	value := opl.registers[channel / 9][0xC0 + channel % 9]
	return value & (0x10 | 0x40) != 0, value & (0x20 | 0x80) != 0
}

opl3_load_operator :: proc(opl: ^Opl3, operator_index, channel: int) {
	bank := channel / 9
	local := channel % 9
	slot := int(OPL3_OPERATOR_SLOT[operator_index % 18])
	fnum :=
		u16(opl.registers[bank][0xA0 + local]) | (u16(opl.registers[bank][0xB0 + local] & 3) << 8)
	block := (opl.registers[bank][0xB0 + local] >> 2) & 7
	reg20 := opl.registers[bank][0x20 + slot]
	reg40 := opl.registers[bank][0x40 + slot]
	reg60 := opl.registers[bank][0x60 + slot]
	reg80 := opl.registers[bank][0x80 + slot]
	waveform: u8
	if opl3_enabled(opl) {
		waveform = opl.registers[bank][0xE0 + slot] & 7
	} else if opl.registers[0][0x01] & 0x20 != 0 {
		waveform = opl.registers[bank][0xE0 + slot] & 3
	}

	operator := &opl.operators[operator_index]
	opl3_operator_set_frequency(operator, fnum, block)
	operator.multiple = reg20 & 0x0F
	operator.key_scale_rate = reg20 & 0x10 != 0
	operator.sustained = reg20 & 0x20 != 0
	operator.vibrato = reg20 & 0x40 != 0
	operator.tremolo = reg20 & 0x80 != 0
	operator.total_level = reg40 & 0x3F
	operator.key_scale_level = reg40 >> 6
	operator.waveform = waveform
	operator.attack = reg60 >> 4
	operator.decay = reg60 & 0x0F
	operator.sustain = reg80 >> 4
	operator.release = reg80 & 0x0F
}

opl3_render_channel :: proc(opl: ^Opl3, channel: int) -> i32 {
	note_select := opl.registers[0][0x08] & 0x40 != 0
	bank := channel / 9
	local := channel % 9
	control := opl.registers[bank][0xC0 + local]
	modulator_index, carrier_index := opl3_channel_operators(channel)
	opl3_load_operator(opl, modulator_index, channel)
	opl3_load_operator(opl, carrier_index, channel)
	modulator := &opl.operators[modulator_index]
	carrier := &opl.operators[carrier_index]
	modulator.feedback = (control >> 1) & 7
	opl3_operator_advance_envelope(modulator, opl.eg_counter, note_select)
	opl3_operator_advance_envelope(carrier, opl.eg_counter, note_select)

	modulator_output := opl3_operator_render_feedback(
		modulator,
		opl3_operator_attenuation(opl, modulator_index),
	)
	carrier_attenuation := opl3_operator_attenuation(opl, carrier_index)
	output: i32
	if control & 1 != 0 {
		output = modulator_output + opl3_operator_sample(carrier, carrier_attenuation)
	} else {
		output = opl3_operator_sample_modulated(carrier, modulator_output, carrier_attenuation)
	}

	vibrato := opl3_vibrato_phase(opl)
	deep := opl.registers[0][0xBD] & 0x40 != 0
	opl3_operator_advance_phase(modulator, vibrato, deep)
	opl3_operator_advance_phase(carrier, vibrato, deep)
	return output
}

opl3_render_four_op :: proc(opl: ^Opl3, channel: int) -> i32 {
	note_select := opl.registers[0][0x08] & 0x40 != 0
	bank := channel / 9
	local := channel % 9
	first_control := opl.registers[bank][0xC0 + local]
	second_control := opl.registers[bank][0xC0 + local + 3]
	op1_index, op2_index := opl3_channel_operators(channel)
	op3_index, op4_index := opl3_channel_operators(channel + 3)
	indices := [4]int{op1_index, op2_index, op3_index, op4_index}
	for index in indices {
		opl3_load_operator(opl, index, channel)
	}
	opl.operators[op1_index].feedback = (first_control >> 1) & 7
	for index in indices {
		opl3_operator_advance_envelope(&opl.operators[index], opl.eg_counter, note_select)
	}
	a1 := opl3_operator_attenuation(opl, op1_index)
	a2 := opl3_operator_attenuation(opl, op2_index)
	a3 := opl3_operator_attenuation(opl, op3_index)
	a4 := opl3_operator_attenuation(opl, op4_index)
	op1 := &opl.operators[op1_index]
	op2 := &opl.operators[op2_index]
	op3 := &opl.operators[op3_index]
	op4 := &opl.operators[op4_index]
	o1 := opl3_operator_render_feedback(op1, a1)
	output: i32

	algorithm := (first_control & 1) << 1 | second_control & 1
	switch algorithm {
	case 0:
		o2 := opl3_operator_sample_modulated(op2, o1, a2)
		o3 := opl3_operator_sample_modulated(op3, o2, a3)
		output = opl3_operator_sample_modulated(op4, o3, a4)
	case 1:
		o2 := opl3_operator_sample_modulated(op2, o1, a2)
		o3 := opl3_operator_sample(op3, a3)
		output = o2 + opl3_operator_sample_modulated(op4, o3, a4)
	case 2:
		o2 := opl3_operator_sample(op2, a2)
		o3 := opl3_operator_sample_modulated(op3, o2, a3)
		output = o1 + opl3_operator_sample_modulated(op4, o3, a4)
	case:
		o2 := opl3_operator_sample(op2, a2)
		o3 := opl3_operator_sample_modulated(op3, o2, a3)
		output = o1 + o3 + opl3_operator_sample(op4, a4)
	}

	vibrato := opl3_vibrato_phase(opl)
	deep := opl.registers[0][0xBD] & 0x40 != 0
	for index in indices {
		opl3_operator_advance_phase(&opl.operators[index], vibrato, deep)
	}
	return output
}

opl3_metal_bit :: proc(hihat_phase, cymbal_phase: u32) -> bool {
	// The published programming model does not define the physical metallic
	// phase network; this retains IzarraVM's deterministic clean-room model.
	a := (hihat_phase >> 10) & 0x3FF
	b := (cymbal_phase >> 10) & 0x3FF
	return ((a >> 8) ~ (a >> 3) ~ (b >> 7) ~ (b >> 2)) & 1 != 0
}

opl3_rhythm_channel :: proc(operator_index: int) -> int {
	switch operator_index {
	case OPL3_RHYTHM_BD_MOD, OPL3_RHYTHM_BD_CAR:
		return 6
	case OPL3_RHYTHM_HH, OPL3_RHYTHM_SD:
		return 7
	case:
		return 8
	}
}

opl3_render_rhythm :: proc(opl: ^Opl3) -> (i32, i32) {
	note_select := opl.registers[0][0x08] & 0x40 != 0
	control := opl.registers[0][0xBD]
	noise := opl.noise & 1 != 0
	indices := [6]int {
		OPL3_RHYTHM_BD_MOD,
		OPL3_RHYTHM_BD_CAR,
		OPL3_RHYTHM_HH,
		OPL3_RHYTHM_TT,
		OPL3_RHYTHM_SD,
		OPL3_RHYTHM_CY,
	}
	for index in indices {
		opl3_load_operator(opl, index, opl3_rhythm_channel(index))
	}
	opl.operators[OPL3_RHYTHM_BD_MOD].feedback = (opl.registers[0][0xC6] >> 1) & 7
	for index in indices {
		opl3_operator_advance_envelope(&opl.operators[index], opl.eg_counter, note_select)
	}

	bd_mod_output := opl3_operator_render_feedback(
		&opl.operators[OPL3_RHYTHM_BD_MOD],
		opl3_operator_attenuation(opl, OPL3_RHYTHM_BD_MOD),
	)
	bd_car_attenuation := opl3_operator_attenuation(opl, OPL3_RHYTHM_BD_CAR)
	bass: i32
	if opl.registers[0][0xC6] & 1 != 0 {
		bass = opl3_operator_sample(&opl.operators[OPL3_RHYTHM_BD_CAR], bd_car_attenuation)
	} else {
		bass = opl3_operator_sample_modulated(
			&opl.operators[OPL3_RHYTHM_BD_CAR],
			bd_mod_output,
			bd_car_attenuation,
		)
	}
	tom := opl3_operator_sample(
		&opl.operators[OPL3_RHYTHM_TT],
		opl3_operator_attenuation(opl, OPL3_RHYTHM_TT),
	)
	metal := opl3_metal_bit(
		opl.operators[OPL3_RHYTHM_HH].phase,
		opl.operators[OPL3_RHYTHM_CY].phase,
	)
	snare_bit := ((opl.operators[OPL3_RHYTHM_SD].phase >> 19) & 1 != 0) != noise
	snare := opl3_operator_percussion_sample(
		&opl.operators[OPL3_RHYTHM_SD],
		opl3_operator_attenuation(opl, OPL3_RHYTHM_SD),
		snare_bit,
	)
	hihat := opl3_operator_percussion_sample(
		&opl.operators[OPL3_RHYTHM_HH],
		opl3_operator_attenuation(opl, OPL3_RHYTHM_HH),
		metal != noise,
	)
	cymbal := opl3_operator_percussion_sample(
		&opl.operators[OPL3_RHYTHM_CY],
		opl3_operator_attenuation(opl, OPL3_RHYTHM_CY),
		metal,
	)

	vibrato := opl3_vibrato_phase(opl)
	deep := control & 0x40 != 0
	for index in indices {
		opl3_operator_advance_phase(&opl.operators[index], vibrato, deep)
	}

	left, right: i32
	outputs := [5]i32{bass, hihat, snare, tom, cymbal}
	channels := [5]int{6, 7, 7, 8, 8}
	for output, output_index in outputs {
		pan_left, pan_right := opl3_channel_pan(opl, channels[output_index])
		if pan_left {left += output}
		if pan_right {right += output}
	}
	return left, right
}

opl3_advance_noise :: proc(opl: ^Opl3) {
	if opl.noise & 1 != 0 {opl.noise ~= 0x80_0302}
	opl.noise >>= 1
}

opl3_noise_apply_transform :: proc(transform: ^[23]u32, value: u32) -> u32 {
	result: u32
	for bit in 0 ..< 23 {
		if value & (u32(1) << u32(bit)) != 0 {result ~= transform[bit]}
	}
	return result
}

opl3_advance_noise_steps :: proc(noise: u32, steps: u64) -> u32 {
	state := noise
	remaining := steps
	if remaining <= 1024 {
		for _ in 0 ..< int(remaining) {
			if state & 1 != 0 {state ~= 0x80_0302}
			state >>= 1
		}
		return state
	}
	power: [23]u32
	for bit in 0 ..< 23 {
		value := u32(1) << u32(bit)
		if value & 1 != 0 {value ~= 0x80_0302}
		power[bit] = value >> 1
	}
	for remaining != 0 {
		if remaining & 1 != 0 {state = opl3_noise_apply_transform(&power, state)}
		remaining >>= 1
		if remaining == 0 {break}
		squared: [23]u32
		for bit in 0 ..< 23 {squared[bit] = opl3_noise_apply_transform(&power, power[bit])}
		power = squared
	}
	return state
}

opl3_synthesize_sample :: proc(opl: ^Opl3) -> (i32, i32) {
	channel_count := opl3_enabled(opl) ? 18 : 9
	rhythm := opl3_rhythm_enabled(opl)
	four_op_mask := opl3_four_op_mask(opl)
	left, right: i32
	for channel in 0 ..< channel_count {
		if rhythm && channel >= 6 && channel <= 8 {continue}
		if opl3_four_op_secondary(channel, four_op_mask) {continue}
		if opl3_four_op_primary(channel, four_op_mask) {
			output := opl3_render_four_op(opl, channel)
			pan_left, pan_right := opl3_channel_pan(opl, channel + 3)
			if pan_left {left += output}
			if pan_right {right += output}
		} else {
			output := opl3_render_channel(opl, channel)
			pan_left, pan_right := opl3_channel_pan(opl, channel)
			if pan_left {left += output}
			if pan_right {right += output}
		}
	}
	if rhythm {
		rhythm_left, rhythm_right := opl3_render_rhythm(opl)
		left += rhythm_left
		right += rhythm_right
	}
	return left, right
}
