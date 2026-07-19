// SPDX-License-Identifier: GPL-3.0-only
package audio

// Creative ADPCM decode adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9 and DOSBox-X commit
// f3483ce0bda88c977dc266924fa36c15ce7eb5f8. Both implementations derive the
// predictor tables from Creative's public Sound Blaster programming material.

Sb16_Adpcm_Mode :: enum u8 {
	None,
	Bits_4,
	Bits_26,
	Bits_2,
}

SB16_ADPCM4_SCALE := [64]i8 {
	0, 1, 2, 3, 4, 5, 6, 7, 0, -1, -2, -3, -4, -5, -6, -7,
	1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15,
	2, 6, 10, 14, 18, 22, 26, 30, -2, -6, -10, -14, -18, -22, -26, -30,
	4, 12, 20, 28, 36, 44, 52, 60, -4, -12, -20, -28, -36, -44, -52, -60,
}

SB16_ADPCM4_ADJUST := [64]u8 {
	0, 0, 0, 0, 0, 16, 16, 16, 0, 0, 0, 0, 0, 16, 16, 16,
	240, 0, 0, 0, 0, 16, 16, 16, 240, 0, 0, 0, 0, 16, 16, 16,
	240, 0, 0, 0, 0, 16, 16, 16, 240, 0, 0, 0, 0, 16, 16, 16,
	240, 0, 0, 0, 0, 0, 0, 0, 240, 0, 0, 0, 0, 0, 0, 0,
}

SB16_ADPCM3_SCALE := [40]i8 {
	0, 1, 2, 3, 0, -1, -2, -3,
	1, 3, 5, 7, -1, -3, -5, -7,
	2, 6, 10, 14, -2, -6, -10, -14,
	4, 12, 20, 28, -4, -12, -20, -28,
	5, 15, 25, 35, -5, -15, -25, -35,
}

SB16_ADPCM3_ADJUST := [40]u8 {
	0, 0, 0, 8, 0, 0, 0, 8,
	248, 0, 0, 8, 248, 0, 0, 8,
	248, 0, 0, 8, 248, 0, 0, 8,
	248, 0, 0, 8, 248, 0, 0, 8,
	248, 0, 0, 0, 248, 0, 0, 0,
}

SB16_ADPCM2_SCALE := [24]i8 {
	0, 1, 0, -1, 1, 3, -1, -3,
	2, 6, -2, -6, 4, 12, -4, -12,
	8, 24, -8, -24, 16, 48, -16, -48,
}

SB16_ADPCM2_ADJUST := [24]u8 {
	0, 4, 0, 4,
	252, 4, 252, 4, 252, 4, 252, 4,
	252, 4, 252, 4, 252, 4, 252, 4,
	252, 0, 252, 0,
}

Sb16_Adpcm :: struct {
	mode:           Sb16_Adpcm_Mode,
	reference:      u8,
	step:           i32,
	wants_reference: bool,
	samples:        [4]u8,
	sample_head:    int,
	sample_count:   int,
}

sb16_adpcm_init :: proc(state: ^Sb16_Adpcm, mode: Sb16_Adpcm_Mode, wants_reference: bool) {
	state^ = {
		mode            = mode,
		reference       = 0x80,
		wants_reference = wants_reference,
	}
}

sb16_adpcm_active :: proc(state: ^Sb16_Adpcm) -> bool {
	return state.mode != .None
}

sb16_adpcm_has_samples :: proc(state: ^Sb16_Adpcm) -> bool {
	return state.sample_count > 0
}

sb16_adpcm_push :: proc(state: ^Sb16_Adpcm, value: u8) {
	if state.sample_count >= len(state.samples) {return}
	index := (state.sample_head + state.sample_count) % len(state.samples)
	state.samples[index] = value
	state.sample_count += 1
}

sb16_adpcm_pop :: proc(state: ^Sb16_Adpcm) -> (u8, bool) {
	if state.sample_count == 0 {return 0, false}
	value := state.samples[state.sample_head]
	state.sample_head = (state.sample_head + 1) % len(state.samples)
	state.sample_count -= 1
	return value, true
}

sb16_adpcm_decode_code :: proc(state: ^Sb16_Adpcm, code: u8) -> u8 {
	index := i32(code) + state.step
	delta: i8
	adjust: u8
	switch state.mode {
	case .Bits_4:
		index = clamp(index, i32(0), i32(len(SB16_ADPCM4_SCALE) - 1))
		delta = SB16_ADPCM4_SCALE[index]
		adjust = SB16_ADPCM4_ADJUST[index]
	case .Bits_26:
		index = clamp(index, i32(0), i32(len(SB16_ADPCM3_SCALE) - 1))
		delta = SB16_ADPCM3_SCALE[index]
		adjust = SB16_ADPCM3_ADJUST[index]
	case .Bits_2:
		index = clamp(index, i32(0), i32(len(SB16_ADPCM2_SCALE) - 1))
		delta = SB16_ADPCM2_SCALE[index]
		adjust = SB16_ADPCM2_ADJUST[index]
	case .None:
		return state.reference
	}
	state.reference = u8(clamp(i32(state.reference) + i32(delta), i32(0), i32(255)))
	state.step = (state.step + i32(adjust)) & 0xFF
	return state.reference
}

sb16_adpcm_decode_byte :: proc(state: ^Sb16_Adpcm, value: u8) {
	switch state.mode {
	case .Bits_4:
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 4))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value & 0x0F))
	case .Bits_26:
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 5 & 0x07))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 2 & 0x07))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, (value & 0x03) << 1))
	case .Bits_2:
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 6 & 0x03))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 4 & 0x03))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value >> 2 & 0x03))
		sb16_adpcm_push(state, sb16_adpcm_decode_code(state, value & 0x03))
	case .None:
	}
}

sb16_arm_adpcm :: proc(
	sb: ^Sb16,
	mode: Sb16_Adpcm_Mode,
	wants_reference, auto_init: bool,
	count: u32,
) {
	sb.dma_16bit = false
	sb.auto_init = auto_init
	sb.stereo = false
	sb.signed_samples = false
	sb.block_size = count
	sb.block_remaining = count
	sb.pending_left_valid = false
	sb.playing = true
	sb.paused = false
	sb.silence_active = false
	sb.direct_dac_valid = false
	sb.release_pending = false
	sb.raw_frame = {}
	sb16_adpcm_init(&sb.adpcm, mode, wants_reference)
	sb16_schedule_first_sample(sb)
}

sb16_render_adpcm_sample :: proc(
	sb: ^Sb16,
	dma_ctx: rawptr,
	read_byte: Sb16_Dma_Read_Byte_Proc,
) -> (
	Audio_Frame,
	bool,
) {
	if !sb16_adpcm_active(&sb.adpcm) || sb.paused {return {}, false}
	for {
		if sample, ok := sb16_adpcm_pop(&sb.adpcm); ok {
			value := audio_pcm_u8(sample)
			frame := Audio_Frame{value, value}
			sb.raw_frame = frame
			if sb.playing || sb16_adpcm_has_samples(&sb.adpcm) {
				sb16_schedule_next_sample(sb)
			} else {
				sb.adpcm = {}
				sb.release_pending = true
				sb16_schedule_next_sample(sb)
			}
			return frame, true
		}
		if !sb.playing {
			sb.adpcm = {}
			sb.sample_scheduled = false
			sb.raw_frame = {}
			return {}, false
		}
		if read_byte == nil {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		encoded, ok := read_byte(dma_ctx, ct1745_selected_dma8(&sb.mixer))
		if !ok {
			sb.starvation_frames += 1
			sb.raw_frame = {}
			sb16_schedule_next_sample(sb)
			return {}, true
		}
		sb16_advance_block(sb)
		if sb.adpcm.wants_reference {
			sb.adpcm.wants_reference = false
			sb.adpcm.reference = encoded
			sb.adpcm.step = 0
		} else {
			sb16_adpcm_decode_byte(&sb.adpcm, encoded)
		}
	}
}
