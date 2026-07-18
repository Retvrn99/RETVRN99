// SPDX-License-Identifier: GPL-3.0-only
package host

import audio "../audio"
import "core:os"
import "core:path/filepath"
import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
test_mechanical_audio_normalizes_repository_and_direct_sounds_roots :: proc(t: ^testing.T) {
	base, base_error := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, base_error == nil) {return}
	root, root_error := os.make_directory_temp(
		base,
		"retvrn99-86box-sounds-*",
		context.temp_allocator,
	)
	if !testing.expect(t, root_error == nil) {return}
	defer os.remove_all(root)
	direct, direct_error := filepath.join({root, "sounds"}, context.temp_allocator)
	marker, marker_error := filepath.join(
		{
			direct,
			HOST_86BOX_HDD_DIRECTORY,
			HOST_86BOX_HDD_PREFIX + "SPINDLE_SPINUP.wav",
		},
		context.temp_allocator,
	)
	if !testing.expect(t, direct_error == nil && marker_error == nil) {return}
	if !testing.expect(t, os.make_directory_all(filepath.dir(marker)) == nil) {return}
	if !testing.expect(t, os.write_entire_file(marker, "not decoded by discovery") == nil) {return}

	from_repository, repository_ok := host_mechanical_audio_normalize_root(root)
	from_direct, direct_ok := host_mechanical_audio_normalize_root(direct)
	testing.expect(t, repository_ok)
	testing.expect(t, direct_ok)
	testing.expect_value(t, from_repository, direct)
	testing.expect_value(t, from_direct, direct)
}

@(test)
test_mechanical_audio_clear_samples_removes_released_slices :: proc(t: ^testing.T) {
	frames: [1]audio.Audio_Frame
	sample := audio.Mechanical_Sample {
		frames = frames[:],
		gain = audio.MECHANICAL_SAMPLE_GAIN_ONE,
	}
	samples := audio.Mechanical_Sample_Set {
		hdd_spin_up = sample,
		hdd_running = sample,
		hdd_spin_down = sample,
		hdd_seek = sample,
		fdd_motor_start = sample,
		fdd_motor_loop = sample,
		fdd_motor_stop = sample,
		hdd_available = true,
		fdd_available = true,
	}
	samples.fdd_seek_up[0] = sample
	samples.fdd_seek_down[0] = sample
	host_mechanical_audio_clear_hdd_samples(&samples)
	host_mechanical_audio_clear_fdd_samples(&samples)
	testing.expect(t, !samples.hdd_available && !samples.fdd_available)
	testing.expect_value(t, len(samples.hdd_spin_up.frames), 0)
	testing.expect_value(t, len(samples.hdd_seek.frames), 0)
	testing.expect_value(t, len(samples.fdd_motor_start.frames), 0)
	testing.expect_value(t, len(samples.fdd_seek_up[0].frames), 0)
	testing.expect_value(t, len(samples.fdd_seek_down[0].frames), 0)
}

@(test)
test_mechanical_audio_unavailable_status_precedes_pack_diagnostics :: proc(t: ^testing.T) {
	host: Host_Mechanical_Audio
	testing.expect_value(
		t,
		host_mechanical_audio_sample_status_text(&host),
		"Device sound output is unavailable",
	)
	testing.expect_value(
		t,
		host_mechanical_audio_sample_status_text(nil),
		"Device sound output is unavailable",
	)
}

@(test)
test_mechanical_audio_missing_status_is_actionable_when_output_is_live :: proc(t: ^testing.T) {
	host: Host_Mechanical_Audio
	host.stream = transmute(^sdl3.AudioStream)(uintptr(1))
	testing.expect_value(
		t,
		host_mechanical_audio_sample_status_text(&host),
		"86Box drive sound pack missing; see docs/drive-sounds.md",
	)
}
