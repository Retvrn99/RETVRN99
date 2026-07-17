// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

Visual_Shader :: enum u8 {
	None,
	Subtle,
	Not_So_Subtle,
}

CRT_SHADER_SPIRV := #load("../../assets/shaders/retvrn99-crt.spv")

Crt_Uniforms :: struct {
	source_width:  f32,
	source_height: f32,
	style:         f32,
	time_seconds:  f32,
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
	if h.tex != nil {
		sdl3.SetTextureScaleMode(h.tex, style == .None ? .NEAREST : .LINEAR)
	}
	return true
}

host_shader_begin :: proc(h: ^Host) -> bool {
	if h == nil || h.shader_state == nil || h.visual_shader == .None {return false}
	uniforms := Crt_Uniforms {
		source_width  = f32(max(1, h.tex_width)),
		source_height = f32(max(1, h.tex_height)),
		style         = h.visual_shader == .Subtle ? 1 : 2,
		time_seconds  = f32(sdl3.GetTicks()) / 1000.0,
	}
	if !sdl3.SetGPURenderStateFragmentUniforms(
		h.shader_state,
		0,
		&uniforms,
		u32(size_of(Crt_Uniforms)),
	) {
		return false
	}
	return sdl3.SetGPURenderState(h.ren, h.shader_state)
}

host_shader_end :: proc(h: ^Host) {
	if h == nil || h.shader_state == nil {return}
	_ = sdl3.SetGPURenderState(h.ren, nil)
}
