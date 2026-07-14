// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:math"

// Polyphase windowed-sinc design adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

AUDIO_RESAMPLER_TAPS :: 64
AUDIO_RESAMPLER_HALF :: AUDIO_RESAMPLER_TAPS / 2
AUDIO_RESAMPLER_PHASES :: 512
AUDIO_RESAMPLER_CAPACITY :: 8_192

Audio_Resampler :: struct {
	input_hz:   u64,
	output_hz:  u64,
	next_num:   u64,
	base_index: u64,
	head:       int,
	count:      int,
	history:    [AUDIO_RESAMPLER_CAPACITY]Audio_Frame_Wide,
	table:      [AUDIO_RESAMPLER_PHASES * AUDIO_RESAMPLER_TAPS]f32,
}

@(private = "file")
audio_resampler_sinc :: proc(value: f64) -> f64 {
	if math.abs(value) < 1.0e-15 {return 1}
	x := math.PI * value
	return math.sin(x) / x
}

@(private = "file")
audio_resampler_blackman :: proc(value, half: f64) -> f64 {
	if math.abs(value) > half {return 0}
	return(
		0.42 +
		0.5 * math.cos(math.PI * value / half) +
		0.08 * math.cos(2 * math.PI * value / half) \
	)
}

audio_resampler_init :: proc(resampler: ^Audio_Resampler, input_hz, output_hz: u64) -> bool {
	if input_hz == 0 || output_hz == 0 {return false}
	resampler^ = {
		input_hz  = input_hz,
		output_hz = output_hz,
	}
	cutoff := min(f64(output_hz) / f64(input_hz), 1.0)
	for phase in 0 ..< AUDIO_RESAMPLER_PHASES {
		fraction := f64(phase) / AUDIO_RESAMPLER_PHASES
		sum: f64
		for tap in 0 ..< AUDIO_RESAMPLER_TAPS {
			distance := fraction + f64(AUDIO_RESAMPLER_HALF - 1) - f64(tap)
			weight :=
				audio_resampler_sinc(cutoff * distance) *
				audio_resampler_blackman(distance, AUDIO_RESAMPLER_HALF)
			resampler.table[phase * AUDIO_RESAMPLER_TAPS + tap] = f32(weight)
			sum += weight
		}
		for tap in 0 ..< AUDIO_RESAMPLER_TAPS {
			index := phase * AUDIO_RESAMPLER_TAPS + tap
			resampler.table[index] = f32(f64(resampler.table[index]) / sum)
		}
	}
	audio_resampler_reset(resampler)
	return true
}

audio_resampler_reset :: proc(resampler: ^Audio_Resampler) {
	resampler.next_num = u64(AUDIO_RESAMPLER_HALF) * resampler.output_hz
	resampler.base_index = 0
	resampler.head = 0
	resampler.count = AUDIO_RESAMPLER_HALF
	for index in 0 ..< AUDIO_RESAMPLER_HALF {resampler.history[index] = {}}
}

audio_resampler_input_space :: proc(resampler: ^Audio_Resampler) -> int {
	return AUDIO_RESAMPLER_CAPACITY - resampler.count
}

audio_resampler_push :: proc(resampler: ^Audio_Resampler, frame: Audio_Frame_Wide) -> bool {
	if resampler.count >= AUDIO_RESAMPLER_CAPACITY {return false}
	index := (resampler.head + resampler.count) % AUDIO_RESAMPLER_CAPACITY
	resampler.history[index] = frame
	resampler.count += 1
	return true
}

@(private = "file")
audio_resampler_frame :: proc(
	resampler: ^Audio_Resampler,
	absolute_index: u64,
) -> Audio_Frame_Wide {
	offset := int(absolute_index - resampler.base_index)
	return resampler.history[(resampler.head + offset) % AUDIO_RESAMPLER_CAPACITY]
}

@(private = "file")
audio_resampler_trim :: proc(resampler: ^Audio_Resampler) {
	base := resampler.next_num / resampler.output_hz
	keep_from: u64
	if base >= AUDIO_RESAMPLER_HALF - 1 {keep_from = base - (AUDIO_RESAMPLER_HALF - 1)}
	if keep_from <= resampler.base_index {return}
	drop := min(int(keep_from - resampler.base_index), resampler.count)
	resampler.head = (resampler.head + drop) % AUDIO_RESAMPLER_CAPACITY
	resampler.base_index += u64(drop)
	resampler.count -= drop
}

audio_resampler_pull :: proc(resampler: ^Audio_Resampler) -> (Audio_Frame_Wide, bool) {
	if resampler.output_hz == 0 {return {}, false}
	base := resampler.next_num / resampler.output_hz
	right := base + AUDIO_RESAMPLER_HALF
	available_end := resampler.base_index + u64(resampler.count)
	if right >= available_end {return {}, false}
	fraction := resampler.next_num % resampler.output_hz
	phase := int(fraction * AUDIO_RESAMPLER_PHASES / resampler.output_hz)
	left, right_sum: f64
	for tap in 0 ..< AUDIO_RESAMPLER_TAPS {
		absolute_index := base + 1 + u64(tap) - AUDIO_RESAMPLER_HALF
		frame := audio_resampler_frame(resampler, absolute_index)
		weight := f64(resampler.table[phase * AUDIO_RESAMPLER_TAPS + tap])
		left += f64(frame.left) * weight
		right_sum += f64(frame.right) * weight
	}
	resampler.next_num += resampler.input_hz
	audio_resampler_trim(resampler)
	return Audio_Frame_Wide {
			left = i32(clamp(math.round(left), f64(-2_147_483_648), f64(2_147_483_647))),
			right = i32(clamp(math.round(right_sum), f64(-2_147_483_648), f64(2_147_483_647))),
		},
		true
}

audio_resampler_process :: proc(
	resampler: ^Audio_Resampler,
	input: []Audio_Frame_Wide,
	output: []Audio_Frame_Wide,
) -> (
	consumed, produced: int,
) {
	for produced < len(output) {
		frame, ok := audio_resampler_pull(resampler)
		if !ok {break}
		output[produced] = frame
		produced += 1
	}
	for consumed < len(input) && produced < len(output) {
		if !audio_resampler_push(resampler, input[consumed]) {break}
		consumed += 1
		for produced < len(output) {
			frame, ok := audio_resampler_pull(resampler)
			if !ok {break}
			output[produced] = frame
			produced += 1
		}
	}
	return
}
