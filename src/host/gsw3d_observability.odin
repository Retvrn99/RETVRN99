// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:sync"
import "core:time"

Host_Gsw3d_Physical_Flight_Snapshot :: struct {
	valid:       bool,
	submit_tick: time.Tick,
	token:       u64,
	generation:  u64,
	discarded:   bool,
}

Host_Gsw3d_Observability_Snapshot :: struct {
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
	sdl_gpu_fence_in_flight:                 u32,
	sdl_gpu_fence_max_in_flight:             u32,
	sdl_gpu_flights:                         [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Host_Gsw3d_Physical_Flight_Snapshot,
	sdl_gpu_latest_submission_tick:          time.Tick,
	sdl_gpu_latest_submission_token:         u64,
	sdl_gpu_latest_submission_generation:    u64,
	sdl_gpu_latest_completion_submit_tick:   time.Tick,
	sdl_gpu_latest_completion_observed_tick: time.Tick,
	sdl_gpu_latest_completion_token:         u64,
	sdl_gpu_latest_completion_generation:    u64,
	sdl_gpu_latest_completion_duration_ns:   u64,
	sdl_gpu_latest_completion_discarded:     bool,
	direct_presents:                         u64,
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
	resident_gpu_surface_bytes:              u64,
}

// Presentation-thread only; the existing backend lock stabilizes generation during the copy.
host_gsw3d_observability_snapshot :: proc(h: ^Host) -> Host_Gsw3d_Observability_Snapshot {
	if h == nil {return {}}
	sync.lock(&h.gsw3d_backend.mu)
	defer sync.unlock(&h.gsw3d_backend.mu)
	device_generation := h.gsw3d_backend.device_generation
	cleanup_required := h.gsw3d_backend.cleanup_required
	in_flight := clamp(h.gsw3d_triangle.flight_count, 0, GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT)
	physical_flights: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Host_Gsw3d_Physical_Flight_Snapshot
	for offset in 0 ..< in_flight {
		index := (h.gsw3d_triangle.flight_head + offset) % GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT
		flight := h.gsw3d_triangle.flights[index]
		if flight.fence == nil ||
		   flight.submitted_at == (time.Tick{}) ||
		   flight.completion.token == 0 ||
		   flight.completion.generation == 0 {continue}
		physical_flights[offset] = {
			valid       = true,
			submit_tick = flight.submitted_at,
			token       = flight.completion.token,
			generation  = flight.completion.generation,
			discarded   = cleanup_required || flight.discarded || flight.completion.generation != device_generation,
		}
	}
	present := h.gpu_present
	surface_width, surface_height: u32
	for surface in h.gpu_surfaces {
		if surface.live &&
		   surface.render_texture != nil &&
		   surface.descriptor.id == present.surface_id {
			surface_width = surface.descriptor.width
			surface_height = surface.descriptor.height
			break
		}
	}
	direct_present_active := present.surface_id != 0 && surface_width != 0 && surface_height != 0
	if !direct_present_active {present = {}}
	// A selected surface remains active; this maps its latest successful physical draw.
	draw_token, draw_generation: u64
	if direct_present_active &&
	   !cleanup_required &&
	   device_generation != 0 &&
	   h.gsw3d_executor.generation == device_generation {
		for resource in h.gsw3d_executor.resources {
			if resource.live &&
			   resource.kind == .Surface &&
			   resource.id == present.surface_id &&
			   resource.rendered &&
			   resource.last_draw_token != 0 &&
			   resource.last_draw_generation == device_generation {
				draw_token = resource.last_draw_token
				draw_generation = resource.last_draw_generation
				break
			}
		}
	}
	latest_submission := h.gsw3d_triangle.metrics.latest_submission
	latest_completion := h.gsw3d_triangle.metrics.latest_completion
	draw_submit_tick := time.Tick{}
	draw_fence_valid := false
	if draw_token != 0 &&
	   latest_submission.tick != (time.Tick{}) &&
	   latest_submission.token == draw_token &&
	   latest_submission.generation == draw_generation {
		draw_submit_tick = latest_submission.tick
		draw_fence_valid = true
	}
	if !draw_fence_valid {
		if !latest_completion.discarded &&
		   latest_completion.submit_tick != (time.Tick{}) &&
		   latest_completion.token == draw_token &&
		   latest_completion.generation == draw_generation {
			draw_submit_tick = latest_completion.submit_tick
			draw_fence_valid = true
		}
	}
	if !draw_fence_valid {
		for flight in physical_flights {
			if flight.valid &&
			   !flight.discarded &&
			   flight.token == draw_token &&
			   flight.generation == draw_generation {
				draw_submit_tick = flight.submit_tick
				draw_fence_valid = true
				break
			}
		}
	}
	if !draw_fence_valid {
		draw_token = 0
		draw_generation = 0
	}
	latest_completion_discarded :=
		latest_completion.token != 0 &&
		(cleanup_required ||
				latest_completion.discarded ||
				latest_completion.generation != device_generation)
	return {
		device_generation = device_generation,
		sdl_gpu_submission_calls = h.gsw3d_triangle.metrics.submission_calls,
		sdl_gpu_submission_failures = h.gsw3d_triangle.metrics.submission_failures,
		sdl_gpu_submission_ns = h.gsw3d_triangle.metrics.submission_ns,
		sdl_gpu_latest_submission_ns = h.gsw3d_triangle.metrics.latest_submission_ns,
		sdl_gpu_fence_submissions = h.gsw3d_triangle.metrics.submissions,
		sdl_gpu_fence_completions = h.gsw3d_triangle.metrics.completions,
		sdl_gpu_fence_completion_ns = h.gsw3d_triangle.metrics.completion_ns,
		sdl_gpu_fence_capacity_waits = h.gsw3d_triangle.metrics.capacity_waits,
		sdl_gpu_fence_capacity_wait_ns = h.gsw3d_triangle.metrics.capacity_wait_ns,
		sdl_gpu_fence_latest_capacity_wait_ns = h.gsw3d_triangle.metrics.latest_capacity_wait_ns,
		sdl_gpu_fence_in_flight = u32(in_flight),
		sdl_gpu_fence_max_in_flight = h.gsw3d_triangle.metrics.max_in_flight,
		sdl_gpu_flights = physical_flights,
		sdl_gpu_latest_submission_tick = latest_submission.tick,
		sdl_gpu_latest_submission_token = latest_submission.token,
		sdl_gpu_latest_submission_generation = latest_submission.generation,
		sdl_gpu_latest_completion_submit_tick = latest_completion.submit_tick,
		sdl_gpu_latest_completion_observed_tick = latest_completion.observed_tick,
		sdl_gpu_latest_completion_token = latest_completion.token,
		sdl_gpu_latest_completion_generation = latest_completion.generation,
		sdl_gpu_latest_completion_duration_ns = latest_completion.duration_ns,
		sdl_gpu_latest_completion_discarded = latest_completion_discarded,
		direct_presents = h.gpu_direct_presents,
		direct_present_active = direct_present_active,
		direct_present_surface_id = present.surface_id,
		direct_present_surface_width = direct_present_active ? surface_width : 0,
		direct_present_surface_height = direct_present_active ? surface_height : 0,
		direct_present_canvas_width = present.canvas_width,
		direct_present_canvas_height = present.canvas_height,
		direct_present_interval = present.interval,
		direct_present_latest_draw_fence_valid = draw_fence_valid,
		direct_present_latest_draw_submit_tick = draw_submit_tick,
		direct_present_latest_draw_token = draw_token,
		direct_present_latest_draw_generation = draw_generation,
		resident_gpu_surface_bytes = h.gpu_surface_bytes,
	}
}
