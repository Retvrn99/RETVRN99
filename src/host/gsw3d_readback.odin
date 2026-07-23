// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:hash"
import sdl3 "vendor:sdl3"

GSW3D_DEBUG_READBACK_ROW_ALIGNMENT :: u64(256)
GSW3D_PROOF_READBACK_ANCHOR_COUNT :: 5

Gsw3d_Debug_Readback_Layout :: struct {
	row_pitch:      u32,
	pixels_per_row: u32,
	byte_size:      u32,
}

Gsw3d_Proof_Readback_Signature :: struct {
	frame_crc32:  u32,
	anchor_crc32: u32,
	anchors:      [GSW3D_PROOF_READBACK_ANCHOR_COUNT][4]u8,
}

GSW3D_PROOF_READBACK_ANCHORS := [GSW3D_PROOF_READBACK_ANCHOR_COUNT][2]u32 {
	{32, 32},
	{320, 160},
	{200, 340},
	{440, 340},
	{320, 293},
}

GSW3D_PROOF_READBACK_EXPECTED := [GSW3D_PROOF_READBACK_ANCHOR_COUNT][4]u8 {
	{16, 16, 24, 255},
	{191, 32, 32, 255},
	{47, 40, 167, 255},
	{47, 168, 40, 255},
	{85, 85, 85, 255},
}

gsw3d_debug_readback_layout :: proc(width, height: u32) -> (Gsw3d_Debug_Readback_Layout, bool) {
	if width == 0 ||
	   height == 0 ||
	   width > HOST_GPU_SURFACE_MAX_DIMENSION ||
	   height > HOST_GPU_SURFACE_MAX_DIMENSION {return {}, false}
	row_bytes := u64(width) * 4
	row_pitch :=
		(row_bytes + GSW3D_DEBUG_READBACK_ROW_ALIGNMENT - 1) &
		~(GSW3D_DEBUG_READBACK_ROW_ALIGNMENT - 1)
	byte_size := row_pitch * u64(height)
	if row_pitch > u64(max(u32)) || byte_size > u64(max(u32)) {return {}, false}
	return {
			row_pitch = u32(row_pitch),
			pixels_per_row = u32(row_pitch / 4),
			byte_size = u32(byte_size),
		},
		true
}

gsw3d_debug_canonicalize_rgba :: proc(
	destination, source: []u8,
	layout: Gsw3d_Debug_Readback_Layout,
	format: sdl3.GPUTextureFormat,
	width, height: u32,
) -> bool {
	expected, valid := gsw3d_debug_readback_layout(width, height)
	output_bytes := u64(width) * u64(height) * 4
	if !valid ||
	   layout != expected ||
	   output_bytes > u64(max(int)) ||
	   len(destination) != int(output_bytes) ||
	   len(source) < int(layout.byte_size) ||
	   !gsw3d_triangle_format_supported(format) {return false}

	for y in 0 ..< int(height) {
		for x in 0 ..< int(width) {
			source_index := y * int(layout.row_pitch) + x * 4
			destination_index := (y * int(width) + x) * 4
			#partial switch format {
			case .B8G8R8A8_UNORM:
				destination[destination_index + 0] = source[source_index + 2]
				destination[destination_index + 1] = source[source_index + 1]
				destination[destination_index + 2] = source[source_index + 0]
				destination[destination_index + 3] = source[source_index + 3]
			case .R8G8B8A8_UNORM:
				copy(destination[destination_index:][:4], source[source_index:][:4])
			}
		}
	}
	return true
}

gsw3d_debug_readback_rgba_sync :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	target: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	width, height: u32,
	destination: []u8,
) -> bool {
	if renderer != nil && renderer.readback_counter != nil {
		host_presentation_metric_add(renderer.readback_counter, 1)
	}
	if renderer == nil ||
	   !renderer.live ||
	   renderer.gpu == nil ||
	   renderer.flight_count != 0 ||
	   target == nil ||
	   !gsw3d_triangle_target_valid(format, width, height) {return false}
	layout, valid := gsw3d_debug_readback_layout(width, height)
	if !valid || len(destination) != int(width) * int(height) * 4 {return false}

	download := sdl3.CreateGPUTransferBuffer(
		renderer.gpu,
		sdl3.GPUTransferBufferCreateInfo{usage = .DOWNLOAD, size = layout.byte_size},
	)
	if download == nil {return false}
	defer sdl3.ReleaseGPUTransferBuffer(renderer.gpu, download)

	command_buffer := sdl3.AcquireGPUCommandBuffer(renderer.gpu)
	if command_buffer == nil {return false}
	submitted := false
	defer if !submitted {_ = sdl3.CancelGPUCommandBuffer(command_buffer)}
	copy_pass := sdl3.BeginGPUCopyPass(command_buffer)
	if copy_pass == nil {return false}
	sdl3.DownloadFromGPUTexture(
		copy_pass,
		sdl3.GPUTextureRegion{texture = target, w = width, h = height, d = 1},
		sdl3.GPUTextureTransferInfo {
			transfer_buffer = download,
			pixels_per_row = layout.pixels_per_row,
			rows_per_layer = height,
		},
	)
	sdl3.EndGPUCopyPass(copy_pass)

	submitted = true
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
	if fence == nil {return false}
	defer sdl3.ReleaseGPUFence(renderer.gpu, fence)
	fences := [1]^sdl3.GPUFence{fence}
	if !sdl3.WaitForGPUFences(renderer.gpu, true, raw_data(fences[:]), 1) {return false}

	mapped := sdl3.MapGPUTransferBuffer(renderer.gpu, download, false)
	if mapped == nil {return false}
	defer sdl3.UnmapGPUTransferBuffer(renderer.gpu, download)
	source := ([^]u8)(mapped)[:int(layout.byte_size)]
	return gsw3d_debug_canonicalize_rgba(destination, source, layout, format, width, height)
}

gsw3d_proof_readback_signature :: proc(
	rgba: []u8,
	width, height: u32,
) -> (
	Gsw3d_Proof_Readback_Signature,
	bool,
) {
	if width != GSW3D_PROOF_WIDTH ||
	   height != GSW3D_PROOF_HEIGHT ||
	   len(rgba) != int(width) * int(height) * 4 {return {}, false}

	signature := Gsw3d_Proof_Readback_Signature {
		frame_crc32 = hash.crc32(rgba),
	}
	anchor_bytes: [GSW3D_PROOF_READBACK_ANCHOR_COUNT * 4]u8
	for coordinate, index in GSW3D_PROOF_READBACK_ANCHORS {
		sums: [4]u32
		for y_offset in 0 ..< 3 {
			for x_offset in 0 ..< 3 {
				x := int(coordinate.x) + x_offset - 1
				y := int(coordinate.y) + y_offset - 1
				source_index := (y * int(width) + x) * 4
				for channel in 0 ..< 4 {sums[channel] += u32(rgba[source_index + channel])}
			}
		}
		for channel in 0 ..< 4 {
			signature.anchors[index][channel] = u8((sums[channel] + 4) / 9)
			anchor_bytes[index * 4 + channel] = signature.anchors[index][channel]
		}
	}
	signature.anchor_crc32 = hash.crc32(anchor_bytes[:])
	return signature, true
}

gsw3d_proof_readback_anchors_valid :: proc(signature: Gsw3d_Proof_Readback_Signature) -> bool {
	for expected, index in GSW3D_PROOF_READBACK_EXPECTED {
		for channel in 0 ..< 4 {
			tolerance := channel == 3 || index == 0 ? 0 : 3
			delta := int(signature.anchors[index][channel]) - int(expected[channel])
			if delta < -tolerance || delta > tolerance {return false}
		}
	}
	return true
}
