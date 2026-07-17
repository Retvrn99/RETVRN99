// SPDX-License-Identifier: GPL-3.0-only
package host

import vga "../vga"
import "core:sync"

GSW3D_PROOF_CONTEXT_CAPACITY :: 4
GSW3D_PROOF_RESOURCE_CAPACITY :: 4
GSW3D_PROOF_TARGET_ID :: u32(1)
GSW3D_PROOF_VERTEX_BUFFER_ID :: u32(2)
GSW3D_PROOF_CONTEXT_ID :: u32(1)
GSW3D_PROOF_WIDTH :: u32(640)
GSW3D_PROOF_HEIGHT :: u32(480)
GSW3D_PROOF_VERTEX_BYTES :: 60
GSW3D_PROOF_CLEAR_COLOR :: u32(0xff10_1018)
GSW3D_PROOF_MAX_BRIDGE_BUDGET :: u64(4 * 1024 * 1024)

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
	clear:      u32,
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
Gsw3d_Proof_Draw_Proc :: proc(ctx: rawptr, draw: ^Gsw3d_Proof_Draw) -> bool
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

Gsw3d_Proof_Backend :: struct {
	bridge:             ^Gsw3d_Bridge,
	mu:                 sync.Mutex,
	bridge_generation:  u64,
	device_generation:  u64,
	stopped:            bool,
	cleanup_required:   bool,
	cleanup_generation: u64,
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

@(private = "file")
gsw3d_proof_words_equal :: proc(data: []u8, offset: int, expected: []u32) -> bool {
	if offset < 0 || offset > len(data) || len(expected) > (len(data) - offset) / 4 {return false}
	for wanted, index in expected {
		value, ok := gsw3d_proof_rd32(data, offset + index * 4)
		if !ok || value != wanted {return false}
	}
	return true
}

@(private = "file")
gsw3d_proof_command :: proc(batch: []u8, offset: int, opcode, body_size: u32) -> bool {
	if offset < 0 || offset > len(batch) || len(batch) - offset < 8 + int(body_size) {return false}
	header := [?]u32{opcode, body_size}
	return gsw3d_proof_words_equal(batch, offset, header[:])
}

@(private = "file")
gsw3d_proof_definitions_valid :: proc(batch: []u8) -> bool {
	if len(batch) != 128 ||
	   !gsw3d_proof_command(batch, 0, 1070, 56) ||
	   !gsw3d_proof_command(batch, 64, 1070, 56) {return false}
	target := [?]u32{1, 0x40, 1, 1, 0, 0, 0, 0, 0, 0, 0, 640, 480, 1}
	buffer := [?]u32{2, 0x12, 37, 1, 0, 0, 0, 0, 0, 0, 0, 60, 1, 1}
	return(
		gsw3d_proof_words_equal(batch, 8, target[:]) &&
		gsw3d_proof_words_equal(batch, 72, buffer[:]) \
	)
}

@(private = "file")
gsw3d_proof_render_valid :: proc(batch: []u8) -> bool {
	if len(batch) != 360 {return false}
	headers := [?][3]u32 {
		{0, 1050, 20},
		{28, 1055, 20},
		{56, 1049, 60},
		{124, 1051, 64},
		{196, 1057, 36},
		{240, 1063, 112},
	}
	for header in headers {
		if !gsw3d_proof_command(batch, int(header[0]), header[1], header[2]) {return false}
	}
	render_target := [?]u32{1, 2, 1, 0, 0}
	viewport := [?]u32{1, 0, 0, 640, 480}
	render_states := [?]u32{1, 1, 0, 2, 0, 5, 0, 9, 0, 35, 1, 47, 15, 30, 2}
	texture_states := [?]u32{1, 0, 1, 0xffff_ffff, 0, 2, 2, 0, 3, 3, 0, 5, 2, 0, 6, 3}
	clear := [?]u32{1, 1, GSW3D_PROOF_CLEAR_COLOR, 0x3f80_0000, 0, 0, 0, 640, 480}
	draw := [?]u32 {
		1,
		2,
		1,
		3,
		0,
		9,
		0,
		2,
		0,
		20,
		0,
		0,
		4,
		0,
		10,
		0,
		2,
		16,
		20,
		0,
		0,
		1,
		1,
		0xffff_ffff,
		0,
		0,
		0,
		0,
	}
	return(
		gsw3d_proof_words_equal(batch, 8, render_target[:]) &&
		gsw3d_proof_words_equal(batch, 36, viewport[:]) &&
		gsw3d_proof_words_equal(batch, 64, render_states[:]) &&
		gsw3d_proof_words_equal(batch, 132, texture_states[:]) &&
		gsw3d_proof_words_equal(batch, 204, clear[:]) &&
		gsw3d_proof_words_equal(batch, 248, draw[:]) \
	)
}

@(private = "file")
gsw3d_proof_destroy_batch :: proc(batch: []u8, destroyed: ^[2]bool = nil) -> bool {
	if len(batch) == 0 || len(batch) > 24 || len(batch) % 12 != 0 {return false}
	seen: [2]bool
	for offset := 0; offset < len(batch); offset += 12 {
		if !gsw3d_proof_command(batch, offset, 1041, 4) {return false}
		id, ok := gsw3d_proof_rd32(batch, offset + 8)
		if !ok || id < GSW3D_PROOF_TARGET_ID || id > GSW3D_PROOF_VERTEX_BUFFER_ID {return false}
		index := int(id - 1)
		if seen[index] {return false}
		seen[index] = true
	}
	if destroyed != nil {destroyed^ = seen}
	return true
}

gsw3d_proof_validate_svga9 :: proc(ctx: rawptr, batch: []u8) -> bool {
	return(
		gsw3d_proof_definitions_valid(batch) ||
		gsw3d_proof_render_valid(batch) ||
		gsw3d_proof_destroy_batch(batch) \
	)
}

gsw3d_proof_resource_size :: proc(ctx: rawptr, format, width, height, depth: u32) -> (u64, bool) {
	if format == 1 && width == 640 && height == 480 && depth == 1 {
		return 640 * 480 * 4, true
	}
	if format == 37 && width == 60 && height == 1 && depth == 1 {return 60, true}
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
gsw3d_proof_define_resources :: proc(executor: ^Gsw3d_Proof_Executor) -> bool {
	if !gsw3d_proof_resources_empty(executor) {return false}
	next := executor.resources
	next[0] = {
		live = true,
		id = GSW3D_PROOF_TARGET_ID,
		kind = .Surface,
		surface = {
			id = GSW3D_PROOF_TARGET_ID,
			format = 1,
			width = GSW3D_PROOF_WIDTH,
			height = GSW3D_PROOF_HEIGHT,
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
gsw3d_proof_destroy_resources :: proc(executor: ^Gsw3d_Proof_Executor, batch: []u8) -> bool {
	destroyed: [2]bool
	if !gsw3d_proof_destroy_batch(batch, &destroyed) {return false}
	for remove, index in destroyed {
		if remove && gsw3d_proof_find_resource(executor, u32(index + 1)) == nil {return false}
	}
	if destroyed[0] && !executor.ops.destroy_surface(executor.ops.ctx, GSW3D_PROOF_TARGET_ID) {
		return false
	}
	for remove, index in destroyed {
		if !remove {continue}
		resource := gsw3d_proof_find_resource(executor, u32(index + 1))
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
	resource: ^Gsw3d_Proof_Resource,
) -> (
	[3]Gsw3d_Triangle_Vertex,
	bool,
) {
	vertices: [3]Gsw3d_Triangle_Vertex
	if resource == nil ||
	   resource.kind != .Buffer ||
	   resource.initialized != (u64(1) << GSW3D_PROOF_VERTEX_BYTES) - 1 {return vertices, false}
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
		   vertex.position.x > f32(GSW3D_PROOF_WIDTH) ||
		   vertex.position.y < 0 ||
		   vertex.position.y > f32(GSW3D_PROOF_HEIGHT) ||
		   vertex.position.z < 0 ||
		   vertex.position.z > 1 ||
		   vertex.position.w != 1 {return {}, false}
	}
	return vertices, true
}

@(private = "file")
gsw3d_proof_render :: proc(executor: ^Gsw3d_Proof_Executor) -> bool {
	target := gsw3d_proof_find_resource(executor, GSW3D_PROOF_TARGET_ID)
	buffer := gsw3d_proof_find_resource(executor, GSW3D_PROOF_VERTEX_BUFFER_ID)
	if target == nil || target.kind != .Surface {return false}
	vertices, ok := gsw3d_proof_read_vertices(buffer)
	if !ok {return false}
	draw := Gsw3d_Proof_Draw {
		surface_id = target.id,
		clear      = GSW3D_PROOF_CLEAR_COLOR,
		vertices   = vertices,
	}
	if !executor.ops.draw(executor.ops.ctx, &draw) {return false}
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
		if gsw3d_proof_definitions_valid(
			work.batch,
		) {return gsw3d_proof_define_resources(executor)}
		if gsw3d_proof_render_valid(work.batch) {return gsw3d_proof_render(executor)}
		return gsw3d_proof_destroy_resources(executor, work.batch)
	case .Direct_Present:
		expected := vga.Gsw3d_Rect {
			width  = GSW3D_PROOF_WIDTH,
			height = GSW3D_PROOF_HEIGHT,
		}
		target := gsw3d_proof_find_resource(executor, work.surface_id)
		if work.context_id != GSW3D_PROOF_CONTEXT_ID ||
		   gsw3d_proof_find_context(executor, work.context_id) == nil ||
		   work.surface_id != GSW3D_PROOF_TARGET_ID ||
		   target == nil ||
		   target.kind != .Surface ||
		   !target.rendered ||
		   !gsw3d_proof_rect_equal(work.source, expected) ||
		   !gsw3d_proof_rect_equal(work.destination, expected) ||
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
	   work.resource_id != GSW3D_PROOF_VERTEX_BUFFER_ID ||
	   work.region_id != 1 ||
	   work.source_offset != 0x80 {return false}
	resource := gsw3d_proof_find_resource(executor, work.resource_id)
	if resource == nil ||
	   resource.kind != .Buffer ||
	   work.destination_offset > GSW3D_PROOF_VERTEX_BYTES ||
	   u64(len(work.upload)) > GSW3D_PROOF_VERTEX_BYTES - work.destination_offset {return false}
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
		vga.GSW3D_BACKEND_RESOURCE_UPLOAD,
		present_intervals = u32(1) << 1,
		validate_svga9 = gsw3d_proof_validate_svga9,
		resource_size = gsw3d_proof_resource_size,
		execute = gsw3d_proof_backend_execute,
		upload = gsw3d_proof_backend_upload,
		reset = gsw3d_proof_backend_reset,
		cancel = gsw3d_proof_backend_cancel,
	}
}
