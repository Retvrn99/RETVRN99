// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

Gsw3d_Triangle_Test_Fences :: struct {
	signaled:      [4]bool,
	released:      [4]bool,
	wait_succeeds: bool,
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
	token1, ok1 := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(0), 7)
	token2, ok2 := gsw3d_triangle_track_fence(&renderer, gsw3d_triangle_test_fence(1), 7)
	if !testing.expect(t, ok1 && ok2) {return}
	state.signaled[1] = true
	completed: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Completion
	count, ok := gsw3d_triangle_poll(&renderer, completed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, renderer.flight_count, 2)
	testing.expect_value(t, state.release_count, 0)

	state.signaled[0] = true
	count, ok = gsw3d_triangle_poll(&renderer, completed[:])
	testing.expect(t, ok)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, completed[0], Gsw3d_Triangle_Completion{token1, 7})
	testing.expect_value(t, completed[1], Gsw3d_Triangle_Completion{token2, 7})
	testing.expect_value(t, renderer.flight_count, 0)
	testing.expect_value(t, state.release_count, 2)
	testing.expect_value(t, renderer.metrics.completions, u64(2))
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
