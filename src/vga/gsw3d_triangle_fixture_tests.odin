// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:crypto/sha2"
import "core:testing"
import "core:time"

GSW3D_TRIANGLE_FIXTURE_RING_GPA :: u64(0x400)
GSW3D_TRIANGLE_FIXTURE_RING_SIZE :: u32(512)
GSW3D_TRIANGLE_FIXTURE_REGION_GPA :: u64(0x1000)
GSW3D_TRIANGLE_FIXTURE_REGION_SIZE :: u64(0x400)
GSW3D_TRIANGLE_FIXTURE_DEFINITIONS_OFFSET :: u64(0)
GSW3D_TRIANGLE_FIXTURE_VERTICES_OFFSET :: u64(0x80)
GSW3D_TRIANGLE_FIXTURE_RENDER_OFFSET :: u64(0xC0)

GSW3D_TRIANGLE_FIXTURE_DEFINITIONS_SHA256 :: [32]u8 {
	0xdb,
	0x9d,
	0x45,
	0x4b,
	0xca,
	0x26,
	0xe0,
	0x71,
	0x3a,
	0x43,
	0xc0,
	0x34,
	0x42,
	0x67,
	0x79,
	0xc9,
	0x99,
	0x7b,
	0x53,
	0x7f,
	0xd5,
	0x79,
	0xd3,
	0x2a,
	0xb4,
	0x5a,
	0x88,
	0x95,
	0xee,
	0xfc,
	0x9c,
	0x79,
}

GSW3D_TRIANGLE_FIXTURE_VERTICES_SHA256 :: [32]u8 {
	0x3f,
	0x4f,
	0x23,
	0xea,
	0x85,
	0x8a,
	0x58,
	0x51,
	0xd4,
	0x18,
	0xee,
	0x5b,
	0xc7,
	0x89,
	0x5d,
	0x6c,
	0x22,
	0x7c,
	0xeb,
	0x60,
	0x18,
	0x46,
	0x73,
	0x65,
	0x5c,
	0x16,
	0x9a,
	0x3d,
	0xef,
	0xd7,
	0xc4,
	0x96,
}

GSW3D_TRIANGLE_FIXTURE_RENDER_SHA256 :: [32]u8 {
	0xe2,
	0x39,
	0x03,
	0xd6,
	0x30,
	0xbe,
	0xc5,
	0xf5,
	0xa9,
	0x73,
	0x7a,
	0x62,
	0x1e,
	0x07,
	0x4c,
	0xe2,
	0x77,
	0x85,
	0x7b,
	0xeb,
	0x70,
	0xc6,
	0xe0,
	0xfd,
	0x0a,
	0x1c,
	0x5b,
	0x47,
	0x84,
	0x5b,
	0x2d,
	0xb4,
}

GSW3D_TRIANGLE_FIXTURE_DESCRIPTORS_SHA256 :: [32]u8 {
	0xa4,
	0xbd,
	0x38,
	0xce,
	0x4f,
	0x36,
	0x85,
	0x49,
	0xcb,
	0xb3,
	0x82,
	0x7c,
	0x9a,
	0x60,
	0x49,
	0x03,
	0xda,
	0x3b,
	0x1b,
	0xad,
	0xa5,
	0xb6,
	0xde,
	0xb0,
	0x9a,
	0x52,
	0x43,
	0x4b,
	0xed,
	0xaf,
	0xf8,
	0x73,
}

gsw3d_triangle_fixture_sha256 :: proc(data: []u8) -> [32]u8 {
	ctx: sha2.Context_256
	digest: [32]u8
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sha2.final(&ctx, digest[:])
	return digest
}

gsw3d_triangle_fixture_command_header :: proc(data: []u8, offset: int, opcode, body_size: u32) {
	gsw_test_wr32(data, offset, opcode)
	gsw_test_wr32(data, offset + 4, body_size)
}

gsw3d_triangle_fixture_surface :: proc(
	data: []u8,
	offset: int,
	surface_id, flags, format, width, height, depth: u32,
) {
	gsw3d_triangle_fixture_command_header(data, offset, 1070, 56)
	gsw_test_wr32(data, offset + 8, surface_id)
	gsw_test_wr32(data, offset + 12, flags)
	gsw_test_wr32(data, offset + 16, format)
	gsw_test_wr32(data, offset + 20, 1)
	gsw_test_wr32(data, offset + 52, width)
	gsw_test_wr32(data, offset + 56, height)
	gsw_test_wr32(data, offset + 60, depth)
}

gsw3d_triangle_fixture_definitions :: proc() -> [128]u8 {
	data: [128]u8
	gsw3d_triangle_fixture_surface(data[:], 0, 1, 0x40, 1, 640, 480, 1)
	gsw3d_triangle_fixture_surface(data[:], 64, 2, 0x12, 37, 60, 1, 1)
	return data
}

gsw3d_triangle_fixture_vertices :: proc() -> [60]u8 {
	data: [60]u8
	words := [?]u32 {
		0x43A0_0000,
		0x42A0_0000,
		0x3F00_0000,
		0x3F80_0000,
		0xFFFF_0000,
		0x440C_0000,
		0x43C8_0000,
		0x3F00_0000,
		0x3F80_0000,
		0xFF00_FF00,
		0x42A0_0000,
		0x43C8_0000,
		0x3F00_0000,
		0x3F80_0000,
		0xFF00_00FF,
	}
	for word, index in words {gsw_test_wr32(data[:], index * 4, word)}
	return data
}

gsw3d_triangle_fixture_render :: proc() -> [360]u8 {
	data: [360]u8

	gsw3d_triangle_fixture_command_header(data[:], 0, 1050, 20)
	render_target := [?]u32{1, 2, 1, 0, 0}
	for value, index in render_target {
		gsw_test_wr32(data[:], 8 + index * 4, value)
	}

	gsw3d_triangle_fixture_command_header(data[:], 28, 1055, 20)
	viewport := [?]u32{1, 0, 0, 640, 480}
	for value, index in viewport {
		gsw_test_wr32(data[:], 36 + index * 4, value)
	}

	gsw3d_triangle_fixture_command_header(data[:], 56, 1049, 60)
	render_states := [?]u32{1, 1, 0, 2, 0, 5, 0, 9, 0, 35, 1, 47, 15, 30, 2}
	for value, index in render_states {gsw_test_wr32(data[:], 64 + index * 4, value)}

	gsw3d_triangle_fixture_command_header(data[:], 124, 1051, 64)
	texture_states := [?]u32{1, 0, 1, 0xFFFF_FFFF, 0, 2, 2, 0, 3, 3, 0, 5, 2, 0, 6, 3}
	for value, index in texture_states {gsw_test_wr32(data[:], 132 + index * 4, value)}

	gsw3d_triangle_fixture_command_header(data[:], 196, 1057, 36)
	clear := [?]u32{1, 1, 0xFF10_1018, 0x3F80_0000, 0, 0, 0, 640, 480}
	for value, index in clear {gsw_test_wr32(data[:], 204 + index * 4, value)}

	gsw3d_triangle_fixture_command_header(data[:], 240, 1063, 112)
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
		0xFFFF_FFFF,
		0,
		0,
		0,
		0,
	}
	for value, index in draw {gsw_test_wr32(data[:], 248 + index * 4, value)}
	return data
}

gsw3d_triangle_fixture_descriptor_header :: proc(
	data: []u8,
	offset, length: int,
	opcode: Gsw3d_Opcode,
	fence: u64,
) {
	command := data[offset:offset + length]
	gsw_test_wr16(command, 0, u16(opcode))
	gsw_test_wr16(command, 2, GSW3D_COMMAND_VERSION)
	gsw_test_wr32(command, 4, u32(length))
	gsw_test_wr64(command, 8, fence)
}

gsw3d_triangle_fixture_descriptors :: proc() -> [256]u8 {
	data: [256]u8

	gsw3d_triangle_fixture_descriptor_header(data[:], 0, 40, .Register_Region, 1)
	gsw_test_wr32(data[:], 16, 1)
	gsw_test_wr64(data[:], 24, GSW3D_TRIANGLE_FIXTURE_REGION_GPA)
	gsw_test_wr64(data[:], 32, GSW3D_TRIANGLE_FIXTURE_REGION_SIZE)

	gsw3d_triangle_fixture_descriptor_header(data[:], 40, 24, .Create_Context, 2)
	gsw_test_wr32(data[:], 56, 1)

	gsw3d_triangle_fixture_descriptor_header(data[:], 64, 40, .Submit, 3)
	gsw_test_wr32(data[:], 80, 1)
	gsw_test_wr32(data[:], 84, 1)
	gsw_test_wr64(data[:], 88, GSW3D_TRIANGLE_FIXTURE_DEFINITIONS_OFFSET)
	gsw_test_wr32(data[:], 96, 128)
	gsw_test_wr32(data[:], 100, GSW3D_PACKET_SVGA9)

	gsw3d_triangle_fixture_descriptor_header(data[:], 104, 48, .Resource_Upload, 4)
	gsw_test_wr32(data[:], 120, 2)
	gsw_test_wr32(data[:], 124, 1)
	gsw_test_wr64(data[:], 128, GSW3D_TRIANGLE_FIXTURE_VERTICES_OFFSET)
	gsw_test_wr64(data[:], 136, 0)
	gsw_test_wr32(data[:], 144, 60)

	gsw3d_triangle_fixture_descriptor_header(data[:], 152, 40, .Submit, 5)
	gsw_test_wr32(data[:], 168, 1)
	gsw_test_wr32(data[:], 172, 1)
	gsw_test_wr64(data[:], 176, GSW3D_TRIANGLE_FIXTURE_RENDER_OFFSET)
	gsw_test_wr32(data[:], 184, 360)
	gsw_test_wr32(data[:], 188, GSW3D_PACKET_SVGA9)

	gsw3d_triangle_fixture_descriptor_header(data[:], 192, 64, .Direct_Present, 6)
	gsw_test_wr32(data[:], 208, 1)
	gsw_test_wr32(data[:], 212, 1)
	gsw_test_wr32(data[:], 224, 640)
	gsw_test_wr32(data[:], 228, 480)
	gsw_test_wr32(data[:], 240, 640)
	gsw_test_wr32(data[:], 244, 480)
	gsw_test_wr32(data[:], 248, 1)
	return data
}

@(test)
gsw3d_triangle_fixture_test_exact_capture :: proc(t: ^testing.T) {
	definitions := gsw3d_triangle_fixture_definitions()
	vertices := gsw3d_triangle_fixture_vertices()
	render := gsw3d_triangle_fixture_render()
	descriptors := gsw3d_triangle_fixture_descriptors()

	testing.expect(
		t,
		gsw3d_triangle_fixture_sha256(definitions[:]) == GSW3D_TRIANGLE_FIXTURE_DEFINITIONS_SHA256,
	)
	testing.expect(
		t,
		gsw3d_triangle_fixture_sha256(vertices[:]) == GSW3D_TRIANGLE_FIXTURE_VERTICES_SHA256,
	)
	testing.expect(
		t,
		gsw3d_triangle_fixture_sha256(render[:]) == GSW3D_TRIANGLE_FIXTURE_RENDER_SHA256,
	)
	testing.expect(
		t,
		gsw3d_triangle_fixture_sha256(descriptors[:]) == GSW3D_TRIANGLE_FIXTURE_DESCRIPTORS_SHA256,
	)

	testing.expect_value(t, len(definitions), 128)
	testing.expect_value(t, gsw_rd32(definitions[:], 0), u32(1070))
	testing.expect_value(t, gsw_rd32(definitions[:], 4), u32(56))
	testing.expect_value(t, gsw_rd32(definitions[:], 8), u32(1))
	testing.expect_value(t, gsw_rd32(definitions[:], 12), u32(0x40))
	testing.expect_value(t, gsw_rd32(definitions[:], 16), u32(1))
	testing.expect_value(t, gsw_rd32(definitions[:], 52), u32(640))
	testing.expect_value(t, gsw_rd32(definitions[:], 56), u32(480))
	testing.expect_value(t, gsw_rd32(definitions[:], 64 + 8), u32(2))
	testing.expect_value(t, gsw_rd32(definitions[:], 64 + 12), u32(0x12))
	testing.expect_value(t, gsw_rd32(definitions[:], 64 + 16), u32(37))
	testing.expect_value(t, gsw_rd32(definitions[:], 64 + 52), u32(60))
	testing.expect(t, gsw3d_validate_svga9_batch(definitions[:]))

	testing.expect_value(t, len(vertices), 60)
	testing.expect_value(t, gsw_rd32(vertices[:], 0), u32(0x43A0_0000))
	testing.expect_value(t, gsw_rd32(vertices[:], 16), u32(0xFFFF_0000))
	testing.expect_value(t, gsw_rd32(vertices[:], 20), u32(0x440C_0000))
	testing.expect_value(t, gsw_rd32(vertices[:], 36), u32(0xFF00_FF00))
	testing.expect_value(t, gsw_rd32(vertices[:], 56), u32(0xFF00_00FF))

	testing.expect_value(t, len(render), 360)
	command_offsets := [?]int{0, 28, 56, 124, 196, 240}
	command_opcodes := [?]u32{1050, 1055, 1049, 1051, 1057, 1063}
	for offset, index in command_offsets {
		testing.expect_value(t, gsw_rd32(render[:], offset), command_opcodes[index])
	}
	testing.expect_value(t, gsw_rd32(render[:], 68), u32(1))
	testing.expect_value(t, gsw_rd32(render[:], 72), u32(0))
	testing.expect_value(t, gsw_rd32(render[:], 108), u32(47))
	testing.expect_value(t, gsw_rd32(render[:], 112), u32(15))
	testing.expect_value(t, gsw_rd32(render[:], 140), u32(1))
	testing.expect_value(t, gsw_rd32(render[:], 144), u32(0xFFFF_FFFF))
	testing.expect_value(t, gsw_rd32(render[:], 212), u32(0xFF10_1018))
	testing.expect_value(t, gsw_rd32(render[:], 252), u32(2))
	testing.expect_value(t, gsw_rd32(render[:], 260), u32(3))
	testing.expect_value(t, gsw_rd32(render[:], 268), u32(9))
	testing.expect_value(t, gsw_rd32(render[:], 276), u32(2))
	testing.expect_value(t, gsw_rd32(render[:], 284), u32(20))
	testing.expect_value(t, gsw_rd32(render[:], 296), u32(4))
	testing.expect_value(t, gsw_rd32(render[:], 304), u32(10))
	testing.expect_value(t, gsw_rd32(render[:], 316), u32(16))
	testing.expect_value(t, gsw_rd32(render[:], 340), u32(0xFFFF_FFFF))
	testing.expect(t, gsw3d_validate_svga9_batch(render[:], 1))

	testing.expect_value(t, len(descriptors), 256)
	descriptor_offsets := [?]int{0, 40, 64, 104, 152, 192}
	descriptor_lengths := [?]u32{40, 24, 40, 48, 40, 64}
	descriptor_opcodes := [?]Gsw3d_Opcode {
		.Register_Region,
		.Create_Context,
		.Submit,
		.Resource_Upload,
		.Submit,
		.Direct_Present,
	}
	for offset, index in descriptor_offsets {
		testing.expect_value(
			t,
			Gsw3d_Opcode(gsw_rd16(descriptors[:], offset)),
			descriptor_opcodes[index],
		)
		testing.expect_value(t, gsw_rd16(descriptors[:], offset + 2), GSW3D_COMMAND_VERSION)
		testing.expect_value(t, gsw_rd32(descriptors[:], offset + 4), descriptor_lengths[index])
		testing.expect_value(t, gsw_rd64(descriptors[:], offset + 8), u64(index + 1))
	}
	testing.expect_value(t, gsw_rd64(descriptors[:], 24), GSW3D_TRIANGLE_FIXTURE_REGION_GPA)
	testing.expect_value(t, gsw_rd64(descriptors[:], 32), GSW3D_TRIANGLE_FIXTURE_REGION_SIZE)
	testing.expect_value(t, gsw_rd64(descriptors[:], 128), GSW3D_TRIANGLE_FIXTURE_VERTICES_OFFSET)
	testing.expect_value(t, gsw_rd32(descriptors[:], 144), u32(60))
	testing.expect_value(t, gsw_rd64(descriptors[:], 176), GSW3D_TRIANGLE_FIXTURE_RENDER_OFFSET)
	testing.expect_value(t, gsw_rd32(descriptors[:], 184), u32(360))
	testing.expect_value(t, gsw_rd32(descriptors[:], 212), u32(1))
	testing.expect_value(t, gsw_rd32(descriptors[:], 224), u32(640))
	testing.expect_value(t, gsw_rd32(descriptors[:], 228), u32(480))
	testing.expect_value(t, gsw_rd32(descriptors[:], 248), u32(1))
}

Gsw3d_Triangle_Fixture_Backend :: struct {
	work_kinds:          [8]Gsw3d_Work_Kind,
	fences:              [8]u64,
	work_count:          int,
	submit_lengths:      [2]int,
	submit_count:        int,
	definitions:         [128]u8,
	render:              [360]u8,
	upload:              [60]u8,
	upload_length:       int,
	resource_id:         u32,
	region_id:           u32,
	source_offset:       u64,
	destination_offset:  u64,
	present_context:     u32,
	present_surface:     u32,
	present_source:      Gsw3d_Rect,
	present_destination: Gsw3d_Rect,
	present_interval:    u32,
}

gsw3d_triangle_fixture_backend_record :: proc(
	backend: ^Gsw3d_Triangle_Fixture_Backend,
	work: ^Gsw3d_Work,
) {
	if backend.work_count < len(backend.work_kinds) {
		backend.work_kinds[backend.work_count] = work.kind
		backend.fences[backend.work_count] = work.fence
	}
	backend.work_count += 1
}

gsw3d_triangle_fixture_backend_validate :: proc(ctx: rawptr, batch: []u8) -> bool {
	return len(batch) == 128 || len(batch) == 360
}

gsw3d_triangle_fixture_backend_resource_size :: proc(
	ctx: rawptr,
	format, width, height, depth: u32,
) -> (
	u64,
	bool,
) {
	bytes_per_element: u64
	switch format {
	case 1:
		bytes_per_element = 4
	case 37:
		bytes_per_element = 1
	case:
		return 0, false
	}
	size := u128(width) * u128(height) * u128(depth) * u128(bytes_per_element)
	if width == 0 || height == 0 || depth == 0 || size > u128(~u64(0)) {return 0, false}
	return u64(size), true
}

gsw3d_triangle_fixture_backend_execute :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Triangle_Fixture_Backend)(ctx)
	gsw3d_triangle_fixture_backend_record(backend, work)
	switch work.kind {
	case .Submit_Svga9:
		if backend.submit_count < len(backend.submit_lengths) {
			backend.submit_lengths[backend.submit_count] = len(work.batch)
		}
		if backend.submit_count == 0 && len(work.batch) == len(backend.definitions) {
			copy(backend.definitions[:], work.batch)
		} else if backend.submit_count == 1 && len(work.batch) == len(backend.render) {
			copy(backend.render[:], work.batch)
		}
		backend.submit_count += 1
	case .Direct_Present:
		backend.present_context = work.context_id
		backend.present_surface = work.surface_id
		backend.present_source = work.source
		backend.present_destination = work.destination
		backend.present_interval = work.interval
	case .Transport_Barrier, .Reset, .Create_Context, .Destroy_Context, .Resource_Upload:
		return true
	}
	return true
}

gsw3d_triangle_fixture_backend_upload :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Triangle_Fixture_Backend)(ctx)
	gsw3d_triangle_fixture_backend_record(backend, work)
	backend.resource_id = work.resource_id
	backend.region_id = work.region_id
	backend.source_offset = work.source_offset
	backend.destination_offset = work.destination_offset
	backend.upload_length = len(work.upload)
	if len(work.upload) == len(backend.upload) {copy(backend.upload[:], work.upload)}
	return true
}

gsw3d_triangle_fixture_backend_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	return true
}

gsw3d_triangle_fixture_backend_cancel :: proc(ctx: rawptr, generation: u64, stopping: bool) {}

@(test)
gsw3d_triangle_fixture_test_transport_executes_captured_frame :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 8192)
	defer delete(ram)
	backend: Gsw3d_Triangle_Fixture_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)

	attached := gsw_vga_set_3d_backend(
		&g,
		{
			ctx = &backend,
			capabilities = GSW3D_BACKEND_SVGA9 |
			GSW3D_BACKEND_DIRECT_PRESENT |
			GSW3D_BACKEND_RESOURCE_UPLOAD,
			present_intervals = u32(1) << 1,
			validate_svga9 = gsw3d_triangle_fixture_backend_validate,
			resource_size = gsw3d_triangle_fixture_backend_resource_size,
			execute = gsw3d_triangle_fixture_backend_execute,
			upload = gsw3d_triangle_fixture_backend_upload,
			reset = gsw3d_triangle_fixture_backend_reset,
			cancel = gsw3d_triangle_fixture_backend_cancel,
		},
	)
	if !testing.expect(t, attached) {return}

	definitions := gsw3d_triangle_fixture_definitions()
	vertices := gsw3d_triangle_fixture_vertices()
	render := gsw3d_triangle_fixture_render()
	descriptors := gsw3d_triangle_fixture_descriptors()
	copy(ram[int(GSW3D_TRIANGLE_FIXTURE_REGION_GPA):], definitions[:])
	copy(
		ram[int(GSW3D_TRIANGLE_FIXTURE_REGION_GPA + GSW3D_TRIANGLE_FIXTURE_VERTICES_OFFSET):],
		vertices[:],
	)
	copy(
		ram[int(GSW3D_TRIANGLE_FIXTURE_REGION_GPA + GSW3D_TRIANGLE_FIXTURE_RENDER_OFFSET):],
		render[:],
	)
	copy(ram[int(GSW3D_TRIANGLE_FIXTURE_RING_GPA):], descriptors[:])

	g.three_d.ring_gpa = GSW3D_TRIANGLE_FIXTURE_RING_GPA
	g.three_d.ring_size = GSW3D_TRIANGLE_FIXTURE_RING_SIZE
	g.three_d.ring_tail = u32(len(descriptors))
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect_value(t, g.three_d.error, Gsw3d_Error.None) {return}
	if !testing.expect_value(t, g.three_d.ring_head, u32(len(descriptors))) {return}
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	expected_kinds := [?]Gsw3d_Work_Kind {
		.Create_Context,
		.Submit_Svga9,
		.Resource_Upload,
		.Submit_Svga9,
		.Direct_Present,
	}
	if !testing.expect_value(t, backend.work_count, len(expected_kinds)) {return}
	for kind, index in expected_kinds {
		testing.expect_value(t, backend.work_kinds[index], kind)
		testing.expect_value(t, backend.fences[index], u64(index + 2))
	}
	testing.expect_value(t, backend.submit_count, 2)
	testing.expect_value(t, backend.submit_lengths[0], len(definitions))
	testing.expect_value(t, backend.submit_lengths[1], len(render))
	testing.expect(t, backend.definitions == definitions)
	testing.expect(t, backend.render == render)
	testing.expect_value(t, backend.upload_length, len(vertices))
	testing.expect(t, backend.upload == vertices)
	testing.expect_value(t, backend.resource_id, u32(2))
	testing.expect_value(t, backend.region_id, u32(1))
	testing.expect_value(t, backend.source_offset, GSW3D_TRIANGLE_FIXTURE_VERTICES_OFFSET)
	testing.expect_value(t, backend.destination_offset, u64(0))
	testing.expect_value(t, backend.present_context, u32(1))
	testing.expect_value(t, backend.present_surface, u32(1))
	testing.expect_value(t, backend.present_source, Gsw3d_Rect{width = 640, height = 480})
	testing.expect_value(t, backend.present_destination, Gsw3d_Rect{width = 640, height = 480})
	testing.expect_value(t, backend.present_interval, u32(1))
	testing.expect_value(t, g.three_d.completed_fence, u64(6))
	testing.expect_value(t, g.three_d.metrics.descriptors, u64(6))
	testing.expect_value(t, g.three_d.metrics.regions_registered, u64(1))
	testing.expect_value(t, g.three_d.metrics.contexts_created, u64(1))
	testing.expect_value(t, g.three_d.metrics.batches, u64(2))
	testing.expect_value(t, g.three_d.metrics.batch_bytes, u64(488))
	testing.expect_value(t, g.three_d.metrics.uploads, u64(1))
	testing.expect_value(t, g.three_d.metrics.upload_bytes, u64(60))
	testing.expect_value(t, g.three_d.metrics.presents, u64(1))
	resource_target := gsw3d_find_resource(&g.three_d, 1)
	resource_vertices := gsw3d_find_resource(&g.three_d, 2)
	if testing.expect(t, resource_target != nil) {
		testing.expect_value(t, resource_target.kind, Gsw3d_Resource_Kind.Surface)
		testing.expect_value(t, resource_target.flags, u32(0x40))
		testing.expect_value(t, resource_target.format, u32(1))
		testing.expect_value(t, resource_target.width, u32(640))
		testing.expect_value(t, resource_target.height, u32(480))
		testing.expect_value(t, resource_target.depth, u32(1))
		testing.expect_value(t, resource_target.mip_levels, u32(1))
		testing.expect_value(t, resource_target.size, u64(1_228_800))
	}
	if testing.expect(t, resource_vertices != nil) {
		testing.expect_value(t, resource_vertices.kind, Gsw3d_Resource_Kind.Buffer)
		testing.expect_value(t, resource_vertices.flags, u32(0x12))
		testing.expect_value(t, resource_vertices.format, u32(37))
		testing.expect_value(t, resource_vertices.width, u32(60))
		testing.expect_value(t, resource_vertices.height, u32(1))
		testing.expect_value(t, resource_vertices.depth, u32(1))
		testing.expect_value(t, resource_vertices.mip_levels, u32(1))
		testing.expect_value(t, resource_vertices.size, u64(60))
	}
}
