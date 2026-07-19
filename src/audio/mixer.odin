// SPDX-License-Identifier: GPL-3.0-only
package audio

// Guest-time speaker integration adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

AUDIO_SPEAKER_AMPLITUDE :: i32(8_000)
AUDIO_RENDER_BATCH :: int(AUDIO_OUTPUT_HZ / 1_000)
AUDIO_RESAMPLE_BATCH :: 512
AUDIO_CDDA_QUEUE_FRAMES :: 16_384
AUDIO_GAIN_UNITY :: u32(65_536)
AUDIO_SPEAKER_DC_SHIFT :: 15
// exp(-2*pi*20/48000), Q15: a 20 Hz DC-blocking pole.
AUDIO_SPEAKER_DC_POLE_Q15 :: i64(32_682)
AUDIO_SPEAKER_BIQUAD_SHIFT :: 30
// Bilinear-transform, Q30 Butterworth low-pass at 8 kHz / 48 kHz.
AUDIO_SPEAKER_LP_B0_Q30 :: i64(166_484_771)
AUDIO_SPEAKER_LP_B1_Q30 :: i64(332_969_542)
AUDIO_SPEAKER_LP_B2_Q30 :: i64(166_484_771)
AUDIO_SPEAKER_LP_A1_Q30 :: i64(-665_939_085)
AUDIO_SPEAKER_LP_A2_Q30 :: i64(258_136_345)
AUDIO_SPEAKER_FILTER_SETTLE :: i64(1)
AUDIO_PCM_FNV_OFFSET :: u64(14_695_981_039_346_656_037)
AUDIO_PCM_FNV_PRIME :: u64(1_099_511_628_211)

Audio_Mixer_Source :: enum u8 {
	PC_Speaker,
	SB16,
	OPL3,
	Native_PCM,
	CDDA,
	Count,
}

Audio_Mixer_Source_Telemetry :: struct {
	frames_produced: u64,
	nonzero_frames:  u64,
}

Audio_Mixer_Telemetry :: struct {
	sources:                     [int(Audio_Mixer_Source.Count)]Audio_Mixer_Source_Telemetry,
	final_clipping_frames:       u64,
	pcm_fnv1a64:                 u64,
	speaker_transitions_applied: u64,
	speaker_transitions_late:    u64,
	speaker_transitions_dropped: u64,
}

Audio_Mixer :: struct {
	now_ticks:              u64,
	output_phase:           u64,
	speaker_enabled:        bool,
	speaker_level:          i32,
	speaker_area:           i128,
	speaker_ticks:          u64,
	speaker_previous_input: i64,
	speaker_highpass:       i64,
	speaker_lowpass_input1: i64,
	speaker_lowpass_input2: i64,
	speaker_lowpass_output1: i64,
	speaker_lowpass_output2: i64,
	sb16_left_area:         i128,
	sb16_right_area:        i128,
	opl3_left_area:         i128,
	opl3_right_area:        i128,
	native_pcm_left_area:   i128,
	native_pcm_right_area:  i128,
	sb16_frame:             Audio_Frame,
	opl3_frame:             Audio_Frame,
	native_pcm_frame:       Audio_Frame,
	native_release_frames:  u16,
	source_active:          [int(Audio_Mixer_Source.Count)]bool,
	speaker_gain_left:      u32,
	speaker_gain_right:     u32,
	cdda_gain_left:         u32,
	cdda_gain_right:        u32,
	cdda_resampler:         Audio_Resampler,
	cdda_frames:            [AUDIO_CDDA_QUEUE_FRAMES]Audio_Frame_Wide,
	cdda_head:              int,
	cdda_count:             int,
	mix_batch:              [AUDIO_RENDER_BATCH]Audio_Frame,
	mix_batch_count:        int,
	output:                 Audio_Output,
	blocks_rendered:        u64,
	telemetry:              Audio_Mixer_Telemetry,
}

audio_mixer_init :: proc(mixer: ^Audio_Mixer) -> bool {
	mixer^ = {
		speaker_gain_left = AUDIO_GAIN_UNITY,
		speaker_gain_right = AUDIO_GAIN_UNITY,
		cdda_gain_left = AUDIO_GAIN_UNITY,
		cdda_gain_right = AUDIO_GAIN_UNITY,
		telemetry = {pcm_fnv1a64 = AUDIO_PCM_FNV_OFFSET},
	}
	audio_output_init(&mixer.output)
	return audio_resampler_init(&mixer.cdda_resampler, AUDIO_CDDA_HZ, AUDIO_OUTPUT_HZ)
}

audio_mixer_output :: proc(mixer: ^Audio_Mixer) -> ^Audio_Output {
	return &mixer.output
}

audio_mixer_set_gains :: proc(mixer: ^Audio_Mixer, speaker, cdda: u32) {
	audio_mixer_set_gain_pairs(mixer, speaker, speaker, cdda, cdda)
}

audio_mixer_set_gain_pairs :: proc(
	mixer: ^Audio_Mixer,
	speaker_left, speaker_right: u32,
	cdda_left, cdda_right: u32,
) {
	mixer.speaker_gain_left = speaker_left
	mixer.speaker_gain_right = speaker_right
	mixer.cdda_gain_left = cdda_left
	mixer.cdda_gain_right = cdda_right
}

@(private = "package")
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

audio_mixer_telemetry :: proc(mixer: ^Audio_Mixer) -> Audio_Mixer_Telemetry {
	return mixer != nil ? mixer.telemetry : Audio_Mixer_Telemetry{}
}

audio_mixer_record_speaker_dropped :: proc(mixer: ^Audio_Mixer, count: u64) {
	if mixer == nil || count == 0 {return}
	mixer.telemetry.speaker_transitions_dropped += count
}

audio_mixer_set_sb16_frame :: proc(mixer: ^Audio_Mixer, at_tick: u64, frame: Audio_Frame) -> bool {
	if at_tick < mixer.now_ticks {return false}
	_ = audio_mixer_advance_to(mixer, at_tick)
	mixer.sb16_frame = frame
	return true
}

audio_mixer_set_opl3_frame :: proc(mixer: ^Audio_Mixer, at_tick: u64, frame: Audio_Frame) -> bool {
	if at_tick < mixer.now_ticks {return false}
	_ = audio_mixer_advance_to(mixer, at_tick)
	mixer.opl3_frame = frame
	return true
}

audio_mixer_set_native_pcm_frame :: proc(
	mixer: ^Audio_Mixer,
	at_tick: u64,
	frame: Audio_Frame,
) -> bool {
	if at_tick < mixer.now_ticks {return false}
	_ = audio_mixer_advance_to(mixer, at_tick)
	mixer.native_pcm_frame = frame
	return true
}

// Stop/reset and starvation release the last native sample over a bounded
// output interval instead of holding stale DC or stepping abruptly to zero.
audio_mixer_release_native_pcm :: proc(mixer: ^Audio_Mixer, at_tick: u64) -> bool {
	if mixer == nil || at_tick < mixer.now_ticks {return false}
	_ = audio_mixer_advance_to(mixer, at_tick)
	mixer.source_active[int(Audio_Mixer_Source.Native_PCM)] = false
	if mixer.native_pcm_frame.left != 0 || mixer.native_pcm_frame.right != 0 {
		mixer.native_release_frames = AUDIO_RAMP_FRAMES
	} else {
		mixer.native_release_frames = 0
		mixer.native_pcm_frame = {}
	}
	return true
}

audio_mixer_set_source_active :: proc(
	mixer: ^Audio_Mixer,
	source: Audio_Mixer_Source,
	active: bool,
) {
	if mixer == nil || source == .Count {return}
	mixer.source_active[int(source)] = active
	if source == .Native_PCM && active {mixer.native_release_frames = 0}
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
audio_mixer_average_area :: proc(area: i128, ticks: u64) -> i64 {
	if ticks == 0 {return 0}
	denominator := i128(ticks)
	if area >= 0 {return i64((area + denominator / 2) / denominator)}
	return i64((area - denominator / 2) / denominator)
}

@(private = "file")
audio_mixer_filter_speaker :: proc(mixer: ^Audio_Mixer, input: i64) -> i64 {
	highpass :=
		input -
		mixer.speaker_previous_input +
		mixer.speaker_highpass * AUDIO_SPEAKER_DC_POLE_Q15 / (1 << AUDIO_SPEAKER_DC_SHIFT)
	lowpass_wide :=
		i128(AUDIO_SPEAKER_LP_B0_Q30) * i128(highpass) +
		i128(AUDIO_SPEAKER_LP_B1_Q30) * i128(mixer.speaker_lowpass_input1) +
		i128(AUDIO_SPEAKER_LP_B2_Q30) * i128(mixer.speaker_lowpass_input2) -
		i128(AUDIO_SPEAKER_LP_A1_Q30) * i128(mixer.speaker_lowpass_output1) -
		i128(AUDIO_SPEAKER_LP_A2_Q30) * i128(mixer.speaker_lowpass_output2)
	lowpass := i64(lowpass_wide / i128(1 << AUDIO_SPEAKER_BIQUAD_SHIFT))
	mixer.speaker_previous_input = input
	mixer.speaker_highpass = highpass
	mixer.speaker_lowpass_input2 = mixer.speaker_lowpass_input1
	mixer.speaker_lowpass_input1 = highpass
	mixer.speaker_lowpass_output2 = mixer.speaker_lowpass_output1
	mixer.speaker_lowpass_output1 = lowpass
	if input == 0 &&
	   abs(highpass) <= AUDIO_SPEAKER_FILTER_SETTLE &&
	   abs(lowpass) <= AUDIO_SPEAKER_FILTER_SETTLE &&
	   abs(mixer.speaker_lowpass_input1) <= AUDIO_SPEAKER_FILTER_SETTLE &&
	   abs(mixer.speaker_lowpass_input2) <= AUDIO_SPEAKER_FILTER_SETTLE &&
	   abs(mixer.speaker_lowpass_output2) <= AUDIO_SPEAKER_FILTER_SETTLE {
		mixer.speaker_highpass = 0
		mixer.speaker_lowpass_input1 = 0
		mixer.speaker_lowpass_input2 = 0
		mixer.speaker_lowpass_output1 = 0
		mixer.speaker_lowpass_output2 = 0
		return 0
	}
	return lowpass
}

@(private = "file")
audio_mixer_record_source_frame :: proc(
	mixer: ^Audio_Mixer,
	source: Audio_Mixer_Source,
	active: bool,
	left, right: i64,
) {
	if !active {return}
	metrics := &mixer.telemetry.sources[int(source)]
	metrics.frames_produced += 1
	if left != 0 || right != 0 {metrics.nonzero_frames += 1}
}

@(private = "file")
audio_mixer_hash_pcm :: proc(mixer: ^Audio_Mixer, frame: Audio_Frame) {
	left := u16(frame.left)
	right := u16(frame.right)
	bytes := [4]u8{u8(left), u8(left >> 8), u8(right), u8(right >> 8)}
	for byte in bytes {
		mixer.telemetry.pcm_fnv1a64 =
			(mixer.telemetry.pcm_fnv1a64 ~ u64(byte)) * AUDIO_PCM_FNV_PRIME
	}
}

@(private = "file")
audio_mixer_emit :: proc(mixer: ^Audio_Mixer) {
	speaker_input := audio_mixer_average_speaker(mixer)
	speaker_active :=
		mixer.speaker_enabled ||
		mixer.speaker_highpass != 0 ||
		mixer.speaker_lowpass_output1 != 0 ||
		mixer.speaker_lowpass_output2 != 0 ||
		speaker_input != 0
	speaker := audio_mixer_filter_speaker(mixer, speaker_input)
	speaker_left := speaker * i64(mixer.speaker_gain_left) / i64(AUDIO_GAIN_UNITY)
	speaker_right := speaker * i64(mixer.speaker_gain_right) / i64(AUDIO_GAIN_UNITY)
	sb16_left := audio_mixer_average_area(mixer.sb16_left_area, mixer.speaker_ticks)
	sb16_right := audio_mixer_average_area(mixer.sb16_right_area, mixer.speaker_ticks)
	opl3_left := audio_mixer_average_area(mixer.opl3_left_area, mixer.speaker_ticks)
	opl3_right := audio_mixer_average_area(mixer.opl3_right_area, mixer.speaker_ticks)
	native_pcm_left := audio_mixer_average_area(mixer.native_pcm_left_area, mixer.speaker_ticks)
	native_pcm_right := audio_mixer_average_area(mixer.native_pcm_right_area, mixer.speaker_ticks)
	if mixer.native_release_frames > 0 {
		native_pcm_left =
			native_pcm_left * i64(mixer.native_release_frames) / i64(AUDIO_RAMP_FRAMES)
		native_pcm_right =
			native_pcm_right * i64(mixer.native_release_frames) / i64(AUDIO_RAMP_FRAMES)
		mixer.native_release_frames -= 1
		if mixer.native_release_frames == 0 {mixer.native_pcm_frame = {}}
	}
	cdda_active := mixer.cdda_count > 0
	cdda := audio_mixer_cdda_pop(mixer)
	cdda_left := i64(cdda.left) * i64(mixer.cdda_gain_left) / i64(AUDIO_GAIN_UNITY)
	cdda_right := i64(cdda.right) * i64(mixer.cdda_gain_right) / i64(AUDIO_GAIN_UNITY)
	left_wide := cdda_left + speaker_left + sb16_left + opl3_left + native_pcm_left
	right_wide := cdda_right + speaker_right + sb16_right + opl3_right + native_pcm_right
	frame := Audio_Frame {
		left  = audio_clamp_i16(left_wide),
		right = audio_clamp_i16(right_wide),
	}
	if left_wide < -32_768 || left_wide > 32_767 || right_wide < -32_768 || right_wide > 32_767 {
		mixer.telemetry.final_clipping_frames += 1
	}
	audio_mixer_record_source_frame(
		mixer,
		.PC_Speaker,
		speaker_active,
		speaker_left,
		speaker_right,
	)
	audio_mixer_record_source_frame(
		mixer,
		.SB16,
		mixer.source_active[int(Audio_Mixer_Source.SB16)] || sb16_left != 0 || sb16_right != 0,
		sb16_left,
		sb16_right,
	)
	audio_mixer_record_source_frame(
		mixer,
		.OPL3,
		mixer.source_active[int(Audio_Mixer_Source.OPL3)] || opl3_left != 0 || opl3_right != 0,
		opl3_left,
		opl3_right,
	)
	audio_mixer_record_source_frame(
		mixer,
		.Native_PCM,
		mixer.source_active[int(Audio_Mixer_Source.Native_PCM)] ||
		native_pcm_left != 0 ||
		native_pcm_right != 0,
		native_pcm_left,
		native_pcm_right,
	)
	audio_mixer_record_source_frame(mixer, .CDDA, cdda_active, cdda_left, cdda_right)
	audio_mixer_hash_pcm(mixer, frame)
	mixer.mix_batch[mixer.mix_batch_count] = frame
	mixer.mix_batch_count += 1
	if mixer.mix_batch_count == AUDIO_RENDER_BATCH {audio_mixer_flush_batch(mixer)}
	mixer.speaker_area = 0
	mixer.sb16_left_area = 0
	mixer.sb16_right_area = 0
	mixer.opl3_left_area = 0
	mixer.opl3_right_area = 0
	mixer.native_pcm_left_area = 0
	mixer.native_pcm_right_area = 0
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
		mixer.sb16_left_area += i128(mixer.sb16_frame.left) * i128(step)
		mixer.sb16_right_area += i128(mixer.sb16_frame.right) * i128(step)
		mixer.opl3_left_area += i128(mixer.opl3_frame.left) * i128(step)
		mixer.opl3_right_area += i128(mixer.opl3_frame.right) * i128(step)
		mixer.native_pcm_left_area += i128(mixer.native_pcm_frame.left) * i128(step)
		mixer.native_pcm_right_area += i128(mixer.native_pcm_frame.right) * i128(step)
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
	if at_tick < mixer.now_ticks {
		mixer.telemetry.speaker_transitions_late += 1
		return false
	}
	_ = audio_mixer_advance_to(mixer, at_tick)
	level := !enabled ? i32(0) : (pit_high ? AUDIO_SPEAKER_AMPLITUDE : -AUDIO_SPEAKER_AMPLITUDE)
	if mixer.speaker_enabled != enabled || mixer.speaker_level != level {
		mixer.telemetry.speaker_transitions_applied += 1
	}
	mixer.speaker_enabled = enabled
	mixer.speaker_level = level
	return true
}

audio_mixer_active :: proc(mixer: ^Audio_Mixer) -> bool {
	return(
		mixer != nil &&
		(mixer.speaker_enabled ||
				mixer.speaker_highpass != 0 ||
				mixer.speaker_lowpass_output1 != 0 ||
				mixer.speaker_lowpass_output2 != 0 ||
				mixer.cdda_count > 0 ||
				mixer.mix_batch_count > 0 ||
				mixer.source_active[int(Audio_Mixer_Source.SB16)] ||
				mixer.source_active[int(Audio_Mixer_Source.OPL3)] ||
				mixer.source_active[int(Audio_Mixer_Source.Native_PCM)] ||
				mixer.native_release_frames > 0 ||
				mixer.sb16_frame.left != 0 ||
				mixer.sb16_frame.right != 0 ||
				mixer.opl3_frame.left != 0 ||
				mixer.opl3_frame.right != 0 ||
				mixer.native_pcm_frame.left != 0 ||
				mixer.native_pcm_frame.right != 0) \
	)
}

audio_mixer_next_render_deadline_tick :: proc(
	mixer: ^Audio_Mixer,
) -> (
	deadline: u64,
	pending: bool,
) {
	if mixer == nil {return 0, false}
	frames_needed := u64(AUDIO_RENDER_BATCH - mixer.mix_batch_count)
	phase_needed := u128(frames_needed) * u128(AUDIO_MASTER_CLOCK_HZ) - u128(mixer.output_phase)
	until_publish := u64((phase_needed + u128(AUDIO_OUTPUT_HZ) - 1) / u128(AUDIO_OUTPUT_HZ))
	until_publish = max(until_publish, u64(1))
	if ~u64(0) - mixer.now_ticks < until_publish {return ~u64(0), true}
	return mixer.now_ticks + until_publish, true
}

audio_mixer_next_deadline_tick :: proc(mixer: ^Audio_Mixer) -> (deadline: u64, pending: bool) {
	if !audio_mixer_active(mixer) {return 0, false}
	return audio_mixer_next_render_deadline_tick(mixer)
}
