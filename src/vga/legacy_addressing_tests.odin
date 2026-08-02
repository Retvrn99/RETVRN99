// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

vga_test_pixels_crc32 :: proc(pixels: []u32) -> u32 {
	crc := u32(0xffff_ffff)
	for pixel in pixels {
		for shift in 0 ..< 4 {
			crc ~= u32(u8(pixel >> uint(shift * 8)))
			for _ in 0 ..< 8 {
				mask := u32(0) - (crc & 1)
				crc = crc >> 1 ~ (0xedb8_8320 & mask)
			}
		}
	}
	return crc ~ 0xffff_ffff
}

@(test)
vga_test_generalized_display_address_transforms :: proc(t: ^testing.T) {
	v: Vga
	v.crtc[0x17] = 0x43
	testing.expect_value(t, legacy_display_counter(&v, 0x100, 7), u32(0x107))
	testing.expect_value(t, legacy_display_offset(&v, 0x1234, 0), 0x1234)

	v.crtc[0x17] = 0x0b
	testing.expect_value(t, legacy_display_counter(&v, 0x100, 7), u32(0x103))
	v.crtc[0x14] = 0x20
	testing.expect_value(t, legacy_display_counter(&v, 0x100, 7), u32(0x101))

	v.crtc[0x14] = 0x40
	v.crtc[0x17] = 0x03
	testing.expect_value(t, legacy_display_offset(&v, 0x1234, 0), 0x48d0)
	v.crtc[0x14] = 0
	v.crtc[0x17] = 0x23
	testing.expect_value(t, legacy_display_offset(&v, 0x8123, 0), 0x0247)
	v.crtc[0x17] = 0x03
	testing.expect_value(t, legacy_display_offset(&v, 0x2123, 0), 0x4247)
	v.crtc[0x17] = 0x40
	testing.expect_value(t, legacy_display_offset(&v, 0, 3), 0x6000)
}

@(test)
vga_test_preset_byte_pan_and_split_geometry :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	v.latched_start = 5
	v.crtc[0x08] = 0x43
	geometry := legacy_graphics_row(&v, .Planar_4, 0)
	testing.expect_value(t, geometry.row_scan, 3)
	testing.expect_value(t, geometry.row_base, u32(247))
	testing.expect(t, !geometry.below_split)

	v.crtc[0x18] = 0
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	v.attr[0x13] = 0x0f
	geometry = legacy_graphics_row(&v, .Planar_4, 1)
	testing.expect(t, geometry.below_split)
	testing.expect_value(t, geometry.row_scan, 0)
	testing.expect_value(t, geometry.row_base, u32(2))
	testing.expect_value(t, legacy_pel_pan(&v, true), 15)
	v.attr[0x10] |= 0x20
	geometry = legacy_graphics_row(&v, .Planar_4, 1)
	testing.expect_value(t, geometry.row_base, u32(0))
	testing.expect_value(t, legacy_pel_pan(&v, true), 0)
}

@(test)
vga_test_ega_split_delay_is_in_counter_lines :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x0d)
	v.crtc[0x18] = 0
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	testing.expect_value(t, legacy_split_first_line(&v, .Planar_4), 3)
	test_bochs_legacy_mode(&v, 0x12)
	v.crtc[0x18] = 0
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	testing.expect_value(t, legacy_split_first_line(&v, .Planar_4), 1)
	testing.expect_value(t, legacy_split_first_line(&v, .Indexed_8), 1)
}

@(test)
vga_test_ega_split_delay_scanout_boundary :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x0d)
	v.latched_start = 10
	v.crtc[0x18] = 0
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	set_plane_byte(&v, 0, 50, 0xff)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.width, 320)
	testing.expect(t, frame.pixels[320] != frame.pixels[640])
	testing.expect_value(t, frame.pixels[640], frame.pixels[0])
}

@(test)
vga_test_attribute_plane_enable_and_color_select :: proc(t: ^testing.T) {
	v: Vga
	v.attr[0x12] = 0x0f
	v.attr[5] = 0x35
	v.attr[0x14] = 0x0d
	v.pel_mask = 0xff
	v.attr[0x10] = 0
	testing.expect_value(t, attribute_palette_index(&v, 5), u8(0xf5))
	v.attr[0x10] = 0x80
	testing.expect_value(t, attribute_palette_index(&v, 5), u8(0xd5))
	v.attr[0x12] = 0x0a
	v.attr[0] = 0x22
	testing.expect_value(t, attribute_palette_index(&v, 5), u8(0xd2))
}

@(test)
vga_test_character_map_a_and_b_fields :: proc(t: ^testing.T) {
	v: Vga
	v.seq[3] = 0x01
	a, b := font_blocks(&v)
	testing.expect_value(t, a, 2)
	testing.expect_value(t, b, 0)
	v.seq[3] = 0x04
	a, b = font_blocks(&v)
	testing.expect_value(t, a, 0)
	testing.expect_value(t, b, 2)
	v.seq[3] = 0x10
	a, b = font_blocks(&v)
	testing.expect_value(t, a, 1)
	testing.expect_value(t, b, 0)
	v.seq[3] = 0x20
	a, b = font_blocks(&v)
	testing.expect_value(t, a, 0)
	testing.expect_value(t, b, 1)
}

vga_test_seed_color_pattern :: proc(v: ^Vga) {
	for offset in 0 ..< 64 {
		for plane in 0 ..< 4 {
			set_plane_byte(v, plane, offset, u8((offset * 17 + plane * 53) & 0xff))
		}
	}
}

@(test)
vga_test_planar_generalized_scanout_crc :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 16, 4)
	v.gfx[5] = 0
	v.crtc[0x17] = 0x43
	v.crtc[0x14] = 0
	v.crtc[0x13] = 2
	v.crtc[0x08] = 0x42
	v.crtc[0x18] = 1
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	v.attr[0x10] |= 0x20
	v.attr[0x13] = 9
	v.latched_start = 4
	vga_test_seed_color_pattern(&v)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Planar_4)
	testing.expect_value(t, vga_test_pixels_crc32(frame.pixels), u32(0x7960_9c05))
}

@(test)
vga_test_mode_x_generalized_scanout_crc :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 16, 4)
	v.gfx[5] = 0x40
	v.seq[4] = 0x06
	v.crtc[0x17] = 0x43
	v.crtc[0x14] = 0
	v.crtc[0x13] = 2
	v.crtc[0x08] = 0x21
	v.crtc[0x18] = 1
	v.crtc[0x07] &= ~u8(0x10)
	v.crtc[0x09] &= ~u8(0x40)
	v.attr[0x10] |= 0x20
	v.attr[0x13] = 5
	v.latched_start = 3
	vga_test_seed_color_pattern(&v)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	// This pin moved once, deliberately. It was recorded while 256-colour PEL
	// panning read the register as a pixel count, which made half the values the
	// hardware defines behave as no shift at all. The register counts dot clocks
	// and a 256-colour pixel is two of them, so the 5 above now moves two pixels
	// rather than one. See vga_test_indexed_pel_pan_shifts_by_half_the_programmed_value.
	testing.expect_value(t, vga_test_pixels_crc32(frame.pixels), u32(0xcc2a_0582))
}

@(test)
vga_test_text_preset_pan_font_and_cursor_crc :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.gfx[6] = 0x0e
	v.attr[0x10] = 0
	v.seq[1] = 1
	v.crtc[0x01] = 1
	v.crtc[0x09] = 1
	v.crtc[0x13] = 1
	v.crtc[0x08] = 0x41
	v.attr[0x13] = 1
	v.timing.visible_dots = 16
	v.timing.visible_lines = 4
	v.latched_start = 1
	for cell in 0 ..< 8 {
		character := u8('A' + cell)
		set_plane_byte(&v, 0, cell * 2, character)
		set_plane_byte(&v, 1, cell * 2, u8(0x10 | (cell + 1) & 0x0f))
		set_plane_byte(&v, 2, int(character) * 32, u8(0x81 >> uint(cell & 1)))
		set_plane_byte(&v, 2, int(character) * 32 + 1, u8(0x42 << uint(cell & 1)))
	}
	v.crtc[0x0e] = 0
	v.crtc[0x0f] = 1
	v.crtc[0x0a] = 1
	v.crtc[0x0b] = 0x20
	v.timing.elapsed_ns = 0
	visible_crc := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	testing.expect_value(t, visible_crc, u32(0x29b0_3ada))
	v.timing.elapsed_ns = 500_000_000
	vga_note_animation_change(&v)
	hidden_crc := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	testing.expect_value(t, hidden_crc, u32(0xd43d_5b18))
	testing.expect(t, visible_crc != hidden_crc)
	v.timing.elapsed_ns = 0
	v.crtc[0x0a] |= 0x20
	vga_note_content_change(&v)
	disabled_crc := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	testing.expect_value(t, disabled_crc, hidden_crc)
}

@(test)
vga_test_text_snapshot_uses_crtc_offset :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.crtc[0x13] = 45
	set_plane_byte(&v, 0, 90, 'X')
	set_plane_byte(&v, 1, 90, 0x1e)
	v.crtc[0x0e] = 0
	v.crtc[0x0f] = 90
	snapshot := vga_text_snapshot(&v)
	testing.expect_value(t, snapshot.columns, 80)
	testing.expect_value(t, snapshot.rows, 25)
	testing.expect_value(t, snapshot.cells[80], u16(0x1e58))
	testing.expect_value(t, snapshot.cursor_row, 1)
	testing.expect_value(t, snapshot.cursor_col, 0)
}
