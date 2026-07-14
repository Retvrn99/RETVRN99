// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

audio_test_resampler_drain :: proc(
	resampler: ^Audio_Resampler,
	output: ^[dynamic]Audio_Frame_Wide,
) {
	for {
		frame, ok := audio_resampler_pull(resampler)
		if !ok {break}
		append(output, frame)
	}
}

audio_test_resampler_feed :: proc(
	resampler: ^Audio_Resampler,
	input: []Audio_Frame_Wide,
	chunk_size: int,
	output: ^[dynamic]Audio_Frame_Wide,
) {
	cursor := 0
	for cursor < len(input) {
		end := min(cursor + max(chunk_size, 1), len(input))
		for frame in input[cursor:end] {
			if !audio_resampler_push(resampler, frame) {return}
		}
		cursor = end
		audio_test_resampler_drain(resampler, output)
	}
	audio_test_resampler_drain(resampler, output)
}

@(test)
test_audio_resampler_stream_partition_invariance :: proc(t: ^testing.T) {
	input := make([]Audio_Frame_Wide, 2_064)
	defer delete(input)
	for index in 0 ..< 2_000 {
		input[index] = {
			left  = i32((index * 97) % 20_001 - 10_000),
			right = i32((index * 193) % 24_001 - 12_000),
		}
	}

	whole := new(Audio_Resampler)
	defer free(whole)
	partitioned := new(Audio_Resampler)
	defer free(partitioned)
	testing.expect(t, audio_resampler_init(whole, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ))
	testing.expect(t, audio_resampler_init(partitioned, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ))
	whole_output := make([dynamic]Audio_Frame_Wide, 0, 2_300)
	defer delete(whole_output)
	partitioned_output := make([dynamic]Audio_Frame_Wide, 0, 2_300)
	defer delete(partitioned_output)
	audio_test_resampler_feed(whole, input, len(input), &whole_output)
	audio_test_resampler_feed(partitioned, input, 17, &partitioned_output)

	testing.expect_value(t, len(whole_output), 2_212)
	if !testing.expect_value(t, len(partitioned_output), len(whole_output)) {return}
	for index in 0 ..< len(whole_output) {
		if !testing.expect_value(t, partitioned_output[index], whole_output[index]) {break}
	}
}

@(test)
test_audio_resampler_preserves_dc :: proc(t: ^testing.T) {
	input: [664]Audio_Frame_Wide
	for index in 0 ..< 600 {input[index] = {
			left  = 10_000,
			right = -7_000,
		}}
	resampler := new(Audio_Resampler)
	defer free(resampler)
	testing.expect(t, audio_resampler_init(resampler, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ))
	output := make([dynamic]Audio_Frame_Wide, 0, 800)
	defer delete(output)
	audio_test_resampler_feed(resampler, input[:], 23, &output)
	testing.expect(t, len(output) > 600)
	for frame in output[100:550] {
		if !testing.expect(t, abs(frame.left - 10_000) <= 1) {break}
		if !testing.expect(t, abs(frame.right + 7_000) <= 1) {break}
	}
}

@(test)
test_audio_resampler_process_reports_progress :: proc(t: ^testing.T) {
	resampler := new(Audio_Resampler)
	defer free(resampler)
	testing.expect(t, audio_resampler_init(resampler, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ))
	input: [320]Audio_Frame_Wide
	for index in 0 ..< 256 {input[index] = {
			left  = 1_000,
			right = -1_000,
		}}
	output: [512]Audio_Frame_Wide
	consumed, produced := audio_resampler_process(resampler, input[:], output[:])
	testing.expect_value(t, consumed, len(input))
	testing.expect(t, produced > 256)
	testing.expect(t, produced < len(output))
}
