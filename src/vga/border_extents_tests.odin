// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Programs a CRT Controller register through the public index and data ports.
// Every mode used here selects the colour address with Miscellaneous Output
// bit 0, so the pair is 3D4h and 3D5h.
@(private = "file")
crtc_select :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
	vga_note_content_change(v)
}

// IBM 2-57 to 2-73. The border occupies the scan lines and dot clocks the raster
// spends outside both the active display and blanking. Mode 12h programs a few of
// each, which is what every stock mode produces: a thin border rather than none.
@(test)
vga_test_border_extents_come_from_display_end_and_blank_start :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)

	testing.expect_value(t, v.timing.visible_lines, 480)
	testing.expect_value(t, v.timing.vblank_start, 488)
	testing.expect_value(t, v.timing.vblank_end, 516)
	testing.expect_value(t, v.timing.total_lines, 525)
	testing.expect_value(t, v.timing.visible_dots, 640)
	testing.expect_value(t, v.timing.hblank_start, 640)
	testing.expect_value(t, v.timing.hblank_end, 784)
	testing.expect_value(t, v.timing.total_dots, 800)

	left, right, top, bottom := border_extents(&v)
	testing.expect_value(t, left, 16) // 800 - 784 dot clocks
	testing.expect_value(t, right, 0) // blank starts where the display ends
	testing.expect_value(t, top, 9) // 525 - 516 scan lines
	testing.expect_value(t, bottom, 8) // 488 - 480 scan lines

	// Moving blank start away from display end widens the trailing border by
	// exactly the lines it skipped and leaves the leading one alone.
	crtc_select(&v, 0x15, 0xF7)
	left, right, top, bottom = border_extents(&v)
	testing.expect_value(t, left, 16)
	testing.expect_value(t, right, 0)
	testing.expect_value(t, top, 9)
	testing.expect_value(t, bottom, 24)
}

// A border is measured in dot clocks, and a 256-colour pixel occupies two of
// them, so the published extent is half the programmed dot count. This is the
// same ratio `display_geometry` applies to the image width.
@(test)
vga_test_border_extents_are_published_in_image_pixels :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	kind, width, height := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Indexed_8)
	testing.expect_value(t, width, 320)
	testing.expect_value(t, height, 200)

	// Seven blanked lines out of a 400-line raster become three image rows.
	_, right, _, bottom := border_extents(&v)
	testing.expect_value(t, right, 0)
	testing.expect_value(t, bottom, 3)

	// Horizontal blank start is write protected by CRT Controller 11h bit 7, so
	// software must lift the protection exactly as this does.
	crtc_select(&v, 0x11, v.crtc[0x11] & 0x7F)
	crtc_select(&v, 0x02, 0x5A)
	testing.expect_value(t, v.timing.hblank_start, 720)
	_, right, _, bottom = border_extents(&v)
	// Eighty dot clocks are forty 256-colour pixels.
	testing.expect_value(t, right, 40)
	testing.expect_value(t, bottom, 3)
}

// The border cannot be larger than the image it surrounds. A raster programmed
// with blank start far past display end is misprogrammed rather than expressive,
// and the host scales a canvas into whatever proportion is published.
@(test)
vga_test_border_extents_are_clamped_to_the_image :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	// Sixteen displayed lines against a blank start still two hundred lines away.
	crtc_select(&v, 0x11, v.crtc[0x11] & 0x7F)
	crtc_select(&v, 0x07, 0x20)
	crtc_select(&v, 0x12, 0x0F)
	testing.expect_value(t, v.timing.visible_lines, 16)
	testing.expect_value(t, v.timing.vblank_start, 232)

	_, _, height := display_geometry(&v)
	testing.expect_value(t, height, 16)
	_, right, top, bottom := border_extents(&v)
	testing.expect_value(t, right, 0)
	testing.expect_value(t, top, 16)
	testing.expect_value(t, bottom, 16)
}

// VBE drives the panel directly and has no border, which the fallback blanking
// in `vga_recalculate_timing` already expresses by putting blank start at
// display end.
@(test)
vga_test_border_extents_are_absent_under_vbe :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 800, 600, 32))
	left, right, top, bottom := border_extents(&v)
	testing.expect_value(t, left, 0)
	testing.expect_value(t, right, 0)
	testing.expect_value(t, top, 0)
	testing.expect_value(t, bottom, 0)
}

// The published legacy frame header carries the extents beside the border
// colour, so presentation paints the surround without reading device state and
// without the pixel buffer ever growing.
@(test)
vga_test_legacy_frame_header_publishes_border_extents :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	crtc_select(&v, 0x15, 0xF7)

	update := vga_legacy_frame_update(&v)
	testing.expect_value(t, update.header.border.left, u32(16))
	testing.expect_value(t, update.header.border.right, u32(0))
	testing.expect_value(t, update.header.border.top, u32(9))
	testing.expect_value(t, update.header.border.bottom, u32(24))
	// The canvas is the active image alone. Border pixels are never carried.
	testing.expect_value(t, update.header.canvas_extent.width, u32(640))
	testing.expect_value(t, update.header.canvas_extent.height, u32(480))
}
