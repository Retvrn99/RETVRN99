// SPDX-License-Identifier: GPL-3.0-only
package host

import audio "../audio"
import "base:runtime"
import "core:c"
import sdl3 "vendor:sdl3"

HOST_MECHANICAL_AUDIO_CALLBACK_FRAMES :: 512

Host_Mechanical_Audio :: struct {
	stream:           ^sdl3.AudioStream,
	subsystem_active: bool,
	engine:           audio.Mechanical_Engine,
	callback_frames:  [HOST_MECHANICAL_AUDIO_CALLBACK_FRAMES]audio.Audio_Frame,
	gain:             f32,
}

host_mechanical_audio_open :: proc(
	host: ^Host_Mechanical_Audio,
	hdd_enabled: bool = true,
	floppy_enabled: bool = true,
) -> bool {
	if host == nil {return false}
	host_mechanical_audio_close(host)
	audio.mechanical_engine_init(&host.engine)
	audio.mechanical_engine_set_enabled(&host.engine, hdd_enabled, floppy_enabled)
	host.gain = 1
	if !sdl3.InitSubSystem({.AUDIO}) {return false}
	host.subsystem_active = true
	spec := sdl3.AudioSpec {
		format   = .S16,
		channels = 2,
		freq     = c.int(audio.AUDIO_OUTPUT_HZ),
	}
	host.stream = sdl3.OpenAudioDeviceStream(
		sdl3.AUDIO_DEVICE_DEFAULT_PLAYBACK,
		&spec,
		host_mechanical_audio_callback,
		host,
	)
	if host.stream == nil {
		host_mechanical_audio_close(host)
		return false
	}
	if !sdl3.ResumeAudioStreamDevice(host.stream) {
		host_mechanical_audio_close(host)
		return false
	}
	return true
}

host_mechanical_audio_close :: proc(host: ^Host_Mechanical_Audio) {
	if host == nil {return}
	if host.stream != nil {sdl3.DestroyAudioStream(host.stream)}
	if host.subsystem_active {sdl3.QuitSubSystem({.AUDIO})}
	host^ = {}
}

host_mechanical_audio_active :: proc(host: ^Host_Mechanical_Audio) -> bool {
	return host != nil && host.stream != nil
}

host_mechanical_audio_sink :: proc(
	host: ^Host_Mechanical_Audio,
) -> audio.Mechanical_Event_Sink {
	if host == nil || host.stream == nil {return {}}
	return audio.mechanical_engine_sink(&host.engine)
}

host_mechanical_audio_set_enabled :: proc(
	host: ^Host_Mechanical_Audio,
	hdd_enabled, floppy_enabled: bool,
) {
	if host == nil {return}
	audio.mechanical_engine_set_enabled(&host.engine, hdd_enabled, floppy_enabled)
}

host_mechanical_audio_set_machine_state :: proc(
	host: ^Host_Mechanical_Audio,
	running, paused: bool,
) {
	if host == nil {return}
	audio.mechanical_engine_set_machine_state(&host.engine, running, paused)
}

host_mechanical_audio_set_gain :: proc(host: ^Host_Mechanical_Audio, gain: f32) -> bool {
	if host == nil {return false}
	host.gain = clamp(gain, 0, 1)
	return host.stream == nil || sdl3.SetAudioStreamGain(host.stream, host.gain)
}

host_mechanical_audio_test_hard_drive :: proc(host: ^Host_Mechanical_Audio) -> bool {
	return(
		host != nil &&
		host.stream != nil &&
		audio.mechanical_engine_test_hard_drive(&host.engine) \
	)
}

host_mechanical_audio_test_floppy :: proc(host: ^Host_Mechanical_Audio) -> bool {
	return(
		host != nil &&
		host.stream != nil &&
		audio.mechanical_engine_test_floppy(&host.engine) \
	)
}

host_mechanical_audio_dropped_events :: proc(host: ^Host_Mechanical_Audio) -> u64 {
	if host == nil {return 0}
	return audio.mechanical_event_queue_dropped(&host.engine.queue)
}

host_mechanical_audio_callback :: proc "c" (
	userdata: rawptr,
	stream: ^sdl3.AudioStream,
	additional_amount, total_amount: c.int,
) {
	context = runtime.default_context()
	_ = total_amount
	host := (^Host_Mechanical_Audio)(userdata)
	if host == nil || stream == nil || additional_amount <= 0 {return}
	remaining :=
		(int(additional_amount) + size_of(audio.Audio_Frame) - 1) / size_of(audio.Audio_Frame)
	for remaining > 0 {
		count := min(remaining, len(host.callback_frames))
		frames := host.callback_frames[:count]
		audio.mechanical_engine_render(&host.engine, frames)
		if !sdl3.PutAudioStreamData(
			stream,
			raw_data(frames),
			c.int(len(frames) * size_of(audio.Audio_Frame)),
		) {
			return
		}
		remaining -= count
	}
}
