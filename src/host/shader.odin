// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import sdl3 "vendor:sdl3"

Visual_Shader :: enum u8 {
	None,
	Subtle,
	Not_So_Subtle,
}

Scaling_Filter :: enum u8 {
	Sharp,
	Nearest,
	Linear,
}

CRT_SHADER_SPIRV := #load("../../assets/shaders/retvrn99-crt.spv")

Crt_Uniforms :: struct {
	source_width:   f32,
	source_height:  f32,
	output_scale_x: f32,
	output_scale_y: f32,
	scaling_filter: f32,
	style:          f32,
	time_seconds:   f32,
	_padding:       f32,
}

Host_Scaling_Geometry :: struct {
	texture_extent: contract.Extent,
	canvas_extent:  contract.Extent,
	source:         contract.Rect,
	destination:    contract.Rect,
	canvas_output:  sdl3.FRect,
}

host_scaling_geometry_from_header :: proc(
	header: contract.Header,
	texture_width, texture_height: int,
	canvas_output: sdl3.FRect,
) -> Host_Scaling_Geometry {
	if texture_width <= 0 || texture_height <= 0 {return {}}
	return {
		texture_extent = {u32(texture_width), u32(texture_height)},
		canvas_extent = header.canvas_extent,
		source = header.source,
		destination = header.destination,
		canvas_output = canvas_output,
	}
}

host_scaling_effective_output_scale :: proc(geometry: Host_Scaling_Geometry) -> (f32, f32) {
	if geometry.texture_extent.width == 0 ||
	   geometry.texture_extent.height == 0 ||
	   geometry.canvas_extent.width == 0 ||
	   geometry.canvas_extent.height == 0 ||
	   !contract.rect_valid_nonempty(geometry.source) ||
	   !contract.rect_valid_nonempty(geometry.destination) ||
	   geometry.canvas_output.w <= 0 ||
	   geometry.canvas_output.h <= 0 {return 1, 1}
	canvas_scale_x := geometry.canvas_output.w / f32(geometry.canvas_extent.width)
	canvas_scale_y := geometry.canvas_output.h / f32(geometry.canvas_extent.height)
	source_to_canvas_x := f32(geometry.destination.width) / f32(geometry.source.width)
	source_to_canvas_y := f32(geometry.destination.height) / f32(geometry.source.height)
	return canvas_scale_x * source_to_canvas_x, canvas_scale_y * source_to_canvas_y
}

scaling_filter_name :: proc(filter: Scaling_Filter) -> cstring {
	switch filter {
	case .Sharp:
		return "Sharp"
	case .Nearest:
		return "Nearest"
	case .Linear:
		return "Linear"
	}
	return "Linear"
}

scaling_filter_available :: proc(filter: Scaling_Filter, shaders_available: bool) -> bool {
	return filter != .Sharp || shaders_available
}

visual_shader_name :: proc(style: Visual_Shader) -> cstring {
	switch style {
	case .None:
		return "None"
	case .Subtle:
		return "Subtle"
	case .Not_So_Subtle:
		return "Not So Subtle"
	}
	return "None"
}

host_shader_init :: proc(h: ^Host) -> bool {
	if h == nil || h.gpu == nil || h.ren == nil {return false}
	formats := sdl3.GetGPUShaderFormats(h.gpu)
	if .SPIRV not_in formats {return false}
	info := sdl3.GPUShaderCreateInfo {
		code_size           = uint(len(CRT_SHADER_SPIRV)),
		code                = ([^]u8)(raw_data(CRT_SHADER_SPIRV)),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = .FRAGMENT,
		num_samplers        = 1,
		num_uniform_buffers = 1,
	}
	h.shader = sdl3.CreateGPUShader(h.gpu, info)
	if h.shader == nil {return false}
	h.shader_state = sdl3.CreateGPURenderState(
		h.ren,
		sdl3.GPURenderStateCreateInfo{fragment_shader = h.shader},
	)
	if h.shader_state == nil {
		sdl3.ReleaseGPUShader(h.gpu, h.shader)
		h.shader = nil
		return false
	}
	return true
}

host_shader_destroy :: proc(h: ^Host) {
	if h == nil {return}
	if h.shader_state != nil {
		sdl3.DestroyGPURenderState(h.shader_state)
		h.shader_state = nil
	}
	if h.shader != nil && h.gpu != nil {
		sdl3.ReleaseGPUShader(h.gpu, h.shader)
		h.shader = nil
	}
}

host_set_visual_shader :: proc(h: ^Host, style: Visual_Shader) -> bool {
	if h == nil {return false}
	if style != .None && h.shader_state == nil {return false}
	h.visual_shader = style
	return true
}

@(private = "package")
host_texture_scale_mode :: proc(filter: Scaling_Filter) -> sdl3.ScaleMode {
	return filter == .Nearest ? .NEAREST : .LINEAR
}

@(private = "file")
host_apply_texture_scale_modes :: proc(h: ^Host) {
	if h == nil {return}
	mode := host_texture_scale_mode(h.scaling_filter)
	if h.tex != nil {_ = sdl3.SetTextureScaleMode(h.tex, mode)}
	state := host_presentation_state(h)
	if state.legacy_staging.texture != nil {
		_ = sdl3.SetTextureScaleMode(state.legacy_staging.texture, mode)
	}
	if state.gsw_texture != nil {
		_ = sdl3.SetTextureScaleMode(state.gsw_texture, mode)
	}
	if state.gsw_staging.texture != nil {
		_ = sdl3.SetTextureScaleMode(state.gsw_staging.texture, mode)
	}
	for &surface in h.gpu_surfaces {
		if surface.live && surface.render_texture != nil {
			_ = sdl3.SetTextureScaleMode(surface.render_texture, mode)
		}
	}
}

host_set_scaling_filter :: proc(h: ^Host, filter: Scaling_Filter) -> bool {
	if h == nil {return false}
	switch filter {
	case .Sharp:
		if !scaling_filter_available(filter, h.shader_state != nil) {return false}
	case .Nearest, .Linear:
	case:
		return false
	}
	h.scaling_filter = filter
	host_apply_texture_scale_modes(h)
	return true
}

host_shader_effect_requested :: proc(h: ^Host) -> bool {
	return h != nil && (h.scaling_filter == .Sharp || h.visual_shader != .None)
}

host_shader_fail_closed :: proc(h: ^Host) {
	if h == nil {return}
	if h.ren != nil && h.shader_state != nil {_ = sdl3.SetGPURenderState(h.ren, nil)}
	host_shader_destroy(h)
	if h.scaling_filter == .Sharp {h.scaling_filter = .Linear}
	h.visual_shader = .None
	host_apply_texture_scale_modes(h)
}

host_shader_begin :: proc(h: ^Host, geometry: Host_Scaling_Geometry) -> bool {
	if h == nil || h.shader_state == nil || !host_shader_effect_requested(h) {return false}
	output_scale_x, output_scale_y := host_scaling_effective_output_scale(geometry)
	uniforms := Crt_Uniforms {
		source_width   = f32(max(1, geometry.texture_extent.width)),
		source_height  = f32(max(1, geometry.texture_extent.height)),
		output_scale_x = output_scale_x,
		output_scale_y = output_scale_y,
		scaling_filter = f32(h.scaling_filter),
		style          = f32(h.visual_shader),
		time_seconds   = f32(sdl3.GetTicks()) / 1000.0,
	}
	if !sdl3.SetGPURenderStateFragmentUniforms(
		h.shader_state,
		0,
		&uniforms,
		u32(size_of(Crt_Uniforms)),
	) {
		host_shader_fail_closed(h)
		return false
	}
	if !sdl3.SetGPURenderState(h.ren, h.shader_state) {
		host_shader_fail_closed(h)
		return false
	}
	return true
}

host_shader_end :: proc(h: ^Host) {
	if h == nil || h.shader_state == nil {return}
	if !sdl3.SetGPURenderState(h.ren, nil) {host_shader_fail_closed(h)}
}
