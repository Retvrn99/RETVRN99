// SPDX-License-Identifier: GPL-3.0-only
package audio

// PCM mappings adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

audio_pcm_u8 :: proc(value: u8) -> i16 {
	return i16((i32(value) - 128) * 256)
}

audio_pcm_i8 :: proc(value: u8) -> i16 {
	return i16(i32(i8(value)) * 256)
}

audio_pcm_i16 :: proc(value: u16) -> i16 {
	return i16(value)
}

audio_pcm_u16 :: proc(value: u16) -> i16 {
	return i16(i32(value) - 32_768)
}

audio_scale_q16 :: proc(value: i16, gain: u32) -> i32 {
	return i32(i64(value) * i64(gain) / i64(AUDIO_GAIN_UNITY))
}
