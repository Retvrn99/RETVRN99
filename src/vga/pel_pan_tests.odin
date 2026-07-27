// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Bit 5 of the Attribute address keeps the Palette Address Source set so the
// display stays on, which is how software pans without blanking.
@(private = "file")
pel_pan_select :: proc(v: ^Vga, value: u8) {
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, 0x13 | 0x20)
	vga_out(v, 0x3C0, value)
}

// IBM 2-95. In 256-colour modes a pixel is two dot clocks wide and panning is
// counted in dot clocks, so 0h, 2h, 4h, and 6h shift by 0, 1, 2, and 3 pixels.
// Reading the register as a pixel count instead moves the image twice as far
// for the even values it should honour and not at all for half of them.
@(test)
vga_test_indexed_pel_pan_shifts_by_half_the_programmed_value :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	// Chained mode 13h reads pixel x of row 0 straight from vram[x], so the
	// first four pixels carry four different palette indices.
	for i in 0 ..< 8 {v.vram[i] = u8(i + 1)}
	vga_note_content_change(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	reference: [4]u32
	for i in 0 ..< 4 {reference[i] = frame.pixels[i]}
	// Distinct indices must give distinct colours or the shift proof is vacuous.
	for i in 1 ..< 4 {
		for j in 0 ..< i {testing.expect(t, reference[i] != reference[j])}
	}

	for pixels in 1 ..= 3 {
		pel_pan_select(&v, u8(pixels) * 2)
		frame = vga_display_frame(&v)
		if !testing.expect(t, frame != nil) {return}
		// Panning by this many pixels brings the pixel that far right to x=0.
		testing.expect_value(t, frame.pixels[0], reference[pixels])
	}

	// An odd value selects no additional dot clock of its own, so it lands on
	// the same pixel as the even value below it.
	pel_pan_select(&v, 5)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], reference[2])
}

// The planar path counts the register in dots directly, and a 16-colour pixel
// is one dot, so that path must keep reading the full four-bit value.
@(test)
vga_test_planar_pel_pan_shifts_by_the_whole_programmed_value :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	// One lit pixel at x=5 of row 0, from plane 0.
	set_plane_byte(&v, 0, 0, 0x04)
	vga_note_content_change(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	lit := frame.pixels[5]
	unlit := frame.pixels[0]
	testing.expect(t, lit != unlit)

	for pan in 1 ..= 5 {
		pel_pan_select(&v, u8(pan))
		frame = vga_display_frame(&v)
		if !testing.expect(t, frame != nil) {return}
		testing.expect_value(t, frame.pixels[5 - pan], lit)
	}
}

// The text path counts dots too, but a nine-dot character cannot shift by nine,
// so a value of 8 with nine-dot cells is defined to mean no shift at all.
@(test)
vga_test_text_pel_pan_shifts_by_dots_and_ignores_eight_on_nine_dot_cells :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	// Power-on 80x25 text is the nine-dot case: Sequencer 01h bit 0 is clear.
	testing.expect_value(t, v.seq[1] & 1, u8(0))
	set_plane_byte(&v, 0, 0, 'A')
	set_plane_byte(&v, 1, 0, 0x0F)
	// One lit dot at glyph column 4 of the first cell, so panning has room.
	set_plane_byte(&v, 2, int('A') * 32, 0x08)
	// Park the cursor so it cannot invert the cell under test.
	v.crtc[0x0A] |= 0x20
	vga_note_content_change(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	width := frame.width
	lit := frame.pixels[4]
	unlit := frame.pixels[0]
	testing.expect(t, lit != unlit)

	for pan in 1 ..= 4 {
		pel_pan_select(&v, u8(pan))
		frame = vga_display_frame(&v)
		if !testing.expect(t, frame != nil) {return}
		testing.expect_value(t, frame.width, width)
		testing.expect_value(t, frame.pixels[4 - pan], lit)
	}

	// Eight on a nine-dot cell is the documented exception and shifts nothing.
	pel_pan_select(&v, 8)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[4], lit)
}
