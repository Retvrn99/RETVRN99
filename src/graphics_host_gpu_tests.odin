// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:time"
import host "host"

@(test)
graphics_host_gpu_test_interval_tracks_physical_fences_and_present_coalescing :: proc(
	t: ^testing.T,
) {
	previous := host.Host_Gsw3d_Observability_Snapshot {
		device_generation              = 4,
		sdl_gpu_submission_calls       = 10,
		sdl_gpu_submission_failures    = 1,
		sdl_gpu_submission_ns          = 1000,
		sdl_gpu_fence_submissions      = 10,
		sdl_gpu_fence_completions      = 8,
		sdl_gpu_fence_completion_ns    = 800,
		sdl_gpu_fence_capacity_waits   = 1,
		sdl_gpu_fence_capacity_wait_ns = 100,
		sdl_gpu_fence_in_flight        = 2,
		sdl_gpu_fence_max_in_flight    = 2,
		direct_presents                = 5,
		resident_gpu_surface_bytes     = 4096,
	}
	current := previous
	current.device_generation = 5
	current.sdl_gpu_submission_calls = 13
	current.sdl_gpu_submission_failures = 2
	current.sdl_gpu_submission_ns = 1600
	current.sdl_gpu_latest_submission_ns = 250
	current.sdl_gpu_fence_submissions = 13
	current.sdl_gpu_fence_completions = 11
	current.sdl_gpu_fence_completion_ns = 1400
	current.sdl_gpu_fence_capacity_waits = 2
	current.sdl_gpu_fence_capacity_wait_ns = 350
	current.sdl_gpu_fence_latest_capacity_wait_ns = 250
	current.sdl_gpu_fence_in_flight = 1
	current.sdl_gpu_flights[0] = {
		valid       = true,
		submit_tick = time.Tick{100},
		token       = 41,
		generation  = 5,
	}
	current.sdl_gpu_latest_submission_tick = time.Tick{100}
	current.sdl_gpu_latest_submission_token = 41
	current.sdl_gpu_latest_submission_generation = 5
	current.sdl_gpu_latest_completion_submit_tick = time.Tick{50}
	current.sdl_gpu_latest_completion_observed_tick = time.Tick{90}
	current.sdl_gpu_latest_completion_token = 40
	current.sdl_gpu_latest_completion_generation = 5
	current.sdl_gpu_latest_completion_duration_ns = 40
	current.direct_presents = 8
	current.direct_present_active = true
	current.direct_present_surface_id = 23
	current.direct_present_surface_width = 640
	current.direct_present_surface_height = 480
	current.direct_present_canvas_width = 800
	current.direct_present_canvas_height = 600
	current.direct_present_interval = 1
	current.direct_present_latest_draw_fence_valid = true
	current.direct_present_latest_draw_submit_tick = time.Tick{100}
	current.direct_present_latest_draw_token = 41
	current.direct_present_latest_draw_generation = 5
	current.resident_gpu_surface_bytes = 8192

	interval := graphics_host_gpu_interval(current, previous, true)
	testing.expect(t, interval.valid)
	testing.expect_value(t, interval.generation_changes, u64(1))
	testing.expect_value(t, interval.sdl_gpu_submission_calls, u64(3))
	testing.expect_value(t, interval.sdl_gpu_submission_failures, u64(1))
	testing.expect_value(t, interval.sdl_gpu_submission_ns, u64(600))
	testing.expect_value(t, interval.sdl_gpu_latest_submission_ns, u64(250))
	testing.expect_value(t, interval.sdl_gpu_fence_submissions, u64(3))
	testing.expect_value(t, interval.sdl_gpu_fence_completions, u64(3))
	testing.expect_value(t, interval.sdl_gpu_fence_completion_ns, u64(600))
	testing.expect_value(t, interval.sdl_gpu_fence_capacity_waits, u64(1))
	testing.expect_value(t, interval.sdl_gpu_fence_capacity_wait_ns, u64(250))
	testing.expect_value(t, interval.sdl_gpu_fence_latest_capacity_wait_ns, u64(250))
	testing.expect_value(t, interval.sdl_gpu_flights[0].token, u64(41))
	testing.expect_value(t, interval.sdl_gpu_latest_submission_token, u64(41))
	testing.expect_value(t, interval.sdl_gpu_latest_completion_token, u64(40))
	testing.expect_value(t, interval.sdl_gpu_latest_completion_duration_ns, u64(40))
	testing.expect_value(t, interval.sdl_gpu_fence_in_flight_current, u32(1))
	testing.expect_value(t, interval.sdl_gpu_fence_in_flight_sampled_peak, u32(1))
	testing.expect_value(t, interval.sdl_gpu_fence_max_in_flight, u32(2))
	testing.expect_value(t, interval.direct_present_commands, u64(3))
	testing.expect_value(t, interval.direct_present_commands_coalesced, u64(2))
	testing.expect(t, interval.direct_present_active)
	testing.expect_value(t, interval.direct_present_surface_id, u32(23))
	testing.expect_value(t, interval.direct_present_surface_width, u32(640))
	testing.expect_value(t, interval.direct_present_surface_height, u32(480))
	testing.expect_value(t, interval.direct_present_canvas_width, u32(800))
	testing.expect_value(t, interval.direct_present_canvas_height, u32(600))
	testing.expect_value(t, interval.direct_present_interval, u32(1))
	testing.expect(t, interval.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, interval.direct_present_latest_draw_token, u64(41))
	testing.expect_value(t, interval.direct_present_latest_draw_generation, u64(5))
	testing.expect_value(t, interval.resident_gpu_surface_bytes_current, u64(8192))
}

@(test)
graphics_host_gpu_test_reset_and_addition_are_explicit_and_bounded :: proc(t: ^testing.T) {
	previous := host.Host_Gsw3d_Observability_Snapshot {
		sdl_gpu_fence_submissions = 9,
		direct_present_active     = true,
	}
	current := host.Host_Gsw3d_Observability_Snapshot {
		sdl_gpu_fence_submissions  = 2,
		sdl_gpu_fence_in_flight    = 1,
		resident_gpu_surface_bytes = 2048,
	}
	interval := graphics_host_gpu_interval(current, previous, true)
	testing.expect_value(t, interval.counter_resets, u64(1))
	testing.expect_value(t, interval.sdl_gpu_fence_submissions, u64(2))
	testing.expect_value(t, interval.direct_present_deactivations, u64(1))

	total := Graphics_Host_Gpu_Interval {
		sdl_gpu_fence_submissions       = max(u64) - 1,
		sdl_gpu_fence_completion_ns     = max(u64) - 1,
		resident_gpu_surface_bytes_peak = 4096,
	}
	interval.sdl_gpu_fence_completion_ns = 600
	graphics_host_gpu_interval_add(&total, interval)
	testing.expect(t, total.valid)
	testing.expect_value(t, total.sdl_gpu_fence_submissions, max(u64))
	testing.expect_value(t, total.sdl_gpu_fence_completion_ns, max(u64))
	testing.expect_value(t, total.direct_present_deactivations, u64(1))
	testing.expect_value(t, total.sdl_gpu_fence_in_flight_current, u32(1))
	testing.expect_value(t, total.sdl_gpu_fence_in_flight_sampled_peak, u32(1))
	testing.expect_value(t, total.resident_gpu_surface_bytes_peak, u64(4096))
}
