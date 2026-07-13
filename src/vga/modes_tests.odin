// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

test_bochs_legacy_mode :: proc(v: ^Vga, mode: u8) {
	v.seq = {}
	v.crtc = {}
	v.attr = {}
	v.gfx = {}
	v.video_on = true
	for i in 0 ..< 16 { v.attr[i] = u8(i) }
	v.attr[0x12] = 0x0F
	v.gfx[7] = 0x0F
	v.gfx[8] = 0xFF
	switch mode {
	case 0x06:
		v.seq[1] = 0x01; v.seq[2] = 0x01; v.seq[4] = 0x06; v.misc = 0x63
		v.crtc[0] = 0x5F; v.crtc[1] = 0x4F; v.crtc[6] = 0xBF; v.crtc[7] = 0x1F
		v.crtc[9] = 0xC1; v.crtc[0x10] = 0x9C; v.crtc[0x11] = 0x8E; v.crtc[0x12] = 0x8F
		v.crtc[0x13] = 0x28; v.crtc[0x18] = 0xFF
		v.attr[0x10] = 0x01; v.attr[0x12] = 0x01
		v.attr[1] = 0x17
		v.gfx[5] = 0x00; v.gfx[6] = 0x0D
	case 0x0D:
		v.seq[1] = 0x09; v.seq[2] = 0x0F; v.seq[4] = 0x06; v.misc = 0x63
		v.crtc[0] = 0x2D; v.crtc[1] = 0x27; v.crtc[6] = 0xBF; v.crtc[7] = 0x1F
		v.crtc[9] = 0xC0; v.crtc[0x10] = 0x9C; v.crtc[0x11] = 0x8E; v.crtc[0x12] = 0x8F
		v.crtc[0x13] = 0x14; v.crtc[0x18] = 0xFF
		v.attr[0x10] = 0x01
		v.gfx[5] = 0x00; v.gfx[6] = 0x05
	case 0x12:
		v.seq[1] = 0x01; v.seq[2] = 0x0F; v.seq[4] = 0x06; v.misc = 0xE3
		v.crtc[0] = 0x5F; v.crtc[1] = 0x4F; v.crtc[6] = 0x0B; v.crtc[7] = 0x3E
		v.crtc[9] = 0x40; v.crtc[0x10] = 0xEA; v.crtc[0x11] = 0x8C; v.crtc[0x12] = 0xDF
		v.crtc[0x13] = 0x28; v.crtc[0x18] = 0xFF
		v.attr[0x10] = 0x01
		v.gfx[5] = 0x00; v.gfx[6] = 0x05
	case 0x13:
		v.seq[1] = 0x01; v.seq[2] = 0x0F; v.seq[4] = 0x0E; v.misc = 0x63
		v.crtc[0] = 0x5F; v.crtc[1] = 0x4F; v.crtc[6] = 0xBF; v.crtc[7] = 0x1F
		v.crtc[9] = 0x41; v.crtc[0x10] = 0x9C; v.crtc[0x11] = 0x8E; v.crtc[0x12] = 0x8F
		v.crtc[0x13] = 0x28; v.crtc[0x18] = 0xFF
		v.attr[0x10] = 0x41
		v.gfx[5] = 0x40; v.gfx[6] = 0x05
	}
	vga_recalculate_timing(v)
}

@(test)
vga_test_bochs_mode06_tuple_and_cga1_rows :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x06)
	set_plane_byte(&v, 0, 0, 0x80)
	set_plane_byte(&v, 0, 0x2000, 0x40)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Cga_1)
	testing.expect_value(t, frame.width, 640)
	testing.expect_value(t, frame.height, 200)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[640] != frame.pixels[641])
	testing.expect(t, frame.pixels[641] != frame.pixels[642])
}

@(test)
vga_test_bochs_mode12_tuple :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0x80)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Planar_4)
	testing.expect_value(t, frame.width, 640)
	testing.expect_value(t, frame.height, 480)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
}

@(test)
vga_test_bochs_mode13_tuple_and_max_scan_repeat :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	for p in 0 ..< 4 { set_plane_byte(&v, p, 0, u8(p + 1)) }
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 200)
	for x in 1 ..< 4 { testing.expect(t, frame.pixels[x] != frame.pixels[x - 1]) }
}

@(test)
vga_test_sequencer_dot_clock_divider :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x0D)
	testing.expect(t, v.timing.frame_period_ns > 14_000_000)
	testing.expect(t, v.timing.frame_period_ns < 15_000_000)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 200)
}

@(test)
vga_test_screen_blank_controls :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0xFF)
	v.attr_flip = false
	vga_out(&v, 0x3C0, 0x00)
	testing.expect(t, !v.video_on)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], u32(0xFF000000))
	v.video_on = true
	v.seq[1] |= 0x20
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], u32(0xFF000000))
}

@(test)
vga_test_start_address_latches_at_retrace_entry :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.timing.frame_period_ns = 1000
	v.timing.line_period_ns = 100
	v.timing.total_lines = 10
	v.timing.visible_lines = 5
	v.timing.retrace_start = 6
	v.timing.retrace_end = 8
	v.pending_start = 1
	v.start_pending = true
	vga_sync_to(&v, 650)
	testing.expect_value(t, v.latched_start, u16(1))
	v.pending_start = 2
	v.start_pending = true
	vga_sync_to(&v, 1000)
	testing.expect_value(t, v.latched_start, u16(1))
	vga_sync_to(&v, 1600)
	testing.expect_value(t, v.latched_start, u16(2))
}

@(test)
vga_test_font_map_permutation_and_attribute_select :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.seq[3] = 0x01
	a, b := font_blocks(&v)
	testing.expect_value(t, a, 0)
	testing.expect_value(t, b, 2)
	set_plane_byte(&v, 0, 0, 'A')
	set_plane_byte(&v, 1, 0, 0x07)
	set_plane_byte(&v, 0, 1, 'A')
	set_plane_byte(&v, 1, 1, 0x0F)
	set_plane_byte(&v, 2, int('A') * 32, 0x80)
	set_plane_byte(&v, 2, 2 * 8192 + int('A') * 32, 0x40)
	v.crtc[0x0A] |= 0x20
	frame := vga_display_frame(&v)
	testing.expect(t, frame.pixels[0] != frame.pixels[1])
	testing.expect(t, frame.pixels[9] != frame.pixels[10])
}
