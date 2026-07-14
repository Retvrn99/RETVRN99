// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

@(test)
test_audio_output_prefill_and_ramps :: proc(t: ^testing.T) {
	output: Audio_Output
	audio_output_init(&output)
	testing.expect_value(t, audio_output_depth(&output), AUDIO_TARGET_FRAMES)

	frames: [AUDIO_RAMP_FRAMES]Audio_Frame
	for &frame in frames {frame = {
			left  = 6_400,
			right = -6_400,
		}}
	audio_output_queue(&output, frames[:])

	consumer: Audio_Consumer
	audio_consumer_init(&consumer, &output)
	prefill: [AUDIO_TARGET_FRAMES]Audio_Frame
	audio_consumer_read(&consumer, prefill[:])
	for frame in prefill {
		if !testing.expect_value(t, frame, Audio_Frame{}) {break}
	}

	ramp_up: [AUDIO_RAMP_FRAMES]Audio_Frame
	audio_consumer_read(&consumer, ramp_up[:])
	testing.expect_value(t, ramp_up[0], Audio_Frame{left = 100, right = -100})
	testing.expect_value(t, ramp_up[AUDIO_RAMP_FRAMES - 1], frames[0])

	ramp_down: [AUDIO_RAMP_FRAMES]Audio_Frame
	audio_consumer_read(&consumer, ramp_down[:])
	testing.expect_value(t, ramp_down[0], Audio_Frame{left = 6_300, right = -6_300})
	testing.expect_value(t, ramp_down[AUDIO_RAMP_FRAMES - 1], Audio_Frame{})

	metrics := audio_output_metrics(&output)
	testing.expect_value(t, metrics.frames_produced, u64(AUDIO_RAMP_FRAMES))
	testing.expect_value(
		t,
		metrics.frames_consumed,
		u64(AUDIO_TARGET_FRAMES + AUDIO_RAMP_FRAMES * 2),
	)
	testing.expect_value(t, metrics.underruns, u64(AUDIO_RAMP_FRAMES))
	testing.expect_value(t, metrics.queue_min_depth, u64(0))
}

@(test)
test_audio_output_overrun_keeps_latest_target :: proc(t: ^testing.T) {
	output: Audio_Output
	audio_output_init(&output)
	batch: [AUDIO_HIGH_FRAMES]Audio_Frame
	for recovery in 1 ..= 4 {
		value := i16(recovery * 4_000)
		for &frame in batch {frame = {
				left  = value,
				right = -value,
			}}
		audio_output_queue(&output, batch[:])
		testing.expect_value(t, audio_output_depth(&output), AUDIO_TARGET_FRAMES)
	}

	consumer: Audio_Consumer
	audio_consumer_init(&consumer, &output)
	boundary: [AUDIO_RAMP_FRAMES + 1]Audio_Frame
	audio_consumer_read(&consumer, boundary[:])
	for frame in boundary[:AUDIO_RAMP_FRAMES] {
		if !testing.expect_value(t, frame, Audio_Frame{}) {break}
	}
	testing.expect_value(t, boundary[AUDIO_RAMP_FRAMES], Audio_Frame{left = 250, right = -250})

	metrics := audio_output_metrics(&output)
	testing.expect_value(t, metrics.frames_produced, u64(AUDIO_HIGH_FRAMES * 4))
	testing.expect_value(t, metrics.overruns, u64(4))
	testing.expect_value(t, metrics.queue_max_depth, u64(AUDIO_TARGET_FRAMES))
}

@(test)
test_audio_output_callback_metrics :: proc(t: ^testing.T) {
	output: Audio_Output
	audio_output_init(&output)
	audio_output_record_callback_lateness(&output, 1_000_000)
	audio_output_record_callback_lateness(&output, 1_500_999)
	audio_output_record_callback_lateness(&output, 3_250_001)
	metrics := audio_output_metrics(&output)
	testing.expect_value(t, metrics.late_callbacks, u64(2))
	testing.expect_value(t, metrics.callback_lateness_us, u64(4_750))
	testing.expect_value(t, metrics.max_callback_lateness_us, u64(3_250))
}
