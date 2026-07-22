// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:time"

graphics_presentation_test_observation :: proc(
	host_gpu: Graphics_Host_Gpu_Interval,
	executed := 0,
	failed := 0,
) -> Graphics_Presentation_Drain_Observation {
	return {
		started = time.Tick{100},
		ended = time.Tick{200},
		executed = executed,
		failed = failed,
		budget = u64(max(executed + failed, 0)) * 16,
		host_gpu = host_gpu,
	}
}

@(test)
graphics_presentation_test_legacy_only_retains_source_and_drain :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	legacy := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{50})
	legacy.source = .Legacy_Scanout
	selection := graphics_presentation_select(
		&mailbox,
		legacy,
		true,
		graphics_presentation_test_observation({}, 2),
	)
	testing.expect(t, selection.active)
	testing.expect_value(t, selection.active_epoch.source, Graphics_Frame_Source.Legacy_Scanout)
	testing.expect_value(t, selection.active_epoch.gpu_requests, u64(2))
	testing.expect(t, !selection.has_terminal)
}

@(test)
graphics_presentation_test_direct_only_and_multiple_presents_select_latest_surface :: proc(
	t: ^testing.T,
) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	g := Graphics_Host_Gpu_Interval {
		valid                             = true,
		direct_present_commands           = 3,
		direct_present_commands_coalesced = 2,
		direct_present_active             = true,
		direct_present_surface_id         = 23,
		direct_present_canvas_width       = 800,
		direct_present_canvas_height      = 600,
	}
	graphics_host_gpu_interval_add(&mailbox.telemetry.pending_host_gpu, g)
	selection := graphics_presentation_select(
		&mailbox,
		{},
		false,
		graphics_presentation_test_observation(g, 3),
	)
	testing.expect(t, selection.active)
	testing.expect_value(t, selection.active_epoch.source, Graphics_Frame_Source.Gsw3d)
	testing.expect_value(t, selection.active_epoch.width, 800)
	testing.expect_value(t, selection.active_epoch.height, 600)
	testing.expect_value(t, selection.active_epoch.host_gpu.direct_present_commands, u64(3))
	testing.expect_value(
		t,
		selection.active_epoch.host_gpu.direct_present_commands_coalesced,
		u64(2),
	)
}

@(test)
graphics_presentation_test_direct_supersedes_legacy_without_stale_gauges :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	legacy := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{50})
	legacy.source = .Legacy_Scanout
	legacy.producer = {
		valid                     = true,
		device_generation         = 4,
		gsw3d_queue_depth_current = 1,
	}
	g := Graphics_Host_Gpu_Interval {
		valid                        = true,
		device_generation            = 5,
		direct_present_commands      = 1,
		direct_present_active        = true,
		direct_present_surface_id    = 23,
		direct_present_canvas_width  = 640,
		direct_present_canvas_height = 480,
	}
	graphics_host_gpu_interval_add(&mailbox.telemetry.pending_host_gpu, g)
	selection := graphics_presentation_select(
		&mailbox,
		legacy,
		true,
		graphics_presentation_test_observation(g, 1),
	)
	testing.expect(t, selection.active)
	testing.expect_value(t, selection.active_epoch.source, Graphics_Frame_Source.Gsw3d)
	testing.expect_value(t, selection.active_epoch.host_gpu.device_generation, u64(5))
	testing.expect_value(t, selection.active_epoch.producer.device_generation, u64(4))
	trace, ok := graphics_telemetry_trace_epoch(&mailbox.telemetry, 0)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, trace.result, Graphics_Frame_Result.Superseded)
}

@(test)
graphics_presentation_test_reset_and_failed_nonvisual_work_are_terminal :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	reset_gpu := Graphics_Host_Gpu_Interval {
		valid                   = true,
		direct_present_commands = 1,
	}
	reset := graphics_presentation_select(
		&mailbox,
		{},
		false,
		graphics_presentation_test_observation(reset_gpu, 1),
	)
	testing.expect(t, !reset.active && reset.has_terminal)
	testing.expect_value(t, reset.terminal_epoch.result, Graphics_Frame_Result.Reset)

	failed := graphics_presentation_select(
		&mailbox,
		{},
		false,
		graphics_presentation_test_observation({}, 0, 1),
	)
	testing.expect(t, !failed.active && failed.has_terminal)
	testing.expect_value(t, failed.terminal_epoch.result, Graphics_Frame_Result.Gpu_Work)
	testing.expect_value(t, failed.terminal_epoch.gpu_failures, u64(1))
}

@(test)
graphics_presentation_test_direct_reset_drains_pending_host_gpu_once :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	pending := Graphics_Host_Gpu_Interval {
		valid                     = true,
		device_generation         = 7,
		sdl_gpu_fence_submissions = 2,
		direct_present_commands   = 1,
	}
	graphics_host_gpu_interval_add(&mailbox.telemetry.pending_host_gpu, pending)
	selection := graphics_presentation_select(
		&mailbox,
		{},
		false,
		graphics_presentation_test_observation(pending, 1),
	)
	if !testing.expect(t, !selection.active && selection.has_terminal) {return}
	testing.expect_value(t, selection.terminal_epoch.result, Graphics_Frame_Result.Reset)
	testing.expect_value(t, selection.terminal_epoch.host_gpu.device_generation, u64(7))
	testing.expect_value(t, selection.terminal_epoch.host_gpu.sdl_gpu_fence_submissions, u64(2))
	testing.expect_value(t, mailbox.telemetry.pending_host_gpu, Graphics_Host_Gpu_Interval{})
	next := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{300})
	testing.expect_value(t, next.host_gpu, Graphics_Host_Gpu_Interval{})
}

@(test)
graphics_presentation_test_standalone_work_drains_pending_host_gpu_once :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	pending := Graphics_Host_Gpu_Interval {
		valid                     = true,
		device_generation         = 8,
		sdl_gpu_fence_completions = 3,
	}
	graphics_host_gpu_interval_add(&mailbox.telemetry.pending_host_gpu, pending)
	selection := graphics_presentation_select(
		&mailbox,
		{},
		false,
		graphics_presentation_test_observation(pending),
	)
	if !testing.expect(t, !selection.active && selection.has_terminal) {return}
	testing.expect_value(t, selection.terminal_epoch.result, Graphics_Frame_Result.Gpu_Work)
	testing.expect_value(t, selection.terminal_epoch.host_gpu.device_generation, u64(8))
	testing.expect_value(t, selection.terminal_epoch.host_gpu.sdl_gpu_fence_completions, u64(3))
	testing.expect_value(t, mailbox.telemetry.pending_host_gpu, Graphics_Host_Gpu_Interval{})
	next := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{300})
	testing.expect_value(t, next.host_gpu, Graphics_Host_Gpu_Interval{})
}

@(test)
graphics_presentation_test_direct_deactivation_without_command_is_reset :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	frame_mailbox_graphics_telemetry_init(&mailbox, true)
	active := frame_mailbox_graphics_telemetry_begin_host_epoch(&mailbox, time.Tick{50})
	active.source = .Gsw3d
	deactivated := Graphics_Host_Gpu_Interval {
		valid                        = true,
		direct_present_deactivations = 1,
	}
	graphics_host_gpu_interval_add(&mailbox.telemetry.pending_host_gpu, deactivated)
	selection := graphics_presentation_select(
		&mailbox,
		active,
		true,
		graphics_presentation_test_observation(deactivated),
	)

	testing.expect_value(t, deactivated.direct_present_commands, u64(0))
	testing.expect(t, !selection.active && selection.has_terminal)
	testing.expect_value(t, selection.terminal_epoch.sequence, active.sequence)
	testing.expect_value(t, selection.terminal_epoch.result, Graphics_Frame_Result.Reset)
	testing.expect_value(t, selection.terminal_epoch.host_gpu.direct_present_deactivations, u64(1))
	testing.expect_value(t, mailbox.telemetry.trace_count, u64(1))
}
