// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:mem"
import "core:time"
import sdl3 "vendor:sdl3"

GSW3D_TRIANGLE_VERTEX_COUNT :: 3
GSW3D_TRIANGLE_VERTEX_BYTES :: u32(60)
GSW3D_TRIANGLE_PIPELINE_CAPACITY :: 2
GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT :: 2

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

Gsw3d_Triangle_Completion :: struct {
	token:      u64,
	generation: u64,
}

// The tick is the host observation of a successful fence submission.
Gsw3d_Triangle_Fence_Stamp :: struct {
	tick:       time.Tick,
	token:      u64,
	generation: u64,
}

// The observed tick is when the host proves retirement, not a device timestamp.
Gsw3d_Triangle_Completion_Stamp :: struct {
	submit_tick:   time.Tick,
	observed_tick: time.Tick,
	token:         u64,
	generation:    u64,
	duration_ns:   u64,
	discarded:     bool,
}

Gsw3d_Triangle_Flight :: struct {
	completion:   Gsw3d_Triangle_Completion,
	submitted_at: time.Tick,
	fence:        ^sdl3.GPUFence,
	discarded:    bool,
}

Gsw3d_Triangle_Query_Fence_Proc :: proc(ctx: rawptr, fence: ^sdl3.GPUFence) -> bool
Gsw3d_Triangle_Wait_Fences_Proc :: proc(ctx: rawptr, fences: []^sdl3.GPUFence) -> bool
Gsw3d_Triangle_Release_Fence_Proc :: proc(ctx: rawptr, fence: ^sdl3.GPUFence)

Gsw3d_Triangle_Fence_Ops :: struct {
	ctx:     rawptr,
	query:   Gsw3d_Triangle_Query_Fence_Proc,
	wait:    Gsw3d_Triangle_Wait_Fences_Proc,
	release: Gsw3d_Triangle_Release_Fence_Proc,
}

Gsw3d_Triangle_Metrics :: struct {
	submission_calls:        u64,
	submission_failures:     u64,
	submission_ns:           u64,
	latest_submission_ns:    u64,
	submissions:             u64,
	completions:             u64,
	completion_ns:           u64,
	capacity_waits:          u64,
	capacity_wait_ns:        u64,
	latest_capacity_wait_ns: u64,
	max_in_flight:           u32,
	latest_submission:       Gsw3d_Triangle_Fence_Stamp,
	latest_completion:       Gsw3d_Triangle_Completion_Stamp,
}

Gsw3d_Triangle_Renderer :: struct {
	gpu:             ^sdl3.GPUDevice,
	vertex_shader:   ^sdl3.GPUShader,
	fragment_shader: ^sdl3.GPUShader,
	vertex_buffer:   ^sdl3.GPUBuffer,
	transfer_buffer: ^sdl3.GPUTransferBuffer,
	pipelines:       [GSW3D_TRIANGLE_PIPELINE_CAPACITY]Gsw3d_Triangle_Pipeline,
	flights:         [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]Gsw3d_Triangle_Flight,
	flight_head:     int,
	flight_count:    int,
	next_token:      u64,
	fence_ops:       Gsw3d_Triangle_Fence_Ops,
	metrics:         Gsw3d_Triangle_Metrics,
	live:            bool,
}

@(private = "package")
gsw3d_triangle_note_submission :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	started, completed: time.Tick,
	succeeded: bool,
) {
	if renderer == nil {return}
	duration_ns := u64(max(time.Duration(0), time.tick_diff(started, completed)))
	renderer.metrics.submission_calls += 1
	renderer.metrics.submission_ns += duration_ns
	renderer.metrics.latest_submission_ns = duration_ns
	if !succeeded {renderer.metrics.submission_failures += 1}
}

#assert(
	size_of(Gsw3d_Triangle_Vertex) == GSW3D_TRIANGLE_VERTEX_BYTES / GSW3D_TRIANGLE_VERTEX_COUNT,
)
#assert(size_of(Gsw3d_Triangle_Uniforms) == 16)

@(private = "file")
gsw3d_triangle_sdl_query_fence :: proc(ctx: rawptr, fence: ^sdl3.GPUFence) -> bool {
	return ctx != nil && fence != nil && sdl3.QueryGPUFence((^sdl3.GPUDevice)(ctx), fence)
}

@(private = "file")
gsw3d_triangle_sdl_wait_fences :: proc(ctx: rawptr, fences: []^sdl3.GPUFence) -> bool {
	return(
		ctx != nil &&
		len(fences) > 0 &&
		sdl3.WaitForGPUFences((^sdl3.GPUDevice)(ctx), true, raw_data(fences), u32(len(fences))) \
	)
}

@(private = "file")
gsw3d_triangle_sdl_release_fence :: proc(ctx: rawptr, fence: ^sdl3.GPUFence) {
	if ctx != nil && fence != nil {sdl3.ReleaseGPUFence((^sdl3.GPUDevice)(ctx), fence)}
}

@(private = "file")
gsw3d_triangle_fence_ops_valid :: proc(ops: Gsw3d_Triangle_Fence_Ops) -> bool {
	return ops.ctx != nil && ops.query != nil && ops.wait != nil && ops.release != nil
}

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

@(private = "file")
gsw3d_triangle_next_token :: proc(renderer: ^Gsw3d_Triangle_Renderer) -> u64 {
	renderer.next_token += 1
	if renderer.next_token == 0 {renderer.next_token = 1}
	return renderer.next_token
}

@(private = "package")
gsw3d_triangle_track_fence_at :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	fence: ^sdl3.GPUFence,
	generation: u64,
	submitted_at: time.Tick,
) -> (
	token: u64,
	ok: bool,
) {
	if renderer == nil ||
	   fence == nil ||
	   generation == 0 ||
	   renderer.flight_count < 0 ||
	   renderer.flight_count >= GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT {return 0, false}
	submit_tick := submitted_at
	if submit_tick == (time.Tick{}) {submit_tick = time.tick_now()}
	token = gsw3d_triangle_next_token(renderer)
	tail := (renderer.flight_head + renderer.flight_count) % GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT
	renderer.flights[tail] = {
		completion = {token = token, generation = generation},
		submitted_at = submit_tick,
		fence = fence,
	}
	renderer.flight_count += 1
	renderer.metrics.submissions += 1
	renderer.metrics.latest_submission = {
		tick       = submit_tick,
		token      = token,
		generation = generation,
	}
	renderer.metrics.max_in_flight = max(
		renderer.metrics.max_in_flight,
		u32(renderer.flight_count),
	)
	return token, true
}

@(private = "package")
gsw3d_triangle_track_fence :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	fence: ^sdl3.GPUFence,
	generation: u64,
) -> (
	token: u64,
	ok: bool,
) {
	return gsw3d_triangle_track_fence_at(renderer, fence, generation, time.tick_now())
}

@(private = "file")
gsw3d_triangle_retire_head_at :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	completed_at: time.Tick,
) -> (
	completion: Gsw3d_Triangle_Completion,
	publish: bool,
	ok: bool,
) {
	if renderer == nil ||
	   renderer.flight_count <= 0 ||
	   renderer.flight_count > GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT ||
	   !gsw3d_triangle_fence_ops_valid(renderer.fence_ops) {return {}, false, false}
	retirement_tick := completed_at
	if retirement_tick == (time.Tick{}) {retirement_tick = time.tick_now()}
	flight := renderer.flights[renderer.flight_head]
	if flight.fence == nil {return {}, false, false}
	renderer.fence_ops.release(renderer.fence_ops.ctx, flight.fence)
	renderer.flights[renderer.flight_head] = {}
	renderer.flight_head = (renderer.flight_head + 1) % GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT
	renderer.flight_count -= 1
	duration_ns := u64(max(time.Duration(0), time.tick_diff(flight.submitted_at, retirement_tick)))
	renderer.metrics.completions += 1
	renderer.metrics.completion_ns += duration_ns
	renderer.metrics.latest_completion = {
		submit_tick   = flight.submitted_at,
		observed_tick = retirement_tick,
		token         = flight.completion.token,
		generation    = flight.completion.generation,
		duration_ns   = duration_ns,
		discarded     = flight.discarded,
	}
	return flight.completion, !flight.discarded, true
}

@(private = "file")
gsw3d_triangle_retire_head :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
) -> (
	completion: Gsw3d_Triangle_Completion,
	publish: bool,
	ok: bool,
) {
	return gsw3d_triangle_retire_head_at(renderer, time.tick_now())
}

@(private = "package")
gsw3d_triangle_poll_at :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	completed: []Gsw3d_Triangle_Completion,
	observed_at: time.Tick,
) -> (
	count: int,
	ok: bool,
) {
	if renderer == nil ||
	   !renderer.live ||
	   len(completed) < GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT ||
	   !gsw3d_triangle_fence_ops_valid(renderer.fence_ops) {return 0, false}
	for renderer.flight_count > 0 {
		flight := &renderer.flights[renderer.flight_head]
		if flight.fence == nil {return count, false}
		if !renderer.fence_ops.query(renderer.fence_ops.ctx, flight.fence) {break}
		completion, publish, retired := gsw3d_triangle_retire_head_at(renderer, observed_at)
		if !retired {return count, false}
		if publish {
			completed[count] = completion
			count += 1
		}
	}
	return count, true
}

gsw3d_triangle_poll :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	completed: []Gsw3d_Triangle_Completion,
) -> (
	count: int,
	ok: bool,
) {
	return gsw3d_triangle_poll_at(renderer, completed, {})
}

gsw3d_triangle_wait_oldest :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
) -> (
	completion: Gsw3d_Triangle_Completion,
	publish: bool,
	ok: bool,
) {
	if renderer == nil ||
	   !renderer.live ||
	   renderer.flight_count <= 0 ||
	   !gsw3d_triangle_fence_ops_valid(renderer.fence_ops) {return {}, false, false}
	flight := renderer.flights[renderer.flight_head]
	if flight.fence == nil {return {}, false, false}
	fences := [1]^sdl3.GPUFence{flight.fence}
	wait_started := time.tick_now()
	renderer.metrics.capacity_waits += 1
	waited := renderer.fence_ops.wait(renderer.fence_ops.ctx, fences[:])
	wait_completed := time.tick_now()
	wait_ns := u64(max(time.Duration(0), time.tick_diff(wait_started, wait_completed)))
	renderer.metrics.capacity_wait_ns += wait_ns
	renderer.metrics.latest_capacity_wait_ns = wait_ns
	if !waited {return {}, false, false}
	return gsw3d_triangle_retire_head_at(renderer, wait_completed)
}

gsw3d_triangle_discard_other_generations :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	generation: u64,
) {
	if renderer == nil {return}
	for offset in 0 ..< renderer.flight_count {
		index := (renderer.flight_head + offset) % GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT
		if generation == 0 || renderer.flights[index].completion.generation != generation {
			renderer.flights[index].discarded = true
		}
	}
}

@(private = "file")
gsw3d_triangle_release_all_fences :: proc(renderer: ^Gsw3d_Triangle_Renderer) {
	if renderer == nil || !gsw3d_triangle_fence_ops_valid(renderer.fence_ops) {return}
	for renderer.flight_count > 0 {
		_, _, ok := gsw3d_triangle_retire_head(renderer)
		if !ok {break}
	}
}

gsw3d_triangle_wait_all :: proc(renderer: ^Gsw3d_Triangle_Renderer) -> bool {
	if renderer == nil || !renderer.live || !gsw3d_triangle_fence_ops_valid(renderer.fence_ops) {
		return false
	}
	if renderer.flight_count == 0 {return true}
	fences: [GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT]^sdl3.GPUFence
	for offset in 0 ..< renderer.flight_count {
		index := (renderer.flight_head + offset) % GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT
		fences[offset] = renderer.flights[index].fence
		if fences[offset] == nil {return false}
	}
	if !renderer.fence_ops.wait(
		renderer.fence_ops.ctx,
		fences[:renderer.flight_count],
	) {return false}
	gsw3d_triangle_release_all_fences(renderer)
	return renderer.flight_count == 0
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
		fence_ops = {
			ctx = gpu,
			query = gsw3d_triangle_sdl_query_fence,
			wait = gsw3d_triangle_sdl_wait_fences,
			release = gsw3d_triangle_sdl_release_fence,
		},
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
		if renderer.live && renderer.flight_count > 0 && !gsw3d_triangle_wait_all(renderer) {
			_ = sdl3.WaitForGPUIdle(renderer.gpu)
			gsw3d_triangle_release_all_fences(renderer)
		}
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

gsw3d_triangle_render_async :: proc(
	renderer: ^Gsw3d_Triangle_Renderer,
	target: ^sdl3.GPUTexture,
	format: sdl3.GPUTextureFormat,
	width, height: u32,
	vertices: ^[GSW3D_TRIANGLE_VERTEX_COUNT]Gsw3d_Triangle_Vertex,
	generation: u64,
	clear_color: sdl3.FColor = {16.0 / 255.0, 16.0 / 255.0, 24.0 / 255.0, 1},
) -> (
	token: u64,
	ok: bool,
) {
	if renderer == nil ||
	   !renderer.live ||
	   target == nil ||
	   vertices == nil ||
	   generation == 0 ||
	   renderer.flight_count >= GSW3D_TRIANGLE_MAX_FRAMES_IN_FLIGHT ||
	   !gsw3d_triangle_target_valid(format, width, height) {return 0, false}
	pipeline := gsw3d_triangle_pipeline(renderer, format)
	if pipeline == nil {return 0, false}

	mapped := sdl3.MapGPUTransferBuffer(renderer.gpu, renderer.transfer_buffer, true)
	if mapped == nil {return 0, false}
	mem.copy(mapped, vertices, int(GSW3D_TRIANGLE_VERTEX_BYTES))
	sdl3.UnmapGPUTransferBuffer(renderer.gpu, renderer.transfer_buffer)

	command_buffer := sdl3.AcquireGPUCommandBuffer(renderer.gpu)
	if command_buffer == nil {return 0, false}
	submitted := false
	defer if !submitted {_ = sdl3.CancelGPUCommandBuffer(command_buffer)}

	copy_pass := sdl3.BeginGPUCopyPass(command_buffer)
	if copy_pass == nil {return 0, false}
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
	if render_pass == nil {return 0, false}
	sdl3.BindGPUGraphicsPipeline(render_pass, pipeline)
	bindings := [1]sdl3.GPUBufferBinding{{renderer.vertex_buffer, 0}}
	sdl3.BindGPUVertexBuffers(render_pass, 0, raw_data(bindings[:]), 1)
	sdl3.DrawGPUPrimitives(render_pass, GSW3D_TRIANGLE_VERTEX_COUNT, 1, 0, 0)
	sdl3.EndGPURenderPass(render_pass)

	submitted = true
	submission_started := time.tick_now()
	fence := sdl3.SubmitGPUCommandBufferAndAcquireFence(command_buffer)
	submitted_at := time.tick_now()
	gsw3d_triangle_note_submission(renderer, submission_started, submitted_at, fence != nil)
	if fence == nil {
		return 0, false
	}
	tracked: bool
	token, tracked = gsw3d_triangle_track_fence_at(renderer, fence, generation, submitted_at)
	if !tracked {
		sdl3.ReleaseGPUFence(renderer.gpu, fence)
		return 0, false
	}
	return token, true
}
