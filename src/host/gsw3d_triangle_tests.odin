// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import "core:time"
import sdl3 "vendor:sdl3"

@(test)
gsw3d_triangle_test_submission_timing_is_bounded_and_counts_failures :: proc(t: ^testing.T) {
	renderer: Gsw3d_Triangle_Renderer
	gsw3d_triangle_note_submission(&renderer, time.Tick{100}, time.Tick{160}, true)
	gsw3d_triangle_note_submission(&renderer, time.Tick{220}, time.Tick{200}, false)

	testing.expect_value(t, renderer.metrics.submission_calls, u64(2))
	testing.expect_value(t, renderer.metrics.submission_failures, u64(1))
	testing.expect_value(t, renderer.metrics.submission_ns, u64(60))
	testing.expect_value(t, renderer.metrics.latest_submission_ns, u64(0))
}

Gsw3d_Triangle_Test_Fences :: struct {
	signaled:      [4]bool,
	released:      [4]bool,
	wait_succeeds: bool,
	wait_delay:    time.Duration,
	wait_count:    int,
	release_count: int,
}

@(private = "file")
gsw3d_triangle_test_fence :: proc(index: int) -> ^sdl3.GPUFence {
	return transmute(^sdl3.GPUFence)(uintptr(index + 1))
}

@(private = "file")
gsw3d_triangle_test_fence_index :: proc(fence: ^sdl3.GPUFence) -> int {
	return int(uintptr(fence)) - 1
}

@(private = "file")
gsw3d_triangle_test_query :: proc(ctx: rawptr, fence: ^sdl3.GPUFence) -> bool {
	state := (^Gsw3d_Triangle_Test_Fences)(ctx)
	index := gsw3d_triangle_test_fence_index(fence)
	return state != nil && index >= 0 && index < len(state.signaled) && state.signaled[index]
}

@(private = "file")
gsw3d_triangle_test_wait :: proc(ctx: rawptr, fences: []^sdl3.GPUFence) -> bool {
	state := (^Gsw3d_Triangle_Test_Fences)(ctx)
	if state == nil || !state.wait_succeeds || len(fences) == 0 {return false}
	if state.wait_delay > 0 {time.sleep(state.wait_delay)}
	state.wait_count += 1
	for fence in fences {
		index := gsw3d_triangle_test_fence_index(fence)
		if index < 0 || index >= len(state.signaled) {return false}
		state.signaled[index] = true
	}
	return true
}

@(private = "file")
gsw3d_triangle_test_release :: proc(ctx: rawptr, fence: ^sdl3.GPUFence) {
	state := (^Gsw3d_Triangle_Test_Fences)(ctx)
	index := gsw3d_triangle_test_fence_index(fence)
	if state == nil || index < 0 || index >= len(state.released) {return}
	state.released[index] = true
	state.release_count += 1
}

@(private = "file")
gsw3d_triangle_test_renderer :: proc(
	state: ^Gsw3d_Triangle_Test_Fences,
) -> Gsw3d_Triangle_Renderer {
	return {
		live = true,
		fence_ops = {
			ctx = state,
			query = gsw3d_triangle_test_query,
			wait = gsw3d_triangle_test_wait,
			release = gsw3d_triangle_test_release,
		},
	}
}

@(test)
gsw3d_triangle_test_vertex_layout_matches_svga9_fixture :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Gsw3d_Triangle_Vertex), 20)
	testing.expect_value(t, GSW3D_TRIANGLE_VERTEX_BYTES, u32(60))
	vertices := gsw3d_triangle_proof_vertices()
	testing.expect_value(t, vertices[0].position, [4]f32{320, 80, 0.5, 1})
	testing.expect_value(t, vertices[0].color, u32(0xffff_0000))
	red_bytes := transmute([4]u8)vertices[0].color
	testing.expect_value(t, red_bytes, [4]u8{0, 0, 255, 255})
}

@(test)
gsw3d_triangle_test_positiont_maps_to_vulkan_clip_coordinates :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		gsw3d_triangle_positiont_clip({0, 0, 0.25, 1}, 640, 480),
		[4]f32{-1, 1, 0.25, 1},
	)
	testing.expect_value(
		t,
		gsw3d_triangle_positiont_clip({640, 480, 0.75, 1}, 640, 480),
		[4]f32{1, -1, 0.75, 1},
	)
	testing.expect_value(t, gsw3d_triangle_positiont_clip({1, 1, 1, 1}, 0, 480), [4]f32{})
}

@(test)
gsw3d_triangle_test_target_formats_and_dimensions_are_bounded :: proc(t: ^testing.T) {
	testing.expect(t, gsw3d_triangle_target_valid(.B8G8R8A8_UNORM, 640, 480))
	testing.expect(t, gsw3d_triangle_target_valid(.R8G8B8A8_UNORM, 1600, 1200))
	testing.expect(t, !gsw3d_triangle_target_valid(.B8G8R8A8_UNORM_SRGB, 640, 480))
	testing.expect(t, !gsw3d_triangle_target_valid(.B8G8R8A8_UNORM, 0, 480))
	testing.expect(
		t,
		!gsw3d_triangle_target_valid(
			sdl3.GPUTextureFormat.B8G8R8A8_UNORM,
			HOST_GPU_SURFACE_MAX_DIMENSION + 1,
			480,
		),
	)
}

@(test)
gsw3d_triangle_test_embedded_shaders_are_spirv :: proc(t: ^testing.T) {
	spirv_magic := [4]u8{0x03, 0x02, 0x23, 0x07}
	testing.expect(t, len(GSW3D_TRIANGLE_VERTEX_SPIRV) > 4)
	testing.expect(t, len(GSW3D_TRIANGLE_FRAGMENT_SPIRV) > 4)
	for value, index in spirv_magic {
		testing.expect_value(t, GSW3D_TRIANGLE_VERTEX_SPIRV[index], value)
		testing.expect_value(t, GSW3D_TRIANGLE_FRAGMENT_SPIRV[index], value)
	}
}

@(test)
gsw3d_triangle_test_poll_retires_physical_fences_in_submission_order :: proc(t: ^testing.T) {
	state := Gsw3d_Triangle_Test_Fences {
		wait_succeeds = true,
	}
	renderer := gsw3d_triangle_test_renderer(&state)
	token1, ok1 := gsw3d_triangle_track_fence_at(
		&renderer,
		gsw3d_triangle_test_fence(0),
		7,
		time.Tick{100},
	)
	token2, ok2 := gsw3d_triangle_track_fence_at(
		&renderer,
		gsw3d_triangle_test_fence(1),
		7,
		time.Tick{200},
	)
	if !testing.expect(t, ok1 && ok2) {return}
	state.signaled[1] = true
	completed: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Completion
	count, ok := gsw3d_triangle_poll_at(&renderer, completed[:], time.Tick{300})
	testing.expect(t, ok)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, renderer.flight_count, 2)
	testing.expect_value(t, state.release_count, 0)

	state.signaled[0] = true
	count, ok = gsw3d_triangle_poll_at(&renderer, completed[:], time.Tick{400})
	testing.expect(t, ok)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, completed[0], Gsw3d_Triangle_Completion{token1, 7})
	testing.expect_value(t, completed[1], Gsw3d_Triangle_Completion{token2, 7})
	testing.expect_value(t, renderer.flight_count, 0)
	testing.expect_value(t, state.release_count, 2)
	testing.expect_value(t, renderer.metrics.completions, u64(2))
	testing.expect_value(t, renderer.metrics.completion_ns, u64(500))
	testing.expect_value(t, renderer.metrics.latest_completion.duration_ns, u64(200))
}

@(test)
gsw3d_triangle_test_third_frame_waits_oldest_without_exceeding_two :: proc(t: ^testing.T) {
	state := Gsw3d_Triangle_Test_Fences {
		wait_succeeds = true,
	}
	renderer := gsw3d_triangle_test_renderer(&state)
	_, ok1 := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(0), 1)
	_, ok2 := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(1), 1)
	if !testing.expect(t, ok1 && ok2) {return}
	_, publish, waited := gsw3d_triangle_wait_oldest(&renderer)
	testing.expect(t, waited && publish)
	_, ok3 := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(2), 1)
	testing.expect(t, ok3)
	testing.expect_value(t, renderer.flight_count, 2)
	testing.expect_value(t, renderer.metrics.max_in_flight, u32(2))
	testing.expect_value(t, renderer.metrics.capacity_waits, u64(1))
	testing.expect_value(t, state.wait_count, 1)
	testing.expect(t, state.released[0])
}

@(test)
gsw3d_triangle_test_reset_discards_old_generation_completion :: proc(t: ^testing.T) {
	state := Gsw3d_Triangle_Test_Fences {
		wait_succeeds = true,
	}
	renderer := gsw3d_triangle_test_renderer(&state)
	_, tracked := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(0), 3)
	if !testing.expect(t, tracked) {return}
	gsw3d_triangle_discard_other_generations(&renderer, 4)
	state.signaled[0] = true
	completed: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Completion
	count, ok := gsw3d_triangle_poll(&renderer, completed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, renderer.flight_count, 0)
	testing.expect_value(t, state.release_count, 1)
}

@(test)
host_gsw3d_observability_test_tracks_physical_fences_and_residency :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		host_gsw3d_observability_snapshot(nil),
		Host_Gsw3d_Observability_Snapshot{},
	)
	state := Gsw3d_Triangle_Test_Fences {
		wait_succeeds = true,
		wait_delay    = time.Millisecond,
	}
	h: Host
	h.gsw3d_backend.device_generation = 9
	h.gsw3d_executor.generation = 9
	h.gsw3d_triangle = gsw3d_triangle_test_renderer(&state)
	h.gpu_surface_bytes = u64(640 * 480 * 4)
	h.gpu_surfaces[0] = {
		live           = true,
		descriptor     = {23, 640, 480, .Bgra8_Unorm},
		byte_size      = h.gpu_surface_bytes,
		render_texture = transmute(^sdl3.Texture)(uintptr(1)),
	}
	first_token, first_tracked := gsw3d_triangle_track_fence_at(
		&h.gsw3d_triangle,
		gsw3d_triangle_test_fence(0),
		9,
		time.Tick{100},
	)
	if !testing.expect(t, first_tracked) {return}
	testing.expect_value(t, h.gsw3d_triangle.flights[0].submitted_at, time.Tick{100})
	testing.expect_value(t, h.gsw3d_triangle.flights[0].completion.token, first_token)
	testing.expect_value(t, h.gsw3d_triangle.flights[0].completion.generation, u64(9))
	h.gsw3d_executor.resources[0] = {
		live                 = true,
		id                   = 23,
		kind                 = .Surface,
		rendered             = true,
		last_draw_token      = first_token,
		last_draw_generation = 9,
	}
	testing.expect(
		t,
		host_gpu_surface_present(
			&h,
			{
				surface_id = 23,
				source = {0, 0, 640, 480},
				destination = {0, 0, 640, 480},
				canvas_width = 640,
				canvas_height = 480,
				interval = HOST_GPU_PRESENT_INTERVAL,
			},
		),
	)
	first_present := host_gsw3d_observability_snapshot(&h)
	testing.expect(t, first_present.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, first_present.direct_present_latest_draw_submit_tick, time.Tick{100})
	testing.expect_value(t, first_present.direct_present_latest_draw_token, first_token)
	testing.expect_value(t, first_present.direct_present_latest_draw_generation, u64(9))
	second_token, second_tracked := gsw3d_triangle_track_fence_at(
		&h.gsw3d_triangle,
		gsw3d_triangle_test_fence(1),
		9,
		time.Tick{200},
	)
	if !testing.expect(t, second_tracked) {return}
	testing.expect_value(t, h.gsw3d_triangle.flights[1].submitted_at, time.Tick{200})
	testing.expect_value(t, h.gsw3d_triangle.flights[1].completion.token, second_token)
	testing.expect_value(t, h.gsw3d_triangle.flights[1].completion.generation, u64(9))
	h.gsw3d_executor.resources[0].last_draw_token = second_token
	testing.expect_value(
		t,
		host_gsw3d_observability_snapshot(&h),
		Host_Gsw3d_Observability_Snapshot {
			device_generation = 9,
			sdl_gpu_fence_submissions = 2,
			sdl_gpu_fence_in_flight = 2,
			sdl_gpu_fence_max_in_flight = 2,
			sdl_gpu_flights = {
				{valid = true, submit_tick = time.Tick{100}, token = first_token, generation = 9},
				{valid = true, submit_tick = time.Tick{200}, token = second_token, generation = 9},
			},
			sdl_gpu_latest_submission_tick = time.Tick{200},
			sdl_gpu_latest_submission_token = second_token,
			sdl_gpu_latest_submission_generation = 9,
			direct_presents = 1,
			direct_present_active = true,
			direct_present_surface_id = 23,
			direct_present_surface_width = 640,
			direct_present_surface_height = 480,
			direct_present_canvas_width = 640,
			direct_present_canvas_height = 480,
			direct_present_interval = 1,
			direct_present_latest_draw_fence_valid = true,
			direct_present_latest_draw_submit_tick = time.Tick{200},
			direct_present_latest_draw_token = second_token,
			direct_present_latest_draw_generation = 9,
			resident_gpu_surface_bytes = u64(640 * 480 * 4),
		},
	)
	h.gsw3d_executor.resources[0].last_draw_token = second_token + 100
	uncorrelated := host_gsw3d_observability_snapshot(&h)
	testing.expect(t, uncorrelated.direct_present_active)
	testing.expect(t, !uncorrelated.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, uncorrelated.direct_present_latest_draw_submit_tick, time.Tick{})
	testing.expect_value(t, uncorrelated.direct_present_latest_draw_token, u64(0))
	testing.expect_value(t, uncorrelated.direct_present_latest_draw_generation, u64(0))
	h.gsw3d_executor.resources[0].last_draw_token = second_token

	_, publish, waited := gsw3d_triangle_wait_oldest(&h.gsw3d_triangle)
	testing.expect(t, waited && publish)
	h.gsw3d_backend.device_generation = 10
	testing.expect(t, !h.gsw3d_triangle.flights[h.gsw3d_triangle.flight_head].discarded)
	retired_one := host_gsw3d_observability_snapshot(&h)
	testing.expect_value(t, retired_one.device_generation, u64(10))
	testing.expect_value(t, retired_one.sdl_gpu_fence_completions, u64(1))
	testing.expect(t, retired_one.sdl_gpu_fence_completion_ns > 0)
	testing.expect_value(t, retired_one.sdl_gpu_fence_capacity_waits, u64(1))
	testing.expect(t, retired_one.sdl_gpu_fence_capacity_wait_ns > 0)
	testing.expect_value(
		t,
		retired_one.sdl_gpu_fence_latest_capacity_wait_ns,
		retired_one.sdl_gpu_fence_capacity_wait_ns,
	)
	testing.expect_value(t, retired_one.sdl_gpu_fence_in_flight, u32(1))
	testing.expect_value(t, retired_one.sdl_gpu_fence_max_in_flight, u32(2))
	testing.expect_value(
		t,
		retired_one.sdl_gpu_flights[0],
		Host_Gsw3d_Physical_Flight_Snapshot {
			valid = true,
			submit_tick = time.Tick{200},
			token = second_token,
			generation = 9,
			discarded = true,
		},
	)
	testing.expect(t, !retired_one.sdl_gpu_flights[1].valid)
	testing.expect_value(t, retired_one.sdl_gpu_latest_submission_tick, time.Tick{200})
	testing.expect_value(t, retired_one.sdl_gpu_latest_submission_token, second_token)
	testing.expect_value(t, retired_one.sdl_gpu_latest_submission_generation, u64(9))
	testing.expect_value(t, retired_one.sdl_gpu_latest_completion_submit_tick, time.Tick{100})
	testing.expect(t, retired_one.sdl_gpu_latest_completion_observed_tick != (time.Tick{}))
	testing.expect_value(t, retired_one.sdl_gpu_latest_completion_token, first_token)
	testing.expect_value(t, retired_one.sdl_gpu_latest_completion_generation, u64(9))
	testing.expect(t, retired_one.sdl_gpu_latest_completion_duration_ns > 0)
	testing.expect(t, retired_one.sdl_gpu_latest_completion_discarded)
	testing.expect(t, retired_one.direct_present_active)
	testing.expect(t, !retired_one.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, retired_one.direct_present_latest_draw_submit_tick, time.Tick{})
	testing.expect_value(t, retired_one.direct_present_latest_draw_token, u64(0))
	testing.expect_value(t, retired_one.direct_present_latest_draw_generation, u64(0))
	state.signaled[1] = true
	completed: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Completion
	count, polled := gsw3d_triangle_poll_at(&h.gsw3d_triangle, completed[:], time.Tick{400})
	testing.expect(t, polled)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, completed[0], Gsw3d_Triangle_Completion{second_token, 9})
	testing.expect(t, gsw3d_proof_backend_complete(&h.gsw3d_backend, completed[0]))
	testing.expect(t, gsw3d_proof_backend_completion(&h.gsw3d_backend, second_token) == .Pending)
	testing.expect(t, !h.gsw3d_triangle.metrics.latest_completion.discarded)
	final := host_gsw3d_observability_snapshot(&h)
	testing.expect_value(t, final.device_generation, u64(10))
	testing.expect_value(t, final.sdl_gpu_fence_submissions, u64(2))
	testing.expect_value(t, final.sdl_gpu_fence_completions, u64(2))
	testing.expect_value(
		t,
		final.sdl_gpu_fence_completion_ns - retired_one.sdl_gpu_fence_completion_ns,
		u64(200),
	)
	testing.expect_value(t, final.sdl_gpu_fence_capacity_waits, u64(1))
	testing.expect_value(
		t,
		final.sdl_gpu_fence_capacity_wait_ns,
		retired_one.sdl_gpu_fence_capacity_wait_ns,
	)
	testing.expect_value(t, final.sdl_gpu_fence_in_flight, u32(0))
	testing.expect_value(t, final.sdl_gpu_fence_max_in_flight, u32(2))
	testing.expect(t, !final.sdl_gpu_flights[0].valid)
	testing.expect(t, !final.sdl_gpu_flights[1].valid)
	testing.expect_value(t, final.sdl_gpu_latest_completion_submit_tick, time.Tick{200})
	testing.expect_value(t, final.sdl_gpu_latest_completion_observed_tick, time.Tick{400})
	testing.expect_value(t, final.sdl_gpu_latest_completion_token, second_token)
	testing.expect_value(t, final.sdl_gpu_latest_completion_generation, u64(9))
	testing.expect_value(t, final.sdl_gpu_latest_completion_duration_ns, u64(200))
	testing.expect(t, final.sdl_gpu_latest_completion_discarded)
	testing.expect(t, final.direct_present_active)
	testing.expect_value(t, final.direct_present_surface_id, u32(23))
	testing.expect_value(t, final.direct_present_surface_width, u32(640))
	testing.expect_value(t, final.direct_present_surface_height, u32(480))
	testing.expect_value(t, final.direct_present_canvas_width, u32(640))
	testing.expect_value(t, final.direct_present_canvas_height, u32(480))
	testing.expect_value(t, final.direct_present_interval, u32(1))
	testing.expect(t, !final.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, final.direct_presents, u64(1))
	testing.expect_value(t, final.resident_gpu_surface_bytes, u64(640 * 480 * 4))
	host_cpu_frame_metadata_publish(&h, 4, 3)
	legacy := host_gsw3d_observability_snapshot(&h)
	testing.expect(t, !legacy.direct_present_active)
	testing.expect_value(t, legacy.direct_present_surface_id, u32(0))
	testing.expect_value(t, legacy.direct_present_surface_width, u32(0))
	testing.expect_value(t, legacy.direct_present_surface_height, u32(0))
	testing.expect_value(t, legacy.direct_present_canvas_width, u32(0))
	testing.expect_value(t, legacy.direct_present_canvas_height, u32(0))
	testing.expect_value(t, legacy.direct_present_interval, u32(0))
	testing.expect(t, !legacy.direct_present_latest_draw_fence_valid)
	testing.expect_value(t, legacy.direct_present_latest_draw_submit_tick, time.Tick{})
	testing.expect_value(t, legacy.direct_present_latest_draw_token, u64(0))
	testing.expect_value(t, legacy.direct_present_latest_draw_generation, u64(0))
	testing.expect_value(t, legacy.direct_presents, u64(1))
	testing.expect_value(t, legacy.resident_gpu_surface_bytes, u64(640 * 480 * 4))
}
