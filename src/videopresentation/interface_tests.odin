// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:sync"
import "core:testing"
import "core:time"
import host "../host"

Video_Presentation_Interface_Probe :: struct {
	video:              ^Video_Presentation,
	start_calls:        int,
	stop_calls:         int,
	clear_calls:        int,
	last_lifecycle:     u64,
	callbacks_unlocked: bool,
}

video_presentation_interface_probe_unlocked :: proc(
	probe: ^Video_Presentation_Interface_Probe,
) -> bool {
	if probe == nil || probe.video == nil {return false}
	unlocked := sync.try_lock(&probe.video.mu)
	if unlocked {sync.unlock(&probe.video.mu)}
	return unlocked
}

video_presentation_interface_start :: proc(ctx: rawptr, lifecycle_generation: u64) -> bool {
	probe := (^Video_Presentation_Interface_Probe)(ctx)
	if probe == nil {return false}
	probe.start_calls += 1
	probe.last_lifecycle = lifecycle_generation
	probe.callbacks_unlocked =
		probe.callbacks_unlocked && video_presentation_interface_probe_unlocked(probe)
	return lifecycle_generation != 0
}

video_presentation_interface_stop :: proc(ctx: rawptr) {
	probe := (^Video_Presentation_Interface_Probe)(ctx)
	if probe == nil {return}
	probe.stop_calls += 1
	probe.callbacks_unlocked =
		probe.callbacks_unlocked && video_presentation_interface_probe_unlocked(probe)
}

video_presentation_interface_clear :: proc(ctx: rawptr) {
	probe := (^Video_Presentation_Interface_Probe)(ctx)
	if probe == nil {return}
	probe.clear_calls += 1
	probe.callbacks_unlocked =
		probe.callbacks_unlocked && video_presentation_interface_probe_unlocked(probe)
}

@(test)
video_presentation_interface_test_lifecycle_callbacks_run_outside_mutex :: proc(t: ^testing.T) {
	video: Video_Presentation
	initialized := video_presentation_init(&video)
	if !testing.expect(t, initialized.initialized) {return}
	defer video_presentation_destroy(&video)

	probe := Video_Presentation_Interface_Probe {
		video = &video,
		callbacks_unlocked = true,
	}
	adapter := Video_Presentation_Host_Adapter {
		ctx = &probe,
		start = video_presentation_interface_start,
		stop = video_presentation_interface_stop,
		clear = video_presentation_interface_clear,
	}
	if !testing.expect(t, video_presentation_start(&video, &adapter)) {return}
	first_lifecycle := probe.last_lifecycle
	video_presentation_reset(&video, &adapter)
	if !testing.expect(t, video_presentation_start(&video, &adapter)) {return}
	video_presentation_stop(&video, &adapter)

	testing.expect_value(t, probe.start_calls, 2)
	testing.expect_value(t, probe.clear_calls, 2)
	testing.expect_value(t, probe.stop_calls, 1)
	testing.expect(t, first_lifecycle != 0)
	testing.expect(t, probe.last_lifecycle != first_lifecycle)
	testing.expect(t, probe.callbacks_unlocked)
}

@(test)
video_presentation_interface_test_snapshots_are_value_copies :: proc(t: ^testing.T) {
	video: Video_Presentation
	initialized := video_presentation_init(&video)
	if !testing.expect(t, initialized.initialized) {return}
	defer video_presentation_destroy(&video)

	telemetry := video_presentation_telemetry_snapshot(&video)
	postmortem := video_presentation_postmortem_snapshot(&video)
	video.lifecycle_generation = 99
	testing.expect_value(t, telemetry.telemetry.trace_observed, u64(0))
	testing.expect_value(t, postmortem.revision, u64(0))
}

@(test)
video_presentation_interface_test_host_policy_state_is_module_owned :: proc(t: ^testing.T) {
	video: Video_Presentation
	initialized := video_presentation_init(&video)
	if !testing.expect(t, initialized.initialized) {return}
	h: host.Host
	adapter := video_presentation_host_adapter(&h)
	if !testing.expect(t, video_presentation_start(&video, &adapter)) {return}

	testing.expect(t, h.presentation_external == &video.host_state)
	testing.expect(t, video.host_state.accepting)
	testing.expect_value(
		t,
		video.host_state.lifecycle,
		frame_mailbox_lifecycle_generation(&video),
	)
	video_presentation_stop(&video, &adapter)
	h.presentation_external = nil
	_ = video_presentation_destroy(&video)
}

@(test)
video_presentation_interface_test_consume_owns_derived_state_and_window_policy :: proc(
	t: ^testing.T,
) {
	video: Video_Presentation
	initialized := video_presentation_init(&video)
	if !testing.expect(t, initialized.initialized) {return}
	defer video_presentation_destroy(&video)

	measured := video_presentation_consume(
		&video,
		nil,
		false,
		nil,
		&Video_Presentation_Consume_Event {
			kind = .Measured_State,
			postmortem_state = {session_generation = 3},
			guest_device_generation = 5,
			host_device_generation = 7,
			frame_generation = 11,
			host_stage = .Present,
		},
	)
	testing.expect(t, measured.event_applied)
	testing.expect(t, measured.postmortem_state_valid)
	testing.expect_value(t, measured.postmortem_state.session_generation, u64(3))
	testing.expect_value(t, measured.postmortem_state.guest_device_generation, u64(5))
	testing.expect_value(t, measured.postmortem_state.host_device_generation, u64(7))
	testing.expect_value(t, measured.postmortem_state.frame_generation, u64(11))
	testing.expect_value(t, measured.postmortem_state.host_stage, Graphics_Postmortem_Host_Stage.Present)

	started := time.Tick{1}
	_ = video_presentation_consume(
		&video,
		nil,
		false,
		nil,
		&Video_Presentation_Consume_Event {
			kind = .Input,
			input_events = 1,
			now = started,
		},
	)
	window := video_presentation_consume(
		&video,
		nil,
		false,
		nil,
		&Video_Presentation_Consume_Event {
			kind = .Telemetry_Window,
			now = time.tick_add(started, time.Second),
		},
	)
	defer delete(window.telemetry_window_text)
	testing.expect(t, window.event_applied)
	testing.expect(t, window.telemetry_window_ready)
	testing.expect(t, window.telemetry_log_admitted)
	testing.expect(t, len(window.telemetry_window_text) > 0)
	testing.expect_value(t, video.aggregate_logs, u64(1))
}
