// SPDX-License-Identifier: GPL-3.0-only
package main

import host "../../src/host"
import "core:c"
import "core:fmt"
import "core:time"
import sdl3 "vendor:sdl3"

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

capture :: proc(
	renderer: ^host.Gsw3d_Triangle_Renderer,
	texture: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	rgba: []u8,
	generation: u64,
) -> host.Gsw3d_Proof_Readback_Signature {
	vertices := host.gsw3d_triangle_proof_vertices()
	token, submitted := host.gsw3d_triangle_render_async(
		renderer,
		texture,
		format,
		host.GSW3D_PROOF_WIDTH,
		host.GSW3D_PROOF_HEIGHT,
		&vertices,
		generation,
	)
	assert(submitted && token != 0, string(sdl3.GetError()))
	completed: [host.GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]host.Gsw3d_Triangle_Completion
	count := 0
	for _ in 0 ..< 5000 {
		polled: bool
		count, polled = host.gsw3d_triangle_poll(renderer, completed[:])
		assert(polled)
		if count != 0 {break}
		time.sleep(time.Millisecond)
	}
	assert(count == 1 && completed[0].token == token && renderer.flight_count == 0)
	assert(
		host.gsw3d_debug_readback_rgba_sync(
			renderer,
			texture,
			format,
			host.GSW3D_PROOF_WIDTH,
			host.GSW3D_PROOF_HEIGHT,
			rgba,
		),
		string(sdl3.GetError()),
	)
	signature, signed := host.gsw3d_proof_readback_signature(
		rgba,
		host.GSW3D_PROOF_WIDTH,
		host.GSW3D_PROOF_HEIGHT,
	)
	assert(signed && host.gsw3d_proof_readback_anchors_valid(signature))
	return signature
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
				id = host.GSW3D_PROOF_TARGET_ID,
				width = host.GSW3D_PROOF_WIDTH,
				height = host.GSW3D_PROOF_HEIGHT,
				format = .Bgra8_Unorm,
			},
		),
		string(sdl3.GetError()),
	)
	defer host.host_gpu_surfaces_destroy(&h)
	texture := host.host_gpu_surface_texture(&h, host.GSW3D_PROOF_TARGET_ID)
	format := sdl3.GetGPUTextureFormatFromPixelFormat(.BGRA32)
	assert(texture != nil && format != .INVALID)

	triangle: host.Gsw3d_Triangle_Renderer
	assert(host.gsw3d_triangle_renderer_init(&triangle, gpu), string(sdl3.GetError()))
	defer host.gsw3d_triangle_renderer_destroy(&triangle)
	rgba := make([]u8, int(host.GSW3D_PROOF_WIDTH * host.GSW3D_PROOF_HEIGHT * 4))
	defer delete(rgba)
	first := capture(&triangle, texture, format, rgba, 1)
	second := capture(&triangle, texture, format, rgba, 1)
	assert(first.frame_crc32 == second.frame_crc32)
	assert(first.anchor_crc32 == second.anchor_crc32)
	assert(triangle.flight_count == 0 && triangle.metrics.capacity_waits == 0)

	compositor_target := sdl3.CreateTexture(
		renderer,
		.RGBA32,
		.TARGET,
		c.int(host.GSW3D_PROOF_WIDTH),
		c.int(host.GSW3D_PROOF_HEIGHT),
	)
	assert(compositor_target != nil, string(sdl3.GetError()))
	defer sdl3.DestroyTexture(compositor_target)
	source := wrapped_surface(&h, host.GSW3D_PROOF_TARGET_ID)
	assert(source != nil && sdl3.SetTextureScaleMode(source, .NEAREST))
	composed_first := compose_capture(renderer, source, compositor_target, rgba)
	composed_second := compose_capture(renderer, source, compositor_target, rgba)
	assert(composed_first.frame_crc32 == composed_second.frame_crc32)
	assert(composed_first.anchor_crc32 == composed_second.anchor_crc32)
	fmt.printf(
		"GSW3D Vulkan readback passed: raw=%08x anchors=%08x composed=%08x\n",
		second.frame_crc32,
		second.anchor_crc32,
		composed_second.frame_crc32,
	)
}
