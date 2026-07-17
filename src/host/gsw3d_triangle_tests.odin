// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

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
