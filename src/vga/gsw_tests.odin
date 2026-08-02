// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

gsw_test_wr16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

gsw_test_wr32 :: proc(data: []u8, offset: int, value: u32) {
	for i in 0 ..< 4 {data[offset + i] = u8(value >> (8 * uint(i)))}
}

gsw_test_wr64 :: proc(data: []u8, offset: int, value: u64) {
	gsw_test_wr32(data, offset, u32(value))
	gsw_test_wr32(data, offset + 4, u32(value >> 32))
}

gsw_test_header :: proc(
	data: []u8,
	opcode: Gsw_Vga_Opcode,
	fence: u64,
	version := GSW_VGA_COMMAND_VERSION,
) {
	gsw_test_wr16(data, 0, u16(opcode))
	gsw_test_wr16(data, 2, version)
	gsw_test_wr32(data, 4, u32(len(data)))
	gsw_test_wr64(data, 8, fence)
}

@(test)
gsw_vga_test_raw_mmio_write_metrics_include_rejected_accesses :: proc(t: ^testing.T) {
	g: Gsw_Vga
	gsw_vga_init(&g, nil)
	defer gsw_vga_destroy(&g)
	valid: [4]u8
	invalid: [3]u8

	gsw_vga_mmio_write(&g, GSW_VGA_REG_STATUS, valid[:], nil)
	gsw_vga_mmio_write(&g, GSW_VGA_REG_STATUS, invalid[:], nil)

	testing.expect_value(t, g.metrics.mmio_write_count, u64(2))
	testing.expect_value(t, g.metrics.mmio_write_bytes, u64(7))
	testing.expect_value(t, g.metrics.malformed, u64(1))
}

@(test)
gsw_vga_test_v2_surface_offset_present_publishes_without_legacy_mutation :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 1024)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	g.ring_gpa = 128
	g.ring_size = 256
	framebuffer[4] = 3

	present := ram[128:168]
	gsw_test_header(present, .Present, 11, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(present, 16, 4)
	gsw_test_wr32(present, 20, 2)
	gsw_test_wr32(present, 24, 1)
	gsw_test_wr32(present, 28, 8)
	gsw_test_wr32(present, 32, u32(Gsw_Pixel_Format.Indexed_8))
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	g.ring_tail = 40
	gsw_vga_process(&g, ram)

	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect_value(t, snapshot.active.header.sequence, sequence + 1)
	testing.expect_value(t, snapshot.active.header.lifecycle_generation, u64(1))
	testing.expect(t, snapshot.active.header.mode_generation != 0)
	testing.expect_value(t, snapshot.active.header.device_generation, u64(1))
	testing.expect_value(t, snapshot.active.header.surface.id, GSW_IMPLICIT_SURFACE_ID)
	testing.expect(t, snapshot.active.header.surface.generation != 0)
	testing.expect_value(t, snapshot.active.source_offset, u64(4))
	testing.expect_value(t, snapshot.active.source_pitch, u32(8))
	testing.expect_value(t, snapshot.active.header.source.width, u32(2))
	testing.expect_value(t, snapshot.active.header.source.height, u32(1))
	testing.expect_value(t, snapshot.active.header.dirty.count, u32(1))
	testing.expect_value(t, snapshot.active.header.interval, u32(0))
	testing.expect_value(t, snapshot.active.header.completion.value, u64(11))
	testing.expect_value(t, snapshot.active.header.completion.generation, u64(1))
	testing.expect(t, snapshot.active.header.source_kind == .Gsw_Snapshot)
	testing.expect(t, snapshot.active.header.ownership == .Vm_Framebuffer)
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, g.metrics.presents, u64(1))
	testing.expect_value(t, g.metrics.commands, u64(1))
	identity := vga_active_presentation_identity(&v, &g)
	testing.expect(t, identity.valid)
	testing.expect(t, identity.owner == .Gsw2d)
	testing.expect_value(t, identity.sequence, snapshot.active.header.sequence)
	testing.expect_value(t, identity.mode_generation, snapshot.active.header.mode_generation)
	testing.expect_value(t, identity.surface_id, snapshot.active.header.surface.id)
	testing.expect_value(t, identity.surface_generation, snapshot.active.header.surface.generation)
	testing.expect_value(t, identity.width, u32(2))
	testing.expect_value(t, identity.height, u32(1))
}

@(test)
gsw_vga_test_v2_present_identity_change_advances_surface_generation :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 1024)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	g.ring_gpa = 128
	g.ring_size = 256
	framebuffer[0] = 1
	framebuffer[16] = 2
	v.dac[3], v.dac[4], v.dac[5] = 0x3F, 0, 0
	v.dac[6], v.dac[7], v.dac[8] = 0, 0x3F, 0

	first := ram[128:168]
	gsw_test_header(first, .Present, 1, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(first, 20, 2)
	gsw_test_wr32(first, 24, 2)
	gsw_test_wr32(first, 28, 8)
	gsw_test_wr32(first, 32, u32(Gsw_Pixel_Format.Indexed_8))
	second := ram[168:208]
	gsw_test_header(second, .Present, 2, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(second, 16, 16)
	gsw_test_wr32(second, 20, 2)
	gsw_test_wr32(second, 24, 2)
	gsw_test_wr32(second, 28, 8)
	gsw_test_wr32(second, 32, u32(Gsw_Pixel_Format.Indexed_8))

	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	g.ring_tail = 40
	gsw_vga_process(&g, ram)
	first_snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, first_snapshot.active_valid)
	testing.expect_value(t, first_snapshot.active.source_offset, u64(0))
	first_surface_generation := first_snapshot.active.header.surface.generation
	g.ring_tail = 80
	gsw_vga_process(&g, ram)
	second_snapshot := gsw_vga_presentation_snapshot(&g)
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 2)
	testing.expect(t, second_snapshot.active_valid)
	testing.expect_value(t, second_snapshot.active.source_offset, u64(16))
	testing.expect(t, second_snapshot.active.header.surface.generation != first_surface_generation)
	testing.expect_value(
		t,
		second_snapshot.active.header.mode_generation,
		first_snapshot.active.header.mode_generation,
	)
	testing.expect_value(t, g.completed_fence, u64(2))
	testing.expect_value(t, g.metrics.presents, u64(2))
	testing.expect_value(t, g.present_generation, u64(2))
}

@(test)
gsw_vga_test_mode_and_present_reject_unrepresentable_surfaces_without_scanout :: proc(
	t: ^testing.T,
) {
	framebuffer: [4096]u8
	ram: [1024]u8

	mode_device: Gsw_Vga
	gsw_vga_init(&mode_device, framebuffer[:])
	defer gsw_vga_destroy(&mode_device)
	mode_device.ring_gpa = 128
	mode_device.ring_size = 256
	mode := ram[128:160]
	gsw_test_header(mode, .Set_Mode, 1)
	gsw_test_wr32(mode, 16, 1)
	gsw_test_wr32(mode, 20, 1)
	gsw_test_wr32(mode, 24, 0x0004_0000)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Xrgb_8888))
	mode_device.ring_tail = 32
	gsw_vga_process(&mode_device, ram[:])
	testing.expect(t, mode_device.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, mode_device.ring_head, u32(0))

	ram = {}
	present_device: Gsw_Vga
	gsw_vga_init(&present_device, framebuffer[:])
	defer gsw_vga_destroy(&present_device)
	present_device.ring_gpa = 128
	present_device.ring_size = 256
	present := ram[128:168]
	gsw_test_header(present, .Present, 2, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(present, 16, 4092)
	gsw_test_wr32(present, 20, 2)
	gsw_test_wr32(present, 24, 1)
	gsw_test_wr32(present, 28, 8)
	gsw_test_wr32(present, 32, u32(Gsw_Pixel_Format.Xrgb_8888))
	present_device.ring_tail = 40
	gsw_vga_process(&present_device, ram[:])
	testing.expect(t, present_device.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, present_device.present_generation, u64(0))
	testing.expect_value(t, present_device.ring_head, u32(0))
}

@(test)
gsw_vga_test_2d_writes_do_not_fabricate_legacy_content :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 1024)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	testing.expect(t, test_set_vbe_mode(&v, 1, 2, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 2))
	_ = vga_display_frame(&v)
	testing.expect(t, v.frame_valid)
	g.ring_gpa = 128
	g.ring_size = 256
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	mode_clock := v.presentation_mode_clock

	fill := ram[128:168]
	gsw_test_header(fill, .Fill, 1)
	gsw_test_wr32(fill, 20, 8)
	gsw_test_wr32(fill, 24, 1)
	gsw_test_wr32(fill, 28, 1)
	gsw_test_wr32(fill, 32, 0x0011_2233)
	gsw_test_wr32(fill, 36, u32(Gsw_Pixel_Format.Xrgb_8888))
	copy_command := ram[168:212]
	gsw_test_header(copy_command, .Copy, 2)
	gsw_test_wr32(copy_command, 16, 0)
	gsw_test_wr32(copy_command, 20, 64)
	gsw_test_wr32(copy_command, 24, 8)
	gsw_test_wr32(copy_command, 28, 8)
	gsw_test_wr32(copy_command, 32, 1)
	gsw_test_wr32(copy_command, 36, 1)
	gsw_test_wr32(copy_command, 40, u32(Gsw_Pixel_Format.Xrgb_8888))
	gsw2d_test_register(t, &g, 7, 128, 2, 1, 8, .Xrgb_8888)
	surface_fill := ram[212:252]
	gsw_test_header(surface_fill, .Surface_Fill, 3, GSW_VGA_COMMAND_VERSION_3)
	gsw_test_wr32(surface_fill, 16, 7)
	gsw_test_wr32(surface_fill, 28, 1)
	gsw_test_wr32(surface_fill, 32, 1)
	gsw_test_wr32(surface_fill, 36, 0x0044_5566)
	surface_dirty := ram[252:288]
	gsw_test_header(surface_dirty, .Surface_Dirty, 4, GSW_VGA_COMMAND_VERSION_3)
	gsw_test_wr32(surface_dirty, 16, 7)
	gsw_test_wr32(surface_dirty, 28, 1)
	gsw_test_wr32(surface_dirty, 32, 1)
	g.ring_tail = 160
	gsw_vga_process(&g, ram)

	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, v.presentation_mode_clock, mode_clock)
	testing.expect_value(t, framebuffer[0], u8(0x33))
	testing.expect_value(t, framebuffer[64], u8(0x33))
	testing.expect_value(t, framebuffer[128], u8(0x66))
	testing.expect_value(t, g.metrics.fills, u64(2))
	testing.expect_value(t, g.metrics.copies, u64(1))
}

@(test)
gsw_vga_test_v2_blt_stretches_and_honors_color_key :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 4096)
	defer delete(framebuffer)
	ram := make([]u8, 1024)
	defer delete(ram)
	source := [4]u8{1, 2, 3, 4}
	copy(framebuffer[0:4], source[:])
	for &pixel in framebuffer[32:40] {pixel = 9}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	g.ring_gpa = 128
	g.ring_size = 256

	blt := ram[128:128 + GSW_BLT_V2_COMMAND_BYTES]
	gsw_test_header(blt, .Blt, 12, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(blt, 16, 0)
	gsw_test_wr32(blt, 20, 32)
	gsw_test_wr32(blt, 24, 2)
	gsw_test_wr32(blt, 28, 4)
	gsw_test_wr32(blt, 40, 2)
	gsw_test_wr32(blt, 44, 2)
	gsw_test_wr32(blt, 56, 4)
	gsw_test_wr32(blt, 60, 2)
	gsw_test_wr32(blt, 64, u32(Gsw_Pixel_Format.Indexed_8))
	gsw_test_wr32(blt, 68, u32(Gsw_Pixel_Format.Indexed_8))
	gsw_test_wr32(blt, 72, GSW_BLT_SRC_COLOR_KEY)
	gsw_test_wr32(blt, 76, 2)
	gsw_test_wr32(blt, 84, 0xCC)
	g.ring_tail = GSW_BLT_V2_COMMAND_BYTES
	gsw_vga_process(&g, ram)

	expected := [?]u8{1, 1, 9, 9, 3, 3, 4, 4}
	for value, i in expected {testing.expect_value(t, framebuffer[32 + i], value)}
	testing.expect_value(t, g.metrics.blits, u64(1))
	testing.expect_value(t, g.completed_fence, u64(12))
}

@(test)
gsw_vga_test_persona_and_control_identity :: proc(t: ^testing.T) {
	vram_mib, core_mhz, agp := gsw_vga_persona()
	testing.expect_value(t, vram_mib, u32(VRAM_SIZE / (1024 * 1024)))
	testing.expect_value(t, core_mhz, u32(150))
	testing.expect_value(t, agp, u32(4))
	g: Gsw_Vga
	gsw_vga_init(&g, make([]u8, 4096))
	defer delete(g.framebuffer)
	data: [4]u8
	gsw_vga_mmio_read(&g, GSW_VGA_REG_ID, data[:])
	testing.expect_value(
		t,
		u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24,
		GSW_VGA_ID,
	)
}

@(test)
gsw_vga_test_fill_copy_present_and_fence_irq :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 4096)
	defer delete(framebuffer)
	ram := make([]u8, 4096)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	asserted := false
	gsw_vga_set_irq(&g, &asserted, proc(ctx: rawptr, value: bool) {(^bool)(ctx)^ = value})
	g.ring_gpa = 512
	g.ring_size = 256
	g.irq_enable = 1

	fill := ram[512:552]
	gsw_test_header(fill, .Fill, 7)
	gsw_test_wr32(fill, 16, 0)
	gsw_test_wr32(fill, 20, 16)
	gsw_test_wr32(fill, 24, 4)
	gsw_test_wr32(fill, 28, 2)
	gsw_test_wr32(fill, 32, 0x1122_3344)
	gsw_test_wr32(fill, 36, u32(Gsw_Pixel_Format.Xrgb_8888))
	g.ring_tail = 40
	gsw_vga_process(&g, ram)
	testing.expect(
		t,
		framebuffer[0] == 0x44 &&
		framebuffer[1] == 0x33 &&
		framebuffer[2] == 0x22 &&
		framebuffer[3] == 0x11,
	)
	testing.expect(
		t,
		framebuffer[16] == 0x44 &&
		framebuffer[17] == 0x33 &&
		framebuffer[18] == 0x22 &&
		framebuffer[19] == 0x11,
	)
	testing.expect_value(t, g.completed_fence, u64(7))
	testing.expect(t, asserted)

	copy_command := ram[552:596]
	gsw_test_header(copy_command, .Copy, 8)
	gsw_test_wr32(copy_command, 16, 0)
	gsw_test_wr32(copy_command, 20, 64)
	gsw_test_wr32(copy_command, 24, 16)
	gsw_test_wr32(copy_command, 28, 16)
	gsw_test_wr32(copy_command, 32, 4)
	gsw_test_wr32(copy_command, 36, 2)
	gsw_test_wr32(copy_command, 40, u32(Gsw_Pixel_Format.Xrgb_8888))
	present := ram[596:636]
	gsw_test_header(present, .Present, 9, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(present, 16, 64)
	gsw_test_wr32(present, 20, 4)
	gsw_test_wr32(present, 24, 2)
	gsw_test_wr32(present, 28, 16)
	gsw_test_wr32(present, 32, u32(Gsw_Pixel_Format.Xrgb_8888))
	g.ring_tail = 124
	gsw_vga_process(&g, ram)
	testing.expect(t, framebuffer[64] == framebuffer[0] && framebuffer[67] == framebuffer[3])
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, g.metrics.commands, u64(3))
	testing.expect_value(t, g.metrics.software_pixels, u64(16))
	testing.expect_value(t, g.metrics.fenced_command_completions, u64(3))
}

@(test)
gsw_vga_test_unfenced_command_preserves_completed_fence_and_irq :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	g.ring_gpa = 128
	g.ring_size = 256

	for command_index in 0 ..< 2 {
		offset := 128 + command_index * 40
		fill := ram[offset:offset + 40]
		gsw_test_header(fill, .Fill, command_index == 0 ? u64(7) : u64(0))
		gsw_test_wr32(fill, 16, u32(command_index * 16))
		gsw_test_wr32(fill, 20, 4)
		gsw_test_wr32(fill, 24, 1)
		gsw_test_wr32(fill, 28, 1)
		gsw_test_wr32(fill, 32, u32(command_index + 1))
		gsw_test_wr32(fill, 36, u32(Gsw_Pixel_Format.Xrgb_8888))
	}
	g.ring_tail = 80
	gsw_vga_process(&g, ram[:])
	testing.expect_value(t, g.completed_fence, u64(7))
	testing.expect(t, g.irq_status & GSW_VGA_IRQ_2D != 0)
	testing.expect_value(t, g.metrics.commands, u64(2))
	testing.expect_value(t, g.metrics.fenced_command_completions, u64(1))
}

@(test)
gsw_vga_test_copy_handles_vertical_overlap :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 4096)
	defer delete(framebuffer)
	ram := make([]u8, 4096)
	defer delete(ram)
	for i in 0 ..< 16 {framebuffer[i] = u8(i + 1)}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	g.ring_gpa = 512
	g.ring_size = 256
	command := ram[512:556]
	gsw_test_header(command, .Copy, 9)
	gsw_test_wr32(command, 16, 0)
	gsw_test_wr32(command, 20, 4)
	gsw_test_wr32(command, 24, 4)
	gsw_test_wr32(command, 28, 4)
	gsw_test_wr32(command, 32, 4)
	gsw_test_wr32(command, 36, 3)
	gsw_test_wr32(command, 40, u32(Gsw_Pixel_Format.Indexed_8))
	g.ring_tail = 44
	gsw_vga_process(&g, ram)
	for i in 0 ..< 12 {testing.expect_value(t, framebuffer[4 + i], u8(i + 1))}
}

@(test)
gsw_vga_test_copy_snapshots_differing_pitch_overlap :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 512)
	defer delete(framebuffer)
	ram := make([]u8, 1024)
	defer delete(ram)
	for row in 0 ..< 3 {
		for x in 0 ..< 10 {framebuffer[row * 100 + x] = u8(row * 10 + x + 1)}
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	g.ring_gpa = 128
	g.ring_size = 256
	command := ram[128:172]
	gsw_test_header(command, .Copy, 9)
	gsw_test_wr32(command, 16, 0)
	gsw_test_wr32(command, 20, 5)
	gsw_test_wr32(command, 24, 100)
	gsw_test_wr32(command, 28, 50)
	gsw_test_wr32(command, 32, 10)
	gsw_test_wr32(command, 36, 3)
	gsw_test_wr32(command, 40, u32(Gsw_Pixel_Format.Indexed_8))
	g.ring_tail = 44
	gsw_vga_process(&g, ram)

	for row in 0 ..< 3 {
		for x in 0 ..< 10 {
			testing.expect_value(t, framebuffer[5 + row * 50 + x], u8(row * 10 + x + 1))
		}
	}
}

@(test)
gsw_vga_test_rejects_wrapping_mode_and_fill_dimensions :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [1024]u8

	mode_device: Gsw_Vga
	gsw_vga_init(&mode_device, framebuffer[:])
	defer gsw_vga_destroy(&mode_device)
	mode_device.ring_gpa = 128
	mode_device.ring_size = 256
	mode := ram[128:160]
	gsw_test_header(mode, .Set_Mode, 1)
	gsw_test_wr32(mode, 16, 0x4000_0000)
	gsw_test_wr32(mode, 20, 1)
	gsw_test_wr32(mode, 24, 0)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Xrgb_8888))
	mode_device.ring_tail = 32
	gsw_vga_process(&mode_device, ram[:])
	testing.expect(t, mode_device.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, mode_device.width, u32(0))

	ram = {}
	fill_device: Gsw_Vga
	gsw_vga_init(&fill_device, framebuffer[:])
	defer gsw_vga_destroy(&fill_device)
	fill_device.ring_gpa = 128
	fill_device.ring_size = 256
	fill := ram[128:168]
	gsw_test_header(fill, .Fill, 2)
	gsw_test_wr32(fill, 16, 0)
	gsw_test_wr32(fill, 20, 0xFFFF_FFFF)
	gsw_test_wr32(fill, 24, 0xC000_0000)
	gsw_test_wr32(fill, 28, 0xFFFF_FFFF)
	gsw_test_wr32(fill, 36, u32(Gsw_Pixel_Format.Xrgb_8888))
	fill_device.ring_tail = 40
	gsw_vga_process(&fill_device, ram[:])
	testing.expect(t, fill_device.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, fill_device.metrics.fills, u64(0))

	_, rect_ok := gsw_surface_rect(
		len(framebuffer),
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		0xFFFF_FFFF,
		4,
	)
	testing.expect(t, !rect_ok)
}

@(test)
gsw_vga_test_mode_palette_and_present_have_separate_legacy_effects :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 4096)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	g.ring_gpa = 512
	g.ring_size = 256

	mode := ram[512:544]
	gsw_test_header(mode, .Set_Mode, 0)
	gsw_test_wr32(mode, 16, 2)
	gsw_test_wr32(mode, 20, 1)
	gsw_test_wr32(mode, 24, 2)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Indexed_8))
	palette := ram[544:572]
	gsw_test_header(palette, .Set_Palette, 0)
	gsw_test_wr32(palette, 16, 1)
	gsw_test_wr32(palette, 20, 1)
	gsw_test_wr32(palette, 24, 0x00FF_0000)
	present := ram[572:588]
	gsw_test_header(present, .Present, 10)
	framebuffer[0] = 1
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	g.ring_tail = 60
	gsw_vga_process(&g, ram)
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, g.metrics.palette_updates, u64(1))
	testing.expect_value(t, g.palette.dac_bits, GSW_PALETTE_DAC_BITS)
	testing.expect_value(t, g.palette.entries[3], u8(0xFF))
	testing.expect_value(t, g.palette.entries[4], u8(0))
	testing.expect_value(t, g.palette.entries[5], u8(0))
	g.ring_tail = 76
	gsw_vga_process(&g, ram)

	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	testing.expect_value(t, g.width, u32(2))
	testing.expect_value(t, g.height, u32(1))
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect(t, snapshot.active.header.format == .Indexed_8)
	testing.expect_value(t, snapshot.active.header.completion.value, u64(10))
}

@(test)
gsw_vga_test_identical_indexed_palette_resubmission_is_presentation_noop :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 1024)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	g.ring_gpa = 128
	g.ring_size = 256

	mode := ram[128:160]
	gsw_test_header(mode, .Set_Mode, 0)
	gsw_test_wr32(mode, 16, 2)
	gsw_test_wr32(mode, 20, 1)
	gsw_test_wr32(mode, 24, 2)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Indexed_8))
	palette := ram[160:188]
	gsw_test_header(palette, .Set_Palette, 0)
	gsw_test_wr32(palette, 16, 1)
	gsw_test_wr32(palette, 20, 1)
	gsw_test_wr32(palette, 24, 0x0012_3456)
	present := ram[188:204]
	gsw_test_header(present, .Present, 1)
	repeat := ram[204:232]
	gsw_test_header(repeat, .Set_Palette, 0)
	gsw_test_wr32(repeat, 16, 1)
	gsw_test_wr32(repeat, 20, 1)
	gsw_test_wr32(repeat, 24, 0x0012_3456)

	g.ring_tail = 76
	gsw_vga_process(&g, ram)
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	header := snapshot.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			header.sequence,
			header.device_generation,
			header.surface.id,
			header.surface.generation,
		),
	)
	testing.expect_value(t, g.presentation_state.damage_batch_count, u32(0))
	testing.expect_value(t, g.presentation_state.active.header.dirty.count, u32(0))
	sequence := vga_presentation_sequence(&v)
	producer_sequence := g.presentation_state.sequence
	state_generation := g.presentation_state.state_generation
	damage := g.presentation_state.damage
	dirty := g.presentation_state.active.header.dirty
	palette_updates := g.metrics.palette_updates

	g.ring_tail = 104
	gsw_vga_process(&g, ram)

	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, g.presentation_state.sequence, producer_sequence)
	testing.expect_value(t, g.presentation_state.active.header.sequence, header.sequence)
	testing.expect_value(t, g.presentation_state.state_generation, state_generation)
	testing.expect_value(t, g.presentation_state.damage, damage)
	testing.expect_value(t, g.presentation_state.damage_batch_count, u32(0))
	testing.expect_value(t, g.presentation_state.active.header.dirty, dirty)
	testing.expect_value(t, g.metrics.palette_updates, palette_updates + 1)
}

@(test)
gsw_vga_test_palette_does_not_inherit_legacy_dac_width :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 1024)
	defer delete(ram)
	v.dispi[DISPI_INDEX_ENABLE] |= DISPI_8BIT_DAC
	v.dac[3], v.dac[4], v.dac[5] = 0x11, 0x22, 0x33
	framebuffer[0] = 1

	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	gsw_vga_attach_scanout(&g, &v)
	g.ring_gpa = 128
	g.ring_size = 256
	mode := ram[128:160]
	gsw_test_header(mode, .Set_Mode, 0)
	gsw_test_wr32(mode, 16, 1)
	gsw_test_wr32(mode, 20, 1)
	gsw_test_wr32(mode, 24, 1)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Indexed_8))
	palette := ram[160:188]
	gsw_test_header(palette, .Set_Palette, 0)
	gsw_test_wr32(palette, 16, 1)
	gsw_test_wr32(palette, 20, 1)
	gsw_test_wr32(palette, 24, 0x0080_4020)
	present := ram[188:204]
	gsw_test_header(present, .Present, 1)
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	g.ring_tail = 60
	gsw_vga_process(&g, ram)
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, g.palette.dac_bits, GSW_PALETTE_DAC_BITS)
	testing.expect_value(t, g.palette.entries[3], u8(0x80))
	testing.expect_value(t, g.palette.entries[4], u8(0x40))
	testing.expect_value(t, g.palette.entries[5], u8(0x20))
	g.ring_tail = 76
	gsw_vga_process(&g, ram)

	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	testing.expect(t, v.dispi[DISPI_INDEX_ENABLE] & DISPI_8BIT_DAC != 0)
	testing.expect_value(t, v.dac[3], u8(0x11))
	testing.expect_value(t, v.dac[4], u8(0x22))
	testing.expect_value(t, v.dac[5], u8(0x33))
	testing.expect(t, gsw_vga_presentation_snapshot(&g).active_valid)
}

@(test)
gsw_vga_test_palette_rejection_is_transactional :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	g.palette.entries[3], g.palette.entries[4], g.palette.entries[5] = 1, 2, 3
	before := g.palette
	gsw_test_header(ram[:28], .Set_Palette, 0)
	gsw_test_wr32(ram[:28], 16, 255)
	gsw_test_wr32(ram[:28], 20, 2)
	gsw_test_wr32(ram[:28], 24, 0x00FF_FFFF)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 28

	gsw_vga_process(&g, ram[:])

	testing.expect_value(t, g.palette, before)
	testing.expect_value(t, g.metrics.palette_updates, u64(0))
	testing.expect_value(t, g.ring_head, u32(0))
	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
}

@(test)
gsw_vga_test_malformed_command_stops_ring :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 4096)
	defer delete(framebuffer)
	ram := make([]u8, 1024)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	g.ring_gpa = 128
	g.ring_size = 256
	g.ring_tail = 16
	gsw_test_wr16(ram[128:], 0, u16(Gsw_Vga_Opcode.Present))
	gsw_test_wr16(ram[128:], 2, 99)
	gsw_test_wr32(ram[128:], 4, 16)
	gsw_vga_process(&g, ram)
	testing.expect(t, g.status & GSW_VGA_STATUS_ERROR != 0)
	testing.expect_value(t, g.ring_head, u32(0))
	testing.expect_value(t, g.metrics.malformed, u64(1))
}

@(test)
gsw_vga_test_control_bar_decode_tracks_pci_state :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	new_base := u64(0xD100_0000)

	gsw_vga_set_pci_decode(&g, false, new_base)
	_, disabled := gsw_vga_control_offset(&g, new_base, 4)
	testing.expect(t, !disabled)
	gsw_vga_set_pci_decode(&g, true, new_base)
	_, old := gsw_vga_control_offset(&g, GSW_VGA_CONTROL_BASE, 4)
	offset, relocated := gsw_vga_control_offset(&g, new_base + u64(GSW_VGA_REG_STATUS), 4)
	testing.expect(t, !old)
	testing.expect(t, relocated)
	testing.expect_value(t, offset, GSW_VGA_REG_STATUS)
}
