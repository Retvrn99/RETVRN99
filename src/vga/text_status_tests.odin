// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(private = "file")
crtc_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
	vga_note_content_change(v)
}

@(private = "file")
attr_out :: proc(v: ^Vga, index, value: u8) {
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, index | 0x20)
	vga_out(v, 0x3C0, value)
	vga_note_content_change(v)
}

// Two nine-dot columns by two two-line rows, all of it programmed through the
// ports so the timing recalculation each write performs lands where the test
// expects it.
@(private = "file")
tiny_text_geometry :: proc(v: ^Vga) {
	vga_out(v, 0x3C2, 0xE3)
	vga_out(v, 0x3C4, 0x00)
	vga_out(v, 0x3C5, 0x03)
	vga_out(v, 0x3C4, 0x01)
	vga_out(v, 0x3C5, 0x00)
	vga_out(v, 0x3C4, 0x04)
	vga_out(v, 0x3C5, 0x06)
	vga_out(v, 0x3CE, 0x06)
	vga_out(v, 0x3CF, 0x0E)
	attr_out(v, 0x10, 0x04)
	attr_out(v, 0x12, 0x0F)
	crtc_out(v, 0x11, 0x0C)
	crtc_out(v, 0x00, 0x03)
	crtc_out(v, 0x01, 0x01)
	crtc_out(v, 0x02, 0x02)
	crtc_out(v, 0x03, 0x87)
	crtc_out(v, 0x05, 0x00)
	crtc_out(v, 0x06, 0x10)
	crtc_out(v, 0x07, 0x10)
	crtc_out(v, 0x09, 0x01)
	crtc_out(v, 0x0A, 0x20)
	crtc_out(v, 0x12, 0x03)
	crtc_out(v, 0x13, 0x01)
	crtc_out(v, 0x17, 0xA3)
	crtc_out(v, 0x18, 0xFF)
}

// Cell 0 holds a line-drawing character whose glyph lights the first and last
// dot of the byte, so the ninth dot is distinguishable from both neighbours.
@(private = "file")
seed_line_graphics_cell :: proc(v: ^Vga, character, attribute: u8) {
	set_plane_byte(v, 0, 0, character)
	set_plane_byte(v, 1, 0, attribute)
	set_plane_byte(v, 0, 1, 0x20)
	set_plane_byte(v, 1, 1, attribute)
	set_plane_byte(v, 2, int(character) * 32, 0x81)
	set_plane_byte(v, 2, int(character) * 32 + 1, 0x00)
	vga_note_content_change(v)
}

@(private = "file")
seek_beam :: proc(v: ^Vga, line, dot: int) {
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	total := u64(max(v.timing.total_dots, 1))
	offset := u64(line) * line_ns + (u64(dot) * 2 + 1) * line_ns / (total * 2)
	at := v.timing.elapsed_ns / period * period + offset
	for at <= v.timing.elapsed_ns {at += period}
	vga_sync_to(v, at)
}

// IBM 2-93. Attribute 10h bit 3 duplicates the eighth dot of the glyph into the
// ninth for C0h through DFh, which is what keeps the line-drawing characters
// joined across cells. Every other character leaves the ninth dot blank.
@(test)
vga_test_line_graphics_duplicates_the_eighth_dot :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_text_geometry(&v)
	seed_line_graphics_cell(&v, 0xC1, 0x0F)

	kind, width, height := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Text)
	testing.expect_value(t, width, 18)
	testing.expect_value(t, height, 4)

	frame := vga_display_frame(&v)
	foreground := frame.pixels[0]
	background := frame.pixels[1]
	testing.expect(t, foreground != background)
	testing.expect_value(t, frame.pixels[7], foreground)
	testing.expect_value(t, frame.pixels[8], foreground)

	// Clearing the enable leaves the ninth dot in the background.
	attr_out(&v, 0x10, 0x00)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[7], foreground)
	testing.expect_value(t, frame.pixels[8], background)

	// A character outside the range never duplicates, enabled or not.
	attr_out(&v, 0x10, 0x04)
	seed_line_graphics_cell(&v, 0xBF, 0x0F)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[7], foreground)
	testing.expect_value(t, frame.pixels[8], background)
}

// IBM 2-94. Input Status 1 bits 4 and 5 carry two of the eight Attribute
// Controller output lines, chosen by Attribute 12h bits 4 and 5. Text modes feed
// that multiplexer the same resolved index the expansion draws with.
@(test)
vga_test_status_multiplexer_reports_text_pixels :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_text_geometry(&v)
	seed_line_graphics_cell(&v, 0xC1, 0x0F)

	// Colour select supplies the top two index bits, so the highest multiplexer
	// selection reads something other than zero.
	attr_out(&v, 0x14, 0x0C)
	lit := attribute_palette_index(&v, 0x0F)
	unlit := attribute_palette_index(&v, 0x00)
	testing.expect(t, lit != unlit)

	selections := [4][2]u8 {
		{(lit >> 2 & 1) << 1 | lit & 1, (unlit >> 2 & 1) << 1 | unlit & 1},
		{lit >> 4 & 3, unlit >> 4 & 3},
		{(lit >> 3 & 1) << 1 | lit >> 1 & 1, (unlit >> 3 & 1) << 1 | unlit >> 1 & 1},
		{lit >> 6 & 3, unlit >> 6 & 3},
	}
	for expected, selection in selections {
		attr_out(&v, 0x12, 0x0F | u8(selection) << 4)
		seek_beam(&v, 0, 0)
		testing.expect_value(t, vga_in(&v, 0x3DA) >> 4 & 3, expected[0])
		seek_beam(&v, 0, 1)
		testing.expect_value(t, vga_in(&v, 0x3DA) >> 4 & 3, expected[1])
	}

	// The multiplexer reads nothing while the beam is inside blanking.
	attr_out(&v, 0x12, 0x0F)
	seek_beam(&v, 0, 20)
	status := vga_in(&v, 0x3DA)
	testing.expect_value(t, status & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status >> 4 & 3, u8(0))
}

// IBM 2-45 and 2-46. The status port follows Miscellaneous Output bit 0, and
// reading it is what resets the Attribute Controller's address/data flip-flop.
@(test)
vga_test_status_port_address_select_and_flip_flop_reset :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_text_geometry(&v)

	// Colour addressing: 3DAh answers and 3BAh is not decoded.
	testing.expect_value(t, vga_in(&v, 0x3BA), u8(0xFF))
	testing.expect(t, vga_in(&v, 0x3DA) != 0xFF)

	// A half-finished attribute write leaves the flip-flop expecting data.
	vga_out(&v, 0x3C0, 0x31)
	testing.expect_value(t, v.attr_ix, u8(0x11))
	testing.expect(t, v.attr_flip)
	_ = vga_in(&v, 0x3DA)
	testing.expect(t, !v.attr_flip)
	// So the next write is taken as an index rather than as data for 11h.
	vga_out(&v, 0x3C0, 0x33)
	testing.expect_value(t, v.attr_ix, u8(0x13))
	testing.expect_value(t, vga_in(&v, 0x3C0) & 0x1F, u8(0x13))

	// Monochrome addressing moves both the status port and the CRT Controller.
	vga_out(&v, 0x3C2, 0xE2)
	testing.expect_value(t, vga_in(&v, 0x3DA), u8(0xFF))
	testing.expect(t, vga_in(&v, 0x3BA) != 0xFF)
	vga_out(&v, 0x3B4, 0x0F)
	testing.expect_value(t, vga_in(&v, 0x3B4), u8(0x0F))
	testing.expect_value(t, vga_in(&v, 0x3D4), u8(0xFF))
}
