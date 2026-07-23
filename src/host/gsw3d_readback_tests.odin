// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
gsw3d_readback_test_layout_is_aligned_and_bounded :: proc(t: ^testing.T) {
	one, ok := gsw3d_debug_readback_layout(1, 1)
	testing.expect(t, ok)
	testing.expect_value(t, one, Gsw3d_Debug_Readback_Layout{256, 64, 256})

	proof, proof_ok := gsw3d_debug_readback_layout(640, 480)
	testing.expect(t, proof_ok)
	testing.expect_value(t, proof, Gsw3d_Debug_Readback_Layout{2560, 640, 1_228_800})

	odd, odd_ok := gsw3d_debug_readback_layout(65, 2)
	testing.expect(t, odd_ok)
	testing.expect_value(t, odd, Gsw3d_Debug_Readback_Layout{512, 128, 1024})
	_, zero_ok := gsw3d_debug_readback_layout(0, 1)
	_, large_ok := gsw3d_debug_readback_layout(HOST_GPU_SURFACE_MAX_DIMENSION + 1, 1)
	testing.expect(t, !zero_ok && !large_ok)
}

@(test)
gsw3d_readback_test_canonicalizes_bgra_and_row_padding :: proc(t: ^testing.T) {
	layout, ok := gsw3d_debug_readback_layout(2, 2)
	if !testing.expect(t, ok) {return}
	source := make([]u8, int(layout.byte_size))
	defer delete(source)
	copy(source[0:8], []u8{3, 2, 1, 4, 7, 6, 5, 8})
	copy(source[int(layout.row_pitch):][:8], []u8{11, 10, 9, 12, 15, 14, 13, 16})
	destination: [16]u8
	testing.expect(
		t,
		gsw3d_debug_canonicalize_rgba(destination[:], source, layout, .B8G8R8A8_UNORM, 2, 2),
	)
	testing.expect_value(
		t,
		destination,
		[16]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
	)
}

@(test)
gsw3d_readback_test_canonicalizes_rgba_and_rejects_bad_layout :: proc(t: ^testing.T) {
	layout, ok := gsw3d_debug_readback_layout(1, 1)
	if !testing.expect(t, ok) {return}
	source := make([]u8, int(layout.byte_size))
	defer delete(source)
	copy(source[:4], []u8{1, 2, 3, 4})
	destination: [4]u8
	testing.expect(
		t,
		gsw3d_debug_canonicalize_rgba(destination[:], source, layout, .R8G8B8A8_UNORM, 1, 1),
	)
	testing.expect_value(t, destination, [4]u8{1, 2, 3, 4})
	testing.expect(
		t,
		!gsw3d_debug_canonicalize_rgba(destination[:3], source, layout, .R8G8B8A8_UNORM, 1, 1),
	)
	testing.expect(
		t,
		!gsw3d_debug_canonicalize_rgba(destination[:], source, layout, .R8G8B8A8_UNORM_SRGB, 1, 1),
	)
	bad := layout
	bad.row_pitch = 4
	testing.expect(
		t,
		!gsw3d_debug_canonicalize_rgba(
			destination[:],
			source,
			bad,
			sdl3.GPUTextureFormat.R8G8B8A8_UNORM,
			1,
			1,
		),
	)
}

@(test)
gsw3d_readback_test_gpu_readback_rejects_tracked_frames :: proc(t: ^testing.T) {
	readbacks: u64
	renderer := Gsw3d_Triangle_Renderer {
		gpu              = transmute(^sdl3.GPUDevice)(uintptr(1)),
		flight_count     = 1,
		readback_counter = &readbacks,
		live             = true,
	}
	target := transmute(^sdl3.GPUTexture)(uintptr(1))
	destination: [4]u8
	testing.expect(
		t,
		!gsw3d_debug_readback_rgba_sync(&renderer, target, .R8G8B8A8_UNORM, 1, 1, destination[:]),
	)
	testing.expect_value(t, readbacks, u64(1))
}

@(test)
gsw3d_readback_test_signature_checks_orientation_and_channels :: proc(t: ^testing.T) {
	rgba := make([]u8, int(GSW3D_PROOF_WIDTH * GSW3D_PROOF_HEIGHT * 4))
	defer delete(rgba)
	for coordinate, index in GSW3D_PROOF_READBACK_ANCHORS {
		for y_offset in 0 ..< 3 {
			for x_offset in 0 ..< 3 {
				x := int(coordinate.x) + x_offset - 1
				y := int(coordinate.y) + y_offset - 1
				destination_index := (y * int(GSW3D_PROOF_WIDTH) + x) * 4
				copy(rgba[destination_index:][:4], GSW3D_PROOF_READBACK_EXPECTED[index][:])
			}
		}
	}
	signature, ok := gsw3d_proof_readback_signature(rgba, GSW3D_PROOF_WIDTH, GSW3D_PROOF_HEIGHT)
	if !testing.expect(t, ok) {return}
	testing.expect(t, gsw3d_proof_readback_anchors_valid(signature))

	signature.anchors[1], signature.anchors[2] = signature.anchors[2], signature.anchors[1]
	testing.expect(t, !gsw3d_proof_readback_anchors_valid(signature))
}
