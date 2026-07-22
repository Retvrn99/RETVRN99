// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:time"
import host "host"

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
}

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
	if previous.direct_present_active && !current.direct_present_active {
		result.direct_present_deactivations = 1
	}
	if reset {result.counter_resets = 1}
	return result
}

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
