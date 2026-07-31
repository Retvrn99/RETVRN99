// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:time"
import host "../host"

Graphics_Host_Gpu_Interval :: struct {
	valid:                                   bool,
	samples:                                 u64,
	counter_resets:                          u64,
	generation_changes:                      u64,
	device_generation:                       u64,
	sdl_gpu_submission_calls:                u64,
	sdl_gpu_submission_failures:             u64,
	sdl_gpu_submission_ns:                   u64,
	sdl_gpu_latest_submission_ns:            u64,
	sdl_gpu_fence_submissions:               u64,
	sdl_gpu_fence_completions:               u64,
	sdl_gpu_fence_completion_ns:             u64,
	sdl_gpu_fence_capacity_waits:            u64,
	sdl_gpu_fence_capacity_wait_ns:          u64,
	sdl_gpu_fence_latest_capacity_wait_ns:   u64,
	sdl_gpu_fence_in_flight_current:         u32,
	sdl_gpu_fence_in_flight_sampled_peak:    u32,
	sdl_gpu_fence_max_in_flight:             u32,
	sdl_gpu_flights:                         [host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]host.Host_Gsw3d_Physical_Flight_Snapshot,
	sdl_gpu_latest_submission_tick:          time.Tick,
	sdl_gpu_latest_submission_token:         u64,
	sdl_gpu_latest_submission_generation:    u64,
	sdl_gpu_latest_completion_submit_tick:   time.Tick,
	sdl_gpu_latest_completion_observed_tick: time.Tick,
	sdl_gpu_latest_completion_token:         u64,
	sdl_gpu_latest_completion_generation:    u64,
	sdl_gpu_latest_completion_duration_ns:   u64,
	sdl_gpu_latest_completion_discarded:     bool,
	direct_present_commands:                 u64,
	direct_present_commands_coalesced:       u64,
	direct_present_deactivations:            u64,
	direct_present_active:                   bool,
	direct_present_surface_id:               u32,
	direct_present_surface_width:            u32,
	direct_present_surface_height:           u32,
	direct_present_canvas_width:             u32,
	direct_present_canvas_height:            u32,
	direct_present_interval:                 u32,
	direct_present_latest_draw_fence_valid:  bool,
	direct_present_latest_draw_submit_tick:  time.Tick,
	direct_present_latest_draw_token:        u64,
	direct_present_latest_draw_generation:   u64,
	resident_gpu_surface_bytes_current:      u64,
	resident_gpu_surface_bytes_peak:         u64,
	presentation:                            host.Host_Presentation_Metrics,
}

@(private = "file")
graphics_host_presentation_interval :: proc(
	current, previous: host.Host_Presentation_Metrics,
) -> (
	host.Host_Presentation_Metrics,
	bool,
) {
	result: host.Host_Presentation_Metrics
	reset := false
	delta: u64
	wrapped: bool
	delta, wrapped = graphics_counter_delta(
		current.legacy_full_updates,
		previous.legacy_full_updates,
	)
	result.legacy_full_updates = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.legacy_partial_updates,
		previous.legacy_partial_updates,
	)
	result.legacy_partial_updates = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.gsw_snapshot_full_updates,
		previous.gsw_snapshot_full_updates,
	)
	result.gsw_snapshot_full_updates = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.gsw_snapshot_partial_updates,
		previous.gsw_snapshot_partial_updates,
	)
	result.gsw_snapshot_partial_updates = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.copy_bytes, previous.copy_bytes)
	result.copy_bytes = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.conversion_pixels, previous.conversion_pixels)
	result.conversion_pixels = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.upload_bytes, previous.upload_bytes)
	result.upload_bytes = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.upload_regions, previous.upload_regions)
	result.upload_regions = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.stale_generation_drops,
		previous.stale_generation_drops,
	)
	result.stale_generation_drops = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.stale_finalization_drops,
		previous.stale_finalization_drops,
	)
	result.stale_finalization_drops = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.invalid_rejections,
		previous.invalid_rejections,
	)
	result.invalid_rejections = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.closed_rejections, previous.closed_rejections)
	result.closed_rejections = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.resident_presents, previous.resident_presents)
	result.resident_presents = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.readback_requests, previous.readback_requests)
	result.readback_requests = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.readback_bytes, previous.readback_bytes)
	result.readback_bytes = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.last_good_restorations,
		previous.last_good_restorations,
	)
	result.last_good_restorations = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.resource_reuses, previous.resource_reuses)
	result.resource_reuses = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.resource_recreations,
		previous.resource_recreations,
	)
	result.resource_recreations = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.resource_retirements,
		previous.resource_retirements,
	)
	result.resource_retirements = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.full_fallback_uploads,
		previous.full_fallback_uploads,
	)
	result.full_fallback_uploads = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.overlay_invalidated_regions,
		previous.overlay_invalidated_regions,
	)
	result.overlay_invalidated_regions = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.overlay_full_invalidations,
		previous.overlay_full_invalidations,
	)
	result.overlay_full_invalidations = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.source_full_initial,
		previous.source_full_initial,
	)
	result.source_full_initial = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.source_full_mode, previous.source_full_mode)
	result.source_full_mode = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.source_full_ambiguous,
		previous.source_full_ambiguous,
	)
	result.source_full_ambiguous = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.source_full_capacity,
		previous.source_full_capacity,
	)
	result.source_full_capacity = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.source_full_external,
		previous.source_full_external,
	)
	result.source_full_external = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.source_full_raster_journal,
		previous.source_full_raster_journal,
	)
	result.source_full_raster_journal = delta
	reset = reset || wrapped
	return result, reset
}

@(private = "file")
graphics_host_presentation_interval_add :: proc(
	target: ^host.Host_Presentation_Metrics,
	addition: host.Host_Presentation_Metrics,
) {
	if target == nil {return}
	graphics_interval_add_counter(&target.legacy_full_updates, addition.legacy_full_updates)
	graphics_interval_add_counter(&target.legacy_partial_updates, addition.legacy_partial_updates)
	graphics_interval_add_counter(
		&target.gsw_snapshot_full_updates,
		addition.gsw_snapshot_full_updates,
	)
	graphics_interval_add_counter(
		&target.gsw_snapshot_partial_updates,
		addition.gsw_snapshot_partial_updates,
	)
	graphics_interval_add_counter(&target.copy_bytes, addition.copy_bytes)
	graphics_interval_add_counter(&target.conversion_pixels, addition.conversion_pixels)
	graphics_interval_add_counter(&target.upload_bytes, addition.upload_bytes)
	graphics_interval_add_counter(&target.upload_regions, addition.upload_regions)
	graphics_interval_add_counter(&target.stale_generation_drops, addition.stale_generation_drops)
	graphics_interval_add_counter(
		&target.stale_finalization_drops,
		addition.stale_finalization_drops,
	)
	graphics_interval_add_counter(&target.invalid_rejections, addition.invalid_rejections)
	graphics_interval_add_counter(&target.closed_rejections, addition.closed_rejections)
	graphics_interval_add_counter(&target.resident_presents, addition.resident_presents)
	graphics_interval_add_counter(&target.readback_requests, addition.readback_requests)
	graphics_interval_add_counter(&target.readback_bytes, addition.readback_bytes)
	graphics_interval_add_counter(&target.last_good_restorations, addition.last_good_restorations)
	graphics_interval_add_counter(&target.resource_reuses, addition.resource_reuses)
	graphics_interval_add_counter(&target.resource_recreations, addition.resource_recreations)
	graphics_interval_add_counter(&target.resource_retirements, addition.resource_retirements)
	graphics_interval_add_counter(&target.full_fallback_uploads, addition.full_fallback_uploads)
	graphics_interval_add_counter(
		&target.overlay_invalidated_regions,
		addition.overlay_invalidated_regions,
	)
	graphics_interval_add_counter(
		&target.overlay_full_invalidations,
		addition.overlay_full_invalidations,
	)
	graphics_interval_add_counter(&target.source_full_initial, addition.source_full_initial)
	graphics_interval_add_counter(&target.source_full_mode, addition.source_full_mode)
	graphics_interval_add_counter(&target.source_full_ambiguous, addition.source_full_ambiguous)
	graphics_interval_add_counter(&target.source_full_capacity, addition.source_full_capacity)
	graphics_interval_add_counter(&target.source_full_external, addition.source_full_external)
	graphics_interval_add_counter(
		&target.source_full_raster_journal,
		addition.source_full_raster_journal,
	)
}

@(private = "package")
graphics_host_gpu_interval :: proc(
	current: host.Host_Gsw3d_Observability_Snapshot,
	previous: host.Host_Gsw3d_Observability_Snapshot,
	previous_valid: bool,
) -> Graphics_Host_Gpu_Interval {
	result := Graphics_Host_Gpu_Interval {
		valid                                   = true,
		samples                                 = 1,
		device_generation                       = current.device_generation,
		sdl_gpu_latest_submission_ns            = current.sdl_gpu_latest_submission_ns,
		sdl_gpu_fence_in_flight_current         = current.sdl_gpu_fence_in_flight,
		sdl_gpu_fence_in_flight_sampled_peak    = current.sdl_gpu_fence_in_flight,
		sdl_gpu_fence_max_in_flight             = current.sdl_gpu_fence_max_in_flight,
		sdl_gpu_fence_latest_capacity_wait_ns   = current.sdl_gpu_fence_latest_capacity_wait_ns,
		sdl_gpu_flights                         = current.sdl_gpu_flights,
		sdl_gpu_latest_submission_tick          = current.sdl_gpu_latest_submission_tick,
		sdl_gpu_latest_submission_token         = current.sdl_gpu_latest_submission_token,
		sdl_gpu_latest_submission_generation    = current.sdl_gpu_latest_submission_generation,
		sdl_gpu_latest_completion_submit_tick   = current.sdl_gpu_latest_completion_submit_tick,
		sdl_gpu_latest_completion_observed_tick = current.sdl_gpu_latest_completion_observed_tick,
		sdl_gpu_latest_completion_token         = current.sdl_gpu_latest_completion_token,
		sdl_gpu_latest_completion_generation    = current.sdl_gpu_latest_completion_generation,
		sdl_gpu_latest_completion_duration_ns   = current.sdl_gpu_latest_completion_duration_ns,
		sdl_gpu_latest_completion_discarded     = current.sdl_gpu_latest_completion_discarded,
		direct_present_active                   = current.direct_present_active,
		direct_present_surface_id               = current.direct_present_surface_id,
		direct_present_surface_width            = current.direct_present_surface_width,
		direct_present_surface_height           = current.direct_present_surface_height,
		direct_present_canvas_width             = current.direct_present_canvas_width,
		direct_present_canvas_height            = current.direct_present_canvas_height,
		direct_present_interval                 = current.direct_present_interval,
		direct_present_latest_draw_fence_valid  = current.direct_present_latest_draw_fence_valid,
		direct_present_latest_draw_submit_tick  = current.direct_present_latest_draw_submit_tick,
		direct_present_latest_draw_token        = current.direct_present_latest_draw_token,
		direct_present_latest_draw_generation   = current.direct_present_latest_draw_generation,
		resident_gpu_surface_bytes_current      = current.resident_gpu_surface_bytes,
		resident_gpu_surface_bytes_peak         = current.resident_gpu_surface_bytes,
	}
	if !previous_valid {return result}
	if current.device_generation != previous.device_generation {
		result.generation_changes = 1
	}
	reset := false
	delta: u64
	wrapped: bool
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_submission_calls,
		previous.sdl_gpu_submission_calls,
	)
	result.sdl_gpu_submission_calls = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_submission_failures,
		previous.sdl_gpu_submission_failures,
	)
	result.sdl_gpu_submission_failures = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_submission_ns,
		previous.sdl_gpu_submission_ns,
	)
	result.sdl_gpu_submission_ns = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_fence_submissions,
		previous.sdl_gpu_fence_submissions,
	)
	result.sdl_gpu_fence_submissions = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_fence_completions,
		previous.sdl_gpu_fence_completions,
	)
	result.sdl_gpu_fence_completions = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_fence_completion_ns,
		previous.sdl_gpu_fence_completion_ns,
	)
	result.sdl_gpu_fence_completion_ns = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_fence_capacity_waits,
		previous.sdl_gpu_fence_capacity_waits,
	)
	result.sdl_gpu_fence_capacity_waits = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.sdl_gpu_fence_capacity_wait_ns,
		previous.sdl_gpu_fence_capacity_wait_ns,
	)
	result.sdl_gpu_fence_capacity_wait_ns = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.direct_presents, previous.direct_presents)
	result.direct_present_commands = delta
	if delta > 1 {result.direct_present_commands_coalesced = delta - 1}
	reset = reset || wrapped
	result.presentation, wrapped = graphics_host_presentation_interval(
		current.presentation,
		previous.presentation,
	)
	reset = reset || wrapped
	if previous.direct_present_active && !current.direct_present_active {
		result.direct_present_deactivations = 1
	}
	if reset {result.counter_resets = 1}
	return result
}

@(private = "package")
graphics_host_gpu_interval_add :: proc(
	target: ^Graphics_Host_Gpu_Interval,
	addition: Graphics_Host_Gpu_Interval,
) {
	if target == nil || !addition.valid {return}
	target.valid = true
	target.samples = graphics_counter_add(target.samples, addition.samples)
	target.counter_resets = graphics_counter_add(target.counter_resets, addition.counter_resets)
	target.generation_changes = graphics_counter_add(
		target.generation_changes,
		addition.generation_changes,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_submission_calls,
		addition.sdl_gpu_submission_calls,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_submission_failures,
		addition.sdl_gpu_submission_failures,
	)
	graphics_interval_add_counter(&target.sdl_gpu_submission_ns, addition.sdl_gpu_submission_ns)
	graphics_interval_add_counter(
		&target.sdl_gpu_fence_submissions,
		addition.sdl_gpu_fence_submissions,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_fence_completions,
		addition.sdl_gpu_fence_completions,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_fence_completion_ns,
		addition.sdl_gpu_fence_completion_ns,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_fence_capacity_waits,
		addition.sdl_gpu_fence_capacity_waits,
	)
	graphics_interval_add_counter(
		&target.sdl_gpu_fence_capacity_wait_ns,
		addition.sdl_gpu_fence_capacity_wait_ns,
	)
	graphics_interval_add_counter(
		&target.direct_present_commands,
		addition.direct_present_commands,
	)
	graphics_interval_add_counter(
		&target.direct_present_commands_coalesced,
		addition.direct_present_commands_coalesced,
	)
	graphics_interval_add_counter(
		&target.direct_present_deactivations,
		addition.direct_present_deactivations,
	)
	graphics_host_presentation_interval_add(&target.presentation, addition.presentation)
	target.device_generation = addition.device_generation
	target.sdl_gpu_latest_submission_ns = addition.sdl_gpu_latest_submission_ns
	target.sdl_gpu_fence_in_flight_current = addition.sdl_gpu_fence_in_flight_current
	target.sdl_gpu_fence_in_flight_sampled_peak = max(
		target.sdl_gpu_fence_in_flight_sampled_peak,
		addition.sdl_gpu_fence_in_flight_sampled_peak,
	)
	target.sdl_gpu_fence_max_in_flight = max(
		target.sdl_gpu_fence_max_in_flight,
		addition.sdl_gpu_fence_max_in_flight,
	)
	target.sdl_gpu_fence_latest_capacity_wait_ns = addition.sdl_gpu_fence_latest_capacity_wait_ns
	target.sdl_gpu_flights = addition.sdl_gpu_flights
	target.sdl_gpu_latest_submission_tick = addition.sdl_gpu_latest_submission_tick
	target.sdl_gpu_latest_submission_token = addition.sdl_gpu_latest_submission_token
	target.sdl_gpu_latest_submission_generation = addition.sdl_gpu_latest_submission_generation
	target.sdl_gpu_latest_completion_submit_tick = addition.sdl_gpu_latest_completion_submit_tick
	target.sdl_gpu_latest_completion_observed_tick =
		addition.sdl_gpu_latest_completion_observed_tick
	target.sdl_gpu_latest_completion_token = addition.sdl_gpu_latest_completion_token
	target.sdl_gpu_latest_completion_generation = addition.sdl_gpu_latest_completion_generation
	target.sdl_gpu_latest_completion_duration_ns = addition.sdl_gpu_latest_completion_duration_ns
	target.sdl_gpu_latest_completion_discarded = addition.sdl_gpu_latest_completion_discarded
	target.direct_present_active = addition.direct_present_active
	target.direct_present_surface_id = addition.direct_present_surface_id
	target.direct_present_surface_width = addition.direct_present_surface_width
	target.direct_present_surface_height = addition.direct_present_surface_height
	target.direct_present_canvas_width = addition.direct_present_canvas_width
	target.direct_present_canvas_height = addition.direct_present_canvas_height
	target.direct_present_interval = addition.direct_present_interval
	target.direct_present_latest_draw_fence_valid = addition.direct_present_latest_draw_fence_valid
	target.direct_present_latest_draw_submit_tick = addition.direct_present_latest_draw_submit_tick
	target.direct_present_latest_draw_token = addition.direct_present_latest_draw_token
	target.direct_present_latest_draw_generation = addition.direct_present_latest_draw_generation
	target.resident_gpu_surface_bytes_current = addition.resident_gpu_surface_bytes_current
	target.resident_gpu_surface_bytes_peak = max(
		target.resident_gpu_surface_bytes_peak,
		addition.resident_gpu_surface_bytes_peak,
	)
}
