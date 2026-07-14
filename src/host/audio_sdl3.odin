// SPDX-License-Identifier: GPL-3.0-only
package host

import audio "../audio"
import "base:runtime"
import "core:c"
import sdl3 "vendor:sdl3"

HOST_AUDIO_CALLBACK_FRAMES :: 1024

Host_Audio :: struct {
	stream:            ^sdl3.AudioStream,
	consumer:          audio.Audio_Consumer,
	callback_frames:   [HOST_AUDIO_CALLBACK_FRAMES]audio.Audio_Frame,
	last_callback_ns:  u64,
	last_frame_count:  int,
}

host_audio_open :: proc(host: ^Host_Audio, output: ^audio.Audio_Output) -> bool {
	if host == nil || output == nil {return false}
	host_audio_close(host)
	audio.audio_consumer_init(&host.consumer, output)
	spec := sdl3.AudioSpec {
		format   = .S16,
		channels = 2,
		freq     = c.int(audio.AUDIO_OUTPUT_HZ),
	}
	host.stream = sdl3.OpenAudioDeviceStream(
		sdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK,
		&spec,
		host_audio_callback,
		host,
	)
	if host.stream == nil {
		host.consumer = {}
		return false
	}
	if !sdl3.ResumeAudioStreamDevice(host.stream) {
		host_audio_close(host)
		return false
	}
	return true
}

host_audio_close :: proc(host: ^Host_Audio) {
	if host == nil {return}
	if host.stream != nil {sdl3.DestroyAudioStream(host.stream)}
	host^ = {}
}

host_audio_active :: proc(host: ^Host_Audio) -> bool {
	return host != nil && host.stream != nil
}

host_audio_callback :: proc "c" (
	userdata: rawptr,
	stream: ^sdl3.AudioStream,
	additional_amount, total_amount: c.int,
) {
	context = runtime.default_context()
	_ = total_amount
	host := (^Host_Audio)(userdata)
	if host == nil || stream == nil || additional_amount <= 0 {return}
	now := u64(sdl3.GetTicksNS())
	if host.last_callback_ns != 0 && host.last_frame_count > 0 {
		expected := u64(host.last_frame_count) * 1_000_000_000 / audio.AUDIO_OUTPUT_HZ
		elapsed := now - min(now, host.last_callback_ns)
		if elapsed > expected {
			audio.audio_output_record_callback_lateness(
				host.consumer.output,
				elapsed - expected,
			)
		}
	}
	remaining := (int(additional_amount) + size_of(audio.Audio_Frame) - 1) /
	             size_of(audio.Audio_Frame)
	host.last_callback_ns = now
	host.last_frame_count = remaining
	for remaining > 0 {
		count := min(remaining, len(host.callback_frames))
		frames := host.callback_frames[:count]
		audio.audio_consumer_read(&host.consumer, frames)
		if !sdl3.PutAudioStreamData(stream, raw_data(frames), c.int(len(frames) * size_of(audio.Audio_Frame))) {
			return
		}
		remaining -= count
	}
}
