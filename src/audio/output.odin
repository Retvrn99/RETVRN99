// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:sync"

// Bounded output and recovery policy adapted from IzarraVM commit
// d930de57acccbc6a70cda8cc5a603173bf23cd1c.

Audio_Queued_Kind :: enum u8 {
	Padding,
	Frame,
}

Audio_Queued_Frame :: struct {
	kind:  Audio_Queued_Kind,
	frame: Audio_Frame,
}

Audio_Metrics :: struct {
	frames_produced:          u64,
	frames_consumed:          u64,
	queue_min_depth:          u64,
	queue_max_depth:          u64,
	underruns:                u64,
	underrun_events:          u64,
	underrun_recoveries:      u64,
	gap_frames:               u64,
	ramp_down_frames:         u64,
	overruns:                 u64,
	late_callbacks:           u64,
	callback_lateness_us:     u64,
	max_callback_lateness_us: u64,
}

Audio_Metrics_Snapshot :: struct {
	frames_produced:          u64,
	frames_consumed:          u64,
	queue_min_depth:          u64,
	queue_max_depth:          u64,
	underruns:                u64,
	underrun_events:          u64,
	underrun_recoveries:      u64,
	gap_frames:               u64,
	ramp_down_frames:         u64,
	overruns:                 u64,
	late_callbacks:           u64,
	callback_lateness_us:     u64,
	max_callback_lateness_us: u64,
}

Audio_Output :: struct {
	frames:      [AUDIO_CAPACITY_FRAMES]u64,
	sequence:    [AUDIO_CAPACITY_FRAMES]u64,
	read_index:  u64,
	write_index: u64,
	skip_to:     u64,
	metrics:     Audio_Metrics,
}

Audio_Consumer :: struct {
	output:            ^Audio_Output,
	last:              Audio_Frame,
	gain:              u16,
	prefill_remaining: int,
	underrunning:      bool,
}

@(private = "file")
audio_metrics_min :: proc(value: ^u64, candidate: u64) {
	for {
		current := sync.atomic_load_explicit(value, .Relaxed)
		if candidate >= current {return}
		_, stored := sync.atomic_compare_exchange_weak_explicit(
			value,
			current,
			candidate,
			.Relaxed,
			.Relaxed,
		)
		if stored {return}
	}
}

@(private = "file")
audio_metrics_max :: proc(value: ^u64, candidate: u64) {
	for {
		current := sync.atomic_load_explicit(value, .Relaxed)
		if candidate <= current {return}
		_, stored := sync.atomic_compare_exchange_weak_explicit(
			value,
			current,
			candidate,
			.Relaxed,
			.Relaxed,
		)
		if stored {return}
	}
}

@(private = "file")
audio_output_observe_depth :: proc(output: ^Audio_Output, depth: u64) {
	audio_metrics_min(&output.metrics.queue_min_depth, depth)
	audio_metrics_max(&output.metrics.queue_max_depth, depth)
}

audio_output_init :: proc(output: ^Audio_Output) {
	output^ = {}
	for index in 0 ..< AUDIO_TARGET_FRAMES {
		audio_output_store(output, u64(index), Audio_Queued_Frame{kind = .Padding})
	}
	sync.atomic_store_explicit(&output.write_index, u64(AUDIO_TARGET_FRAMES), .Release)
	sync.atomic_store_explicit(&output.metrics.queue_min_depth, u64(AUDIO_TARGET_FRAMES), .Relaxed)
	sync.atomic_store_explicit(&output.metrics.queue_max_depth, u64(AUDIO_TARGET_FRAMES), .Relaxed)
}

audio_output_depth :: proc(output: ^Audio_Output) -> int {
	read := sync.atomic_load_explicit(&output.read_index, .Acquire)
	skip := sync.atomic_load_explicit(&output.skip_to, .Acquire)
	write := sync.atomic_load_explicit(&output.write_index, .Acquire)
	effective_read := max(read, skip)
	if write <= effective_read {return 0}
	return int(min(write - effective_read, u64(AUDIO_CAPACITY_FRAMES)))
}

@(private = "file")
audio_output_store :: proc(output: ^Audio_Output, index: u64, queued: Audio_Queued_Frame) {
	packed :=
		u64(u16(queued.frame.left)) | u64(u16(queued.frame.right)) << 16 | u64(queued.kind) << 32
	slot := index % u64(AUDIO_CAPACITY_FRAMES)
	sync.atomic_store_explicit(&output.frames[slot], packed, .Relaxed)
	sync.atomic_store_explicit(&output.sequence[slot], index + 1, .Release)
}

@(private = "file")
audio_output_recover :: proc(output: ^Audio_Output, frames: []Audio_Frame, write: u64) {
	_ = sync.atomic_add_explicit(&output.metrics.overruns, u64(1), .Relaxed)
	target := AUDIO_TARGET_FRAMES
	audio_limit := max(target - min(AUDIO_RAMP_FRAMES, target), 0)
	audio_count := min(len(frames), audio_limit)
	padding := target - audio_count
	start := write
	cursor := write
	sync.atomic_store_explicit(&output.skip_to, start, .Release)
	for index in 0 ..< padding {
		audio_output_store(output, cursor + u64(index), Audio_Queued_Frame{kind = .Padding})
	}
	cursor += u64(padding)
	for frame in frames[len(frames) - audio_count:] {
		audio_output_store(output, cursor, Audio_Queued_Frame{kind = .Frame, frame = frame})
		cursor += 1
	}
	sync.atomic_store_explicit(&output.write_index, cursor, .Release)
	audio_output_observe_depth(output, u64(target))
}

audio_output_queue :: proc(output: ^Audio_Output, frames: []Audio_Frame) {
	if len(frames) == 0 {return}
	_ = sync.atomic_add_explicit(&output.metrics.frames_produced, u64(len(frames)), .Relaxed)
	read := sync.atomic_load_explicit(&output.read_index, .Acquire)
	skip := sync.atomic_load_explicit(&output.skip_to, .Acquire)
	write := sync.atomic_load_explicit(&output.write_index, .Relaxed)
	effective_read := max(read, skip)
	logical_depth := int(min(write - effective_read, u64(AUDIO_CAPACITY_FRAMES)))
	if logical_depth + len(frames) > AUDIO_HIGH_FRAMES {
		audio_output_recover(output, frames, write)
		return
	}
	for frame in frames {
		audio_output_store(output, write, Audio_Queued_Frame{kind = .Frame, frame = frame})
		write += 1
	}
	sync.atomic_store_explicit(&output.write_index, write, .Release)
	audio_output_observe_depth(output, u64(logical_depth + len(frames)))
}

audio_consumer_init :: proc(consumer: ^Audio_Consumer, output: ^Audio_Output) {
	consumer^ = {
		output            = output,
		prefill_remaining = AUDIO_TARGET_FRAMES,
	}
}

audio_consumer_discard_queued :: proc(consumer: ^Audio_Consumer) {
	if consumer.output == nil {return}
	write := sync.atomic_load_explicit(&consumer.output.write_index, .Acquire)
	sync.atomic_store_explicit(&consumer.output.read_index, write, .Release)
	sync.atomic_store_explicit(&consumer.output.skip_to, write, .Release)
	consumer.prefill_remaining = 0
	consumer.gain = 0
	consumer.last = {}
	consumer.underrunning = false
	audio_output_observe_depth(consumer.output, 0)
}

@(private = "file")
audio_consumer_pop :: proc(consumer: ^Audio_Consumer) -> (Audio_Queued_Frame, bool) {
	output := consumer.output
	for {
		read := sync.atomic_load_explicit(&output.read_index, .Relaxed)
		skip := sync.atomic_load_explicit(&output.skip_to, .Acquire)
		if skip > read {
			read = skip
			sync.atomic_store_explicit(&output.read_index, read, .Release)
		}
		write := sync.atomic_load_explicit(&output.write_index, .Acquire)
		if read >= write {return {}, false}
		slot := read % u64(AUDIO_CAPACITY_FRAMES)
		expected := read + 1
		before := sync.atomic_load_explicit(&output.sequence[slot], .Acquire)
		if before != expected {continue}
		packed := sync.atomic_load_explicit(&output.frames[slot], .Relaxed)
		after := sync.atomic_load_explicit(&output.sequence[slot], .Acquire)
		if after != expected {continue}
		frame := Audio_Queued_Frame {
			kind = Audio_Queued_Kind((packed >> 32) & 0xff),
			frame = {left = i16(u16(packed)), right = i16(u16(packed >> 16))},
		}
		sync.atomic_store_explicit(&output.read_index, read + 1, .Release)
		audio_output_observe_depth(output, write - read - 1)
		return frame, true
	}
}

@(private = "file")
audio_consumer_scale :: proc(frame: Audio_Frame, gain: u16) -> Audio_Frame {
	return {
		left = audio_clamp_i16(i64(frame.left) * i64(gain) / AUDIO_RAMP_FRAMES),
		right = audio_clamp_i16(i64(frame.right) * i64(gain) / AUDIO_RAMP_FRAMES),
	}
}

audio_consumer_read :: proc(consumer: ^Audio_Consumer, destination: []Audio_Frame) {
	if consumer.output == nil {return}
	for &out in destination {
		queued, available := audio_consumer_pop(consumer)
		if available && queued.kind == .Frame {
			if consumer.underrunning {
				_ = sync.atomic_add_explicit(
					&consumer.output.metrics.underrun_recoveries,
					u64(1),
					.Relaxed,
				)
				consumer.underrunning = false
			}
			consumer.last = queued.frame
			consumer.gain = min(consumer.gain + 1, u16(AUDIO_RAMP_FRAMES))
		} else {
			_ = sync.atomic_add_explicit(&consumer.output.metrics.gap_frames, u64(1), .Relaxed)
			if consumer.gain > 0 {
				_ = sync.atomic_add_explicit(
					&consumer.output.metrics.ramp_down_frames,
					u64(1),
					.Relaxed,
				)
				consumer.gain -= 1
			}
			if !available && consumer.prefill_remaining == 0 {
				_ = sync.atomic_add_explicit(&consumer.output.metrics.underruns, u64(1), .Relaxed)
				if !consumer.underrunning {
					_ = sync.atomic_add_explicit(
						&consumer.output.metrics.underrun_events,
						u64(1),
						.Relaxed,
					)
					consumer.underrunning = true
				}
			}
			if consumer.gain == 0 {consumer.last = {}}
		}
		consumer.prefill_remaining -= min(consumer.prefill_remaining, 1)
		out = audio_consumer_scale(consumer.last, consumer.gain)
	}
	_ = sync.atomic_add_explicit(
		&consumer.output.metrics.frames_consumed,
		u64(len(destination)),
		.Relaxed,
	)
}

audio_output_record_callback_lateness :: proc(output: ^Audio_Output, lateness_ns: u64) {
	if lateness_ns <= 1_000_000 {return}
	lateness_us := lateness_ns / 1_000
	_ = sync.atomic_add_explicit(&output.metrics.late_callbacks, u64(1), .Relaxed)
	_ = sync.atomic_add_explicit(&output.metrics.callback_lateness_us, lateness_us, .Relaxed)
	audio_metrics_max(&output.metrics.max_callback_lateness_us, lateness_us)
}

audio_output_metrics :: proc(output: ^Audio_Output) -> Audio_Metrics_Snapshot {
	return {
		frames_produced = sync.atomic_load_explicit(&output.metrics.frames_produced, .Relaxed),
		frames_consumed = sync.atomic_load_explicit(&output.metrics.frames_consumed, .Relaxed),
		queue_min_depth = sync.atomic_load_explicit(&output.metrics.queue_min_depth, .Relaxed),
		queue_max_depth = sync.atomic_load_explicit(&output.metrics.queue_max_depth, .Relaxed),
		underruns = sync.atomic_load_explicit(&output.metrics.underruns, .Relaxed),
		underrun_events = sync.atomic_load_explicit(&output.metrics.underrun_events, .Relaxed),
		underrun_recoveries = sync.atomic_load_explicit(
			&output.metrics.underrun_recoveries,
			.Relaxed,
		),
		gap_frames = sync.atomic_load_explicit(&output.metrics.gap_frames, .Relaxed),
		ramp_down_frames = sync.atomic_load_explicit(&output.metrics.ramp_down_frames, .Relaxed),
		overruns = sync.atomic_load_explicit(&output.metrics.overruns, .Relaxed),
		late_callbacks = sync.atomic_load_explicit(&output.metrics.late_callbacks, .Relaxed),
		callback_lateness_us = sync.atomic_load_explicit(
			&output.metrics.callback_lateness_us,
			.Relaxed,
		),
		max_callback_lateness_us = sync.atomic_load_explicit(
			&output.metrics.max_callback_lateness_us,
			.Relaxed,
		),
	}
}
