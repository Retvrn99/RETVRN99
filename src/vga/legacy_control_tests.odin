// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Compatibility expectations are adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

@(test)
vga_test_video_subsystem_enable_gates_legacy_aperture :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	testing.expect_value(t, vga_in(&v, 0x3C3), u8(1))
	testing.expect(t, vga_mmio_contains(&v, 0xB8000, 1))
	testing.expect(t, vga_mmio_contains(&v, VBE_LFB_BASE, 1))
	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0x80)
	testing.expect(t, vga_display_frame(&v).pixels[0] != u32(0xFF000000))
	vga_out(&v, 0x3C3, 0)
	testing.expect_value(t, vga_in(&v, 0x3C3), u8(0))
	testing.expect(t, !video_output_enabled(&v))
	testing.expect_value(t, vga_display_frame(&v).pixels[0], u32(0xFF000000))
	testing.expect(t, !vga_mmio_contains(&v, 0xB8000, 1))
	testing.expect(t, vga_mmio_contains(&v, VBE_LFB_BASE, 1))
	vga_out(&v, 0x3C3, 0xFF)
	testing.expect_value(t, vga_in(&v, 0x3C3), u8(1))
	testing.expect(t, vga_mmio_contains(&v, 0xB8000, 1))
}

@(test)
vga_test_status0_switch_sense_and_retrace :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	expected := [4]u8{0, 0x10, 0x10, 0}
	for selected in 0 ..< 4 {
		v.misc = (v.misc & ~u8(0x0C)) | u8(selected << 2)
		testing.expect_value(t, vga_in(&v, 0x3C2) & 0x10, expected[selected])
	}
	v.timing = Video_Timing {
		elapsed_ns      = 450,
		frame_period_ns = 1000,
		line_period_ns  = 100,
		total_lines     = 10,
		visible_lines   = 5,
		visible_dots    = 8,
		total_dots      = 10,
		vblank_start    = 5,
		vblank_end      = 10,
		retrace_start   = 6,
		retrace_end     = 8,
	}
	v.crtc[0x11] = 0x10
	testing.expect_value(t, vga_in(&v, 0x3C2) & 0x80, u8(0))
	vga_sync_to(&v, 550)
	testing.expect_value(t, vga_in(&v, 0x3C2) & 0x80, u8(0x80))
	vga_out(&v, 0x3D4, 0x11)
	vga_out(&v, 0x3D5, 0)
	testing.expect_value(t, vga_in(&v, 0x3C2) & 0x80, u8(0))
}

@(test)
vga_test_status1_pixel_mux_samples_planar_color :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0x80)
	set_plane_byte(&v, 2, 0, 0x80)
	v.attr[0x12] = 0x0F
	v.timing.elapsed_ns = 0
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x39, u8(0x30))
}

@(test)
cga_test_mode_control_and_palette_distinctions :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	vga_out(&v, 0x3D9, 0x20)
	testing.expect(t, !v.cga.active)
	vga_out(&v, 0x3D9, 0)
	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
	testing.expect(t, vga_mmio_write(&v, 0xB8000, 1, 0x6C))
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Cga_2)
	testing.expect_value(t, frame.width, 320)
	testing.expect_value(t, frame.height, 200)
	testing.expect_value(t, frame.pixels[0], CGA_COLORS[2])
	testing.expect_value(t, frame.pixels[1], CGA_COLORS[4])
	testing.expect_value(t, frame.pixels[2], CGA_COLORS[6])
	testing.expect_value(t, frame.pixels[3], CGA_COLORS[0])

	vga_out(&v, 0x3D9, 0x20)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], CGA_COLORS[3])
	testing.expect_value(t, frame.pixels[1], CGA_COLORS[5])
	testing.expect_value(t, frame.pixels[2], CGA_COLORS[7])

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_BW | CGA_MODE_VIDEO_ENABLE)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], CGA_COLORS[3])
	testing.expect_value(t, frame.pixels[1], CGA_COLORS[4])
	testing.expect_value(t, frame.pixels[2], CGA_COLORS[7])

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_HIGH_RES | CGA_MODE_VIDEO_ENABLE)
	vga_out(&v, 0x3D9, 0x0F)
	testing.expect(t, vga_mmio_write(&v, 0xB8000, 1, 0x80))
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Cga_1)
	testing.expect_value(t, frame.width, 640)
	testing.expect_value(t, frame.pixels[0], CGA_COLORS[15])
	testing.expect_value(t, frame.pixels[1], CGA_COLORS[0])
}

@(test)
cga_test_6845_aliases_masks_and_readback :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	vga_out(&v, 0x3D8, CGA_MODE_VIDEO_ENABLE)
	indices := [6]u8{0x03, 0x04, 0x05, 0x08, 0x0C, 0x0E}
	expected := [6]u8{0x0F, 0x7F, 0x1F, 0x03, 0x3F, 0x3F}
	index_ports := [4]u16{0x3D0, 0x3D2, 0x3D4, 0x3D6}
	data_ports := [4]u16{0x3D1, 0x3D3, 0x3D5, 0x3D7}
	for i in 0 ..< len(indices) {
		alias := i & 3
		vga_out(&v, index_ports[alias], indices[i])
		vga_out(&v, data_ports[alias], 0xFF)
		testing.expect_value(t, v.crtc[indices[i]], expected[i])
	}
	vga_out(&v, 0x3D4, 0x03)
	testing.expect_value(t, vga_in(&v, 0x3D5), u8(0xFF))
	vga_out(&v, 0x3D6, 0x0E)
	testing.expect_value(t, vga_in(&v, 0x3D7), u8(0x3F))
	testing.expect_value(t, vga_in(&v, 0x3D6), u8(0xFF))
}

@(test)
cga_test_status_and_light_pen_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
	v.timing.elapsed_ns = 0
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x07, u8(0x04))
	_ = vga_in(&v, 0x3DC)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x06, u8(0x06))
	light_pen_latch := v.cga.light_pen_latch
	vga_out(&v, 0x3D4, 0x10)
	testing.expect_value(t, vga_in(&v, 0x3D5), u8(light_pen_latch >> 8))
	vga_out(&v, 0x3D4, 0x11)
	testing.expect_value(t, vga_in(&v, 0x3D5), u8(light_pen_latch))
	_ = vga_in(&v, 0x3DB)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x06, u8(0x04))

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS)
	testing.expect_value(t, vga_in(&v, 0x3DA) & 0x05, u8(0x05))
	testing.expect_value(t, vga_display_frame(&v).pixels[0], u32(0xFF000000))
}
