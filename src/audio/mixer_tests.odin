// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

AUDIO_TEST_FIVE_MS_TICKS :: AUDIO_MASTER_CLOCK_HZ * 5 / 1_000

audio_test_new_mixer :: proc(t: ^testing.T) -> ^Audio_Mixer {
	mixer := new(Audio_Mixer)
	if !testing.expect(t, audio_mixer_init(mixer)) {
		free(mixer)
		return nil
	}
	return mixer
}

@(test)
test_audio_mixer_speaker_transition_area :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES

	testing.expect(t, audio_mixer_set_speaker_state(mixer, 0, true, true))
	three_quarters := AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ * 3 / 4
	testing.expect(t, audio_mixer_set_speaker_state(mixer, three_quarters, true, false))
	testing.expect_value(
		t,
		audio_mixer_advance_to(mixer, AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ),
		u64(1),
	)
	deadline, pending := audio_mixer_next_deadline_tick(mixer)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, AUDIO_MASTER_CLOCK_HZ / 1_000)
	audio_mixer_publish_pending(mixer)
	frame: [1]Audio_Frame
	audio_consumer_read(&consumer, frame[:])
	testing.expect_value(t, frame[0], Audio_Frame{left = 620, right = 620})
	testing.expect(t, !audio_mixer_set_speaker_state(mixer, 0, false, false))
	audio_mixer_record_speaker_dropped(mixer, 3)
	telemetry := audio_mixer_telemetry(mixer)
	testing.expect_value(t, telemetry.speaker_transitions_applied, u64(2))
	testing.expect_value(t, telemetry.speaker_transitions_late, u64(1))
	testing.expect_value(t, telemetry.speaker_transitions_dropped, u64(3))
}

@(test)
test_audio_mixer_speaker_filter_rejects_dc_and_settles :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES
	testing.expect(t, audio_mixer_set_speaker_state(mixer, 0, true, true))
	frames: [AUDIO_RENDER_BATCH]Audio_Frame
	first, last: Audio_Frame
	for millisecond in 1 ..= 50 {
		_ = audio_mixer_advance_to(mixer, u64(millisecond) * AUDIO_MASTER_CLOCK_HZ / 1_000)
		audio_consumer_read(&consumer, frames[:])
		if millisecond == 1 {first = frames[0]}
		last = frames[len(frames) - 1]
	}
	testing.expect(t, abs(i32(first.left)) > 1_000)
	testing.expect(t, abs(i32(last.left)) <= 2)
	testing.expect(
		t,
		audio_mixer_set_speaker_state(mixer, 50 * AUDIO_MASTER_CLOCK_HZ / 1_000, false, true),
	)
	for millisecond in 51 ..= 100 {
		_ = audio_mixer_advance_to(mixer, u64(millisecond) * AUDIO_MASTER_CLOCK_HZ / 1_000)
		audio_consumer_read(&consumer, frames[:])
		last = frames[len(frames) - 1]
	}
	testing.expect_value(t, last, Audio_Frame{})
	_, pending := audio_mixer_next_deadline_tick(mixer)
	testing.expect(t, !pending)
}

@(test)
test_audio_mixer_silence_has_no_deadline :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	_, pending := audio_mixer_next_deadline_tick(mixer)
	testing.expect(t, !pending)
}

@(test)
test_audio_mixer_integrates_sb16_and_opl3_stereo_sources :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES
	frame_ticks := AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ
	testing.expect(t, audio_mixer_set_sb16_frame(mixer, 0, {1_000, -1_000}))
	testing.expect(t, audio_mixer_set_opl3_frame(mixer, 0, {250, 500}))
	testing.expect(t, audio_mixer_set_native_pcm_frame(mixer, 0, {750, -250}))
	audio_mixer_set_source_active(mixer, .SB16, true)
	audio_mixer_set_source_active(mixer, .OPL3, true)
	audio_mixer_set_source_active(mixer, .Native_PCM, true)
	_ = audio_mixer_advance_to(mixer, frame_ticks)
	audio_mixer_publish_pending(mixer)
	frame: [1]Audio_Frame
	audio_consumer_read(&consumer, frame[:])
	testing.expect_value(t, frame[0], Audio_Frame{2_000, -750})
	telemetry := audio_mixer_telemetry(mixer)
	testing.expect_value(
		t,
		telemetry.sources[int(Audio_Mixer_Source.SB16)].frames_produced,
		u64(1),
	)
	testing.expect_value(
		t,
		telemetry.sources[int(Audio_Mixer_Source.OPL3)].frames_produced,
		u64(1),
	)
	testing.expect_value(
		t,
		telemetry.sources[int(Audio_Mixer_Source.Native_PCM)].frames_produced,
		u64(1),
	)
	testing.expect(t, telemetry.pcm_fnv1a64 != AUDIO_PCM_FNV_OFFSET)
}

@(test)
test_audio_mixer_telemetry_counts_clipping_and_source_nonzero_frames :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES
	testing.expect(t, audio_mixer_set_sb16_frame(mixer, 0, {30_000, -30_000}))
	testing.expect(t, audio_mixer_set_opl3_frame(mixer, 0, {30_000, -30_000}))
	testing.expect(t, audio_mixer_set_native_pcm_frame(mixer, 0, {30_000, -30_000}))
	audio_mixer_set_source_active(mixer, .SB16, true)
	audio_mixer_set_source_active(mixer, .OPL3, true)
	audio_mixer_set_source_active(mixer, .Native_PCM, true)
	_ = audio_mixer_advance_to(mixer, AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ)
	audio_mixer_publish_pending(mixer)
	frame: [1]Audio_Frame
	audio_consumer_read(&consumer, frame[:])
	testing.expect_value(t, frame[0], Audio_Frame{left = 32_767, right = -32_768})
	telemetry := audio_mixer_telemetry(mixer)
	testing.expect_value(t, telemetry.final_clipping_frames, u64(1))
	sources := [3]Audio_Mixer_Source {
		Audio_Mixer_Source.SB16,
		Audio_Mixer_Source.OPL3,
		Audio_Mixer_Source.Native_PCM,
	}
	for source in sources {
		metrics := telemetry.sources[int(source)]
		testing.expect_value(t, metrics.frames_produced, u64(1))
		testing.expect_value(t, metrics.nonzero_frames, u64(1))
	}
}

@(test)
test_audio_mixer_preserves_independent_speaker_and_cdda_gains :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES
	audio_mixer_set_gain_pairs(
		mixer,
		AUDIO_GAIN_UNITY,
		AUDIO_GAIN_UNITY / 2,
		AUDIO_GAIN_UNITY / 2,
		AUDIO_GAIN_UNITY / 4,
	)
	_ = audio_mixer_cdda_push(mixer, {left = 1_000, right = 1_000})
	testing.expect(t, audio_mixer_set_speaker_state(mixer, 0, true, true))
	_ = audio_mixer_advance_to(mixer, AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ)
	audio_mixer_publish_pending(mixer)
	frame: [1]Audio_Frame
	audio_consumer_read(&consumer, frame[:])
	testing.expect_value(t, frame[0], Audio_Frame{left = 1_740, right = 870})
	telemetry := audio_mixer_telemetry(mixer)
	testing.expect_value(
		t,
		telemetry.sources[int(Audio_Mixer_Source.PC_Speaker)],
		Audio_Mixer_Source_Telemetry{frames_produced = 1, nonzero_frames = 1},
	)
	testing.expect_value(
		t,
		telemetry.sources[int(Audio_Mixer_Source.CDDA)],
		Audio_Mixer_Source_Telemetry{frames_produced = 1, nonzero_frames = 1},
	)
}

audio_test_fill_cdda :: proc(frames: []Audio_Frame, content_frames: int) {
	for index in 0 ..< min(content_frames, len(frames)) {
		frames[index] = {
			left  = i16((index * 97) % 20_001 - 10_000),
			right = i16((index * 193) % 24_001 - 12_000),
		}
	}
}

audio_test_advance_partitioned :: proc(mixer: ^Audio_Mixer) {
	_ = audio_mixer_advance_to(mixer, 1_000_003)
	_ = audio_mixer_advance_to(mixer, 7_777_777)
	_ = audio_mixer_advance_to(mixer, 19_000_011)
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS, true, false)
	_ = audio_mixer_advance_to(mixer, 45_500_009)
	_ = audio_mixer_advance_to(mixer, 62_000_001)
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS * 2, true, true)
	_ = audio_mixer_advance_to(mixer, 78_000_017)
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS * 3, true, false)
	_ = audio_mixer_advance_to(mixer, AUDIO_TEST_FIVE_MS_TICKS * 4)
}

audio_test_advance_coarse :: proc(mixer: ^Audio_Mixer) {
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS, true, false)
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS * 2, true, true)
	_ = audio_mixer_set_speaker_state(mixer, AUDIO_TEST_FIVE_MS_TICKS * 3, true, false)
	_ = audio_mixer_advance_to(mixer, AUDIO_TEST_FIVE_MS_TICKS * 4)
}

@(test)
test_audio_mixer_partition_invariance :: proc(t: ^testing.T) {
	coarse := audio_test_new_mixer(t)
	if coarse == nil {return}
	defer free(coarse)
	partitioned := audio_test_new_mixer(t)
	if partitioned == nil {return}
	defer free(partitioned)

	source: [1_088]Audio_Frame
	audio_test_fill_cdda(source[:], 1_024)
	testing.expect_value(t, audio_mixer_queue_cdda(coarse, source[:]), len(source))
	testing.expect_value(t, audio_mixer_queue_cdda(partitioned, source[:]), len(source))
	coarse_consumer, partitioned_consumer: Audio_Consumer
	audio_consumer_init(&coarse_consumer, audio_mixer_output(coarse))
	audio_consumer_init(&partitioned_consumer, audio_mixer_output(partitioned))
	audio_consumer_discard_queued(&coarse_consumer)
	audio_consumer_discard_queued(&partitioned_consumer)
	coarse_consumer.gain = AUDIO_RAMP_FRAMES
	partitioned_consumer.gain = AUDIO_RAMP_FRAMES
	testing.expect(t, audio_mixer_set_speaker_state(coarse, 0, true, true))
	testing.expect(t, audio_mixer_set_speaker_state(partitioned, 0, true, true))
	audio_test_advance_coarse(coarse)
	audio_test_advance_partitioned(partitioned)

	coarse_metrics := audio_output_metrics(audio_mixer_output(coarse))
	partitioned_metrics := audio_output_metrics(audio_mixer_output(partitioned))
	testing.expect_value(t, coarse_metrics.frames_produced, u64(960))
	testing.expect_value(t, partitioned_metrics.frames_produced, coarse_metrics.frames_produced)
	coarse_frames: [960]Audio_Frame
	partitioned_frames: [960]Audio_Frame
	audio_consumer_read(&coarse_consumer, coarse_frames[:])
	audio_consumer_read(&partitioned_consumer, partitioned_frames[:])
	for index in 0 ..< len(coarse_frames) {
		if !testing.expect_value(t, partitioned_frames[index], coarse_frames[index]) {break}
	}
	testing.expect_value(t, audio_mixer_telemetry(partitioned), audio_mixer_telemetry(coarse))
}

@(test)
test_audio_mixer_partition_invariance_across_recovery :: proc(t: ^testing.T) {
	coarse := audio_test_new_mixer(t)
	if coarse == nil {return}
	defer free(coarse)
	partitioned := audio_test_new_mixer(t)
	if partitioned == nil {return}
	defer free(partitioned)
	coarse_consumer, partitioned_consumer: Audio_Consumer
	audio_consumer_init(&coarse_consumer, audio_mixer_output(coarse))
	audio_consumer_init(&partitioned_consumer, audio_mixer_output(partitioned))
	audio_consumer_discard_queued(&coarse_consumer)
	audio_consumer_discard_queued(&partitioned_consumer)
	coarse_consumer.gain = AUDIO_RAMP_FRAMES
	partitioned_consumer.gain = AUDIO_RAMP_FRAMES
	testing.expect(t, audio_mixer_set_speaker_state(coarse, 0, true, true))
	testing.expect(t, audio_mixer_set_speaker_state(partitioned, 0, true, true))
	target := AUDIO_MASTER_CLOCK_HZ / 10
	_ = audio_mixer_advance_to(coarse, target)
	steps := [5]u64{1_000_003, 7_777_779, 13_000_019, 333_331, 5_500_009}
	cursor: u64
	step_index := 0
	for cursor < target {
		cursor = min(cursor + steps[step_index % len(steps)], target)
		_ = audio_mixer_advance_to(partitioned, cursor)
		step_index += 1
	}

	coarse_metrics := audio_output_metrics(audio_mixer_output(coarse))
	partitioned_metrics := audio_output_metrics(audio_mixer_output(partitioned))
	testing.expect_value(t, coarse_metrics, partitioned_metrics)
	testing.expect_value(t, coarse_metrics.frames_produced, u64(4_800))
	testing.expect_value(t, coarse_metrics.overruns, u64(2))
	depth := audio_output_depth(audio_mixer_output(coarse))
	testing.expect_value(t, audio_output_depth(audio_mixer_output(partitioned)), depth)
	coarse_frames := make([]Audio_Frame, depth)
	defer delete(coarse_frames)
	partitioned_frames := make([]Audio_Frame, depth)
	defer delete(partitioned_frames)
	audio_consumer_read(&coarse_consumer, coarse_frames)
	audio_consumer_read(&partitioned_consumer, partitioned_frames)
	for index in 0 ..< depth {
		if !testing.expect_value(t, partitioned_frames[index], coarse_frames[index]) {break}
	}
}

audio_test_offline_workload :: proc(t: ^testing.T) -> Audio_Offline_Snapshot {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return {}}
	defer free(mixer)
	source: [4_474]Audio_Frame
	audio_test_fill_cdda(source[:], 4_410)
	testing.expect_value(t, audio_mixer_queue_cdda(mixer, source[:]), len(source))
	offline: Audio_Offline
	audio_offline_init(&offline, audio_mixer_output(mixer), true)
	testing.expect(t, audio_mixer_set_speaker_state(mixer, 0, true, true))
	for period in 1 ..= 20 {
		tick := u64(period) * AUDIO_TEST_FIVE_MS_TICKS
		high := period % 2 == 0
		testing.expect(t, audio_mixer_set_speaker_state(mixer, tick, true, high))
		if high {audio_offline_consume(&offline, 480)}
	}
	return audio_offline_snapshot(&offline)
}

@(test)
test_audio_offline_deterministic_crc :: proc(t: ^testing.T) {
	first := audio_test_offline_workload(t)
	second := audio_test_offline_workload(t)
	testing.expect_value(t, first, second)
	testing.expect_value(t, first.frames, u64(4_800))
	testing.expect(t, first.non_silent_frames > 4_700)
	testing.expect(t, first.peak > 8_000)
	testing.expect_value(t, first.crc32, u32(0x5240_8b96))
}

@(test)
test_audio_mixer_native_stop_ramps_to_zero_in_64_frames :: proc(t: ^testing.T) {
	mixer := audio_test_new_mixer(t)
	if mixer == nil {return}
	defer free(mixer)
	consumer: Audio_Consumer
	audio_consumer_init(&consumer, audio_mixer_output(mixer))
	audio_consumer_discard_queued(&consumer)
	consumer.gain = AUDIO_RAMP_FRAMES
	frame_ticks := AUDIO_MASTER_CLOCK_HZ / AUDIO_OUTPUT_HZ
	audio_mixer_set_source_active(mixer, .Native_PCM, true)
	testing.expect(t, audio_mixer_set_native_pcm_frame(mixer, 0, {left = 6_400, right = -6_400}))
	_ = audio_mixer_advance_to(mixer, frame_ticks)
	audio_mixer_publish_pending(mixer)
	discard: [1]Audio_Frame
	audio_consumer_read(&consumer, discard[:])

	testing.expect(t, audio_mixer_release_native_pcm(mixer, frame_ticks))
	_ = audio_mixer_advance_to(mixer, frame_ticks * 66)
	audio_mixer_publish_pending(mixer)
	frames: [65]Audio_Frame
	audio_consumer_read(&consumer, frames[:])
	testing.expect_value(t, frames[0], Audio_Frame{left = 6_400, right = -6_400})
	testing.expect_value(t, frames[63], Audio_Frame{left = 100, right = -100})
	testing.expect_value(t, frames[64], Audio_Frame{})
	testing.expect_value(t, mixer.native_release_frames, u16(0))
	testing.expect_value(t, mixer.native_pcm_frame, Audio_Frame{})
}
