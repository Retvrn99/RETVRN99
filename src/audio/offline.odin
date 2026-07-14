// SPDX-License-Identifier: GPL-3.0-only
package audio

// Deterministic sink adapted from the offline validation approach in IzarraVM
// commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

AUDIO_OFFLINE_BATCH :: 512

Audio_Offline_Snapshot :: struct {
	crc32:             u32,
	frames:            u64,
	non_silent_frames: u64,
	peak:              u16,
}

Audio_Offline :: struct {
	consumer:          Audio_Consumer,
	crc:               u32,
	frames:            u64,
	non_silent_frames: u64,
	peak:              u16,
	batch:             [AUDIO_OFFLINE_BATCH]Audio_Frame,
}

audio_offline_init :: proc(
	offline: ^Audio_Offline,
	output: ^Audio_Output,
	discard_queued := false,
) {
	offline^ = {
		crc = 0xffff_ffff,
	}
	audio_consumer_init(&offline.consumer, output)
	if discard_queued {audio_consumer_discard_queued(&offline.consumer)}
}

@(private = "file")
audio_offline_crc_byte :: proc(crc: u32, value: u8) -> u32 {
	result := crc ~ u32(value)
	for _ in 0 ..< 8 {
		mask := u32(0) - (result & 1)
		result = (result >> 1) ~ (0xedb8_8320 & mask)
	}
	return result
}

@(private = "file")
audio_offline_abs_sample :: proc(sample: i16) -> u16 {
	value := i32(sample)
	if value < 0 {value = -value}
	return u16(min(value, i32(32_768)))
}

@(private = "file")
audio_offline_record :: proc(offline: ^Audio_Offline, frames: []Audio_Frame) {
	for frame in frames {
		left := u16(frame.left)
		right := u16(frame.right)
		offline.crc = audio_offline_crc_byte(offline.crc, u8(left))
		offline.crc = audio_offline_crc_byte(offline.crc, u8(left >> 8))
		offline.crc = audio_offline_crc_byte(offline.crc, u8(right))
		offline.crc = audio_offline_crc_byte(offline.crc, u8(right >> 8))
		left_peak := audio_offline_abs_sample(frame.left)
		right_peak := audio_offline_abs_sample(frame.right)
		offline.peak = max(offline.peak, max(left_peak, right_peak))
		if frame.left != 0 || frame.right != 0 {offline.non_silent_frames += 1}
	}
	offline.frames += u64(len(frames))
}

audio_offline_consume :: proc(offline: ^Audio_Offline, frame_count: int) {
	remaining := max(frame_count, 0)
	for remaining > 0 {
		count := min(remaining, AUDIO_OFFLINE_BATCH)
		audio_consumer_read(&offline.consumer, offline.batch[:count])
		audio_offline_record(offline, offline.batch[:count])
		remaining -= count
	}
}

audio_offline_snapshot :: proc(offline: ^Audio_Offline) -> Audio_Offline_Snapshot {
	return {
		crc32 = offline.crc ~ 0xffff_ffff,
		frames = offline.frames,
		non_silent_frames = offline.non_silent_frames,
		peak = offline.peak,
	}
}
