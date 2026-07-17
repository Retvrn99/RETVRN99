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
gsw_vga_test_v2_surface_offset_present :: proc(t: ^testing.T) {
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
	g.ring_tail = 40
	gsw_vga_process(&g, ram)

	testing.expect_value(t, v.dispi[DISPI_INDEX_X_OFFSET], u16(4))
	testing.expect_value(t, v.dispi[DISPI_INDEX_Y_OFFSET], u16(0))
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], u32(0xFF00_AAAA))
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
	testing.expect_value(t, vram_mib, u32(32))
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
	present := ram[596:612]
	gsw_test_header(present, .Present, 9)
	g.ring_tail = 100
	gsw_vga_process(&g, ram)
	testing.expect(t, framebuffer[64] == framebuffer[0] && framebuffer[67] == framebuffer[3])
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, g.metrics.commands, u64(3))
	testing.expect_value(t, g.metrics.software_pixels, u64(16))
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
gsw_vga_test_mode_palette_and_present_drive_scanout :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	ram := make([]u8, 4096)
	defer delete(ram)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
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
	g.ring_tail = 76
	gsw_vga_process(&g, ram)

	testing.expect(t, vga_vbe_enabled(&v))
	testing.expect_value(t, v.dispi[DISPI_INDEX_XRES], u16(2))
	testing.expect_value(t, g.metrics.palette_updates, u64(1))
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF_0000))
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
