// SPDX-License-Identifier: GPL-3.0-only
package host

import audio "../audio"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import sdl3 "vendor:sdl3"

HOST_MECHANICAL_AUDIO_CALLBACK_FRAMES :: 512
HOST_MECHANICAL_AUDIO_SAMPLE_ALLOCATION_CAPACITY :: 192
HOST_MECHANICAL_HDD_SAMPLE_GAIN :: audio.MECHANICAL_SAMPLE_GAIN_ONE / 4
HOST_MECHANICAL_FDD_SAMPLE_GAIN :: audio.MECHANICAL_SAMPLE_GAIN_ONE / 2
HOST_86BOX_HDD_DIRECTORY :: "hdd/1997 Quantum Bigfoot 2110AT"
HOST_86BOX_HDD_PREFIX :: "1997_Quantum Bigfoot 2110AT_3600RPM_"
HOST_86BOX_FDD_DIRECTORY :: "fdd/3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks"
HOST_86BOX_FDD_PREFIX :: "3.5_Alps_Electric_Co_Ltd_DF354H148F_1.44M_80tracks_"

Host_Mechanical_Sample_Status :: struct {
	root_found:     bool,
	hdd_loaded:     bool,
	floppy_loaded:  bool,
	files_loaded:   int,
}

Host_Mechanical_Audio :: struct {
	stream:                  ^sdl3.AudioStream,
	subsystem_active:        bool,
	engine:                  audio.Mechanical_Engine,
	callback_frames:         [HOST_MECHANICAL_AUDIO_CALLBACK_FRAMES]audio.Audio_Frame,
	sample_allocations:      [HOST_MECHANICAL_AUDIO_SAMPLE_ALLOCATION_CAPACITY]rawptr,
	sample_allocation_count: int,
	sample_status:           Host_Mechanical_Sample_Status,
	gain:                    f32,
}

@(private = "file")
host_mechanical_audio_path :: proc(root, relative: string) -> (string, bool) {
	path, path_error := filepath.join({root, relative}, context.temp_allocator)
	return path, path_error == nil
}

@(private = "file")
host_mechanical_audio_root_has_profile :: proc(root: string) -> bool {
	hdd_marker, hdd_path_ok := host_mechanical_audio_path(
		root,
		HOST_86BOX_HDD_DIRECTORY + "/" + HOST_86BOX_HDD_PREFIX + "SPINDLE_SPINUP.wav",
	)
	fdd_marker, fdd_path_ok := host_mechanical_audio_path(
		root,
		HOST_86BOX_FDD_DIRECTORY + "/" + HOST_86BOX_FDD_PREFIX + "motor_start.wav",
	)
	return (hdd_path_ok && os.is_file(hdd_marker)) || (fdd_path_ok && os.is_file(fdd_marker))
}

@(private = "package")
host_mechanical_audio_normalize_root :: proc(candidate: string) -> (string, bool) {
	if len(candidate) == 0 {return "", false}
	relatives := [?]string{"", "sounds", "assets/sounds", "sounds/86box"}
	for relative in relatives {
		root := candidate
		if len(relative) > 0 {
			joined, joined_ok := host_mechanical_audio_path(candidate, relative)
			if !joined_ok {continue}
			root = joined
		}
		if host_mechanical_audio_root_has_profile(root) {return root, true}
	}
	return "", false
}

@(private = "file")
host_mechanical_audio_find_root :: proc() -> (string, bool) {
	if configured, found := os.lookup_env("RETVRN99_86BOX_ASSETS", context.temp_allocator);
	   found {
		if root, ok := host_mechanical_audio_normalize_root(configured); ok {return root, true}
	}
	base_path := sdl3.GetBasePath()
	if base_path == nil {return "", false}
	adjacent, adjacent_ok := host_mechanical_audio_path(string(base_path), "sounds/86box")
	if !adjacent_ok {return "", false}
	return host_mechanical_audio_normalize_root(adjacent)
}

@(private = "file")
host_mechanical_audio_release_from :: proc(host: ^Host_Mechanical_Audio, first: int) {
	if host == nil {return}
	start := clamp(first, 0, host.sample_allocation_count)
	for index in start ..< host.sample_allocation_count {
		if host.sample_allocations[index] != nil {sdl3.free(host.sample_allocations[index])}
		host.sample_allocations[index] = nil
	}
	host.sample_allocation_count = start
}

@(private = "file")
host_mechanical_audio_load_wav :: proc(
	host: ^Host_Mechanical_Audio,
	path: string,
	gain: i32,
) -> (audio.Mechanical_Sample, bool) {
	if host == nil || host.sample_allocation_count >= len(host.sample_allocations) {
		return {}, false
	}
	cpath, path_error := strings.clone_to_cstring(path, context.temp_allocator)
	if path_error != nil {return {}, false}
	source_spec: sdl3.AudioSpec
	source_data: [^]sdl3.Uint8
	source_length: sdl3.Uint32
	if !sdl3.LoadWAV(cpath, &source_spec, &source_data, &source_length) {return {}, false}
	defer sdl3.free(rawptr(source_data))
	destination_spec := sdl3.AudioSpec {
		format   = .S16,
		channels = 2,
		freq     = c.int(audio.AUDIO_OUTPUT_HZ),
	}
	destination_data: [^]sdl3.Uint8
	destination_length: c.int
	if !sdl3.ConvertAudioSamples(
		&source_spec,
		source_data,
		c.int(source_length),
		&destination_spec,
		&destination_data,
		&destination_length,
	) || destination_data == nil || destination_length <= 0 {
		if destination_data != nil {sdl3.free(rawptr(destination_data))}
		return {}, false
	}
	if destination_length % c.int(size_of(audio.Audio_Frame)) != 0 {
		sdl3.free(rawptr(destination_data))
		return {}, false
	}
	allocation_index := host.sample_allocation_count
	host.sample_allocations[allocation_index] = rawptr(destination_data)
	host.sample_allocation_count += 1
	frame_count := int(destination_length) / size_of(audio.Audio_Frame)
	frames := ([^]audio.Audio_Frame)(rawptr(destination_data))[:frame_count]
	return {frames = frames, gain = gain}, true
}

@(private = "file")
host_mechanical_audio_load_relative :: proc(
	host: ^Host_Mechanical_Audio,
	root, relative: string,
	gain: i32,
) -> (audio.Mechanical_Sample, bool) {
	path, path_ok := host_mechanical_audio_path(root, relative)
	if !path_ok {return {}, false}
	return host_mechanical_audio_load_wav(host, path, gain)
}

@(private = "package")
host_mechanical_audio_clear_hdd_samples :: proc(samples: ^audio.Mechanical_Sample_Set) {
	if samples == nil {return}
	samples.hdd_spin_up = {}
	samples.hdd_running = {}
	samples.hdd_spin_down = {}
	samples.hdd_seek = {}
	samples.hdd_available = false
}

@(private = "package")
host_mechanical_audio_clear_fdd_samples :: proc(samples: ^audio.Mechanical_Sample_Set) {
	if samples == nil {return}
	samples.fdd_motor_start = {}
	samples.fdd_motor_loop = {}
	samples.fdd_motor_stop = {}
	samples.fdd_seek_up = {}
	samples.fdd_seek_down = {}
	samples.fdd_available = false
}

@(private = "file")
host_mechanical_audio_load_hdd :: proc(
	host: ^Host_Mechanical_Audio,
	root: string,
	samples: ^audio.Mechanical_Sample_Set,
) -> bool {
	first := host.sample_allocation_count
	loaded: bool
	samples.hdd_spin_up, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_HDD_DIRECTORY + "/" + HOST_86BOX_HDD_PREFIX + "SPINDLE_SPINUP.wav",
		HOST_MECHANICAL_HDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_hdd_samples(samples)
		return false
	}
	samples.hdd_running, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_HDD_DIRECTORY + "/" + HOST_86BOX_HDD_PREFIX + "SPINDLE_RUNNING.wav",
		HOST_MECHANICAL_HDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_hdd_samples(samples)
		return false
	}
	samples.hdd_spin_down, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_HDD_DIRECTORY + "/" + HOST_86BOX_HDD_PREFIX + "SPINDLE_SPINDOWN.wav",
		HOST_MECHANICAL_HDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_hdd_samples(samples)
		return false
	}
	samples.hdd_seek, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_HDD_DIRECTORY + "/" + HOST_86BOX_HDD_PREFIX + "SEEK_1TRACK.wav",
		HOST_MECHANICAL_HDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_hdd_samples(samples)
		return false
	}
	samples.hdd_available = true
	return true
}

@(private = "file")
host_mechanical_audio_load_fdd :: proc(
	host: ^Host_Mechanical_Audio,
	root: string,
	samples: ^audio.Mechanical_Sample_Set,
) -> bool {
	first := host.sample_allocation_count
	loaded: bool
	samples.fdd_motor_start, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_FDD_DIRECTORY + "/" + HOST_86BOX_FDD_PREFIX + "motor_start.wav",
		HOST_MECHANICAL_FDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_fdd_samples(samples)
		return false
	}
	samples.fdd_motor_loop, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_FDD_DIRECTORY + "/" + HOST_86BOX_FDD_PREFIX + "motor_loop.wav",
		HOST_MECHANICAL_FDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_fdd_samples(samples)
		return false
	}
	samples.fdd_motor_stop, loaded = host_mechanical_audio_load_relative(
		host, root, HOST_86BOX_FDD_DIRECTORY + "/" + HOST_86BOX_FDD_PREFIX + "motor_stop.wav",
		HOST_MECHANICAL_FDD_SAMPLE_GAIN,
	)
	if !loaded {
		host_mechanical_audio_release_from(host, first)
		host_mechanical_audio_clear_fdd_samples(samples)
		return false
	}
	for distance in 1 ..= audio.MECHANICAL_FDD_SEEK_SAMPLE_COUNT {
		up_name := fmt.tprintf(
			"%s/%s%dup.wav",
			HOST_86BOX_FDD_DIRECTORY,
			HOST_86BOX_FDD_PREFIX,
			distance,
		)
		down_name := fmt.tprintf(
			"%s/%s%ddown.wav",
			HOST_86BOX_FDD_DIRECTORY,
			HOST_86BOX_FDD_PREFIX,
			distance,
		)
		samples.fdd_seek_up[distance - 1], loaded = host_mechanical_audio_load_relative(
			host, root, up_name, HOST_MECHANICAL_FDD_SAMPLE_GAIN,
		)
		if !loaded {
			host_mechanical_audio_release_from(host, first)
			host_mechanical_audio_clear_fdd_samples(samples)
			return false
		}
		samples.fdd_seek_down[distance - 1], loaded = host_mechanical_audio_load_relative(
			host, root, down_name, HOST_MECHANICAL_FDD_SAMPLE_GAIN,
		)
		if !loaded {
			host_mechanical_audio_release_from(host, first)
			host_mechanical_audio_clear_fdd_samples(samples)
			return false
		}
	}
	samples.fdd_available = true
	return true
}

@(private = "file")
host_mechanical_audio_load_samples :: proc(host: ^Host_Mechanical_Audio) {
	root, found := host_mechanical_audio_find_root()
	host.sample_status.root_found = found
	if !found {
		fmt.println("device sounds: external 86Box samples not found; set RETVRN99_86BOX_ASSETS or use sounds/86box")
		return
	}
	samples: audio.Mechanical_Sample_Set
	host.sample_status.hdd_loaded = host_mechanical_audio_load_hdd(host, root, &samples)
	host.sample_status.floppy_loaded = host_mechanical_audio_load_fdd(host, root, &samples)
	host.sample_status.files_loaded = host.sample_allocation_count
	audio.mechanical_engine_set_samples(&host.engine, samples)
	fmt.printfln(
		"device sounds: 86Box samples hdd=%v floppy=%v files=%d",
		host.sample_status.hdd_loaded,
		host.sample_status.floppy_loaded,
		host.sample_status.files_loaded,
	)
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
	// Load and convert every sample before opening the callback-driven stream.
	host_mechanical_audio_load_samples(host)
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
	host.stream = nil
	// The callback is gone, so its sample slices can now be released safely.
	host_mechanical_audio_release_from(host, 0)
	if host.subsystem_active {sdl3.QuitSubSystem({.AUDIO})}
	host^ = {}
}

host_mechanical_audio_active :: proc(host: ^Host_Mechanical_Audio) -> bool {
	return host != nil && host.stream != nil
}

host_mechanical_audio_sample_status :: proc(
	host: ^Host_Mechanical_Audio,
) -> Host_Mechanical_Sample_Status {
	if host == nil {return {}}
	return host.sample_status
}

host_mechanical_audio_sample_status_text :: proc(host: ^Host_Mechanical_Audio) -> string {
	if host == nil || host.stream == nil {return "Device sound output is unavailable"}
	if !host.sample_status.root_found {
		return "86Box drive sound pack missing; see docs/drive-sounds.md"
	}
	if host.sample_status.hdd_loaded && host.sample_status.floppy_loaded {
		return "86Box Bigfoot HDD and Alps floppy samples loaded"
	}
	if host.sample_status.hdd_loaded {
		return "86Box Bigfoot HDD samples loaded; Alps floppy pack incomplete"
	}
	if host.sample_status.floppy_loaded {
		return "86Box Alps floppy samples loaded; Bigfoot HDD pack incomplete"
	}
	return "86Box drive sound folders found, but required samples are incomplete or invalid"
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

host_mechanical_audio_set_hdd_attached :: proc(host: ^Host_Mechanical_Audio, attached: bool) {
	if host == nil {return}
	audio.mechanical_engine_set_hdd_attached(&host.engine, attached)
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
