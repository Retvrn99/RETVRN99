// SPDX-License-Identifier: GPL-3.0-only
package audio

// Guest-time speaker integration adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

AUDIO_SPEAKER_AMPLITUDE :: i32(8_000)
AUDIO_RENDER_BATCH :: int(AUDIO_OUTPUT_HZ / 1_000)
AUDIO_RESAMPLE_BATCH :: 512
AUDIO_CDDA_QUEUE_FRAMES :: 16_384
AUDIO_GAIN_UNITY :: u32(65_536)

Audio_Mixer :: struct {
	now_ticks:       u64,
	output_phase:    u64,
	speaker_enabled: bool,
	speaker_level:   i32,
	speaker_area:    i128,
	speaker_ticks:   u64,
	speaker_gain:    u32,
	cdda_gain:       u32,
	cdda_resampler:  Audio_Resampler,
	cdda_frames:     [AUDIO_CDDA_QUEUE_FRAMES]Audio_Frame_Wide,
	cdda_head:       int,
	cdda_count:      int,
	mix_batch:       [AUDIO_RENDER_BATCH]Audio_Frame,
	mix_batch_count: int,
	output:          Audio_Output,
	blocks_rendered: u64,
}

audio_mixer_init :: proc(mixer: ^Audio_Mixer) -> bool {
	mixer^ = {
		speaker_gain = AUDIO_GAIN_UNITY,
		cdda_gain    = AUDIO_GAIN_UNITY,
	}
	audio_output_init(&mixer.output)
	return audio_resampler_init(&mixer.cdda_resampler, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ)
}

audio_mixer_output :: proc(mixer: ^Audio_Mixer) -> ^Audio_Output {
	return &mixer.output
}

audio_mixer_set_gains :: proc(mixer: ^Audio_Mixer, speaker, cdda: u32) {
	mixer.speaker_gain = min(speaker, AUDIO_GAIN_UNITY)
	mixer.cdda_gain = min(cdda, AUDIO_GAIN_UNITY)
}

@(private = "file")
audio_mixer_cdda_push :: proc(mixer: ^Audio_Mixer, frame: Audio_Frame_Wide) -> bool {
	if mixer.cdda_count >= AUDIO_CDDA_QUEUE_FRAMES {return false}
	index := (mixer.cdda_head + mixer.cdda_count) % AUDIO_CDDA_QUEUE_FRAMES
	mixer.cdda_frames[index] = frame
	mixer.cdda_count += 1
	return true
}

@(private = "file")
audio_mixer_cdda_pop :: proc(mixer: ^Audio_Mixer) -> Audio_Frame_Wide {
	if mixer.cdda_count == 0 {return {}}
	frame := mixer.cdda_frames[mixer.cdda_head]
	mixer.cdda_head = (mixer.cdda_head + 1) % AUDIO_CDDA_QUEUE_FRAMES
	mixer.cdda_count -= 1
	return frame
}

@(private = "file")
audio_mixer_drain_resampler :: proc(mixer: ^Audio_Mixer) -> int {
	produced := 0
	for mixer.cdda_count < AUDIO_CDDA_QUEUE_FRAMES {
		frame, ok := audio_resampler_pull(&mixer.cdda_resampler)
		if !ok {break}
		_ = audio_mixer_cdda_push(mixer, frame)
		produced += 1
	}
	return produced
}

audio_mixer_queue_cdda :: proc(mixer: ^Audio_Mixer, frames: []Audio_Frame) -> int {
	consumed := 0
	_ = audio_mixer_drain_resampler(mixer)
	wide_input: [AUDIO_RESAMPLE_BATCH]Audio_Frame_Wide
	wide_output: [AUDIO_RESAMPLE_BATCH]Audio_Frame_Wide
	for consumed < len(frames) && mixer.cdda_count < AUDIO_CDDA_QUEUE_FRAMES {
		chunk := min(len(frames) - consumed, AUDIO_RESAMPLE_BATCH)
		for index in 0 ..< chunk {
			wide_input[index] = {
				left  = i32(frames[consumed + index].left),
				right = i32(frames[consumed + index].right),
			}
		}
		output_space := min(AUDIO_CDDA_QUEUE_FRAMES - mixer.cdda_count, AUDIO_RESAMPLE_BATCH)
		accepted, produced := audio_resampler_process(
			&mixer.cdda_resampler,
			wide_input[:chunk],
			wide_output[:output_space],
		)
		for index in 0 ..< produced {_ = audio_mixer_cdda_push(mixer, wide_output[index])}
		consumed += accepted
		if accepted == 0 && produced == 0 {break}
	}
	_ = audio_mixer_drain_resampler(mixer)
	return consumed
}

audio_mixer_reset_cdda :: proc(mixer: ^Audio_Mixer) {
	audio_resampler_reset(&mixer.cdda_resampler)
	mixer.cdda_head = 0
	mixer.cdda_count = 0
}

audio_mixer_cdda_queued :: proc(mixer: ^Audio_Mixer) -> int {
	return mixer.cdda_count
}

@(private = "file")
audio_mixer_flush_batch :: proc(mixer: ^Audio_Mixer) {
	if mixer.mix_batch_count == 0 {return}
	audio_output_queue(&mixer.output, mixer.mix_batch[:mixer.mix_batch_count])
	mixer.blocks_rendered += 1
	mixer.mix_batch_count = 0
}

audio_mixer_publish_pending :: proc(mixer: ^Audio_Mixer) {
	audio_mixer_flush_batch(mixer)
}

audio_mixer_blocks_rendered :: proc(mixer: ^Audio_Mixer) -> u64 {
	return mixer != nil ? mixer.blocks_rendered : 0
}

@(private = "file")
audio_mixer_average_speaker :: proc(mixer: ^Audio_Mixer) -> i64 {
	if mixer.speaker_ticks == 0 {return 0}
	denominator := i128(mixer.speaker_ticks)
	if mixer.speaker_area >= 0 {
		return i64((mixer.speaker_area + denominator / 2) / denominator)
	}
	return i64((mixer.speaker_area - denominator / 2) / denominator)
}

@(private = "file")
audio_mixer_emit :: proc(mixer: ^Audio_Mixer) {
	speaker := audio_mixer_average_speaker(mixer) * i64(mixer.speaker_gain) / i64(AUDIO_GAIN_UNITY)
	cdda := audio_mixer_cdda_pop(mixer)
	left := i64(cdda.left) * i64(mixer.cdda_gain) / i64(AUDIO_GAIN_UNITY) + speaker
	right := i64(cdda.right) * i64(mixer.cdda_gain) / i64(AUDIO_GAIN_UNITY) + speaker
	mixer.mix_batch[mixer.mix_batch_count] = {
		left  = audio_clamp_i16(left),
		right = audio_clamp_i16(right),
	}
	mixer.mix_batch_count += 1
	if mixer.mix_batch_count == AUDIO_RENDER_BATCH {audio_mixer_flush_batch(mixer)}
	mixer.speaker_area = 0
	mixer.speaker_ticks = 0
}

audio_mixer_advance_to :: proc(mixer: ^Audio_Mixer, target_tick: u64) -> u64 {
	if target_tick <= mixer.now_ticks {return 0}
	produced: u64
	for mixer.now_ticks < target_tick {
		remaining_phase := AUDIO_MASTER_CLOCK_HZ - mixer.output_phase
		until_frame := (remaining_phase + AUDIO_OUTPUT_HZ - 1) / AUDIO_OUTPUT_HZ
		step := min(target_tick - mixer.now_ticks, max(until_frame, u64(1)))
		mixer.speaker_area += i128(mixer.speaker_level) * i128(step)
		mixer.speaker_ticks += step
		phase := u128(mixer.output_phase) + u128(step) * u128(AUDIO_OUTPUT_HZ)
		mixer.output_phase = u64(phase % u128(AUDIO_MASTER_CLOCK_HZ))
		mixer.now_ticks += step
		if phase >= u128(AUDIO_MASTER_CLOCK_HZ) {
			audio_mixer_emit(mixer)
			produced += 1
		}
	}
	return produced
}

audio_mixer_set_speaker_state :: proc(
	mixer: ^Audio_Mixer,
	at_tick: u64,
	enabled, pit_high: bool,
) -> bool {
	if at_tick < mixer.now_ticks {return false}
	_ = audio_mixer_advance_to(mixer, at_tick)
	mixer.speaker_enabled = enabled
	mixer.speaker_level =
		!enabled ? 0 : (pit_high ? AUDIO_SPEAKER_AMPLITUDE : -AUDIO_SPEAKER_AMPLITUDE)
	return true
}

audio_mixer_active :: proc(mixer: ^Audio_Mixer) -> bool {
	return mixer != nil &&
	       (mixer.speaker_enabled || mixer.cdda_count > 0 || mixer.mix_batch_count > 0)
}

audio_mixer_next_deadline_tick :: proc(mixer: ^Audio_Mixer) -> (deadline: u64, pending: bool) {
	if !audio_mixer_active(mixer) {return 0, false}
	frames_needed := u64(AUDIO_RENDER_BATCH - mixer.mix_batch_count)
	phase_needed := u128(frames_needed) * u128(AUDIO_MASTER_CLOCK_HZ) - u128(mixer.output_phase)
	until_publish := u64((phase_needed + u128(AUDIO_OUTPUT_HZ) - 1) / u128(AUDIO_OUTPUT_HZ))
	until_publish = max(until_publish, u64(1))
	if ~u64(0) - mixer.now_ticks < until_publish {return ~u64(0), true}
	return mixer.now_ticks + until_publish, true
}
