// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:mem"
import sdl3 "vendor:sdl3"

GSW3D_TRIANGLE_VERTEX_COUNT :: 3
GSW3D_TRIANGLE_VERTEX_BYTES :: u32(60)
GSW3D_TRIANGLE_PIPELINE_CAPACITY :: 2

GSW3D_TRIANGLE_VERTEX_SPIRV := #load("../../assets/shaders/gsw3d-triangle.vert.spv")
GSW3D_TRIANGLE_FRAGMENT_SPIRV := #load("../../assets/shaders/gsw3d-triangle.frag.spv")

Gsw3d_Triangle_Vertex :: struct {
	position: [4]f32,
	color:    u32,
}

Gsw3d_Triangle_Uniforms :: struct {
	target_width:  f32,
	target_height: f32,
	padding:       [2]f32,
}

Gsw3d_Triangle_Pipeline :: struct {
	format:   sdl3.GPUTextureFormat,
	pipeline: ^sdl3.GPUGraphicsPipeline,
}

Gsw3d_Triangle_Renderer :: struct {
	gpu:             ^sdl3.GPUDevice,
	vertex_shader:   ^sdl3.GPUShader,
	fragment_shader: ^sdl3.GPUShader,
	vertex_buffer:   ^sdl3.GPUBuffer,
	transfer_buffer: ^sdl3.GPUTransferBuffer,
	pipelines:       [GSW3D_TRIANGLE_PIPELINE_CAPACITY]Gsw3d_Triangle_Pipeline,
	live:            bool,
}

#assert(
	size_of(Gsw3d_Triangle_Vertex) == GSW3D_TRIANGLE_VERTEX_BYTES / GSW3D_TRIANGLE_VERTEX_COUNT,
)
#assert(size_of(Gsw3d_Triangle_Uniforms) == 16)

gsw3d_triangle_format_supported :: proc(format: sdl3.GPUTextureFormat) -> bool {
	return format == .B8G8R8A8_UNORM || format == .R8G8B8A8_UNORM
}

gsw3d_triangle_target_valid :: proc(format: sdl3.GPUTextureFormat, width, height: u32) -> bool {
	return(
		gsw3d_triangle_format_supported(format) &&
		width > 0 &&
		height > 0 &&
		width <= HOST_GPU_SURFACE_MAX_DIMENSION &&
		height <= HOST_GPU_SURFACE_MAX_DIMENSION \
	)
}

gsw3d_triangle_positiont_clip :: proc(position: [4]f32, width, height: u32) -> [4]f32 {
	if width == 0 || height == 0 {return {}}
	return {
		position.x * (2.0 / f32(width)) - 1.0,
		1.0 - position.y * (2.0 / f32(height)),
		position.z,
		1.0,
	}
}

gsw3d_triangle_proof_vertices :: proc() -> [GSW3D_TRIANGLE_VERTEX_COUNT]Gsw3d_Triangle_Vertex {
	return {
		{{320, 80, 0.5, 1}, 0xffff_0000},
		{{560, 400, 0.5, 1}, 0xff00_ff00},
		{{80, 400, 0.5, 1}, 0xff00_00ff},
	}
}

gsw3d_triangle_renderer_init :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	gpu: ^sdl3.GPUDevice,
) -> (
	ok: bool,
) {
	if renderer == nil || gpu == nil || renderer.live || renderer.gpu != nil {return false}
	renderer^ = {
		gpu = gpu,
	}
	defer if !ok {gsw3d_triangle_renderer_destroy(renderer)}

	if .SPIRV not_in sdl3.GetGPUShaderFormats(gpu) {return false}
	vertex_info := sdl3.GPUShaderCreateInfo {
		code_size           = uint(len(GSW3D_TRIANGLE_VERTEX_SPIRV)),
		code                = ([^]u8)(raw_data(GSW3D_TRIANGLE_VERTEX_SPIRV)),
		entrypoint          = "vs_main",
		format              = {.SPIRV},
		stage               = .VERTEX,
		num_uniform_buffers = 1,
	}
	renderer.vertex_shader = sdl3.CreateGPUShader(gpu, vertex_info)
	if renderer.vertex_shader == nil {return false}
	fragment_info := sdl3.GPUShaderCreateInfo {
		code_size  = uint(len(GSW3D_TRIANGLE_FRAGMENT_SPIRV)),
		code       = ([^]u8)(raw_data(GSW3D_TRIANGLE_FRAGMENT_SPIRV)),
		entrypoint = "ps_main",
		format     = {.SPIRV},
		stage      = .FRAGMENT,
	}
	renderer.fragment_shader = sdl3.CreateGPUShader(gpu, fragment_info)
	if renderer.fragment_shader == nil {return false}
	renderer.vertex_buffer = sdl3.CreateGPUBuffer(
		gpu,
		sdl3.GPUBufferCreateInfo{usage = {.VERTEX}, size = GSW3D_TRIANGLE_VERTEX_BYTES},
	)
	if renderer.vertex_buffer == nil {return false}
	renderer.transfer_buffer = sdl3.CreateGPUTransferBuffer(
		gpu,
		sdl3.GPUTransferBufferCreateInfo{usage = .UPLOAD, size = GSW3D_TRIANGLE_VERTEX_BYTES},
	)
	if renderer.transfer_buffer == nil {return false}
	renderer.live = true
	return true
}

gsw3d_triangle_renderer_destroy :: proc(renderer: ^Gsw3d_Triangle_Renderer) {
	if renderer == nil {return}
	if renderer.gpu != nil {
		for cached in renderer.pipelines {
			if cached.pipeline != nil {
				sdl3.ReleaseGPUGraphicsPipeline(renderer.gpu, cached.pipeline)
			}
		}
		if renderer.transfer_buffer != nil {
			sdl3.ReleaseGPUTransferBuffer(renderer.gpu, renderer.transfer_buffer)
		}
		if renderer.vertex_buffer != nil {
			sdl3.ReleaseGPUBuffer(renderer.gpu, renderer.vertex_buffer)
		}
		if renderer.fragment_shader != nil {
			sdl3.ReleaseGPUShader(renderer.gpu, renderer.fragment_shader)
		}
		if renderer.vertex_shader != nil {
			sdl3.ReleaseGPUShader(renderer.gpu, renderer.vertex_shader)
		}
	}
	renderer^ = {}
}

@(private = "file")
gsw3d_triangle_pipeline :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	format: sdl3.GPUTextureFormat,
) -> ^sdl3.GPUGraphicsPipeline {
	if renderer == nil || !renderer.live || !gsw3d_triangle_format_supported(format) {return nil}
	free_slot: ^Gsw3d_Triangle_Pipeline
	for &cached in renderer.pipelines {
		if cached.pipeline != nil && cached.format == format {return cached.pipeline}
		if cached.pipeline == nil && free_slot == nil {free_slot = &cached}
	}
	if free_slot == nil {return nil}

	vertex_buffers := [1]sdl3.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Gsw3d_Triangle_Vertex)), input_rate = .VERTEX},
	}
	attributes := [2]sdl3.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT4, offset = 0},
		{location = 1, buffer_slot = 0, format = .UBYTE4_NORM, offset = 16},
	}
	targets := [1]sdl3.GPUColorTargetDescription {
		{
			format = format,
			blend_state = {
				color_write_mask = {.R, .G, .B, .A},
				enable_blend = false,
				enable_color_write_mask = true,
			},
		},
	}
	create_info := sdl3.GPUGraphicsPipelineCreateInfo {
		vertex_shader = renderer.vertex_shader,
		fragment_shader = renderer.fragment_shader,
		vertex_input_state = {
			vertex_buffer_descriptions = raw_data(vertex_buffers[:]),
			num_vertex_buffers = u32(len(vertex_buffers)),
			vertex_attributes = raw_data(attributes[:]),
			num_vertex_attributes = u32(len(attributes)),
		},
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {
			fill_mode = .FILL,
			cull_mode = .NONE,
			front_face = .COUNTER_CLOCKWISE,
			enable_depth_clip = true,
		},
		multisample_state = {sample_count = ._1},
		target_info = {
			color_target_descriptions = raw_data(targets[:]),
			num_color_targets = u32(len(targets)),
		},
	}
	pipeline := sdl3.CreateGPUGraphicsPipeline(renderer.gpu, create_info)
	if pipeline == nil {return nil}
	free_slot^ = {format, pipeline}
	return pipeline
}

gsw3d_triangle_render_sync :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	target: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	width, height: u32,
	vertices: ^[GSW3D_TRIANGLE_VERTEX_COUNT]Gsw3d_Triangle_Vertex,
	clear_color: sdl3.FColor = {16.0 / 255.0, 16.0 / 255.0, 24.0 / 255.0, 1},
) -> bool {
	if renderer == nil ||
	   !renderer.live ||
	   target == nil ||
	   vertices == nil ||
	   !gsw3d_triangle_target_valid(format, width, height) {return false}
	pipeline := gsw3d_triangle_pipeline(renderer, format)
	if pipeline == nil {return false}

	mapped := sdl3.MapGPUTransferBuffer(renderer.gpu, renderer.transfer_buffer, true)
	if mapped == nil {return false}
	mem.copy(mapped, vertices, int(GSW3D_TRIANGLE_VERTEX_BYTES))
	sdl3.UnmapGPUTransferBuffer(renderer.gpu, renderer.transfer_buffer)

	command_buffer := sdl3.AcquireGPUCommandBuffer(renderer.gpu)
	if command_buffer == nil {return false}
	submitted := false
	defer if !submitted {_ = sdl3.CancelGPUCommandBuffer(command_buffer)}

	copy_pass := sdl3.BeginGPUCopyPass(command_buffer)
	if copy_pass == nil {return false}
	sdl3.UploadToGPUBuffer(
		copy_pass,
		sdl3.GPUTransferBufferLocation{renderer.transfer_buffer, 0},
		sdl3.GPUBufferRegion{renderer.vertex_buffer, 0, GSW3D_TRIANGLE_VERTEX_BYTES},
		true,
	)
	sdl3.EndGPUCopyPass(copy_pass)

	uniforms := Gsw3d_Triangle_Uniforms {
		target_width  = f32(width),
		target_height = f32(height),
	}
	sdl3.PushGPUVertexUniformData(command_buffer, 0, &uniforms, u32(size_of(uniforms)))
	target_info := [1]sdl3.GPUColorTargetInfo {
		{
			texture = target,
			clear_color = clear_color,
			load_op = .CLEAR,
			store_op = .STORE,
			cycle = true,
		},
	}
	render_pass := sdl3.BeginGPURenderPass(command_buffer, raw_data(target_info[:]), 1, nil)
	if render_pass == nil {return false}
	sdl3.BindGPUGraphicsPipeline(render_pass, pipeline)
	bindings := [1]sdl3.GPUBufferBinding{{renderer.vertex_buffer, 0}}
	sdl3.BindGPUVertexBuffers(render_pass, 0, raw_data(bindings[:]), 1)
	sdl3.DrawGPUPrimitives(render_pass, GSW3D_TRIANGLE_VERTEX_COUNT, 1, 0, 0)
	sdl3.EndGPURenderPass(render_pass)

	submitted = true
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
	if fence == nil {return false}
	defer sdl3.ReleaseGPUFence(renderer.gpu, fence)
	if sdl3.QueryGPUFence(renderer.gpu, fence) {return true}
	fences := [1]^sdl3.GPUFence{fence}
	return(
		sdl3.WaitForGPUFences(renderer.gpu, true, raw_data(fences[:]), 1) &&
		sdl3.QueryGPUFence(renderer.gpu, fence) \
	)
}
