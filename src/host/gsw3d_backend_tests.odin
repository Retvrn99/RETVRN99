// SPDX-License-Identifier: GPL-3.0-only
package host

import vga "../vga"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Gsw3d_Proof_Test_Event :: enum u8 {
	Invalid,
	Create_Surface,
	Draw,
	Present,
	Destroy_Surface,
	Reset,
}

Gsw3d_Proof_Test_Ops :: struct {
	events:       [16]Gsw3d_Proof_Test_Event,
	event_count:  int,
	fail_create:  bool,
	fail_destroy: bool,
	fail_draw:    bool,
	fail_present: bool,
	fail_reset:   bool,
	draw_token:   u64,
	surface:      Gsw3d_Proof_Surface,
	draw:         Gsw3d_Proof_Draw,
	present:      Gsw3d_Proof_Present,
	generation:   u64,
}

@(private = "file")
gsw3d_proof_test_record :: proc(state: ^Gsw3d_Proof_Test_Ops, event: Gsw3d_Proof_Test_Event) {
	if state.event_count < len(state.events) {state.events[state.event_count] = event}
	state.event_count += 1
}

@(private = "file")
gsw3d_proof_test_create_surface :: proc(ctx: rawptr, surface: Gsw3d_Proof_Surface) -> bool {
	state := (^Gsw3d_Proof_Test_Ops)(ctx)
	gsw3d_proof_test_record(state, .Create_Surface)
	state.surface = surface
	return !state.fail_create
}

@(private = "file")
gsw3d_proof_test_destroy_surface :: proc(ctx: rawptr, surface_id: u32) -> bool {
	state := (^Gsw3d_Proof_Test_Ops)(ctx)
	gsw3d_proof_test_record(state, .Destroy_Surface)
	return !state.fail_destroy && surface_id == GSW3D_PROOF_TARGET_ID
}

@(private = "file")
gsw3d_proof_test_draw :: proc(ctx: rawptr, draw: ^Gsw3d_Proof_Draw) -> (u64, bool) {
	state := (^Gsw3d_Proof_Test_Ops)(ctx)
	gsw3d_proof_test_record(state, .Draw)
	if draw != nil {state.draw = draw^}
	return state.draw_token, !state.fail_draw
}

@(private = "file")
gsw3d_proof_test_present :: proc(ctx: rawptr, present: ^Gsw3d_Proof_Present) -> bool {
	state := (^Gsw3d_Proof_Test_Ops)(ctx)
	gsw3d_proof_test_record(state, .Present)
	if present != nil {state.present = present^}
	return !state.fail_present
}

@(private = "file")
gsw3d_proof_test_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	state := (^Gsw3d_Proof_Test_Ops)(ctx)
	gsw3d_proof_test_record(state, .Reset)
	state.generation = generation
	return !state.fail_reset
}

@(private = "file")
gsw3d_proof_test_ops :: proc(state: ^Gsw3d_Proof_Test_Ops) -> Gsw3d_Proof_Ops {
	return {
		ctx = state,
		create_surface = gsw3d_proof_test_create_surface,
		destroy_surface = gsw3d_proof_test_destroy_surface,
		draw = gsw3d_proof_test_draw,
		present = gsw3d_proof_test_present,
		reset = gsw3d_proof_test_reset,
	}
}

@(private = "file")
gsw3d_proof_test_wr32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

@(private = "file")
gsw3d_proof_test_command :: proc(data: []u8, offset: int, opcode, body_size: u32) {
	gsw3d_proof_test_wr32(data, offset, opcode)
	gsw3d_proof_test_wr32(data, offset + 4, body_size)
}

@(private = "file")
gsw3d_proof_test_surface :: proc(
	data: []u8,
	offset: int,
	id, flags, format, width, height, depth: u32,
) {
	gsw3d_proof_test_command(data, offset, 1070, 56)
	words := [?]u32{id, flags, format, 1, 0, 0, 0, 0, 0, 0, 0, width, height, depth}
	for word, index in words {gsw3d_proof_test_wr32(data, offset + 8 + index * 4, word)}
}

@(private = "file")
gsw3d_proof_test_definitions :: proc(
	width: u32 = GSW3D_PROOF_WIDTH,
	height: u32 = GSW3D_PROOF_HEIGHT,
) -> [128]u8 {
	data: [128]u8
	gsw3d_proof_test_surface(data[:], 0, 1, 0x40, 1, width, height, 1)
	gsw3d_proof_test_surface(data[:], 64, 2, 0x12, 37, 60, 1, 1)
	return data
}

@(private = "file")
gsw3d_proof_test_vertices :: proc() -> [60]u8 {
	data: [60]u8
	words := [?]u32 {
		0x43a0_0000,
		0x42a0_0000,
		0x3f00_0000,
		0x3f80_0000,
		0xffff_0000,
		0x440c_0000,
		0x43c8_0000,
		0x3f00_0000,
		0x3f80_0000,
		0xff00_ff00,
		0x42a0_0000,
		0x43c8_0000,
		0x3f00_0000,
		0x3f80_0000,
		0xff00_00ff,
	}
	for word, index in words {gsw3d_proof_test_wr32(data[:], index * 4, word)}
	return data
}

@(private = "file")
gsw3d_proof_test_render :: proc(
	width: u32 = GSW3D_PROOF_WIDTH,
	height: u32 = GSW3D_PROOF_HEIGHT,
	clear_color: u32 = GSW3D_PROOF_CLEAR_COLOR,
) -> [360]u8 {
	data: [360]u8
	gsw3d_proof_test_command(data[:], 0, 1050, 20)
	render_target := [?]u32{1, 2, 1, 0, 0}
	for value, index in render_target {gsw3d_proof_test_wr32(data[:], 8 + index * 4, value)}

	gsw3d_proof_test_command(data[:], 28, 1055, 20)
	viewport := [?]u32{1, 0, 0, width, height}
	for value, index in viewport {gsw3d_proof_test_wr32(data[:], 36 + index * 4, value)}

	gsw3d_proof_test_command(data[:], 56, 1049, 60)
	render_states := [?]u32{1, 1, 0, 2, 0, 5, 0, 9, 0, 35, 1, 47, 15, 30, 2}
	for value, index in render_states {gsw3d_proof_test_wr32(data[:], 64 + index * 4, value)}

	gsw3d_proof_test_command(data[:], 124, 1051, 64)
	texture_states := [?]u32{1, 0, 1, 0xffff_ffff, 0, 2, 2, 0, 3, 3, 0, 5, 2, 0, 6, 3}
	for value, index in texture_states {gsw3d_proof_test_wr32(data[:], 132 + index * 4, value)}

	gsw3d_proof_test_command(data[:], 196, 1057, 36)
	clear := [?]u32{1, 1, clear_color, 0x3f80_0000, 0, 0, 0, width, height}
	for value, index in clear {gsw3d_proof_test_wr32(data[:], 204 + index * 4, value)}

	gsw3d_proof_test_command(data[:], 240, 1063, 112)
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
	for value, index in draw {gsw3d_proof_test_wr32(data[:], 248 + index * 4, value)}
	return data
}

@(private = "file")
gsw3d_proof_test_destroy_batch :: proc(first: u32, second: u32 = 0) -> ([24]u8, int) {
	data: [24]u8
	gsw3d_proof_test_command(data[:], 0, 1041, 4)
	gsw3d_proof_test_wr32(data[:], 8, first)
	if second == 0 {return data, 12}
	gsw3d_proof_test_command(data[:], 12, 1041, 4)
	gsw3d_proof_test_wr32(data[:], 20, second)
	return data, 24
}

Gsw3d_Proof_Test_Call_Kind :: enum u8 {
	Execute,
	Upload,
	Reset,
}

Gsw3d_Proof_Test_Producer :: struct {
	descriptor: vga.Gsw3d_Backend,
	kind:       Gsw3d_Proof_Test_Call_Kind,
	work:       ^vga.Gsw3d_Work,
	generation: u64,
	returned:   sync.Sema,
	result:     bool,
}

@(private = "file")
gsw3d_proof_test_notify :: proc(ctx: rawptr, generation: u64) {
	sync.sema_post((^sync.Sema)(ctx))
}

@(private = "file")
gsw3d_proof_test_produce :: proc(producer: ^Gsw3d_Proof_Test_Producer) {
	switch producer.kind {
	case .Execute:
		producer.result = producer.descriptor.execute(producer.descriptor.ctx, producer.work)
	case .Upload:
		producer.result = producer.descriptor.upload(producer.descriptor.ctx, producer.work)
	case .Reset:
		producer.result = producer.descriptor.reset(producer.descriptor.ctx, producer.generation)
	}
	sync.sema_post(&producer.returned)
}

@(private = "file")
gsw3d_proof_test_submit :: proc(
	t: ^testing.T,
	pending: ^sync.Sema,
	backend: ^Gsw3d_Proof_Backend,
	executor: ^Gsw3d_Proof_Executor,
	descriptor: vga.Gsw3d_Backend,
	kind: Gsw3d_Proof_Test_Call_Kind,
	work: ^vga.Gsw3d_Work = nil,
	generation: u64 = 0,
) -> (
	bool,
	bool,
) {
	producer := Gsw3d_Proof_Test_Producer {
		descriptor = descriptor,
		kind       = kind,
		work       = work,
		generation = generation,
	}
	worker := thread.create_and_start_with_poly_data(&producer, gsw3d_proof_test_produce)
	if !testing.expect(t, worker != nil) {return false, false}
	if !testing.expect(t, sync.sema_wait_with_timeout(pending, time.Second)) {
		cancel_generation := generation
		if cancel_generation == 0 && work != nil {cancel_generation = work.generation}
		if cancel_generation != 0 {descriptor.cancel(descriptor.ctx, cancel_generation, true)}
		_ = sync.sema_wait_with_timeout(&producer.returned, time.Second)
		thread.destroy(worker)
		return false, false
	}
	drain := gsw3d_proof_backend_drain(backend, executor)
	returned := testing.expect(t, sync.sema_wait_with_timeout(&producer.returned, time.Second))
	thread.destroy(worker)
	if !returned {return false, false}
	return producer.result, drain.executed == 1
}

@(test)
host_gsw3d_proof_test_golden_frame_marshals_in_order :: proc(t: ^testing.T) {
	pending: sync.Sema
	bridge: Gsw3d_Bridge
	gsw3d_bridge_init(&bridge, gsw3d_proof_test_notify, &pending)
	backend: Gsw3d_Proof_Backend
	if !testing.expect(t, gsw3d_proof_backend_init(&backend, &bridge)) {return}
	descriptor := gsw3d_proof_backend_descriptor(&backend)
	if !testing.expect(
		t,
		descriptor.capabilities & vga.GSW3D_BACKEND_ASYNC_COMPLETION != 0 &&
		descriptor.completion != nil,
	) {return}
	state := Gsw3d_Proof_Test_Ops {
		draw_token = 41,
	}
	executor: Gsw3d_Proof_Executor
	if !testing.expect(
		t,
		gsw3d_proof_executor_init(&executor, gsw3d_proof_test_ops(&state)),
	) {return}
	defer descriptor.cancel(descriptor.ctx, 1, true)

	create := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = 1,
	}
	result, drained := gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&create,
	)
	if !testing.expect(t, result && drained) {return}

	definitions := gsw3d_proof_test_definitions()
	define := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = definitions[:],
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&define,
	)
	if !testing.expect(t, result && drained) {return}

	vertices := gsw3d_proof_test_vertices()
	upload := vga.Gsw3d_Work {
		kind          = .Resource_Upload,
		generation    = 1,
		resource_id   = 2,
		region_id     = 1,
		source_offset = 0x80,
		upload        = vertices[:],
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Upload,
		&upload,
	)
	if !testing.expect(t, result && drained) {return}

	render_bytes := gsw3d_proof_test_render()
	render := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = render_bytes[:],
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&render,
	)
	if !testing.expect(t, result && drained) {return}
	testing.expect_value(t, render.backend_token, u64(41))

	present := vga.Gsw3d_Work {
		kind = .Direct_Present,
		generation = 1,
		context_id = 1,
		surface_id = 1,
		source = {width = 640, height = 480},
		destination = {width = 640, height = 480},
		interval = 1,
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&present,
	)
	if !testing.expect(t, result && drained) {return}

	destroy_bytes, destroy_length := gsw3d_proof_test_destroy_batch(2, 1)
	destroy := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = destroy_bytes[:destroy_length],
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&destroy,
	)
	if !testing.expect(t, result && drained) {return}
	destroy_context := vga.Gsw3d_Work {
		kind       = .Destroy_Context,
		generation = 1,
		context_id = 1,
	}
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&destroy_context,
	)
	if !testing.expect(t, result && drained) {return}

	expected_events := [?]Gsw3d_Proof_Test_Event {
		.Create_Surface,
		.Draw,
		.Present,
		.Destroy_Surface,
	}
	if testing.expect_value(t, state.event_count, len(expected_events)) {
		for expected, index in expected_events {testing.expect_value(
				t,
				state.events[index],
				expected,
			)}
	}
	testing.expect_value(
		t,
		state.surface,
		Gsw3d_Proof_Surface{1, 1, GSW3D_PROOF_WIDTH, GSW3D_PROOF_HEIGHT},
	)
	testing.expect_value(t, state.draw.surface_id, GSW3D_PROOF_TARGET_ID)
	testing.expect_value(t, state.draw.width, GSW3D_PROOF_WIDTH)
	testing.expect_value(t, state.draw.height, GSW3D_PROOF_HEIGHT)
	testing.expect_value(t, state.draw.clear, GSW3D_PROOF_CLEAR_COLOR)
	testing.expect_value(t, state.draw.generation, u64(1))
	testing.expect_value(t, state.draw.vertices, gsw3d_triangle_proof_vertices())
	testing.expect_value(t, state.present.surface_id, GSW3D_PROOF_TARGET_ID)
	testing.expect_value(t, state.present.interval, u32(1))
	testing.expect(t, gsw3d_proof_find_context(&executor, GSW3D_PROOF_CONTEXT_ID) == nil)
	testing.expect(t, gsw3d_proof_resources_empty(&executor))
}

@(test)
host_gsw3d_proof_test_pure_whitelist_rejects_semantic_drift :: proc(t: ^testing.T) {
	definitions := gsw3d_proof_test_definitions()
	render := gsw3d_proof_test_render()
	destroy, destroy_length := gsw3d_proof_test_destroy_batch(1)
	testing.expect(t, gsw3d_proof_validate_svga9(nil, definitions[:]))
	testing.expect(t, gsw3d_proof_validate_svga9(nil, render[:]))
	testing.expect(t, gsw3d_proof_validate_svga9(nil, destroy[:destroy_length]))

	gsw3d_proof_test_wr32(definitions[:], 16, 2)
	testing.expect(t, !gsw3d_proof_validate_svga9(nil, definitions[:]))
	gsw3d_proof_test_wr32(render[:], 72, 1)
	testing.expect(t, !gsw3d_proof_validate_svga9(nil, render[:]))
	duplicate, duplicate_length := gsw3d_proof_test_destroy_batch(1, 1)
	testing.expect(t, !gsw3d_proof_validate_svga9(nil, duplicate[:duplicate_length]))
	testing.expect(t, !gsw3d_proof_validate_svga9(nil, render[:359]))

	size, ok := gsw3d_proof_resource_size(nil, 1, 640, 480, 1)
	testing.expect(t, ok)
	testing.expect_value(t, size, u64(1_228_800))
	size, ok = gsw3d_proof_resource_size(nil, 1, 641, 480, 1)
	testing.expect(t, ok)
	testing.expect_value(t, size, u64(1_230_720))
	_, ok = gsw3d_proof_resource_size(nil, 1, vga.GSW3D_SVGA9_PROFILE_MAX_DIMENSION + 1, 1, 1)
	testing.expect(t, !ok)
	_, ok = gsw3d_proof_resource_size(nil, 1, 0, 480, 1)
	testing.expect(t, !ok)
	_, ok = gsw3d_proof_resource_size(nil, 37, 61, 1, 1)
	testing.expect(t, !ok)
}

@(test)
host_gsw3d_proof_test_dynamic_extent_is_consistent_across_frame :: proc(t: ^testing.T) {
	WIDTH :: u32(1_600)
	HEIGHT :: u32(1_200)
	GUEST_CLEAR :: u32(0x1212_3456)
	CANONICAL_CLEAR :: u32(0xff12_3456)

	state := Gsw3d_Proof_Test_Ops {
		draw_token = 73,
	}
	executor: Gsw3d_Proof_Executor
	if !testing.expect(
		t,
		gsw3d_proof_executor_init(&executor, gsw3d_proof_test_ops(&state)),
	) {return}

	create := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = GSW3D_PROOF_CONTEXT_ID,
	}
	if !testing.expect(t, gsw3d_proof_execute_work(&executor, &create)) {return}

	definitions := gsw3d_proof_test_definitions(WIDTH, HEIGHT)
	define := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = GSW3D_PROOF_CONTEXT_ID,
		batch      = definitions[:],
	}
	if !testing.expect(t, gsw3d_proof_execute_work(&executor, &define)) {return}
	testing.expect_value(
		t,
		state.surface,
		Gsw3d_Proof_Surface{GSW3D_PROOF_TARGET_ID, 1, WIDTH, HEIGHT},
	)

	vertices := gsw3d_proof_test_vertices()
	gsw3d_proof_test_wr32(vertices[:], 0, 0x4448_0000)
	gsw3d_proof_test_wr32(vertices[:], 20, 0x44af_0000)
	gsw3d_proof_test_wr32(vertices[:], 24, 0x447a_0000)
	gsw3d_proof_test_wr32(vertices[:], 40, 0x4348_0000)
	gsw3d_proof_test_wr32(vertices[:], 44, 0x447a_0000)
	upload := vga.Gsw3d_Work {
		kind          = .Resource_Upload,
		generation    = 1,
		resource_id   = GSW3D_PROOF_VERTEX_BUFFER_ID,
		region_id     = 1,
		source_offset = 0x80,
		upload        = vertices[:],
	}
	if !testing.expect(t, gsw3d_proof_upload_work(&executor, &upload)) {return}

	mismatched_render_bytes := gsw3d_proof_test_render(WIDTH, HEIGHT - 1, GUEST_CLEAR)
	mismatched_render := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = GSW3D_PROOF_CONTEXT_ID,
		batch      = mismatched_render_bytes[:],
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &mismatched_render))
	testing.expect_value(t, state.event_count, 1)

	render_bytes := gsw3d_proof_test_render(WIDTH, HEIGHT, GUEST_CLEAR)
	render := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = GSW3D_PROOF_CONTEXT_ID,
		batch      = render_bytes[:],
	}
	if !testing.expect(t, gsw3d_proof_execute_work(&executor, &render)) {return}
	testing.expect_value(t, render.backend_token, u64(73))
	testing.expect_value(t, state.draw.surface_id, GSW3D_PROOF_TARGET_ID)
	testing.expect_value(t, state.draw.width, WIDTH)
	testing.expect_value(t, state.draw.height, HEIGHT)
	testing.expect_value(t, state.draw.clear, CANONICAL_CLEAR)
	testing.expect_value(t, state.draw.generation, u64(1))
	expected_vertices := gsw3d_triangle_proof_vertices()
	expected_vertices[0].position.x = 800
	expected_vertices[1].position.x = 1400
	expected_vertices[1].position.y = 1000
	expected_vertices[2].position.x = 200
	expected_vertices[2].position.y = 1000
	testing.expect_value(t, state.draw.vertices, expected_vertices)

	present := vga.Gsw3d_Work {
		kind = .Direct_Present,
		generation = 1,
		context_id = GSW3D_PROOF_CONTEXT_ID,
		surface_id = GSW3D_PROOF_TARGET_ID,
		source = {width = WIDTH, height = HEIGHT},
		destination = {width = GSW3D_PROOF_WIDTH, height = GSW3D_PROOF_HEIGHT},
		interval = 1,
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &present))
	testing.expect_value(t, state.event_count, 2)

	present.destination = {
		width  = WIDTH,
		height = HEIGHT,
	}
	if !testing.expect(t, gsw3d_proof_execute_work(&executor, &present)) {return}
	testing.expect_value(t, state.event_count, 3)
	testing.expect_value(t, state.present.surface_id, GSW3D_PROOF_TARGET_ID)
	testing.expect_value(t, state.present.source, vga.Gsw3d_Rect{width = WIDTH, height = HEIGHT})
	testing.expect_value(
		t,
		state.present.destination,
		vga.Gsw3d_Rect{width = WIDTH, height = HEIGHT},
	)
	testing.expect_value(t, state.present.interval, u32(1))
}

@(test)
host_gsw3d_proof_test_vertices_upload_and_present_are_bounded :: proc(t: ^testing.T) {
	state: Gsw3d_Proof_Test_Ops
	executor: Gsw3d_Proof_Executor
	if !testing.expect(
		t,
		gsw3d_proof_executor_init(&executor, gsw3d_proof_test_ops(&state)),
	) {return}
	create := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = 1,
	}
	testing.expect(t, gsw3d_proof_execute_work(&executor, &create))
	definitions := gsw3d_proof_test_definitions()
	define := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = definitions[:],
	}
	testing.expect(t, gsw3d_proof_execute_work(&executor, &define))
	present := vga.Gsw3d_Work {
		kind = .Direct_Present,
		generation = 1,
		context_id = 1,
		surface_id = 1,
		source = {width = 640, height = 480},
		destination = {width = 640, height = 480},
		interval = 1,
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &present))

	vertices := gsw3d_proof_test_vertices()
	overflow := vga.Gsw3d_Work {
		kind               = .Resource_Upload,
		generation         = 1,
		resource_id        = 2,
		region_id          = 1,
		source_offset      = 0x80,
		destination_offset = 1,
		upload             = vertices[:],
	}
	testing.expect(t, !gsw3d_proof_upload_work(&executor, &overflow))

	gsw3d_proof_test_wr32(vertices[:], 0, 0x7fc0_0000)
	overflow.destination_offset = 0
	testing.expect(t, gsw3d_proof_upload_work(&executor, &overflow))
	render_bytes := gsw3d_proof_test_render()
	render := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = render_bytes[:],
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &render))
	testing.expect_value(t, state.event_count, 1)

	vertices = gsw3d_proof_test_vertices()
	gsw3d_proof_test_wr32(vertices[:], 0, 0x4420_4000)
	overflow.upload = vertices[:]
	testing.expect(t, gsw3d_proof_upload_work(&executor, &overflow))
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &render))
	testing.expect_value(t, state.event_count, 1)

	vertices = gsw3d_proof_test_vertices()
	overflow.upload = vertices[:]
	testing.expect(t, gsw3d_proof_upload_work(&executor, &overflow))
	testing.expect(t, gsw3d_proof_execute_work(&executor, &render))
	present.destination.width = 639
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &present))
	present.destination.width = 640
	testing.expect(t, gsw3d_proof_execute_work(&executor, &present))
	wrong_context := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = 2,
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &wrong_context))
}

@(test)
host_gsw3d_proof_test_physical_completions_are_consumed_once_and_generation_scoped :: proc(
	t: ^testing.T,
) {
	backend := Gsw3d_Proof_Backend {
		device_generation = 4,
	}
	testing.expect(t, gsw3d_proof_backend_complete(&backend, {token = 17, generation = 4}))
	testing.expect_value(
		t,
		gsw3d_proof_backend_completion(&backend, 17),
		vga.Gsw3d_Backend_Completion_State.Complete,
	)
	testing.expect_value(
		t,
		gsw3d_proof_backend_completion(&backend, 17),
		vga.Gsw3d_Backend_Completion_State.Pending,
	)
	testing.expect(t, gsw3d_proof_backend_complete(&backend, {token = 18, generation = 3}))
	testing.expect_value(
		t,
		gsw3d_proof_backend_completion(&backend, 18),
		vga.Gsw3d_Backend_Completion_State.Pending,
	)
}

@(test)
host_gsw3d_proof_test_callback_failures_and_reset_are_transactional :: proc(t: ^testing.T) {
	state := Gsw3d_Proof_Test_Ops {
		fail_create = true,
	}
	executor: Gsw3d_Proof_Executor
	if !testing.expect(
		t,
		gsw3d_proof_executor_init(&executor, gsw3d_proof_test_ops(&state)),
	) {return}
	create := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = 1,
	}
	testing.expect(t, gsw3d_proof_execute_work(&executor, &create))
	definitions := gsw3d_proof_test_definitions()
	define := vga.Gsw3d_Work {
		kind       = .Submit_Svga9,
		generation = 1,
		context_id = 1,
		batch      = definitions[:],
	}
	testing.expect(t, !gsw3d_proof_execute_work(&executor, &define))
	testing.expect(t, gsw3d_proof_resources_empty(&executor))

	state.fail_create = false
	testing.expect(t, gsw3d_proof_execute_work(&executor, &define))
	testing.expect(t, !gsw3d_proof_resources_empty(&executor))
	state.fail_reset = true
	testing.expect(t, !gsw3d_proof_reset_executor(&executor, 2))
	testing.expect_value(t, executor.generation, u64(1))
	testing.expect(t, !gsw3d_proof_resources_empty(&executor))
	state.fail_reset = false
	testing.expect(t, gsw3d_proof_reset_executor(&executor, 2))
	testing.expect_value(t, executor.generation, u64(2))
	testing.expect(t, gsw3d_proof_resources_empty(&executor))
	testing.expect(t, gsw3d_proof_find_context(&executor, 1) == nil)
}

@(test)
host_gsw3d_proof_test_cancel_generation_and_machine_restart :: proc(t: ^testing.T) {
	pending: sync.Sema
	bridge: Gsw3d_Bridge
	gsw3d_bridge_init(&bridge, gsw3d_proof_test_notify, &pending)
	backend: Gsw3d_Proof_Backend
	if !testing.expect(t, gsw3d_proof_backend_init(&backend, &bridge)) {return}
	descriptor := gsw3d_proof_backend_descriptor(&backend)
	state: Gsw3d_Proof_Test_Ops
	executor: Gsw3d_Proof_Executor
	if !testing.expect(
		t,
		gsw3d_proof_executor_init(&executor, gsw3d_proof_test_ops(&state)),
	) {return}

	work := vga.Gsw3d_Work {
		kind       = .Create_Context,
		generation = 1,
		context_id = 1,
	}
	producer := Gsw3d_Proof_Test_Producer {
		descriptor = descriptor,
		kind       = .Execute,
		work       = &work,
	}
	worker := thread.create_and_start_with_poly_data(&producer, gsw3d_proof_test_produce)
	if !testing.expect(t, worker != nil) {return}
	if !testing.expect(t, sync.sema_wait_with_timeout(&pending, time.Second)) {return}
	descriptor.cancel(descriptor.ctx, 1, false)
	testing.expect(t, sync.sema_wait_with_timeout(&producer.returned, time.Second))
	thread.destroy(worker)
	testing.expect(t, !producer.result)

	result, drained := gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Reset,
		nil,
		2,
	)
	if !testing.expect(t, result && drained) {return}
	testing.expect_value(t, executor.generation, u64(2))
	testing.expect(t, !descriptor.execute(descriptor.ctx, &work))
	descriptor.cancel(descriptor.ctx, 2, true)
	testing.expect(t, gsw3d_bridge_snapshot(&bridge).shutdown == false)

	if !testing.expect(t, gsw3d_proof_backend_init(&backend, &bridge)) {return}
	descriptor = gsw3d_proof_backend_descriptor(&backend)
	defer descriptor.cancel(descriptor.ctx, 1, true)
	result, drained = gsw3d_proof_test_submit(
		t,
		&pending,
		&backend,
		&executor,
		descriptor,
		.Execute,
		&work,
	)
	testing.expect(t, result && drained)
	testing.expect_value(t, executor.generation, u64(1))
	testing.expect_value(t, state.event_count, 2)
	testing.expect_value(t, state.events[1], Gsw3d_Proof_Test_Event.Reset)
	testing.expect_value(t, state.generation, u64(1))
}
