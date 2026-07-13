// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
vga_test_text_snapshot_and_guest_font :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, vga_mmio_write(&v, 0xB8000, 2, 0x0741))
	set_plane_byte(&v, 2, int('A') * 32, 0x80)
	v.crtc[0x0E] = 0
	v.crtc[0x0F] = 0
	snapshot := vga_text_snapshot(&v)
	testing.expect_value(t, snapshot.cells[0], u16(0x0741))
	testing.expect(t, snapshot.cursor_on)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Text)
	testing.expect_value(t, frame.width, 720)
	testing.expect_value(t, frame.height, 400)
	testing.expect_value(t, frame.aspect_width, 4)
	testing.expect_value(t, frame.aspect_height, 3)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
}

test_graphics_geometry :: proc(v: ^Vga, dots, lines: int) {
	v.gfx[6] = 0x05
	v.attr[0x10] |= 1
	v.attr[0x12] = 0x0F
	v.crtc[9] = 0
	v.crtc[0x13] = 1
	v.crtc[0x18] = 0xFF
	v.crtc[7] |= 0x10
	v.crtc[9] |= 0x40
	v.timing.visible_dots = dots
	v.timing.visible_lines = lines
}

@(test)
vga_test_planar_scanout_and_panning :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 8, 1)
	v.gfx[5] = 0
	set_plane_byte(&v, 0, 0, 0x80)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Planar_4)
	testing.expect_value(t, frame.width, 8)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	v.attr[0x13] = 1
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], frame.pixels[1])
}

@(test)
vga_test_mode_x_scanout :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 8, 1)
	v.gfx[5] = 0x40
	for p in 0 ..< 4 { set_plane_byte(&v, p, 0, u8(p + 1)) }
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 4)
	for x in 1 ..< 4 { testing.expect(t, frame.pixels[x] != frame.pixels[x - 1]) }
}

@(test)
vga_test_line_compare_split_and_page_latch :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 8, 2)
	v.gfx[5] = 0
	v.crtc[0x13] = 1
	v.crtc[0x18] = 0
	v.crtc[7] &= ~u8(0x10)
	v.crtc[9] &= ~u8(0x40)
	set_plane_byte(&v, 0, 0, 0xFF)
	set_plane_byte(&v, 0, 2, 0x00)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], frame.pixels[8])

	v.pending_start = 1
	v.start_pending = true
	v.timing.frame_period_ns = 1000
	vga_sync_to(&v, 1000)
	testing.expect_value(t, v.latched_start, u16(1))
	testing.expect(t, !v.start_pending)
}

test_vbe_pixel :: proc(v: ^Vga, bpp: u16, bytes: []u8) -> u32 {
	test_set_vbe_mode(v, 1, 1, bpp)
	copy(v.vram, bytes)
	return vga_display_frame(v).pixels[0]
}

@(test)
vga_test_vbe_pixel_formats :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.dac[3] = 0x3F
	v.dac[4] = 0
	v.dac[5] = 0
	set_plane_byte(&v, 0, 0, 0x80)
	testing.expect_value(t, test_vbe_pixel(&v, 4, v.vram[:4]), u32(0xFFFF0000))
	testing.expect_value(t, test_vbe_pixel(&v, 8, []u8{0x01}), u32(0xFFFF0000))
	testing.expect_value(t, test_vbe_pixel(&v, 15, []u8{0x00, 0x7C}), u32(0xFFFF0000))
	testing.expect_value(t, test_vbe_pixel(&v, 16, []u8{0x00, 0xF8}), u32(0xFFFF0000))
	testing.expect_value(t, test_vbe_pixel(&v, 24, []u8{0x11, 0x22, 0x33}), u32(0xFF332211))
	testing.expect_value(t, test_vbe_pixel(&v, 32, []u8{0x11, 0x22, 0x33, 0x77}), u32(0xFF332211))
}

@(test)
vga_test_vbe_planar_multi_byte_rows :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 16, 2, 4))
	set_plane_byte(&v, 0, 0, 0x80)
	set_plane_byte(&v, 2, 1, 0x80)
	set_plane_byte(&v, 1, 2, 0x80)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.width, 16)
	testing.expect_value(t, frame.height, 2)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[8] != frame.pixels[9])
	testing.expect(t, frame.pixels[16] != frame.pixels[17])
	testing.expect(t, frame.pixels[0] != frame.pixels[8])
}

@(test)
vga_test_mid_frame_palette_change_preserves_completed_line :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 2, 8))
	for i in 0 ..< 4 { v.vram[i] = 1 }
	old_color := u32(0xFF0000AA)
	v.timing = Video_Timing {
		frame_period_ns = 4_000_000,
		line_period_ns = 1_000_000,
		total_lines = 4,
		visible_lines = 2,
		visible_dots = 2,
		total_dots = 4,
		retrace_start = 2,
		retrace_end = 3,
	}
	vga_sync_to(&v, 500_000)
	v.dac[3] = 0x3F
	v.dac[4] = 0
	v.dac[5] = 0
	new_color := u32(0xFFFF0000)
	testing.expect(t, old_color != new_color)
	vga_sync_to(&v, 1_500_000)
	vga_sync_to(&v, 4_000_000)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], old_color)
	testing.expect_value(t, frame.pixels[1], old_color)
	testing.expect_value(t, frame.pixels[2], new_color)
	testing.expect_value(t, frame.pixels[3], new_color)
}
