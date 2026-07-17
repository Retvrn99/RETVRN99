// SPDX-License-Identifier: GPL-3.0-only
package main

import host "../../src/host"
import vga "../../src/vga"
import "core:c"
import "core:fmt"
import "core:hash"
import "core:time"
import sdl3 "vendor:sdl3"

HIGH_RESOLUTION_WIDTH :: u32(1600)
HIGH_RESOLUTION_HEIGHT :: u32(1200)
LOW_RESOLUTION_SURFACE_ID :: u32(0x7fff_0001)
HIGH_RESOLUTION_ANCHOR_COUNT :: 5

High_Resolution_Signature :: struct {
	frame_crc32:  u32,
	anchor_crc32: u32,
	anchors:      [HIGH_RESOLUTION_ANCHOR_COUNT][4]u8,
}

Mixed_Resolution_Signatures :: struct {
	low:  host.Gsw3d_Proof_Readback_Signature,
	high: High_Resolution_Signature,
}

HIGH_RESOLUTION_ANCHORS := [HIGH_RESOLUTION_ANCHOR_COUNT][2]u32 {
	{80, 80},
	{800, 400},
	{500, 850},
	{1100, 850},
	{800, 733},
}

HIGH_RESOLUTION_EXPECTED := [HIGH_RESOLUTION_ANCHOR_COUNT][4]u8 {
	{16, 16, 24, 255},
	{191, 32, 32, 255},
	{47, 40, 167, 255},
	{47, 168, 40, 255},
	{85, 85, 85, 255},
}

create_gpu_device :: proc() -> ^sdl3.GPUDevice {
	props := sdl3.CreateProperties()
	if props == 0 {return nil}
	defer sdl3.DestroyProperties(props)
	vulkan := sdl3.GPUVulkanOptions {
		vulkan_api_version = host.HOST_VULKAN_API_VERSION,
	}
	if !sdl3.SetStringProperty(
		   props,
		   sdl3.PROP_GPU_DEVICE_CREATE_NAME_STRING,
		   host.HOST_GPU_DRIVER,
	   ) ||
	   !sdl3.SetBooleanProperty(props, sdl3.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true) ||
	   !sdl3.SetPointerProperty(
			   props,
			   sdl3.PROP_GPU_DEVICE_CREATE_VULKAN_OPTIONS_POINTER,
			   &vulkan,
		   ) {return nil}
	return sdl3.CreateGPUDeviceWithProperties(props)
}

high_resolution_vertices :: proc(
) -> [host.GSW3D_TRIANGLE_VERTEX_COUNT]host.Gsw3d_Triangle_Vertex {
	vertices := host.gsw3d_triangle_proof_vertices()
	x_scale := f32(HIGH_RESOLUTION_WIDTH) / f32(host.GSW3D_PROOF_WIDTH)
	y_scale := f32(HIGH_RESOLUTION_HEIGHT) / f32(host.GSW3D_PROOF_HEIGHT)
	for &vertex in vertices {
		vertex.position.x *= x_scale
		vertex.position.y *= y_scale
	}
	return vertices
}

high_resolution_signature :: proc(rgba: []u8) -> (High_Resolution_Signature, bool) {
	if len(rgba) != int(HIGH_RESOLUTION_WIDTH * HIGH_RESOLUTION_HEIGHT * 4) {
		return {}, false
	}
	signature := High_Resolution_Signature {
		frame_crc32 = hash.crc32(rgba),
	}
	anchor_bytes: [HIGH_RESOLUTION_ANCHOR_COUNT * 4]u8
	for coordinate, index in HIGH_RESOLUTION_ANCHORS {
		sums: [4]u32
		for y_offset in 0 ..< 3 {
			for x_offset in 0 ..< 3 {
				x := int(coordinate.x) + x_offset - 1
				y := int(coordinate.y) + y_offset - 1
				source_index := (y * int(HIGH_RESOLUTION_WIDTH) + x) * 4
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

high_resolution_anchors_valid :: proc(signature: High_Resolution_Signature) -> bool {
	for expected, index in HIGH_RESOLUTION_EXPECTED {
		for channel in 0 ..< 4 {
			tolerance := channel == 3 || index == 0 ? 0 : 3
			delta := int(signature.anchors[index][channel]) - int(expected[channel])
			if delta < -tolerance || delta > tolerance {return false}
		}
	}
	return true
}

capture_mixed_resolution_pair :: proc(
	renderer: ^host.Gsw3d_Triangle_Renderer,
	low_texture, high_texture: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	low_rgba, high_rgba: []u8,
	generation: u64,
) -> Mixed_Resolution_Signatures {
	low_vertices := host.gsw3d_triangle_proof_vertices()
	high_vertices := high_resolution_vertices()
	low_token, low_submitted := host.gsw3d_triangle_render_async(
		renderer,
		low_texture,
		format,
		host.GSW3D_PROOF_WIDTH,
		host.GSW3D_PROOF_HEIGHT,
		&low_vertices,
		generation,
	)
	assert(low_submitted && low_token != 0, string(sdl3.GetError()))
	high_token, high_submitted := host.gsw3d_triangle_render_async(
		renderer,
		high_texture,
		format,
		HIGH_RESOLUTION_WIDTH,
		HIGH_RESOLUTION_HEIGHT,
		&high_vertices,
		generation,
	)
	assert(high_submitted && high_token != 0, string(sdl3.GetError()))
	assert(
		renderer.flight_count == host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT &&
		renderer.metrics.max_in_flight == host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT &&
		renderer.metrics.capacity_waits == 0,
	)

	polled_completions: [host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]host.Gsw3d_Triangle_Completion
	ordered_completions: [host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]host.Gsw3d_Triangle_Completion
	ordered_count := 0
	for _ in 0 ..< 5000 {
		count, polled := host.gsw3d_triangle_poll(renderer, polled_completions[:])
		assert(polled)
		assert(ordered_count + count <= len(ordered_completions))
		for index in 0 ..< count {
			ordered_completions[ordered_count] = polled_completions[index]
			ordered_count += 1
		}
		if ordered_count == len(ordered_completions) {break}
		time.sleep(time.Millisecond)
	}
	assert(
		ordered_count == len(ordered_completions) &&
		ordered_completions[0].token == low_token &&
		ordered_completions[0].generation == generation &&
		ordered_completions[1].token == high_token &&
		ordered_completions[1].generation == generation &&
		renderer.flight_count == 0 &&
		renderer.metrics.max_in_flight == host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT &&
		renderer.metrics.capacity_waits == 0,
	)

	assert(
		host.gsw3d_debug_readback_rgba_sync(
			renderer,
			low_texture,
			format,
			host.GSW3D_PROOF_WIDTH,
			host.GSW3D_PROOF_HEIGHT,
			low_rgba,
		),
		string(sdl3.GetError()),
	)
	low_signature, low_signed := host.gsw3d_proof_readback_signature(
		low_rgba,
		host.GSW3D_PROOF_WIDTH,
		host.GSW3D_PROOF_HEIGHT,
	)
	assert(low_signed && host.gsw3d_proof_readback_anchors_valid(low_signature))
	assert(
		host.gsw3d_debug_readback_rgba_sync(
			renderer,
			high_texture,
			format,
			HIGH_RESOLUTION_WIDTH,
			HIGH_RESOLUTION_HEIGHT,
			high_rgba,
		),
		string(sdl3.GetError()),
	)
	high_signature, high_signed := high_resolution_signature(high_rgba)
	assert(high_signed && high_resolution_anchors_valid(high_signature))
	return {low = low_signature, high = high_signature}
}

wrapped_surface :: proc(h: ^host.Host, id: u32) -> ^sdl3.Texture {
	for &surface in h.gpu_surfaces {
		if surface.live && surface.descriptor.id == id {return surface.render_texture}
	}
	return nil
}

compose_capture :: proc(
	renderer: ^sdl3.Renderer,
	source, target: ^sdl3.Texture,
	rgba: []u8,
) -> host.Gsw3d_Proof_Readback_Signature {
	assert(renderer != nil && source != nil && target != nil)
	assert(sdl3.SetRenderTarget(renderer, target), string(sdl3.GetError()))
	defer assert(sdl3.SetRenderTarget(renderer, nil), string(sdl3.GetError()))
	assert(sdl3.SetRenderDrawColor(renderer, 0, 0, 0, 255), string(sdl3.GetError()))
	assert(sdl3.RenderClear(renderer), string(sdl3.GetError()))
	assert(sdl3.RenderTexture(renderer, source, nil, nil), string(sdl3.GetError()))
	surface := sdl3.RenderReadPixels(renderer, nil)
	assert(surface != nil, string(sdl3.GetError()))
	defer sdl3.DestroySurface(surface)
	converted := sdl3.ConvertSurface(surface, .RGBA32)
	assert(converted != nil, string(sdl3.GetError()))
	defer sdl3.DestroySurface(converted)
	assert(
		converted.w == c.int(host.GSW3D_PROOF_WIDTH) &&
		converted.h == c.int(host.GSW3D_PROOF_HEIGHT) &&
		converted.pitch >= c.int(host.GSW3D_PROOF_WIDTH * 4) &&
		converted.pixels != nil,
	)
	pixels := ([^]u8)(converted.pixels)[:int(converted.pitch) * int(converted.h)]
	for y in 0 ..< int(host.GSW3D_PROOF_HEIGHT) {
		copy(
			rgba[y * int(host.GSW3D_PROOF_WIDTH) * 4:][:int(host.GSW3D_PROOF_WIDTH) * 4],
			pixels[y * int(converted.pitch):][:int(host.GSW3D_PROOF_WIDTH) * 4],
		)
	}
	signature, signed := host.gsw3d_proof_readback_signature(
		rgba,
		host.GSW3D_PROOF_WIDTH,
		host.GSW3D_PROOF_HEIGHT,
	)
	assert(signed && host.gsw3d_proof_readback_anchors_valid(signature))
	return signature
}

main :: proc() {
	assert(sdl3.Init({.VIDEO}), string(sdl3.GetError()))
	defer sdl3.Quit()
	window := sdl3.CreateWindow(
		"RETVRN99 GSW3D proof",
		c.int(host.GSW3D_PROOF_WIDTH),
		c.int(host.GSW3D_PROOF_HEIGHT),
		{.HIDDEN},
	)
	assert(window != nil, string(sdl3.GetError()))
	defer sdl3.DestroyWindow(window)
	gpu := create_gpu_device()
	assert(gpu != nil, string(sdl3.GetError()))
	defer sdl3.DestroyGPUDevice(gpu)
	assert(string(sdl3.GetGPUDeviceDriver(gpu)) == host.HOST_GPU_DRIVER)
	renderer := sdl3.CreateGPURenderer(gpu, window)
	assert(renderer != nil, string(sdl3.GetError()))
	defer sdl3.DestroyRenderer(renderer)

	h := host.Host {
		win = window,
		ren = renderer,
		gpu = gpu,
	}
	assert(
		host.host_gpu_surface_create(
			&h,
			{
				id = LOW_RESOLUTION_SURFACE_ID,
				width = host.GSW3D_PROOF_WIDTH,
				height = host.GSW3D_PROOF_HEIGHT,
				format = .Bgra8_Unorm,
			},
		),
		string(sdl3.GetError()),
	)
	assert(
		host.host_gsw3d_proof_create_surface(
			&h,
			host.Gsw3d_Proof_Surface {
				id = host.GSW3D_PROOF_TARGET_ID,
				format = vga.GSW3D_SVGA9_PROFILE_TARGET_FORMAT,
				width = HIGH_RESOLUTION_WIDTH,
				height = HIGH_RESOLUTION_HEIGHT,
			},
		),
		string(sdl3.GetError()),
	)
	defer host.host_gpu_surfaces_destroy(&h)
	low_texture := host.host_gpu_surface_texture(&h, LOW_RESOLUTION_SURFACE_ID)
	high_texture := host.host_gpu_surface_texture(&h, host.GSW3D_PROOF_TARGET_ID)
	format := sdl3.GetGPUTextureFormatFromPixelFormat(.BGRA32)
	assert(
		low_texture != nil &&
		high_texture != nil &&
		low_texture != high_texture &&
		format != .INVALID,
	)

	triangle: host.Gsw3d_Triangle_Renderer
	assert(host.gsw3d_triangle_renderer_init(&triangle, gpu), string(sdl3.GetError()))
	defer host.gsw3d_triangle_renderer_destroy(&triangle)
	low_rgba := make([]u8, int(host.GSW3D_PROOF_WIDTH * host.GSW3D_PROOF_HEIGHT * 4))
	defer delete(low_rgba)
	high_rgba := make([]u8, int(HIGH_RESOLUTION_WIDTH * HIGH_RESOLUTION_HEIGHT * 4))
	defer delete(high_rgba)
	first := capture_mixed_resolution_pair(
		&triangle,
		low_texture,
		high_texture,
		format,
		low_rgba,
		high_rgba,
		1,
	)
	second := capture_mixed_resolution_pair(
		&triangle,
		low_texture,
		high_texture,
		format,
		low_rgba,
		high_rgba,
		2,
	)
	assert(first.low.frame_crc32 == second.low.frame_crc32)
	assert(first.low.anchor_crc32 == second.low.anchor_crc32)
	assert(first.high.frame_crc32 == second.high.frame_crc32)
	assert(first.high.anchor_crc32 == second.high.anchor_crc32)
	assert(
		triangle.flight_count == 0 &&
		triangle.metrics.max_in_flight == host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT &&
		triangle.metrics.capacity_waits == 0,
	)
	present := host.Gsw3d_Proof_Present {
		surface_id  = host.GSW3D_PROOF_TARGET_ID,
		source      = {0, 0, HIGH_RESOLUTION_WIDTH, HIGH_RESOLUTION_HEIGHT},
		destination = {0, 0, HIGH_RESOLUTION_WIDTH, HIGH_RESOLUTION_HEIGHT},
		interval    = 1,
	}
	assert(host.host_gsw3d_proof_present(&h, &present))
	assert(
		h.gpu_present.surface_id == host.GSW3D_PROOF_TARGET_ID &&
		h.gpu_present.source ==
			host.Host_Gpu_Rect{0, 0, HIGH_RESOLUTION_WIDTH, HIGH_RESOLUTION_HEIGHT} &&
		h.gpu_present.destination ==
			host.Host_Gpu_Rect{0, 0, HIGH_RESOLUTION_WIDTH, HIGH_RESOLUTION_HEIGHT} &&
		h.gpu_present.canvas_width == HIGH_RESOLUTION_WIDTH &&
		h.gpu_present.canvas_height == HIGH_RESOLUTION_HEIGHT &&
		h.gpu_present.interval == 1 &&
		h.gpu_direct_presents == 1 &&
		h.has_frame,
	)
	active_texture := wrapped_surface(&h, h.gpu_present.surface_id)
	active_width, active_height: f32
	assert(
		active_texture != nil &&
		sdl3.GetTextureSize(active_texture, &active_width, &active_height) &&
		active_width == f32(HIGH_RESOLUTION_WIDTH) &&
		active_height == f32(HIGH_RESOLUTION_HEIGHT),
	)

	compositor_target := sdl3.CreateTexture(
		renderer,
		.RGBA32,
		.TARGET,
		c.int(host.GSW3D_PROOF_WIDTH),
		c.int(host.GSW3D_PROOF_HEIGHT),
	)
	assert(compositor_target != nil, string(sdl3.GetError()))
	defer sdl3.DestroyTexture(compositor_target)
	source := wrapped_surface(&h, LOW_RESOLUTION_SURFACE_ID)
	assert(source != nil && sdl3.SetTextureScaleMode(source, .NEAREST))
	composed_first := compose_capture(renderer, source, compositor_target, low_rgba)
	composed_second := compose_capture(renderer, source, compositor_target, low_rgba)
	assert(composed_first.frame_crc32 == composed_second.frame_crc32)
	assert(composed_first.anchor_crc32 == composed_second.anchor_crc32)
	fmt.printf(
		"GSW3D Vulkan readback passed: raw=%08x anchors=%08x composed=%08x\n",
		second.low.frame_crc32,
		second.low.anchor_crc32,
		composed_second.frame_crc32,
	)
	fmt.printf(
		"GSW3D 1600x1200 Vulkan readback passed: raw=%08x anchors=%08x\n",
		second.high.frame_crc32,
		second.high.anchor_crc32,
	)
}
