// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:math"

// Clean-room integer synthesis tables and waveform rules adapted from IzarraVM
// commit b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

OPL3_MULTIPLE_X2 := [16]u32{1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30}

OPL3_EG_PATTERN := [4][8]u16 {
	{1, 1, 1, 1, 1, 1, 1, 1},
	{1, 1, 1, 2, 1, 1, 1, 2},
	{1, 2, 1, 2, 1, 2, 1, 2},
	{1, 2, 2, 2, 1, 2, 2, 2},
}

opl3_logsin_table: [256]u16
opl3_exp_table: [256]u16
opl3_ksl_table: [16]u16

@(init)
opl3_build_tables :: proc "contextless" () {
	for index in 0 ..< 256 {
		angle := (f64(index) + 0.5) * math.PI / 512.0
		opl3_logsin_table[index] = u16(math.round(-math.log2(math.sin(angle)) * 256.0))
		opl3_exp_table[index] = u16(math.round((math.pow(2.0, f64(index) / 256.0) - 1.0) * 1024.0))
	}
	for index in 1 ..< 16 {
		opl3_ksl_table[index] = u16(math.ceil(8.0 * math.log2(16.0 * f64(index))))
	}
}

opl3_logsin :: proc(index: u32) -> u16 {
	return opl3_logsin_table[index & 0xFF]
}

opl3_exp_lookup :: proc(attenuation: u32) -> i32 {
	fraction := attenuation & 0xFF
	shift := attenuation >> 8
	if shift >= 32 {return 0}
	return ((i32(opl3_exp_table[fraction ~ 0xFF]) + 1024) << 1) >> shift
}

opl3_waveform_attenuation :: proc(
	position: u32,
	waveform: u8,
) -> (
	attenuation: u16,
	negative, audible: bool,
) {
	quarter := position & 0xFF
	second_quarter := position & 0x100 != 0
	second_half := position & 0x200 != 0
	folded := second_quarter ? opl3_logsin(quarter ~ 0xFF) : opl3_logsin(quarter)

	switch waveform {
	case 0:
		return folded, second_half, true
	case 1:
		return folded, false, !second_half
	case 2:
		return folded, false, true
	case 3:
		return opl3_logsin(quarter), false, !second_quarter
	case 4:
		if second_half {return 0, false, false}
		return opl3_waveform_attenuation((position << 1) & 0x3FF, 0)
	case 5:
		if second_half {return 0, false, false}
		return opl3_waveform_attenuation((position << 1) & 0x3FF, 2)
	case 6:
		return 0, second_half, true
	case:
		ramp := position & 0x1FF
		if second_half {ramp ~= 0x1FF}
		return u16(ramp << 3), second_half, true
	}
}

opl3_waveform_output :: proc(position: u32, waveform: u8, attenuation: u32) -> i32 {
	wave_attenuation, negative, audible := opl3_waveform_attenuation(position, waveform)
	if !audible {return 0}
	magnitude := opl3_exp_lookup(u32(wave_attenuation) + attenuation)
	return negative ? -magnitude : magnitude
}

opl3_eg_increment :: proc(effective_rate: u8, counter: u32) -> u16 {
	if effective_rate == 0 {return 0}
	rate_high := effective_rate >> 2
	rate_low := effective_rate & 3
	if rate_high < 13 {
		shift := u32(13 - rate_high)
		if counter & ((u32(1) << shift) - 1) != 0 {return 0}
		phase := (counter >> shift) & 7
		return OPL3_EG_PATTERN[rate_low][phase]
	}
	phase := counter & 7
	return OPL3_EG_PATTERN[rate_low][phase] << (rate_high - 13)
}
