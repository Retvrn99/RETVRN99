// SPDX-License-Identifier: GPL-3.0-only
package host

import vga "../vga"
import "core:sync"

GSW3D_PROOF_CONTEXT_CAPACITY :: 4
GSW3D_PROOF_RESOURCE_CAPACITY :: 4
GSW3D_PROOF_TARGET_ID :: vga.GSW3D_SVGA9_PROFILE_TARGET_ID
GSW3D_PROOF_VERTEX_BUFFER_ID :: vga.GSW3D_SVGA9_PROFILE_BUFFER_ID
GSW3D_PROOF_CONTEXT_ID :: vga.GSW3D_SVGA9_PROFILE_CONTEXT_ID
GSW3D_PROOF_WIDTH :: u32(640)
GSW3D_PROOF_HEIGHT :: u32(480)
GSW3D_PROOF_VERTEX_BYTES :: int(vga.GSW3D_SVGA9_PROFILE_VERTEX_BYTES)
GSW3D_PROOF_CLEAR_COLOR :: u32(0xff10_1018)
GSW3D_PROOF_MAX_BRIDGE_BUDGET :: u64(4 * 1024 * 1024)
GSW3D_PROOF_COMPLETION_CAPACITY :: 64

Gsw3d_Proof_Resource_Kind :: enum u8 {
	Invalid,
	Surface,
	Buffer,
}

Gsw3d_Proof_Surface :: struct {
	id:     u32,
	format: u32,
	width:  u32,
	height: u32,
}

Gsw3d_Proof_Draw :: struct {
	surface_id: u32,
	width:      u32,
	height:     u32,
	clear:      u32,
	generation: u64,
	vertices:   [GSW3D_TRIANGLE_VERTEX_COUNT]Gsw3d_Triangle_Vertex,
}

Gsw3d_Proof_Present :: struct {
	surface_id:  u32,
	source:      vga.Gsw3d_Rect,
	destination: vga.Gsw3d_Rect,
	interval:    u32,
}

Gsw3d_Proof_Create_Surface_Proc :: proc(ctx: rawptr, surface: Gsw3d_Proof_Surface) -> bool
Gsw3d_Proof_Destroy_Surface_Proc :: proc(ctx: rawptr, surface_id: u32) -> bool
Gsw3d_Proof_Draw_Proc :: proc(ctx: rawptr, draw: ^Gsw3d_Proof_Draw) -> (u64, bool)
Gsw3d_Proof_Present_Proc :: proc(ctx: rawptr, present: ^Gsw3d_Proof_Present) -> bool
Gsw3d_Proof_Reset_Proc :: proc(ctx: rawptr, generation: u64) -> bool

Gsw3d_Proof_Ops :: struct {
	ctx:             rawptr,
	create_surface:  Gsw3d_Proof_Create_Surface_Proc,
	destroy_surface: Gsw3d_Proof_Destroy_Surface_Proc,
	draw:            Gsw3d_Proof_Draw_Proc,
	present:         Gsw3d_Proof_Present_Proc,
	reset:           Gsw3d_Proof_Reset_Proc,
}

Gsw3d_Proof_Context :: struct {
	live: bool,
	id:   u32,
}

Gsw3d_Proof_Resource :: struct {
	live:        bool,
	id:          u32,
	kind:        Gsw3d_Proof_Resource_Kind,
	surface:     Gsw3d_Proof_Surface,
	bytes:       [GSW3D_PROOF_VERTEX_BYTES]u8,
	initialized: u64,
	rendered:    bool,
}

Gsw3d_Proof_Executor :: struct {
	ops:        Gsw3d_Proof_Ops,
	contexts:   [GSW3D_PROOF_CONTEXT_CAPACITY]Gsw3d_Proof_Context,
	resources:  [GSW3D_PROOF_RESOURCE_CAPACITY]Gsw3d_Proof_Resource,
	generation: u64,
	live:       bool,
}

Gsw3d_Proof_Completed_Token :: struct {
	live:       bool,
	token:      u64,
	generation: u64,
}

Gsw3d_Proof_Backend :: struct {
	bridge:             ^Gsw3d_Bridge,
	mu:                 sync.Mutex,
	bridge_generation:  u64,
	device_generation:  u64,
	stopped:            bool,
	cleanup_required:   bool,
	cleanup_generation: u64,
	completed:          [GSW3D_PROOF_COMPLETION_CAPACITY]Gsw3d_Proof_Completed_Token,
}

@(private = "file")
Gsw3d_Proof_Reset_Request :: struct {
	generation: u64,
}

@(private = "file")
gsw3d_proof_rd32 :: proc(data: []u8, offset: int) -> (u32, bool) {
	if offset < 0 || offset > len(data) || len(data) - offset < 4 {return 0, false}
	value :=
		u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24
	return value, true
}

gsw3d_proof_validate_svga9 :: proc(ctx: rawptr, batch: []u8) -> bool {
	_, ok := vga.gsw3d_svga9_profile_parse(batch)
	return ok
}

gsw3d_proof_resource_size :: proc(ctx: rawptr, format, width, height, depth: u32) -> (u64, bool) {
	if format == vga.GSW3D_SVGA9_PROFILE_TARGET_FORMAT &&
	   depth == 1 &&
	   vga.gsw3d_svga9_profile_extent_valid(width, height) {
		return u64(width) * u64(height) * 4, true
	}
	if format == vga.GSW3D_SVGA9_PROFILE_BUFFER_FORMAT &&
	   width == vga.GSW3D_SVGA9_PROFILE_VERTEX_BYTES &&
	   height == 1 &&
	   depth == 1 {return u64(vga.GSW3D_SVGA9_PROFILE_VERTEX_BYTES), true}
	return 0, false
}

@(private = "package")
gsw3d_proof_find_context :: proc(
	executor: ^Gsw3d_Proof_Executor,
	id: u32,
) -> ^Gsw3d_Proof_Context {
	for &entry in executor.contexts {if entry.live && entry.id == id {return &entry}}
	return nil
}

@(private = "file")
gsw3d_proof_free_context :: proc(executor: ^Gsw3d_Proof_Executor) -> ^Gsw3d_Proof_Context {
	for &entry in executor.contexts {if !entry.live {return &entry}}
	return nil
}

@(private = "file")
gsw3d_proof_find_resource :: proc(
	executor: ^Gsw3d_Proof_Executor,
	id: u32,
) -> ^Gsw3d_Proof_Resource {
	for &entry in executor.resources {if entry.live && entry.id == id {return &entry}}
	return nil
}

@(private = "package")
gsw3d_proof_resources_empty :: proc(executor: ^Gsw3d_Proof_Executor) -> bool {
	for entry in executor.resources {if entry.live {return false}}
	return true
}

@(private = "file")
gsw3d_proof_define_resources :: proc(
	executor: ^Gsw3d_Proof_Executor,
	profile: vga.Gsw3d_Svga9_Profile_Command,
) -> bool {
	if profile.kind != .Define ||
	   !vga.gsw3d_svga9_profile_extent_valid(profile.width, profile.height) {return false}
	if !gsw3d_proof_resources_empty(executor) {return false}
	next := executor.resources
	next[0] = {
		live = true,
		id = GSW3D_PROOF_TARGET_ID,
		kind = .Surface,
		surface = {
			id = GSW3D_PROOF_TARGET_ID,
			format = vga.GSW3D_SVGA9_PROFILE_TARGET_FORMAT,
			width = profile.width,
			height = profile.height,
		},
	}
	next[1] = {
		live = true,
		id   = GSW3D_PROOF_VERTEX_BUFFER_ID,
		kind = .Buffer,
	}
	if !executor.ops.create_surface(executor.ops.ctx, next[0].surface) {
		_ = executor.ops.destroy_surface(executor.ops.ctx, GSW3D_PROOF_TARGET_ID)
		return false
	}
	executor.resources = next
	return true
}

@(private = "file")
gsw3d_proof_destroy_resources :: proc(
	executor: ^Gsw3d_Proof_Executor,
	profile: vga.Gsw3d_Svga9_Profile_Command,
) -> bool {
	if profile.kind != .Destroy {return false}
	for remove, index in profile.destroyed {
		id := GSW3D_PROOF_TARGET_ID + u32(index)
		if remove && gsw3d_proof_find_resource(executor, id) == nil {return false}
	}
	if profile.destroyed[0] &&
	   !executor.ops.destroy_surface(executor.ops.ctx, GSW3D_PROOF_TARGET_ID) {
		return false
	}
	for remove, index in profile.destroyed {
		if !remove {continue}
		resource := gsw3d_proof_find_resource(executor, GSW3D_PROOF_TARGET_ID + u32(index))
		resource^ = {}
	}
	return true
}

@(private = "file")
gsw3d_proof_bits_finite :: proc(bits: u32) -> bool {
	return bits & 0x7f80_0000 != 0x7f80_0000
}

@(private = "file")
gsw3d_proof_read_vertices :: proc(
	resource, target: ^Gsw3d_Proof_Resource,
) -> (
	[3]Gsw3d_Triangle_Vertex,
	bool,
) {
	vertices: [3]Gsw3d_Triangle_Vertex
	if resource == nil ||
	   target == nil ||
	   resource.kind != .Buffer ||
	   target.kind != .Surface ||
	   !vga.gsw3d_svga9_profile_extent_valid(target.surface.width, target.surface.height) ||
	   resource.initialized !=
		   (u64(1) << u64(GSW3D_PROOF_VERTEX_BYTES)) - 1 {return vertices, false}
	for &vertex, vertex_index in vertices {
		base := vertex_index * 20
		for axis in 0 ..< 4 {
			bits, ok := gsw3d_proof_rd32(resource.bytes[:], base + axis * 4)
			if !ok || !gsw3d_proof_bits_finite(bits) {return {}, false}
			vertex.position[axis] = transmute(f32)bits
		}
		color, ok := gsw3d_proof_rd32(resource.bytes[:], base + 16)
		if !ok {return {}, false}
		vertex.color = color
		if vertex.position.x < 0 ||
		   vertex.position.x > f32(target.surface.width) ||
		   vertex.position.y < 0 ||
		   vertex.position.y > f32(target.surface.height) ||
		   vertex.position.z < 0 ||
		   vertex.position.z > 1 ||
		   vertex.position.w != 1 {return {}, false}
	}
	return vertices, true
}

@(private = "file")
gsw3d_proof_render :: proc(
	executor: ^Gsw3d_Proof_Executor,
	work: ^vga.Gsw3d_Work,
	profile: vga.Gsw3d_Svga9_Profile_Command,
) -> bool {
	if work == nil ||
	   profile.kind != .Render ||
	   work.generation != executor.generation {return false}
	target := gsw3d_proof_find_resource(executor, GSW3D_PROOF_TARGET_ID)
	buffer := gsw3d_proof_find_resource(executor, GSW3D_PROOF_VERTEX_BUFFER_ID)
	if target == nil ||
	   target.kind != .Surface ||
	   target.surface.width != profile.width ||
	   target.surface.height != profile.height {return false}
	vertices, ok := gsw3d_proof_read_vertices(buffer, target)
	if !ok {return false}
	draw := Gsw3d_Proof_Draw {
		surface_id = target.id,
		width      = profile.width,
		height     = profile.height,
		clear      = profile.clear,
		generation = work.generation,
		vertices   = vertices,
	}
	token, drawn := executor.ops.draw(executor.ops.ctx, &draw)
	if !drawn {return false}
	work.backend_token = token
	target.rendered = true
	return true
}

@(private = "file")
gsw3d_proof_rect_equal :: proc(a, b: vga.Gsw3d_Rect) -> bool {
	return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
}

@(private = "package")
gsw3d_proof_execute_work :: proc(executor: ^Gsw3d_Proof_Executor, work: ^vga.Gsw3d_Work) -> bool {
	if executor == nil || !executor.live || work == nil || work.generation != executor.generation {
		return false
	}
	work.backend_token = 0
	switch work.kind {
	case .Create_Context:
		if work.context_id != GSW3D_PROOF_CONTEXT_ID ||
		   gsw3d_proof_find_context(executor, work.context_id) != nil {return false}
		entry := gsw3d_proof_free_context(executor)
		if entry == nil {return false}
		entry^ = {
			live = true,
			id   = work.context_id,
		}
		return true
	case .Destroy_Context:
		entry := gsw3d_proof_find_context(executor, work.context_id)
		if entry == nil || !gsw3d_proof_resources_empty(executor) {return false}
		entry^ = {}
		return true
	case .Submit_Svga9:
		if work.context_id != GSW3D_PROOF_CONTEXT_ID ||
		   gsw3d_proof_find_context(executor, work.context_id) == nil {return false}
		profile, parsed := vga.gsw3d_svga9_profile_parse(work.batch)
		if !parsed {return false}
		switch profile.kind {
		case .Define:
			return gsw3d_proof_define_resources(executor, profile)
		case .Render:
			return gsw3d_proof_render(executor, work, profile)
		case .Destroy:
			return gsw3d_proof_destroy_resources(executor, profile)
		case .Invalid:
			return false
		}
		return false
	case .Direct_Present:
		target := gsw3d_proof_find_resource(executor, work.surface_id)
		if work.context_id != GSW3D_PROOF_CONTEXT_ID ||
		   gsw3d_proof_find_context(executor, work.context_id) == nil ||
		   work.surface_id != GSW3D_PROOF_TARGET_ID ||
		   target == nil ||
		   target.kind != .Surface ||
		   !target.rendered ||
		   !vga.gsw3d_svga9_profile_extent_valid(target.surface.width, target.surface.height) ||
		   !gsw3d_proof_rect_equal(
				   work.source,
				   vga.Gsw3d_Rect{width = target.surface.width, height = target.surface.height},
			   ) ||
		   !gsw3d_proof_rect_equal(work.destination, work.source) ||
		   work.interval != 1 {return false}
		present := Gsw3d_Proof_Present {
			surface_id  = work.surface_id,
			source      = work.source,
			destination = work.destination,
			interval    = work.interval,
		}
		return executor.ops.present(executor.ops.ctx, &present)
	case .Transport_Barrier, .Reset, .Resource_Upload:
		return false
	}
	return false
}

@(private = "package")
gsw3d_proof_upload_work :: proc(executor: ^Gsw3d_Proof_Executor, work: ^vga.Gsw3d_Work) -> bool {
	if executor == nil ||
	   !executor.live ||
	   work == nil ||
	   work.generation != executor.generation ||
	   work.kind != .Resource_Upload ||
	   work.resource_id != GSW3D_PROOF_VERTEX_BUFFER_ID {return false}
	resource := gsw3d_proof_find_resource(executor, work.resource_id)
	if resource == nil ||
	   resource.kind != .Buffer ||
	   work.destination_offset > u64(GSW3D_PROOF_VERTEX_BYTES) ||
	   u64(len(work.upload)) >
		   u64(GSW3D_PROOF_VERTEX_BYTES) - work.destination_offset {return false}
	if len(work.upload) == 0 {return false}
	start := int(work.destination_offset)
	copy(resource.bytes[start:start + len(work.upload)], work.upload)
	for index in start ..< start + len(work.upload) {resource.initialized |= u64(1) << u64(index)}
	return true
}

@(private = "package")
gsw3d_proof_reset_executor :: proc(executor: ^Gsw3d_Proof_Executor, generation: u64) -> bool {
	if executor == nil || !executor.live || generation == 0 {return false}
	if !executor.ops.reset(executor.ops.ctx, generation) {return false}
	executor.contexts = {}
	executor.resources = {}
	executor.generation = generation
	return true
}

gsw3d_proof_executor_init :: proc(executor: ^Gsw3d_Proof_Executor, ops: Gsw3d_Proof_Ops) -> bool {
	if executor == nil ||
	   ops.create_surface == nil ||
	   ops.destroy_surface == nil ||
	   ops.draw == nil ||
	   ops.present == nil ||
	   ops.reset == nil {return false}
	executor^ = {
		ops        = ops,
		generation = 1,
		live       = true,
	}
	return true
}

@(private = "file")
gsw3d_proof_bridge_execute :: proc(ctx: rawptr, request: Gsw3d_Bridge_Request) -> bool {
	executor := (^Gsw3d_Proof_Executor)(ctx)
	if executor == nil || request.payload == nil {return false}
	switch request.kind {
	case .Execute:
		return gsw3d_proof_execute_work(executor, (^vga.Gsw3d_Work)(request.payload))
	case .Upload:
		return gsw3d_proof_upload_work(executor, (^vga.Gsw3d_Work)(request.payload))
	case .Reset:
		reset := (^Gsw3d_Proof_Reset_Request)(request.payload)
		return gsw3d_proof_reset_executor(executor, reset.generation)
	case .Invalid:
		return false
	}
	return false
}

gsw3d_proof_backend_drain :: proc(
	backend: ^Gsw3d_Proof_Backend,
	executor: ^Gsw3d_Proof_Executor,
	limits: Gsw3d_Bridge_Drain_Limits = {
		max_requests = 1,
		max_budget = GSW3D_PROOF_MAX_BRIDGE_BUDGET,
	},
) -> Gsw3d_Bridge_Drain_Result {
	if backend == nil || backend.bridge == nil || executor == nil {return {}}
	sync.lock(&backend.mu)
	cleanup_required := backend.cleanup_required
	cleanup_generation := backend.cleanup_generation
	sync.unlock(&backend.mu)
	if cleanup_required {
		if !gsw3d_proof_reset_executor(executor, cleanup_generation) {
			return {failed = 1}
		}
		sync.lock(&backend.mu)
		if backend.cleanup_required && backend.cleanup_generation == cleanup_generation {
			backend.cleanup_required = false
		}
		sync.unlock(&backend.mu)
	}
	return gsw3d_bridge_drain(backend.bridge, limits, gsw3d_proof_bridge_execute, executor)
}

@(private = "file")
gsw3d_proof_backend_session :: proc(backend: ^Gsw3d_Proof_Backend, generation: u64) -> u64 {
	if backend == nil {return 0}
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	if backend.stopped || generation != backend.device_generation {return 0}
	return backend.bridge_generation
}

@(private = "file")
gsw3d_proof_backend_submit :: proc(
	backend: ^Gsw3d_Proof_Backend,
	generation: u64,
	kind: Gsw3d_Bridge_Request_Kind,
	payload: rawptr,
	budget: u64,
) -> bool {
	session := gsw3d_proof_backend_session(backend, generation)
	if session == 0 || backend.bridge == nil {return false}
	return gsw3d_bridge_submit(
		backend.bridge,
		{kind = kind, generation = session, budget_cost = max(budget, u64(1)), payload = payload},
	)
}

@(private = "file")
gsw3d_proof_backend_execute :: proc(ctx: rawptr, work: ^vga.Gsw3d_Work) -> bool {
	if work == nil {return false}
	budget := work.kind == .Submit_Svga9 ? u64(len(work.batch)) : 1
	return gsw3d_proof_backend_submit(
		(^Gsw3d_Proof_Backend)(ctx),
		work.generation,
		.Execute,
		work,
		budget,
	)
}

@(private = "file")
gsw3d_proof_backend_upload :: proc(ctx: rawptr, work: ^vga.Gsw3d_Work) -> bool {
	if work == nil {return false}
	return gsw3d_proof_backend_submit(
		(^Gsw3d_Proof_Backend)(ctx),
		work.generation,
		.Upload,
		work,
		u64(len(work.upload)),
	)
}

@(private = "file")
gsw3d_proof_backend_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	reset := Gsw3d_Proof_Reset_Request{generation}
	return gsw3d_proof_backend_submit((^Gsw3d_Proof_Backend)(ctx), generation, .Reset, &reset, 1)
}

@(private = "file")
gsw3d_proof_next_generation :: proc(generation: u64) -> u64 {
	next := generation + 1
	return next != 0 ? next : 1
}

gsw3d_proof_backend_complete :: proc(
	backend: ^Gsw3d_Proof_Backend,
	completion: Gsw3d_Triangle_Completion,
) -> bool {
	if backend == nil || completion.token == 0 || completion.generation == 0 {return false}
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	if backend.stopped || completion.generation != backend.device_generation {return true}
	free_entry: ^Gsw3d_Proof_Completed_Token
	for &entry in backend.completed {
		if entry.live &&
		   entry.token == completion.token {return entry.generation == completion.generation}
		if !entry.live && free_entry == nil {free_entry = &entry}
	}
	if free_entry == nil {return false}
	free_entry^ = {
		live       = true,
		token      = completion.token,
		generation = completion.generation,
	}
	return true
}

@(private = "package")
gsw3d_proof_backend_completion :: proc(
	ctx: rawptr,
	token: u64,
) -> vga.Gsw3d_Backend_Completion_State {
	backend := (^Gsw3d_Proof_Backend)(ctx)
	if backend == nil || token == 0 {return .Failed}
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	if backend.stopped || backend.device_generation == 0 {return .Failed}
	for &entry in backend.completed {
		if entry.live && entry.token == token && entry.generation == backend.device_generation {
			entry = {}
			return .Complete
		}
	}
	return .Pending
}

@(private = "file")
gsw3d_proof_backend_cancel :: proc(ctx: rawptr, generation: u64, stopping: bool) {
	backend := (^Gsw3d_Proof_Backend)(ctx)
	if backend == nil || backend.bridge == nil {return}
	sync.lock(&backend.mu)
	if backend.stopped || generation != backend.device_generation {
		sync.unlock(&backend.mu)
		return
	}
	old_session := backend.bridge_generation
	backend.bridge_generation = 0
	backend.completed = {}
	if stopping {
		backend.stopped = true
		backend.cleanup_generation = generation
		backend.device_generation = 0
		backend.cleanup_required = true
	} else {
		backend.device_generation = gsw3d_proof_next_generation(generation)
	}
	sync.unlock(&backend.mu)

	if old_session != 0 {_ = gsw3d_bridge_cancel_session(backend.bridge, old_session)}
	if stopping {return}
	next_session := gsw3d_bridge_begin_session(backend.bridge)
	sync.lock(&backend.mu)
	if !backend.stopped {backend.bridge_generation = next_session}
	sync.unlock(&backend.mu)
}

gsw3d_proof_backend_init :: proc(backend: ^Gsw3d_Proof_Backend, bridge: ^Gsw3d_Bridge) -> bool {
	if backend == nil || bridge == nil {return false}
	sync.lock(&backend.mu)
	if backend.device_generation != 0 && !backend.stopped {
		sync.unlock(&backend.mu)
		return false
	}
	restarting := backend.bridge != nil
	backend.bridge = bridge
	backend.bridge_generation = 0
	backend.device_generation = 1
	backend.stopped = false
	backend.completed = {}
	if restarting {
		backend.cleanup_required = true
		backend.cleanup_generation = 1
	}
	sync.unlock(&backend.mu)

	session := gsw3d_bridge_begin_session(bridge)
	if session == 0 {
		sync.lock(&backend.mu)
		backend.device_generation = 0
		backend.stopped = true
		sync.unlock(&backend.mu)
		return false
	}
	sync.lock(&backend.mu)
	backend.bridge_generation = session
	sync.unlock(&backend.mu)
	return true
}

gsw3d_proof_backend_descriptor :: proc(backend: ^Gsw3d_Proof_Backend) -> vga.Gsw3d_Backend {
	if backend == nil || backend.bridge == nil {return {}}
	return {
		ctx = backend,
		capabilities = vga.GSW3D_BACKEND_SVGA9 |
		vga.GSW3D_BACKEND_DIRECT_PRESENT |
		vga.GSW3D_BACKEND_RESOURCE_UPLOAD |
		vga.GSW3D_BACKEND_ASYNC_COMPLETION,
		present_intervals = u32(1) << 1,
		validate_svga9 = gsw3d_proof_validate_svga9,
		resource_size = gsw3d_proof_resource_size,
		execute = gsw3d_proof_backend_execute,
		upload = gsw3d_proof_backend_upload,
		reset = gsw3d_proof_backend_reset,
		cancel = gsw3d_proof_backend_cancel,
		completion = gsw3d_proof_backend_completion,
	}
}
