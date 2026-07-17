// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

HOST_GPU_SURFACE_CAPACITY :: 256
HOST_GPU_SURFACE_MAX_DIMENSION :: u32(8192)
HOST_GPU_SURFACE_BUDGET_BYTES :: u64(256 * 1024 * 1024)
HOST_GPU_PRESENT_INTERVAL :: u32(1)

Host_Gpu_Surface_Format :: enum u32 {
	Bgra8_Unorm    = 1,
	Rgba8_Unorm    = 2,
	Rgb565_Unorm   = 3,
	Argb1555_Unorm = 4,
	Argb4444_Unorm = 5,
}

Host_Gpu_Surface_Descriptor :: struct {
	id:     u32,
	width:  u32,
	height: u32,
	format: Host_Gpu_Surface_Format,
}

Host_Gpu_Rect :: struct {
	x, y, width, height: u32,
}

Host_Gpu_Present :: struct {
	surface_id:    u32,
	source:        Host_Gpu_Rect,
	destination:   Host_Gpu_Rect,
	canvas_width:  u32,
	canvas_height: u32,
	interval:      u32,
}

Host_Gpu_Surface :: struct {
	live:           bool,
	descriptor:     Host_Gpu_Surface_Descriptor,
	byte_size:      u64,
	gpu_texture:    ^sdl3.GPUTexture,
	render_texture: ^sdl3.Texture,
}

host_gpu_surface_pixel_format :: proc(
	format: Host_Gpu_Surface_Format,
) -> (
	sdl3.PixelFormat,
	u32,
	bool,
) {
	switch format {
	case .Bgra8_Unorm:
		return .BGRA32, 4, true
	case .Rgba8_Unorm:
		return .RGBA32, 4, true
	case .Rgb565_Unorm, .Argb1555_Unorm, .Argb4444_Unorm:
		return .UNKNOWN, 0, false
	}
	return .UNKNOWN, 0, false
}

host_gpu_surface_byte_size :: proc(descriptor: Host_Gpu_Surface_Descriptor) -> (u64, bool) {
	_, bytes_per_pixel, known := host_gpu_surface_pixel_format(descriptor.format)
	if !known ||
	   descriptor.id == 0 ||
	   descriptor.width == 0 ||
	   descriptor.height == 0 ||
	   descriptor.width > HOST_GPU_SURFACE_MAX_DIMENSION ||
	   descriptor.height > HOST_GPU_SURFACE_MAX_DIMENSION {
		return 0, false
	}
	byte_size := u64(descriptor.width) * u64(descriptor.height) * u64(bytes_per_pixel)
	return byte_size, byte_size <= HOST_GPU_SURFACE_BUDGET_BYTES
}

host_gpu_surface_can_allocate :: proc(
	used_bytes: u64,
	descriptor: Host_Gpu_Surface_Descriptor,
) -> bool {
	byte_size, valid := host_gpu_surface_byte_size(descriptor)
	return valid && used_bytes <= HOST_GPU_SURFACE_BUDGET_BYTES - byte_size
}

host_gpu_surface_can_replace :: proc(
	used_bytes, replaced_bytes: u64,
	descriptor: Host_Gpu_Surface_Descriptor,
) -> bool {
	// The old texture remains live until the replacement has been created and
	// wrapped, so both allocations count against the hard transient budget.
	return replaced_bytes <= used_bytes && host_gpu_surface_can_allocate(used_bytes, descriptor)
}

host_gpu_rect_fits :: proc(rect: Host_Gpu_Rect, width, height: u32) -> bool {
	return(
		rect.width != 0 &&
		rect.height != 0 &&
		rect.x <= width &&
		rect.y <= height &&
		rect.width <= width - rect.x &&
		rect.height <= height - rect.y \
	)
}

host_gpu_present_valid :: proc(
	present: Host_Gpu_Present,
	descriptor: Host_Gpu_Surface_Descriptor,
) -> bool {
	return(
		present.surface_id != 0 &&
		present.surface_id == descriptor.id &&
		present.canvas_width != 0 &&
		present.canvas_height != 0 &&
		present.canvas_width <= HOST_GPU_SURFACE_MAX_DIMENSION &&
		present.canvas_height <= HOST_GPU_SURFACE_MAX_DIMENSION &&
		present.interval == HOST_GPU_PRESENT_INTERVAL &&
		host_gpu_rect_fits(present.source, descriptor.width, descriptor.height) &&
		host_gpu_rect_fits(present.destination, present.canvas_width, present.canvas_height) \
	)
}

host_gpu_present_destination :: proc(base: sdl3.FRect, present: Host_Gpu_Present) -> sdl3.FRect {
	if present.canvas_width == 0 || present.canvas_height == 0 {return {}}
	return {
		base.x + base.w * f32(present.destination.x) / f32(present.canvas_width),
		base.y + base.h * f32(present.destination.y) / f32(present.canvas_height),
		base.w * f32(present.destination.width) / f32(present.canvas_width),
		base.h * f32(present.destination.height) / f32(present.canvas_height),
	}
}

@(private = "file")
host_gpu_surface_find :: proc(h: ^Host, id: u32) -> ^Host_Gpu_Surface {
	if h == nil || id == 0 {return nil}
	for &surface in h.gpu_surfaces {
		if surface.live && surface.descriptor.id == id {return &surface}
	}
	return nil
}

@(private = "file")
host_gpu_surface_free_slot :: proc(h: ^Host) -> ^Host_Gpu_Surface {
	for &surface in h.gpu_surfaces {if !surface.live {return &surface}}
	return nil
}

host_gpu_surface_texture :: proc(h: ^Host, id: u32) -> ^sdl3.GPUTexture {
	surface := host_gpu_surface_find(h, id)
	return surface != nil ? surface.gpu_texture : nil
}

@(private = "package")
host_gpu_surface_render_target :: proc(
	h: ^Host,
	id: u32,
) -> (
	texture: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	width, height: u32,
	ok: bool,
) {
	surface := host_gpu_surface_find(h, id)
	if surface == nil || surface.gpu_texture == nil || h.gpu == nil {return}
	pixel_format, _, known := host_gpu_surface_pixel_format(surface.descriptor.format)
	if !known {return}
	format = sdl3.GetGPUTextureFormatFromPixelFormat(pixel_format)
	if format == .INVALID {return}
	return surface.gpu_texture, format, surface.descriptor.width, surface.descriptor.height, true
}

host_gpu_surface_create :: proc(h: ^Host, descriptor: Host_Gpu_Surface_Descriptor) -> bool {
	if h == nil || h.gpu == nil || h.ren == nil {
		return false
	}
	existing := host_gpu_surface_find(h, descriptor.id)
	replaced_bytes := existing != nil ? existing.byte_size : u64(0)
	if !host_gpu_surface_can_replace(
		h.gpu_surface_bytes,
		replaced_bytes,
		descriptor,
	) {return false}
	slot := existing
	if slot == nil {slot = host_gpu_surface_free_slot(h)}
	if slot == nil {return false}

	pixel_format, _, known := host_gpu_surface_pixel_format(descriptor.format)
	if !known {return false}
	gpu_format := sdl3.GetGPUTextureFormatFromPixelFormat(pixel_format)
	usage: sdl3.GPUTextureUsageFlags = {.SAMPLER, .COLOR_TARGET}
	if gpu_format == .INVALID || !sdl3.GPUTextureSupportsFormat(h.gpu, gpu_format, .D2, usage) {
		return false
	}
	create_info := sdl3.GPUTextureCreateInfo {
		type                 = .D2,
		format               = gpu_format,
		usage                = usage,
		width                = descriptor.width,
		height               = descriptor.height,
		layer_count_or_depth = 1,
		num_levels           = 1,
		sample_count         = ._1,
	}
	gpu_texture := sdl3.CreateGPUTexture(h.gpu, create_info)
	if gpu_texture == nil {return false}

	props := sdl3.CreateProperties()
	if props == 0 {
		sdl3.ReleaseGPUTexture(h.gpu, gpu_texture)
		return false
	}
	defer sdl3.DestroyProperties(props)
	properties_ok :=
		sdl3.SetNumberProperty(
			props,
			sdl3.PROP_TEXTURE_CREATE_FORMAT_NUMBER,
			sdl3.Sint64(pixel_format),
		) &&
		sdl3.SetNumberProperty(
			props,
			sdl3.PROP_TEXTURE_CREATE_ACCESS_NUMBER,
			sdl3.Sint64(sdl3.TextureAccess.STATIC),
		) &&
		sdl3.SetNumberProperty(
			props,
			sdl3.PROP_TEXTURE_CREATE_WIDTH_NUMBER,
			sdl3.Sint64(descriptor.width),
		) &&
		sdl3.SetNumberProperty(
			props,
			sdl3.PROP_TEXTURE_CREATE_HEIGHT_NUMBER,
			sdl3.Sint64(descriptor.height),
		) &&
		sdl3.SetPointerProperty(props, sdl3.PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, gpu_texture)
	if !properties_ok {
		sdl3.ReleaseGPUTexture(h.gpu, gpu_texture)
		return false
	}
	render_texture := sdl3.CreateTextureWithProperties(h.ren, props)
	if render_texture == nil {
		sdl3.ReleaseGPUTexture(h.gpu, gpu_texture)
		return false
	}
	render_props := sdl3.GetTextureProperties(render_texture)
	if render_props == 0 {
		sdl3.DestroyTexture(render_texture)
		sdl3.ReleaseGPUTexture(h.gpu, gpu_texture)
		return false
	}
	wrapped_texture := sdl3.GetPointerProperty(
		render_props,
		sdl3.PROP_TEXTURE_GPU_TEXTURE_POINTER,
		nil,
	)
	if wrapped_texture != rawptr(gpu_texture) ||
	   !sdl3.SetTextureBlendMode(render_texture, sdl3.BLENDMODE_NONE) ||
	   !sdl3.SetTextureScaleMode(render_texture, .LINEAR) {
		sdl3.DestroyTexture(render_texture)
		sdl3.ReleaseGPUTexture(h.gpu, gpu_texture)
		return false
	}
	byte_size, _ := host_gpu_surface_byte_size(descriptor)
	previous := slot^
	slot^ = {
		live           = true,
		descriptor     = descriptor,
		byte_size      = byte_size,
		gpu_texture    = gpu_texture,
		render_texture = render_texture,
	}
	h.gpu_surface_bytes = h.gpu_surface_bytes - replaced_bytes + byte_size
	if previous.live {
		// Replacement storage is undefined until the backend renders or uploads
		// it, even when the new descriptor has the same dimensions and format.
		if h.gpu_present.surface_id == descriptor.id {
			h.gpu_present = {}
			h.has_frame = false
		}
		if previous.render_texture != nil {sdl3.DestroyTexture(previous.render_texture)}
		if previous.gpu_texture != nil {sdl3.ReleaseGPUTexture(h.gpu, previous.gpu_texture)}
	}
	return true
}

host_gpu_surface_destroy :: proc(h: ^Host, id: u32) -> bool {
	surface := host_gpu_surface_find(h, id)
	if surface == nil {return false}
	if h.gpu_present.surface_id == id {
		h.gpu_present = {}
		h.has_frame = false
	}
	if surface.render_texture != nil {sdl3.DestroyTexture(surface.render_texture)}
	if surface.gpu_texture != nil &&
	   h.gpu != nil {sdl3.ReleaseGPUTexture(h.gpu, surface.gpu_texture)}
	if surface.byte_size <=
	   h.gpu_surface_bytes {h.gpu_surface_bytes -= surface.byte_size} else {h.gpu_surface_bytes = 0}
	surface^ = {}
	return true
}

host_gpu_surfaces_destroy :: proc(h: ^Host) {
	if h == nil {return}
	for &surface in h.gpu_surfaces {
		if !surface.live {continue}
		if surface.render_texture != nil {sdl3.DestroyTexture(surface.render_texture)}
		if surface.gpu_texture != nil &&
		   h.gpu != nil {sdl3.ReleaseGPUTexture(h.gpu, surface.gpu_texture)}
		surface = {}
	}
	h.gpu_surface_bytes = 0
	h.gpu_present = {}
}

host_gpu_surface_present :: proc(h: ^Host, present: Host_Gpu_Present) -> bool {
	surface := host_gpu_surface_find(h, present.surface_id)
	if surface == nil ||
	   surface.render_texture == nil ||
	   !host_gpu_present_valid(present, surface.descriptor) {
		return false
	}
	h.gpu_present = present
	h.aspect_width = int(present.canvas_width)
	h.aspect_height = int(present.canvas_height)
	h.has_frame = true
	h.gpu_direct_presents += 1
	return true
}

@(private = "package")
host_active_texture :: proc(h: ^Host) -> (^sdl3.Texture, sdl3.FRect, bool, ^Host_Gpu_Present) {
	if h == nil {return nil, {}, false, nil}
	if h.gpu_present.surface_id != 0 {
		surface := host_gpu_surface_find(h, h.gpu_present.surface_id)
		if surface != nil && surface.render_texture != nil {
			source := sdl3.FRect {
				f32(h.gpu_present.source.x),
				f32(h.gpu_present.source.y),
				f32(h.gpu_present.source.width),
				f32(h.gpu_present.source.height),
			}
			return surface.render_texture, source, true, &h.gpu_present
		}
	}
	return h.tex, {}, false, nil
}
