// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

@(test)
test_audio_pcm_conversions_cover_signed_and_unsigned_extremes :: proc(t: ^testing.T) {
	testing.expect_value(t, audio_pcm_u8(0), i16(-32_768))
	testing.expect_value(t, audio_pcm_u8(0x80), i16(0))
	testing.expect_value(t, audio_pcm_u8(0xFF), i16(32_512))
	testing.expect_value(t, audio_pcm_i8(0x80), i16(-32_768))
	testing.expect_value(t, audio_pcm_i8(0x7F), i16(32_512))
	testing.expect_value(t, audio_pcm_i16(0x8000), i16(-32_768))
	testing.expect_value(t, audio_pcm_u16(0), i16(-32_768))
	testing.expect_value(t, audio_pcm_u16(0x8000), i16(0))
}
