// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:testing"
import "core:time"
import host "../host"

@(test)
graphics_host_gpu_test_interval_tracks_physical_fences_and_present_coalescing :: proc(
	t: ^testing.T,
) {
	previous := host.Host_Gsw3d_Observability_Snapshot {
		device_generation = 4,
		sdl_gpu_submission_calls = 10,
		sdl_gpu_submission_failures = 1,
		sdl_gpu_submission_ns = 1000,
		sdl_gpu_fence_submissions = 10,
		sdl_gpu_fence_completions = 8,
		sdl_gpu_fence_completion_ns = 800,
		sdl_gpu_fence_capacity_waits = 1,
		sdl_gpu_fence_capacity_wait_ns = 100,
		sdl_gpu_fence_in_flight = 2,
		sdl_gpu_fence_max_in_flight = 2,
		direct_presents = 5,
		resident_gpu_surface_bytes = 4096,
		presentation = {
			legacy_full_updates = 2,
			gsw_snapshot_full_updates = 1,
			gsw_snapshot_partial_updates = 2,
			copy_bytes = 100,
			conversion_pixels = 25,
			upload_bytes = 100,
			upload_regions = 2,
			stale_generation_drops = 1,
			stale_finalization_drops = 1,
			invalid_rejections = 2,
			closed_rejections = 3,
			readback_requests = 1,
			readback_bytes = 16,
			resource_reuses = 2,
			resource_recreations = 1,
			resource_retirements = 1,
			full_fallback_uploads = 1,
			overlay_invalidated_regions = 2,
			overlay_full_invalidations = 1,
			source_full_initial = 1,
			source_full_mode = 2,
			source_full_ambiguous = 1,
			source_full_capacity = 1,
			source_full_external = 1,
		},
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
	current.presentation = {
		legacy_full_updates          = 4,
		legacy_partial_updates       = 1,
		gsw_snapshot_full_updates    = 4,
		gsw_snapshot_partial_updates = 3,
		copy_bytes                   = 300,
		conversion_pixels            = 75,
		upload_bytes                 = 300,
		upload_regions               = 5,
		stale_generation_drops       = 3,
		stale_finalization_drops     = 2,
		invalid_rejections           = 5,
		closed_rejections            = 7,
		resident_presents            = 2,
		readback_requests            = 2,
		readback_bytes               = 40,
		last_good_restorations       = 1,
		resource_reuses              = 5,
		resource_recreations         = 3,
		resource_retirements         = 2,
		full_fallback_uploads        = 4,
		overlay_invalidated_regions  = 7,
		overlay_full_invalidations   = 2,
		source_full_initial          = 2,
		source_full_mode             = 4,
		source_full_ambiguous        = 3,
		source_full_capacity         = 5,
		source_full_external         = 2,
	}

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
	testing.expect_value(t, interval.presentation.legacy_full_updates, u64(2))
	testing.expect_value(t, interval.presentation.legacy_partial_updates, u64(1))
	testing.expect_value(t, interval.presentation.gsw_snapshot_full_updates, u64(3))
	testing.expect_value(t, interval.presentation.gsw_snapshot_partial_updates, u64(1))
	testing.expect_value(t, interval.presentation.copy_bytes, u64(200))
	testing.expect_value(t, interval.presentation.conversion_pixels, u64(50))
	testing.expect_value(t, interval.presentation.upload_bytes, u64(200))
	testing.expect_value(t, interval.presentation.upload_regions, u64(3))
	testing.expect_value(t, interval.presentation.stale_generation_drops, u64(2))
	testing.expect_value(t, interval.presentation.stale_finalization_drops, u64(1))
	testing.expect_value(t, interval.presentation.invalid_rejections, u64(3))
	testing.expect_value(t, interval.presentation.closed_rejections, u64(4))
	testing.expect_value(t, interval.presentation.resident_presents, u64(2))
	testing.expect_value(t, interval.presentation.readback_requests, u64(1))
	testing.expect_value(t, interval.presentation.readback_bytes, u64(24))
	testing.expect_value(t, interval.presentation.last_good_restorations, u64(1))
	testing.expect_value(t, interval.presentation.resource_reuses, u64(3))
	testing.expect_value(t, interval.presentation.resource_recreations, u64(2))
	testing.expect_value(t, interval.presentation.resource_retirements, u64(1))
	testing.expect_value(t, interval.presentation.full_fallback_uploads, u64(3))
	testing.expect_value(t, interval.presentation.overlay_invalidated_regions, u64(5))
	testing.expect_value(t, interval.presentation.overlay_full_invalidations, u64(1))
	testing.expect_value(t, interval.presentation.source_full_initial, u64(1))
	testing.expect_value(t, interval.presentation.source_full_mode, u64(2))
	testing.expect_value(t, interval.presentation.source_full_ambiguous, u64(2))
	testing.expect_value(t, interval.presentation.source_full_capacity, u64(4))
	testing.expect_value(t, interval.presentation.source_full_external, u64(1))
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
		sdl_gpu_fence_submissions = max(u64) - 1,
		sdl_gpu_fence_completion_ns = max(u64) - 1,
		resident_gpu_surface_bytes_peak = 4096,
		presentation = {
			upload_regions = max(u64) - 1,
			readback_bytes = max(u64) - 1,
			resource_reuses = max(u64) - 1,
			resource_recreations = max(u64) - 1,
			resource_retirements = max(u64) - 1,
			full_fallback_uploads = max(u64) - 1,
			overlay_invalidated_regions = max(u64) - 1,
			overlay_full_invalidations = max(u64) - 1,
			source_full_capacity = max(u64) - 1,
		},
	}
	interval.sdl_gpu_fence_completion_ns = 600
	interval.presentation.upload_regions = 600
	interval.presentation.readback_bytes = 600
	interval.presentation.resource_reuses = 600
	interval.presentation.resource_recreations = 600
	interval.presentation.resource_retirements = 600
	interval.presentation.full_fallback_uploads = 600
	interval.presentation.overlay_invalidated_regions = 600
	interval.presentation.overlay_full_invalidations = 600
	interval.presentation.source_full_capacity = 600
	graphics_host_gpu_interval_add(&total, interval)
	testing.expect(t, total.valid)
	testing.expect_value(t, total.sdl_gpu_fence_submissions, max(u64))
	testing.expect_value(t, total.sdl_gpu_fence_completion_ns, max(u64))
	testing.expect_value(t, total.direct_present_deactivations, u64(1))
	testing.expect_value(t, total.sdl_gpu_fence_in_flight_current, u32(1))
	testing.expect_value(t, total.sdl_gpu_fence_in_flight_sampled_peak, u32(1))
	testing.expect_value(t, total.resident_gpu_surface_bytes_peak, u64(4096))
	testing.expect_value(t, total.presentation.upload_regions, max(u64))
	testing.expect_value(t, total.presentation.readback_bytes, max(u64))
	testing.expect_value(t, total.presentation.resource_reuses, max(u64))
	testing.expect_value(t, total.presentation.resource_recreations, max(u64))
	testing.expect_value(t, total.presentation.resource_retirements, max(u64))
	testing.expect_value(t, total.presentation.full_fallback_uploads, max(u64))
	testing.expect_value(t, total.presentation.overlay_invalidated_regions, max(u64))
	testing.expect_value(t, total.presentation.overlay_full_invalidations, max(u64))
	testing.expect_value(t, total.presentation.source_full_capacity, max(u64))
}
