// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import "profile"

Graphics_Postmortem_Test_Sink :: struct {
	mu:          sync.Mutex,
	diagnostic:  profile.Graphics_Postmortem_Save_Diagnostic,
	calls:       int,
	path:        [GRAPHICS_POSTMORTEM_PATH_MAX_BYTES]u8,
	path_len:    int,
	payload:     [profile.GRAPHICS_POSTMORTEM_MAX_BYTES]u8,
	payload_len: int,
}

graphics_postmortem_test_sink :: proc(
	ctx: rawptr,
	path: string,
	payload: []u8,
) -> profile.Graphics_Postmortem_Save_Diagnostic {
	sink := (^Graphics_Postmortem_Test_Sink)(ctx)
	if sink == nil {return .Write_Failed}
	sync.lock(&sink.mu)
	defer sync.unlock(&sink.mu)
	sink.calls += 1
	sink.path_len = copy(sink.path[:], transmute([]u8)path)
	sink.payload_len = copy(sink.payload[:], payload)
	return sink.diagnostic
}

graphics_postmortem_test_sink_snapshot :: proc(
	sink: ^Graphics_Postmortem_Test_Sink,
) -> (
	int,
	string,
	string,
) {
	sync.lock(&sink.mu)
	defer sync.unlock(&sink.mu)
	return sink.calls, string(sink.path[:sink.path_len]), string(sink.payload[:sink.payload_len])
}

graphics_postmortem_test_init :: proc(
	t: ^testing.T,
	writer: ^Graphics_Postmortem,
	sink: ^Graphics_Postmortem_Test_Sink,
) -> bool {
	return testing.expect_value(
		t,
		graphics_postmortem_init(
			writer,
			{
				enabled = true,
				path = "graphics-postmortem.json",
				session = "session-17",
				device = "GSW-VGA",
				sink = graphics_postmortem_test_sink,
				sink_ctx = sink,
			},
		),
		Graphics_Postmortem_Init_Diagnostic.None,
	)
}

@(test)
graphics_postmortem_test_opt_in_and_publish_bounds :: proc(t: ^testing.T) {
	disabled: Graphics_Postmortem
	testing.expect_value(
		t,
		graphics_postmortem_init(&disabled, {}),
		Graphics_Postmortem_Init_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&disabled, "not persisted", 0),
		Graphics_Postmortem_Publish_Diagnostic.Disabled,
	)
	testing.expect_value(t, graphics_postmortem_status(&disabled).writes_attempted, u64(0))

	too_long_session := make([]u8, GRAPHICS_POSTMORTEM_SESSION_MAX_BYTES + 1)
	defer delete(too_long_session)
	rejected: Graphics_Postmortem
	testing.expect_value(
		t,
		graphics_postmortem_init(
			&rejected,
			{
				enabled = true,
				path = "graphics-postmortem.json",
				session = string(too_long_session),
				device = "GSW-VGA",
			},
		),
		Graphics_Postmortem_Init_Diagnostic.Field_Too_Large,
	)

	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	active := true
	defer if active {_ = graphics_postmortem_destroy(&writer)}
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, "retained", 11),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	before := graphics_postmortem_snapshot(&writer)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, "\x00", 12),
		Graphics_Postmortem_Publish_Diagnostic.Invalid_Argument,
	)
	too_long_window := make([]u8, GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES + 1)
	defer delete(too_long_window)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, string(too_long_window), 12),
		Graphics_Postmortem_Publish_Diagnostic.Text_Too_Large,
	)
	after := graphics_postmortem_snapshot(&writer)
	testing.expect_value(t, after.revision, before.revision)
	testing.expect_value(t, string(after.window.data[:after.window.length]), "retained")
	_ = graphics_postmortem_destroy(&writer)
	active = false
}

@(test)
graphics_postmortem_test_maximum_escaped_payload_stays_bounded :: proc(t: ^testing.T) {
	snapshot := Graphics_Postmortem_Snapshot {
		schema_version = GRAPHICS_POSTMORTEM_SCHEMA_VERSION,
		revision       = 1,
	}
	mem.set(&snapshot.session.data, '"', len(snapshot.session.data))
	mem.set(&snapshot.device.data, '"', len(snapshot.device.data))
	mem.set(&snapshot.window.data, '"', len(snapshot.window.data))
	mem.set(&snapshot.vm.data, '"', len(snapshot.vm.data))
	snapshot.session.length = GRAPHICS_POSTMORTEM_SESSION_MAX_BYTES
	snapshot.device.length = GRAPHICS_POSTMORTEM_DEVICE_MAX_BYTES
	snapshot.window.length = GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES
	snapshot.vm.length = GRAPHICS_POSTMORTEM_VM_MAX_BYTES
	payload, encoded := graphics_postmortem_format(&snapshot)
	if !testing.expect(t, encoded) {return}
	defer delete(payload)
	testing.expect(t, len(payload) <= profile.GRAPHICS_POSTMORTEM_MAX_BYTES)
}

@(test)
graphics_postmortem_test_maximum_telemetry_window_is_retained :: proc(t: ^testing.T) {
	window: Graphics_Telemetry_Window
	mem.set(&window, 0xff, size_of(window))
	window.started = time.tick_add({}, 1)
	window.ended = time.tick_add({}, max(time.Duration))
	window.latest_source = .Legacy_Scanout
	window.latest_kind = .Xrgb_8888
	window.latest_width = max(int)
	window.latest_height = max(int)
	window.producer.valid = true
	window.producer.mode.kind = .Xrgb_8888
	window.producer.mode.width = max(int)
	window.producer.mode.height = max(int)
	window.producer.mode.vbe_pitch_bytes_derived = max(int)
	window.producer.mode.vbe_enabled = true
	window.producer.mode.legacy_display_start_pending_valid = true
	window.producer.mode.vbe_display_start_derived_valid = true
	window.producer.gsw3d_queue_depth_current = max(int)
	window.producer.gsw3d_queue_depth_sampled_peak = max(int)
	window.producer.gsw3d_queue_depth_high_water = max(int)
	window.producer.gsw3d_queued_presents_current = max(int)
	window.producer.gsw3d_queued_presents_sampled_peak = max(int)
	window.producer.gsw3d_queued_presents_high_water = max(int)
	window.producer.gsw3d_completion_depth_current = max(int)
	window.host_gpu.valid = true
	window.host_gpu.direct_present_active = true

	text := graphics_telemetry_window_text(window)
	defer delete(text)
	testing.expect(t, len(text) > 4096)
	if !testing.expect(t, len(text) <= GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES) {return}

	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	defer graphics_postmortem_destroy(&writer)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(
			&writer,
			graphics_postmortem_measured_state(3, 11, 29, max(u64), .Complete),
		),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, text, max(u64)),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	snapshot := graphics_postmortem_snapshot(&writer)
	testing.expect_value(t, snapshot.window.length, len(text))
	testing.expect_value(t, string(snapshot.window.data[:snapshot.window.length]), text)
	testing.expect_value(t, snapshot.window_frame_generation, max(u64))
}

@(test)
graphics_postmortem_test_zero_generations_are_unavailable :: proc(t: ^testing.T) {
	state := graphics_postmortem_measured_state(0, 0, 0, 0, .Capture)
	testing.expect_value(t, state.session_generation, u64(0))
	testing.expect_value(
		t,
		state.session_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(t, state.guest_device_generation, u64(0))
	testing.expect_value(
		t,
		state.guest_device_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(t, state.host_device_generation, u64(0))
	testing.expect_value(
		t,
		state.host_device_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(t, state.frame_generation, u64(0))
	testing.expect_value(
		t,
		state.frame_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(t, state.host_stage, Graphics_Postmortem_Host_Stage.Capture)
	testing.expect_value(
		t,
		state.host_stage_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
}

@(test)
graphics_postmortem_test_stage_retained_with_explicit_provenance :: proc(t: ^testing.T) {
	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	active := true
	defer if active {_ = graphics_postmortem_destroy(&writer)}
	initial := graphics_postmortem_snapshot(&writer)
	testing.expect_value(
		t,
		initial.session_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(
		t,
		initial.guest_device_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(
		t,
		initial.host_device_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(
		t,
		initial.frame_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(
			&writer,
			graphics_postmortem_measured_state(3, 5, 9, 77, .Upload),
		),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, "one-second-window", 77, .Derived),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "EIP=12345678", 77, .Measured),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	snapshot := graphics_postmortem_snapshot(&writer)
	testing.expect_value(t, snapshot.host_stage, Graphics_Postmortem_Host_Stage.Upload)
	testing.expect_value(
		t,
		snapshot.host_stage_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
	testing.expect_value(t, snapshot.frame_generation, u64(77))
	testing.expect_value(t, snapshot.session_generation, u64(3))
	testing.expect_value(t, snapshot.guest_device_generation, u64(5))
	testing.expect_value(t, snapshot.host_device_generation, u64(9))
	testing.expect_value(
		t,
		snapshot.session_generation_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
	testing.expect_value(
		t,
		snapshot.guest_device_generation_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
	testing.expect_value(
		t,
		snapshot.host_device_generation_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
	testing.expect_value(
		t,
		snapshot.frame_generation_provenance,
		Graphics_Postmortem_Provenance.Measured,
	)
	testing.expect_value(t, snapshot.window_provenance, Graphics_Postmortem_Provenance.Derived)
	testing.expect_value(t, snapshot.window_frame_generation, u64(77))
	testing.expect_value(t, snapshot.vm_frame_generation, u64(77))
	payload, encoded := graphics_postmortem_format(&snapshot)
	if !testing.expect(t, encoded) {return}
	defer delete(payload)
	text := string(payload)
	testing.expect(t, strings.contains(text, `"schema": 2`))
	testing.expect(t, strings.contains(text, `"value": "session-17"`))
	testing.expect(t, strings.contains(text, `"value": "GSW-VGA"`))
	testing.expect(t, strings.contains(text, `"session_generation": {`))
	testing.expect(t, strings.contains(text, `"guest_device_generation": {`))
	testing.expect(t, strings.contains(text, `"host_device_generation": {`))
	testing.expect(t, strings.contains(text, `"frame_generation": {`))
	testing.expect(t, strings.contains(text, `"window_frame_generation": {`))
	testing.expect(t, strings.contains(text, `"vm_frame_generation": {`))
	testing.expect(t, strings.contains(text, `"value": 3`))
	testing.expect(t, strings.contains(text, `"value": 5`))
	testing.expect(t, strings.contains(text, `"value": 9`))
	testing.expect(t, strings.contains(text, `"value": 77`))
	testing.expect(t, strings.contains(text, `"value": "upload"`))
	testing.expect(t, strings.contains(text, `"provenance": "measured"`))
	testing.expect(t, strings.contains(text, `"provenance": "derived"`))
	_ = graphics_postmortem_destroy(&writer)
	active = false
}

@(test)
graphics_postmortem_test_state_rejects_stale_frames_and_backward_stages :: proc(t: ^testing.T) {
	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	defer graphics_postmortem_destroy(&writer)

	state_41 := graphics_postmortem_measured_state(3, 11, 29, 41, .Render)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(&writer, state_41),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	state_41.host_stage = .Mailbox
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(&writer, state_41),
		Graphics_Postmortem_Publish_Diagnostic.Stale_State,
	)
	state_40 := graphics_postmortem_measured_state(3, 10, 28, 40, .Complete)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(&writer, state_40),
		Graphics_Postmortem_Publish_Diagnostic.Stale_State,
	)

	state_42 := graphics_postmortem_measured_state(3, 12, 30, 42, .Capture)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(&writer, state_42),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	state_41.host_stage = .Complete
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(&writer, state_41),
		Graphics_Postmortem_Publish_Diagnostic.Stale_State,
	)
	snapshot := graphics_postmortem_snapshot(&writer)
	testing.expect_value(t, snapshot.frame_generation, u64(42))
	testing.expect_value(t, snapshot.host_stage, Graphics_Postmortem_Host_Stage.Capture)
	testing.expect_value(t, snapshot.guest_device_generation, u64(12))
	testing.expect_value(t, snapshot.host_device_generation, u64(30))
	testing.expect_value(t, snapshot.revision, u64(2))
}

@(test)
graphics_postmortem_test_payload_generations_do_not_regress_frame_state :: proc(t: ^testing.T) {
	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	defer graphics_postmortem_destroy(&writer)

	testing.expect_value(
		t,
		graphics_postmortem_publish_state(
			&writer,
			graphics_postmortem_measured_state(3, 11, 29, 77, .Upload),
		),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, "window-77", 77),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "vm-77", 77),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(
			&writer,
			graphics_postmortem_measured_state(3, 12, 30, 78, .Capture),
		),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	before := graphics_postmortem_snapshot(&writer)
	testing.expect_value(
		t,
		graphics_postmortem_publish_window(&writer, "window-zero", 0),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "vm-76", 76),
		Graphics_Postmortem_Publish_Diagnostic.Stale_State,
	)
	after := graphics_postmortem_snapshot(&writer)
	testing.expect_value(t, after.revision, before.revision + 1)
	testing.expect_value(t, after.frame_generation, u64(78))
	testing.expect_value(t, after.host_stage, Graphics_Postmortem_Host_Stage.Capture)
	testing.expect_value(t, after.window_frame_generation, u64(0))
	testing.expect_value(
		t,
		after.window_frame_generation_provenance,
		Graphics_Postmortem_Provenance.Unavailable,
	)
	testing.expect_value(t, after.vm_frame_generation, u64(77))
	testing.expect_value(t, string(after.window.data[:after.window.length]), "window-zero")
	testing.expect_value(t, string(after.vm.data[:after.vm.length]), "vm-77")
}

@(test)
graphics_postmortem_test_destroy_flushes_latest_coalesced_snapshot :: proc(t: ^testing.T) {
	writer: Graphics_Postmortem
	sink: Graphics_Postmortem_Test_Sink
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "first-vm-state", 90),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "latest-vm-state", 91),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_publish_state(
			&writer,
			graphics_postmortem_measured_state(3, 5, 9, 91, .Present),
		),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	latest_revision := graphics_postmortem_snapshot(&writer).revision
	testing.expect_value(
		t,
		graphics_postmortem_destroy(&writer),
		profile.Graphics_Postmortem_Save_Diagnostic.None,
	)
	calls, path, payload := graphics_postmortem_test_sink_snapshot(&sink)
	testing.expect_value(t, calls, 1)
	testing.expect_value(t, path, "graphics-postmortem.json")
	testing.expect(t, strings.contains(payload, "latest-vm-state"))
	testing.expect(t, !strings.contains(payload, "first-vm-state"))
	testing.expect(t, strings.contains(payload, `"value": "present"`))
	status := graphics_postmortem_status(&writer)
	testing.expect(t, !status.enabled)
	testing.expect(t, !status.worker_running)
	testing.expect_value(t, status.persisted_revision, latest_revision)
	testing.expect_value(t, status.writes_attempted, u64(1))
	testing.expect_value(t, status.writes_succeeded, u64(1))
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "after-destroy", 92),
		Graphics_Postmortem_Publish_Diagnostic.Disabled,
	)
	time.sleep(5 * time.Millisecond)
	after_calls, _, _ := graphics_postmortem_test_sink_snapshot(&sink)
	testing.expect_value(t, after_calls, calls)
}

@(test)
graphics_postmortem_test_failed_final_save_retains_diagnostic :: proc(t: ^testing.T) {
	writer: Graphics_Postmortem
	sink := Graphics_Postmortem_Test_Sink {
		diagnostic = .Write_Failed,
	}
	if !graphics_postmortem_test_init(t, &writer, &sink) {return}
	testing.expect_value(
		t,
		graphics_postmortem_publish_vm(&writer, "failure-state", 1),
		Graphics_Postmortem_Publish_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_destroy(&writer),
		profile.Graphics_Postmortem_Save_Diagnostic.Write_Failed,
	)
	status := graphics_postmortem_status(&writer)
	testing.expect(t, !status.worker_running)
	testing.expect(t, status.dirty)
	testing.expect_value(t, status.writes_attempted, u64(1))
	testing.expect_value(t, status.writes_failed, u64(1))
	testing.expect_value(
		t,
		status.last_save_diagnostic,
		profile.Graphics_Postmortem_Save_Diagnostic.Write_Failed,
	)
}
