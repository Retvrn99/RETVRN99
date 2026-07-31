// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:strings"
import "core:testing"
import "core:time"
import host "../host"
import vga "../vga"

@(test)
graphics_telemetry_test_aggregate_log_is_bounded :: proc(t: ^testing.T) {
	emitted := u64(GRAPHICS_TELEMETRY_AGGREGATE_LOG_CAPACITY - 1)
	testing.expect(t, graphics_telemetry_aggregate_log_admit(&emitted))
	testing.expect_value(t, emitted, u64(GRAPHICS_TELEMETRY_AGGREGATE_LOG_CAPACITY))
	testing.expect(t, !graphics_telemetry_aggregate_log_admit(&emitted))
	testing.expect_value(t, emitted, u64(GRAPHICS_TELEMETRY_AGGREGATE_LOG_CAPACITY))
	testing.expect(t, !graphics_telemetry_aggregate_log_admit(nil))
}

@(test)
graphics_telemetry_test_legacy_refresh_then_gsw_attempt_preserves_physical_work :: proc(
	t: ^testing.T,
) {
	epoch := Graphics_Frame_Epoch {
		sequence = 4,
		lifecycle_generation = 3,
		bytes_copied = 512,
		descriptor_copy_ns = 20,
		producer = {valid = true},
	}
	graphics_frame_epoch_render_begin(&epoch, .Legacy_Scanout, time.Tick{10})
	frame := vga.Display_Frame {
		kind           = .Xrgb_8888,
		width          = 640,
		height         = 480,
		updated_pixels = 640 * 480,
	}
	graphics_frame_epoch_render_complete(&epoch, &frame, time.Tick{20})
	graphics_frame_epoch_upload_begin(&epoch, time.Tick{21})
	graphics_frame_epoch_upload_complete(&epoch, 640 * 480 * 4, true, time.Tick{30})

	graphics_frame_epoch_render_begin(&epoch, .Gsw2d, time.Tick{40})

	testing.expect_value(t, epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, epoch.kind, vga.Display_Kind.Invalid)
	testing.expect_value(t, epoch.width, 0)
	testing.expect_value(t, epoch.height, 0)
	testing.expect_value(t, epoch.rendered_pixels, u64(640 * 480))
	testing.expect_value(t, epoch.bytes_uploaded, u64(640 * 480 * 4))
	testing.expect(t, epoch.texture_recreated)
	testing.expect_value(t, epoch.render_ended, time.Tick{})
	testing.expect_value(t, epoch.upload_started, time.Tick{})
	testing.expect_value(t, epoch.upload_ended, time.Tick{})
	testing.expect_value(t, epoch.lifecycle_generation, u64(3))
	testing.expect_value(t, epoch.bytes_copied, u64(512))
	testing.expect_value(t, epoch.descriptor_copy_ns, u64(20))
	testing.expect(t, epoch.producer.valid)

	gsw_frame := vga.Display_Frame {
		kind           = .Rgb_565,
		width          = 320,
		height         = 240,
		updated_pixels = 320 * 240,
	}
	graphics_frame_epoch_render_complete(&epoch, &gsw_frame, time.Tick{50})
	graphics_frame_epoch_upload_begin(&epoch, time.Tick{51})
	graphics_frame_epoch_upload_complete(&epoch, 320 * 240 * 4, false, time.Tick{60})

	testing.expect_value(t, epoch.source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, epoch.kind, vga.Display_Kind.Rgb_565)
	testing.expect_value(t, epoch.width, 320)
	testing.expect_value(t, epoch.height, 240)
	testing.expect_value(t, epoch.rendered_pixels, u64(640 * 480 + 320 * 240))
	testing.expect_value(t, epoch.bytes_uploaded, u64((640 * 480 + 320 * 240) * 4))
	testing.expect(t, epoch.texture_recreated)
	testing.expect_value(t, epoch.first_render_started, time.Tick{10})
	testing.expect_value(t, epoch.render_started, time.Tick{40})
	testing.expect_value(t, epoch.render_work_ns, u64(20))
	testing.expect_value(t, epoch.render_work_samples, u64(2))
	testing.expect_value(t, epoch.upload_work_ns, u64(18))
	testing.expect_value(t, epoch.upload_work_samples, u64(2))
}

@(test)
graphics_telemetry_test_two_attempt_window_accumulates_work_without_queue_inflation :: proc(
	t: ^testing.T,
) {
	telemetry: Graphics_Telemetry
	epoch := graphics_frame_epoch_begin(1, 1, time.Tick{10})
	graphics_frame_epoch_capture_begin(&epoch, time.Tick{10})
	graphics_frame_epoch_capture_complete(&epoch, 64, time.Tick{20})
	legacy := vga.Display_Frame {
		kind           = .Xrgb_8888,
		width          = 4,
		height         = 2,
		updated_pixels = 4 * 2,
	}
	graphics_frame_epoch_render_begin(&epoch, .Legacy_Scanout, time.Tick{30})
	graphics_frame_epoch_render_complete(&epoch, &legacy, time.Tick{40})
	graphics_frame_epoch_upload_begin(&epoch, time.Tick{41})
	graphics_frame_epoch_upload_complete(&epoch, 4 * 2 * 4, true, time.Tick{51})
	gsw := vga.Display_Frame {
		kind           = .Rgb_565,
		width          = 2,
		height         = 2,
		updated_pixels = 2 * 2,
	}
	graphics_frame_epoch_render_begin(&epoch, .Gsw2d, time.Tick{100})
	graphics_frame_epoch_render_complete(&epoch, &gsw, time.Tick{120})
	graphics_frame_epoch_upload_begin(&epoch, time.Tick{121})
	graphics_frame_epoch_upload_complete(&epoch, 2 * 2 * 4, false, time.Tick{151})
	graphics_frame_epoch_complete(&epoch, .Superseded, time.Tick{160})
	graphics_telemetry_record(&telemetry, epoch)

	window := telemetry.current
	testing.expect_value(t, window.queue_ns, u64(10))
	testing.expect_value(t, window.queue_samples, u64(1))
	testing.expect_value(t, window.render_ns, u64(30))
	testing.expect_value(t, window.render_samples, u64(2))
	testing.expect_value(t, window.upload_ns, u64(40))
	testing.expect_value(t, window.upload_samples, u64(2))
	testing.expect_value(t, window.rendered_pixels, u64(12))
	testing.expect_value(t, window.bytes_uploaded, u64(48))
	testing.expect_value(t, window.texture_recreates, u64(1))
	testing.expect_value(t, window.latest_source, Graphics_Frame_Source.Gsw2d)
	testing.expect_value(t, window.latest_kind, vga.Display_Kind.Rgb_565)
	testing.expect_value(t, window.latest_width, 2)
	testing.expect_value(t, window.latest_height, 2)
}

@(test)
graphics_telemetry_test_top_level_aggregates_saturate :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	telemetry.window_active = true
	telemetry.current = {
		started                  = time.Tick{1},
		publish_attempts         = max(u64),
		input_events             = max(u64) - 1,
		input_residence_ns       = max(u64) - 2,
		epochs                   = max(u64),
		presented                = max(u64),
		bytes_copied             = max(u64) - 3,
		descriptor_copy_ns       = max(u64) - 4,
		descriptor_copy_samples  = max(u64),
		bytes_uploaded           = max(u64) - 5,
		rendered_pixels          = max(u64) - 6,
		texture_recreates        = max(u64),
		input_to_present_ns      = max(u64) - 7,
		input_to_present_samples = max(u64),
		compose_ns               = max(u64) - 8,
		compose_samples          = max(u64),
	}
	telemetry.pending_input_events = max(u64) - 1
	telemetry.pending_input_ns = max(u64) - 2
	telemetry.input_correlation_events = max(u64) - 1
	telemetry.input_correlation_samples = max(u64)
	telemetry.input_correlation_total_ns = max(u64) - 2
	telemetry.input_correlation_max_ns = 7
	graphics_telemetry_note_publish_attempt(&telemetry, time.Tick{2})
	graphics_telemetry_note_input(&telemetry, 8, 8, 8, time.Tick{3})
	graphics_telemetry_note_compose(&telemetry, time.Tick{3}, time.Tick{20})

	epoch := graphics_frame_epoch_begin(1, 1, time.Tick{2})
	epoch.bytes_copied = 8
	epoch.descriptor_copy_ns = 8
	epoch.bytes_uploaded = 8
	epoch.rendered_pixels = 8
	epoch.texture_recreated = true
	epoch.input_events = 8
	epoch.input_to_present_ns = 8
	epoch.compose_started = time.Tick{3}
	epoch.compose_ended = time.Tick{20}
	graphics_frame_epoch_complete(&epoch, .Presented, time.Tick{20})
	graphics_telemetry_record(&telemetry, epoch)

	window := telemetry.current
	testing.expect_value(t, window.publish_attempts, max(u64))
	testing.expect_value(t, window.input_events, max(u64))
	testing.expect_value(t, window.input_residence_ns, max(u64))
	testing.expect_value(t, telemetry.pending_input_events, max(u64))
	testing.expect_value(t, telemetry.pending_input_ns, max(u64))
	testing.expect_value(t, window.epochs, max(u64))
	testing.expect_value(t, window.presented, max(u64))
	testing.expect_value(t, window.bytes_copied, max(u64))
	testing.expect_value(t, window.descriptor_copy_ns, max(u64))
	testing.expect_value(t, window.descriptor_copy_samples, max(u64))
	testing.expect_value(t, window.bytes_uploaded, max(u64))
	testing.expect_value(t, window.rendered_pixels, max(u64))
	testing.expect_value(t, window.texture_recreates, max(u64))
	testing.expect_value(t, window.input_to_present_ns, max(u64))
	testing.expect_value(t, window.input_to_present_samples, max(u64))
	testing.expect_value(t, telemetry.input_correlation_events, max(u64))
	testing.expect_value(t, telemetry.input_correlation_samples, max(u64))
	testing.expect_value(t, telemetry.input_correlation_total_ns, max(u64))
	testing.expect_value(t, telemetry.input_correlation_max_ns, u64(8))
	testing.expect_value(t, window.compose_ns, max(u64))
	testing.expect_value(t, window.compose_samples, max(u64))
}

@(test)
graphics_telemetry_test_compose_and_present_aggregate_every_host_call :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	graphics_telemetry_init(&telemetry, true)
	defer graphics_telemetry_destroy(&telemetry)
	graphics_telemetry_note_compose(&telemetry, time.Tick{10}, time.Tick{20})
	graphics_telemetry_note_present(&telemetry, time.Tick{20}, time.Tick{35})

	epoch := graphics_frame_epoch_begin(1, 1, time.Tick{40})
	graphics_frame_epoch_compose(&epoch, time.Tick{40}, time.Tick{50})
	graphics_frame_epoch_present_begin(&epoch, time.Tick{50})
	graphics_telemetry_note_compose(&telemetry, time.Tick{40}, time.Tick{50})
	graphics_telemetry_note_present(&telemetry, time.Tick{50}, time.Tick{70})
	graphics_frame_epoch_complete(&epoch, .Presented, time.Tick{70})
	graphics_telemetry_record(&telemetry, epoch)

	window := telemetry.current
	testing.expect_value(t, window.compose_ns, u64(20))
	testing.expect_value(t, window.compose_samples, u64(2))
	testing.expect_value(t, window.present_ns, u64(35))
	testing.expect_value(t, window.present_samples, u64(2))
	retained, ok := graphics_telemetry_trace_epoch(&telemetry, 0)
	if !testing.expect(t, ok) {return}
	testing.expect_value(
		t,
		u64(time.tick_diff(retained.compose_started, retained.compose_ended)),
		u64(10),
	)
	testing.expect_value(
		t,
		u64(time.tick_diff(retained.present_started, retained.completed)),
		u64(20),
	)
}

@(test)
graphics_telemetry_test_epoch_correlates_every_current_scanout_phase :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	graphics_telemetry_init(&telemetry, true)
	defer graphics_telemetry_destroy(&telemetry)
	started := time.Tick{100}
	graphics_telemetry_note_publish_attempt(&telemetry, started)
	graphics_telemetry_note_input(&telemetry, 2, 600, 400, time.Tick{105}, time.Tick{50})
	producer_before := Graphics_Producer_Sample {
		valid                        = true,
		output_underrun_frames       = 5,
		output_underrun_events       = 1,
		native_pcm_starvation_frames = 3,
	}
	producer_before.machine.mode.io_write_count = 7
	producer_before.machine.mode.io_write_bytes = 11
	producer_before.machine.gsw2d.metrics.mmio_write_count = 2
	producer_before.machine.gsw2d.metrics.mmio_write_bytes = 8
	producer_after := producer_before
	producer_after.output_underrun_frames = 7
	producer_after.output_underrun_events = 2
	producer_after.native_pcm_starvation_frames = 6
	producer_after.machine.mode.io_write_count = 10
	producer_after.machine.mode.io_write_bytes = 17
	producer_after.machine.gsw2d.metrics.mmio_write_count = 4
	producer_after.machine.gsw2d.metrics.mmio_write_bytes = 16
	graphics_telemetry_note_producer(&telemetry, producer_before, time.Tick{106})
	graphics_telemetry_note_producer(&telemetry, producer_after, time.Tick{107})
	host_before := host.Host_Gsw3d_Observability_Snapshot {
		device_generation              = 3,
		sdl_gpu_submission_calls       = 4,
		sdl_gpu_submission_ns          = 100,
		sdl_gpu_fence_submissions      = 4,
		sdl_gpu_fence_completions      = 2,
		sdl_gpu_fence_completion_ns    = 50,
		sdl_gpu_fence_capacity_wait_ns = 100,
		direct_presents                = 1,
		resident_gpu_surface_bytes     = 4096,
	}
	host_after := host_before
	host_after.sdl_gpu_submission_calls = 6
	host_after.sdl_gpu_submission_failures = 1
	host_after.sdl_gpu_submission_ns = 360
	host_after.sdl_gpu_latest_submission_ns = 200
	host_after.sdl_gpu_fence_submissions = 6
	host_after.sdl_gpu_fence_completions = 5
	host_after.sdl_gpu_fence_completion_ns = 150
	host_after.sdl_gpu_fence_capacity_waits = 1
	host_after.sdl_gpu_fence_capacity_wait_ns = 350
	host_after.sdl_gpu_fence_latest_capacity_wait_ns = 250
	host_after.sdl_gpu_fence_in_flight = 1
	host_after.sdl_gpu_fence_max_in_flight = 2
	host_after.direct_presents = 3
	host_after.direct_present_active = true
	host_after.direct_present_surface_id = 23
	host_after.direct_present_surface_width = 640
	host_after.direct_present_surface_height = 480
	host_after.direct_present_canvas_width = 800
	host_after.direct_present_canvas_height = 600
	host_after.direct_present_interval = 1
	host_after.sdl_gpu_latest_submission_tick = time.Tick{80}
	host_after.sdl_gpu_latest_submission_token = 42
	host_after.sdl_gpu_latest_submission_generation = 3
	host_after.sdl_gpu_flights[0] = {
		valid       = true,
		submit_tick = time.Tick{80},
		token       = 42,
		generation  = 3,
	}
	host_after.sdl_gpu_latest_completion_submit_tick = time.Tick{60}
	host_after.sdl_gpu_latest_completion_observed_tick = time.Tick{90}
	host_after.sdl_gpu_latest_completion_token = 41
	host_after.sdl_gpu_latest_completion_generation = 3
	host_after.sdl_gpu_latest_completion_duration_ns = 30
	host_after.direct_present_latest_draw_fence_valid = true
	host_after.direct_present_latest_draw_submit_tick = time.Tick{80}
	host_after.direct_present_latest_draw_token = 42
	host_after.direct_present_latest_draw_generation = 3
	host_after.resident_gpu_surface_bytes = 8192
	_ = graphics_telemetry_note_host_gpu(&telemetry, host_before, time.Tick{108})
	_ = graphics_telemetry_note_host_gpu(&telemetry, host_after, time.Tick{109})
	epoch := graphics_telemetry_begin_epoch(&telemetry, 1, 9, started)
	graphics_frame_epoch_capture_begin(&epoch, started)
	graphics_frame_epoch_descriptor_copy(&epoch, 40)
	graphics_frame_epoch_capture_complete(&epoch, 1024, time.Tick{200})
	graphics_frame_epoch_render_begin(&epoch, .Legacy_Scanout, time.Tick{300})
	frame := vga.Display_Frame {
		kind           = .Rgb_565,
		width          = 640,
		height         = 480,
		updated_pixels = 640 * 480,
	}
	graphics_frame_epoch_render_complete(&epoch, &frame, time.Tick{500})
	graphics_frame_epoch_upload_begin(&epoch, time.Tick{500})
	graphics_frame_epoch_upload_complete(&epoch, 640 * 480 * 4, true, time.Tick{700})
	graphics_frame_epoch_gpu_drain(&epoch, time.Tick{700}, time.Tick{800}, 2, 1, 64)
	graphics_telemetry_note_gpu_drain(&telemetry, time.Tick{700}, time.Tick{800}, 2, 1, 64)
	graphics_telemetry_note_compose(&telemetry, time.Tick{800}, time.Tick{900})
	graphics_frame_epoch_compose(&epoch, time.Tick{800}, time.Tick{900})
	graphics_telemetry_note_present(&telemetry, time.Tick{900}, time.Tick{1100})
	graphics_frame_epoch_present_begin(&epoch, time.Tick{900})
	graphics_frame_epoch_complete(&epoch, .Presented, time.Tick{1100})
	graphics_telemetry_record(&telemetry, epoch)

	_, ready := graphics_telemetry_take_window(&telemetry, time.Tick{1200})
	testing.expect(t, !ready)
	window: Graphics_Telemetry_Window
	window, ready = graphics_telemetry_take_window(&telemetry, time.tick_add(started, time.Second))
	if !testing.expect(t, ready) {return}
	testing.expect_value(t, window.publish_attempts, u64(1))
	testing.expect_value(t, window.epochs, u64(1))
	testing.expect_value(t, window.presented, u64(1))
	testing.expect_value(t, window.bytes_copied, u64(1024))
	testing.expect_value(t, window.descriptor_copy_ns, u64(40))
	testing.expect_value(t, window.descriptor_copy_samples, u64(1))
	testing.expect_value(t, window.bytes_uploaded, u64(640 * 480 * 4))
	testing.expect_value(t, window.rendered_pixels, u64(640 * 480))
	testing.expect_value(t, window.texture_recreates, u64(1))
	testing.expect_value(t, window.gpu_requests, u64(2))
	testing.expect_value(t, window.gpu_failures, u64(1))
	testing.expect_value(t, window.gpu_budget, u64(64))
	testing.expect_value(t, window.input_events, u64(2))
	testing.expect_value(t, window.input_residence_ns, u64(600))
	testing.expect_value(t, window.max_input_residence_ns, u64(400))
	testing.expect_value(t, window.input_to_present_ns, u64(1050))
	testing.expect_value(t, window.max_input_to_present_ns, u64(1050))
	testing.expect_value(t, window.input_to_present_samples, u64(1))
	testing.expect_value(t, telemetry.input_correlation_events, u64(2))
	testing.expect_value(t, telemetry.input_correlation_samples, u64(1))
	testing.expect_value(t, telemetry.input_correlation_total_ns, u64(1050))
	testing.expect_value(t, telemetry.input_correlation_max_ns, u64(1050))
	correlation := graphics_telemetry_input_correlation(&telemetry)
	testing.expect_value(t, correlation.retained_samples, u64(1))
	testing.expect_value(t, correlation.retention_capacity, u64(4096))
	testing.expect_value(t, correlation.retention_dropped, u64(0))
	testing.expect(t, correlation.retention_enabled)
	testing.expect(t, !correlation.retention_overflowed)
	testing.expect(t, correlation.percentiles_valid)
	testing.expect_value(t, correlation.p50_ns, u64(1050))
	testing.expect_value(t, correlation.p95_ns, u64(1050))
	testing.expect_value(t, correlation.p99_ns, u64(1050))
	testing.expect_value(t, window.producer.output_underrun_frames, u64(2))
	testing.expect_value(t, window.producer.output_underrun_events, u64(1))
	testing.expect_value(t, window.producer.native_pcm_starvation_frames, u64(3))
	testing.expect_value(t, window.producer.vga_io_writes, u64(3))
	testing.expect_value(t, window.producer.vga_io_write_bytes, u64(6))
	testing.expect_value(t, window.producer.gsw_control_writes, u64(2))
	testing.expect_value(t, window.producer.gsw_control_write_bytes, u64(8))
	testing.expect_value(t, window.host_gpu.sdl_gpu_submission_calls, u64(2))
	testing.expect_value(t, window.host_gpu.sdl_gpu_submission_failures, u64(1))
	testing.expect_value(t, window.host_gpu.sdl_gpu_submission_ns, u64(260))
	testing.expect_value(t, window.host_gpu.sdl_gpu_latest_submission_ns, u64(200))
	testing.expect_value(t, window.host_gpu.sdl_gpu_fence_submissions, u64(2))
	testing.expect_value(t, window.host_gpu.sdl_gpu_fence_completions, u64(3))
	testing.expect_value(t, window.host_gpu.sdl_gpu_fence_completion_ns, u64(100))
	testing.expect_value(t, window.host_gpu.sdl_gpu_fence_capacity_waits, u64(1))
	testing.expect_value(t, window.host_gpu.sdl_gpu_fence_capacity_wait_ns, u64(250))
	testing.expect_value(t, window.host_gpu.sdl_gpu_latest_submission_token, u64(42))
	testing.expect_value(t, window.host_gpu.sdl_gpu_latest_completion_token, u64(41))
	testing.expect_value(t, window.host_gpu.sdl_gpu_latest_completion_duration_ns, u64(30))
	testing.expect(t, window.host_gpu.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, window.host_gpu.direct_present_latest_draw_token, u64(42))
	testing.expect_value(t, window.host_gpu.direct_present_commands, u64(2))
	testing.expect_value(t, window.host_gpu.direct_present_commands_coalesced, u64(1))
	testing.expect_value(t, window.host_gpu.resident_gpu_surface_bytes_current, u64(8192))
	testing.expect_value(t, window.capture_ns, u64(100))
	testing.expect_value(t, window.queue_ns, u64(100))
	testing.expect_value(t, window.render_ns, u64(200))
	testing.expect_value(t, window.upload_ns, u64(200))
	testing.expect_value(t, window.gpu_drain_ns, u64(100))
	testing.expect_value(t, window.compose_ns, u64(100))
	testing.expect_value(t, window.present_ns, u64(200))
	testing.expect_value(t, window.end_to_end_ns, u64(1000))
	testing.expect_value(t, window.max_end_to_end_ns, u64(1000))
	testing.expect_value(t, window.capture_samples, u64(1))
	testing.expect_value(t, window.queue_samples, u64(1))
	testing.expect_value(t, window.render_samples, u64(1))
	testing.expect_value(t, window.upload_samples, u64(1))
	testing.expect_value(t, window.gpu_drain_samples, u64(1))
	testing.expect_value(t, window.compose_samples, u64(1))
	testing.expect_value(t, window.present_samples, u64(1))
	testing.expect_value(t, window.end_to_end_samples, u64(1))

	retained, ok := graphics_telemetry_trace_epoch(&telemetry, 0)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, retained.sequence, u64(1))
	testing.expect_value(t, retained.input_events, u64(2))
	testing.expect_value(t, retained.input_to_present_ns, u64(1050))
	testing.expect_value(t, retained.producer.output_underrun_frames, u64(2))
	testing.expect_value(t, retained.producer.output_underrun_events, u64(1))
	testing.expect_value(t, retained.producer.native_pcm_starvation_frames, u64(3))
	testing.expect_value(t, retained.host_gpu.sdl_gpu_fence_submissions, u64(2))
	testing.expect_value(t, retained.host_gpu.direct_present_surface_id, u32(23))
	snapshot := graphics_telemetry_snapshot(&telemetry, time.tick_add(started, time.Second))
	testing.expect(t, snapshot.trace_enabled)
	testing.expect_value(t, snapshot.trace_observed, u64(1))
	testing.expect_value(t, snapshot.trace_retained, u64(1))
	testing.expect_value(t, snapshot.latest.sequence, u64(1))
	text := graphics_telemetry_window_text(window)
	defer delete(text)
	testing.expect(t, strings.contains(text, "mode=640x480/rgb565"))
	testing.expect(t, strings.contains(text, "audio_underrun_frames=2"))
	testing.expect(t, strings.contains(text, "audio_underrun_events=1"))
	testing.expect(t, strings.contains(text, "native_pcm_starvation_frames=3"))
	testing.expect(t, strings.contains(text, "direct_physical_fences=2/3 completion_ns=100"))
	testing.expect(t, strings.contains(text, "direct_sdl_gpu_submissions=2/1/260ns"))
	testing.expect(t, strings.contains(text, "tracked_sdl_render_present="))
	testing.expect(t, strings.contains(text, "direct_present_commands=2"))
	testing.expect(t, strings.contains(text, "input_to_present=1/1us/1us"))
	testing.expect(t, strings.contains(text, "capacity_wait_ns=250"))
	testing.expect(t, strings.contains(text, "latest_completion=41/3/30ns/discarded:0"))
	testing.expect(t, strings.contains(text, "direct_draw=42/3/valid:1"))
	testing.expect(t, strings.contains(text, "physical_flight_0=42/3/discarded:0"))
	testing.expect(t, strings.contains(text, "vga_io_writes=3/6_bytes"))
	testing.expect(t, strings.contains(text, "gsw_control_writes=2/8_bytes"))
	trace_text := graphics_telemetry_trace_text(&telemetry)
	defer delete(trace_text)
	testing.expect(t, strings.contains(trace_text, "vga_io_writes=3/6_bytes"))
	testing.expect(t, strings.contains(trace_text, "gsw_control_writes=2/8_bytes"))
	testing.expect(t, strings.contains(trace_text, "latest_completion=41/3/30ns/discarded:0"))
	testing.expect(t, strings.contains(trace_text, "physical_flight_0=42/3/discarded:0"))
}

@(test)
graphics_telemetry_test_trace_is_opt_in_and_bounded :: proc(t: ^testing.T) {
	disabled: Graphics_Telemetry
	graphics_telemetry_init(&disabled, false)
	defer graphics_telemetry_destroy(&disabled)
	epoch := graphics_frame_epoch_begin(1, 1, time.Tick{1})
	epoch.input_events = 1
	graphics_frame_epoch_complete(&epoch, .Presented, time.Tick{2})
	epoch.input_to_present_ns = 1
	graphics_telemetry_record(&disabled, epoch)
	_, retained := graphics_telemetry_trace_epoch(&disabled, 0)
	testing.expect(t, !retained)
	disabled_correlation := graphics_telemetry_input_correlation(&disabled)
	testing.expect_value(t, disabled_correlation.samples, u64(1))
	testing.expect_value(t, disabled_correlation.retained_samples, u64(0))
	testing.expect(t, !disabled_correlation.retention_enabled)
	testing.expect(t, !disabled_correlation.retention_overflowed)
	testing.expect(t, !disabled_correlation.percentiles_valid)

	telemetry: Graphics_Telemetry
	graphics_telemetry_init(&telemetry, true)
	defer graphics_telemetry_destroy(&telemetry)
	for index in 0 ..< GRAPHICS_FRAME_TRACE_CAPACITY + 3 {
		sequence := u64(index + 1)
		item := graphics_frame_epoch_begin(sequence, sequence, time.Tick{i64(index + 1)})
		graphics_frame_epoch_complete(&item, .Coalesced, time.Tick{i64(index + 2)})
		graphics_telemetry_record(&telemetry, item)
	}
	first, first_ok := graphics_telemetry_trace_epoch(&telemetry, 0)
	last, last_ok := graphics_telemetry_trace_epoch(&telemetry, GRAPHICS_FRAME_TRACE_CAPACITY - 1)
	if !testing.expect(t, first_ok && last_ok) {return}
	testing.expect_value(t, first.sequence, u64(4))
	testing.expect_value(t, last.sequence, u64(GRAPHICS_FRAME_TRACE_CAPACITY + 3))
	_, overflow := graphics_telemetry_trace_epoch(&telemetry, GRAPHICS_FRAME_TRACE_CAPACITY)
	testing.expect(t, !overflow)
}

@(test)
graphics_telemetry_test_input_correlation_retention_outlives_trace_ring :: proc(
	t: ^testing.T,
) {
	telemetry: Graphics_Telemetry
	graphics_telemetry_init(&telemetry, true)
	defer graphics_telemetry_destroy(&telemetry)
	for index in 0 ..< GRAPHICS_INPUT_CORRELATION_CAPACITY {
		sequence := u64(index + 1)
		latency := u64(GRAPHICS_INPUT_CORRELATION_CAPACITY - index)
		epoch := graphics_frame_epoch_begin(sequence, sequence, time.Tick{i64(sequence)})
		epoch.input_events = 1
		graphics_frame_epoch_complete(&epoch, .Presented, time.Tick{i64(sequence + 1)})
		epoch.input_to_present_ns = latency
		graphics_telemetry_record(&telemetry, epoch)
	}

	snapshot := graphics_telemetry_snapshot(&telemetry, time.Tick{5000})
	testing.expect_value(t, snapshot.trace_observed, u64(4096))
	testing.expect_value(t, snapshot.trace_retained, u64(GRAPHICS_FRAME_TRACE_CAPACITY))
	correlation := graphics_telemetry_input_correlation(&telemetry)
	testing.expect_value(t, correlation.events, u64(4096))
	testing.expect_value(t, correlation.samples, u64(4096))
	testing.expect_value(t, correlation.retained_samples, u64(4096))
	testing.expect_value(t, correlation.retention_capacity, u64(4096))
	testing.expect_value(t, correlation.retention_dropped, u64(0))
	testing.expect(t, correlation.retention_enabled)
	testing.expect(t, !correlation.retention_overflowed)
	testing.expect(t, correlation.percentiles_valid)
	testing.expect_value(t, correlation.p50_ns, u64(2048))
	testing.expect_value(t, correlation.p95_ns, u64(3892))
	testing.expect_value(t, correlation.p99_ns, u64(4056))
	testing.expect_value(t, correlation.max_ns, u64(4096))
	testing.expect_value(t, telemetry.input_correlation_latencies[0], u64(4096))
	testing.expect_value(t, telemetry.input_correlation_latencies[4095], u64(1))

	overflow := graphics_frame_epoch_begin(4097, 4097, time.Tick{4097})
	overflow.input_events = 1
	graphics_frame_epoch_complete(&overflow, .Presented, time.Tick{4098})
	overflow.input_to_present_ns = 4097
	graphics_telemetry_record(&telemetry, overflow)
	correlation = graphics_telemetry_input_correlation(&telemetry)
	testing.expect_value(t, correlation.samples, u64(4097))
	testing.expect_value(t, correlation.retained_samples, u64(4096))
	testing.expect_value(t, correlation.retention_dropped, u64(1))
	testing.expect(t, correlation.retention_overflowed)
	testing.expect(t, !correlation.percentiles_valid)
	testing.expect_value(t, correlation.p50_ns, u64(0))
	testing.expect_value(t, correlation.p95_ns, u64(0))
	testing.expect_value(t, correlation.p99_ns, u64(0))
	testing.expect_value(t, correlation.max_ns, u64(4097))

	telemetry.input_correlation_dropped = max(u64)
	graphics_telemetry_record(&telemetry, {
		sequence = 4098,
		result = .Presented,
		completed = time.Tick{4099},
		input_events = 1,
		input_to_present_ns = 4098,
	})
	testing.expect_value(t, telemetry.input_correlation_dropped, max(u64))
}

@(test)
graphics_telemetry_test_trace_cursor_rotates_after_observed_count_saturates :: proc(
	t: ^testing.T,
) {
	telemetry: Graphics_Telemetry
	graphics_telemetry_init(&telemetry, true)
	defer graphics_telemetry_destroy(&telemetry)
	telemetry.trace_count = max(u64) - 1
	telemetry.trace_cursor = GRAPHICS_FRAME_TRACE_CAPACITY - 2
	for sequence in u64(100) ..= 102 {
		epoch := graphics_frame_epoch_begin(sequence, sequence, time.Tick{i64(sequence)})
		graphics_frame_epoch_complete(&epoch, .Coalesced, time.Tick{i64(sequence + 1)})
		graphics_telemetry_record(&telemetry, epoch)
	}

	testing.expect_value(t, telemetry.trace_count, max(u64))
	testing.expect_value(t, telemetry.trace_cursor, 1)
	expected_sequences := [3]u64{100, 101, 102}
	for expected, offset in expected_sequences {
		index := u64(GRAPHICS_FRAME_TRACE_CAPACITY - 3 + offset)
		epoch, ok := graphics_telemetry_trace_epoch(&telemetry, index)
		if testing.expect(t, ok) {testing.expect_value(t, epoch.sequence, expected)}
	}
	snapshot := graphics_telemetry_snapshot(&telemetry, time.Tick{200})
	testing.expect_value(t, snapshot.trace_observed, max(u64))
	testing.expect_value(t, snapshot.trace_retained, u64(GRAPHICS_FRAME_TRACE_CAPACITY))
}

@(test)
graphics_telemetry_test_one_second_window_is_delivered_once :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	defer graphics_telemetry_destroy(&telemetry)
	graphics_telemetry_note_publish_attempt(&telemetry, time.Tick{10})
	graphics_telemetry_note_unchanged(&telemetry, time.Tick{11})
	graphics_telemetry_note_blocked(&telemetry, time.Tick{12})
	window, ready := graphics_telemetry_take_window(
		&telemetry,
		time.tick_add(time.Tick{10}, time.Second),
	)
	if !testing.expect(t, ready) {return}
	testing.expect_value(t, window.publish_attempts, u64(1))
	testing.expect_value(t, window.unchanged_attempts, u64(1))
	testing.expect_value(t, window.blocked_attempts, u64(1))
	_, repeated := graphics_telemetry_take_window(
		&telemetry,
		time.tick_add(time.Tick{10}, time.Second),
	)
	testing.expect(t, !repeated)
}

@(test)
graphics_telemetry_test_window_tracks_first_and_latest_completed_epochs :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	first := graphics_frame_epoch_begin(7, 1, time.Tick{10})
	graphics_frame_epoch_complete(&first, .Coalesced, time.Tick{11})
	graphics_telemetry_record(&telemetry, first)
	last := graphics_frame_epoch_begin(9, 1, time.Tick{12})
	graphics_frame_epoch_complete(&last, .Presented, time.Tick{13})
	graphics_telemetry_record(&telemetry, last)

	testing.expect_value(t, telemetry.current.first_epoch, u64(7))
	testing.expect_value(t, telemetry.current.latest_epoch, u64(9))
	testing.expect_value(t, telemetry.current.epochs, u64(2))
}

@(test)
graphics_telemetry_test_epoch_range_resets_on_window_rollover :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	started := time.Tick{100}
	graphics_telemetry_note_publish_attempt(&telemetry, started)
	first := graphics_frame_epoch_begin(11, 1, started)
	graphics_frame_epoch_complete(&first, .Presented, time.Tick{101})
	graphics_telemetry_record(&telemetry, first)

	window, ready := graphics_telemetry_take_window(
		&telemetry,
		time.tick_add(started, time.Second),
	)
	if !testing.expect(t, ready) {return}
	testing.expect_value(t, window.sequence, u64(1))
	testing.expect_value(t, window.first_epoch, u64(11))
	testing.expect_value(t, window.latest_epoch, u64(11))
	testing.expect_value(t, telemetry.current.first_epoch, u64(0))
	testing.expect_value(t, telemetry.current.latest_epoch, u64(0))

	second := graphics_frame_epoch_begin(12, 1, time.tick_add(started, time.Second + 1))
	graphics_frame_epoch_complete(
		&second,
		.Presented,
		time.tick_add(started, time.Second + 2),
	)
	graphics_telemetry_record(&telemetry, second)
	testing.expect_value(t, telemetry.current.first_epoch, u64(12))
	testing.expect_value(t, telemetry.current.latest_epoch, u64(12))

	window, ready = graphics_telemetry_take_window(
		&telemetry,
		time.tick_add(started, 2 * time.Second),
	)
	if !testing.expect(t, ready) {return}
	testing.expect_value(t, window.sequence, u64(2))
	testing.expect_value(t, window.first_epoch, u64(12))
	testing.expect_value(t, window.latest_epoch, u64(12))
}

@(test)
graphics_telemetry_test_no_epoch_window_has_zero_epoch_range :: proc(t: ^testing.T) {
	telemetry: Graphics_Telemetry
	started := time.Tick{10}
	graphics_telemetry_note_publish_attempt(&telemetry, started)
	window, ready := graphics_telemetry_take_window(
		&telemetry,
		time.tick_add(started, time.Second),
	)
	if !testing.expect(t, ready) {return}
	testing.expect_value(t, window.epochs, u64(0))
	testing.expect_value(t, window.first_epoch, u64(0))
	testing.expect_value(t, window.latest_epoch, u64(0))
}

@(test)
graphics_telemetry_test_window_text_formats_epoch_range :: proc(t: ^testing.T) {
	started := time.Tick{10}
	window := Graphics_Telemetry_Window {
		sequence     = 17,
		started      = started,
		ended        = time.tick_add(started, time.Second),
		first_epoch  = 23,
		latest_epoch = 29,
	}
	text := graphics_telemetry_window_text(window)
	defer delete(text)
	testing.expect(
		t,
		strings.has_prefix(
			text,
			"graphics/s window=1000ms window_sequence=17 first_epoch=23 latest_epoch=29 attempts=0",
		),
	)
}
