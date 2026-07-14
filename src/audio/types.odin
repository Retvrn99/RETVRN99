// SPDX-License-Identifier: GPL-3.0-only
package audio

// Audio timing and queue policy adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

AUDIO_MASTER_CLOCK_HZ :: u64(6_600_000_000)
AUDIO_OUTPUT_HZ :: u64(48_000)
AUDIO_CDDA_HZ :: u64(44_100)

AUDIO_TARGET_FRAMES :: int(AUDIO_OUTPUT_HZ * 30 / 1_000)
AUDIO_HIGH_FRAMES :: int(AUDIO_OUTPUT_HZ * 60 / 1_000)
AUDIO_CAPACITY_FRAMES :: int(AUDIO_OUTPUT_HZ * 120 / 1_000)
AUDIO_RAMP_FRAMES :: 64

Audio_Frame :: struct {
	left:  i16,
	right: i16,
}

Audio_Frame_Wide :: struct {
	left:  i32,
	right: i32,
}

audio_clamp_i16 :: proc(value: i64) -> i16 {
	return i16(clamp(value, i64(-32_768), i64(32_767)))
}
