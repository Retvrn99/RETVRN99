// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// A two-cell text mode with an eight-line cell, driven through the public ports
// where the register is reachable that way. Returns the frame width.
@(private = "file")
mono_text_setup :: proc(v: ^Vga) -> int {
	v.seq[1] = 1 // eight dots per character
	v.crtc[1] = 1 // two columns
	v.crtc[9] = 7 // eight scan lines per character
	v.crtc[0x13] = 1
	v.gfx[6] = 0x0E
	v.attr[0x10] = 0
	v.timing.visible_dots = 16
	v.timing.visible_lines = 8
	v.crtc[0x0A] = 0x20 // cursor off, it would invert the cells under test
	return 16
}

// Writes one cell and gives its glyph a solid top row and a blank second row, so
// a foreground pixel and a background pixel can be sampled from known places.
@(private = "file")
mono_text_cell :: proc(v: ^Vga, cell: int, character, attribute: u8) {
	set_plane_byte(v, 0, cell, character)
	set_plane_byte(v, 1, cell, attribute)
	set_plane_byte(v, 2, int(character) * 32, 0xFF)
	for line in 1 ..< 8 {set_plane_byte(v, 2, int(character) * 32 + line, 0x00)}
	vga_note_content_change(v)
}

// `attribute_color` is file private to `scanout.odin`, so each colour under test
// is proven by rendering an image pixel that carries the same palette index
// rather than by naming a value. Sampled with monochrome emulation off, where
// the foreground index is the attribute's low nibble.
@(private = "file")
mono_reference_colors :: proc(v: ^Vga) -> (blank, normal, intense: u32) {
	mono_text_cell(v, 0, 'A', 0x00)
	blank = vga_display_frame(v).pixels[0]
	mono_text_cell(v, 0, 'A', 0x07)
	normal = vga_display_frame(v).pixels[0]
	mono_text_cell(v, 0, 'A', 0x0F)
	intense = vga_display_frame(v).pixels[0]
	return
}

// Programs a CRT Controller register through the public index and data ports.
// CRT Controller 14h sits above the 11h write protection, so no unlock is needed.
@(private = "file")
mono_crtc_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
	vga_note_content_change(v)
}

// Leaves the rest of Mode Control alone, so a test may set blink enable or line
// graphics first and still reach bit 1 the way software does.
@(private = "file")
mono_select :: proc(v: ^Vga, enabled: bool) {
	value := v.attr[0x10] & ~u8(0x02) | (enabled ? u8(0x02) : 0)
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, 0x30) // 10h with the Palette Address Source held set
	vga_out(v, 0x3C0, value)
	vga_out(v, 0x3C0, 0x20)
	vga_note_content_change(v)
}

// IBM 2-92. Attribute Controller 10h bit 1 replaces the colour reading of the
// attribute byte with the monochrome one, where the four-bit index is only ever
// blank, normal, or intense. Proving it through an image pixel rather than
// through a colour value avoids depending on DAC scaling.
@(test)
vga_test_monochrome_emulation_replaces_the_attribute_colors :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	width := mono_text_setup(&v)
	blank, normal, intense := mono_reference_colors(&v)

	// Attribute 46h is brown on red in colour, and normal on blank in mono
	// because neither of its halves matches the reverse-video combination and
	// bit 3, the intensity, is clear.
	mono_text_cell(&v, 0, 'A', 0x46)
	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	color_foreground := frame.pixels[0]
	color_background := frame.pixels[width]
	testing.expect(t, color_foreground != normal)

	mono_select(&v, true)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], normal)
	testing.expect_value(t, frame.pixels[width], blank)

	// Bit 3 is the intensity, and it is the only bit below the reverse-video
	// combination that changes the foreground.
	mono_text_cell(&v, 0, 'A', 0x0F)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], intense)
	testing.expect(t, intense != normal)

	// Clearing the bit puts the colour reading back, which keeps every existing
	// text mode on the path it was already on.
	mono_text_cell(&v, 0, 'A', 0x46)
	mono_select(&v, false)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], color_foreground)
	testing.expect_value(t, frame.pixels[width], color_background)
}

// The three cell forms a monochrome attribute can take. Everything blank in both
// halves is invisible, 70h is blank on bright, and everything else is foreground
// on blank.
@(test)
vga_test_monochrome_attribute_forms :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	width := mono_text_setup(&v)
	blank, normal, intense := mono_reference_colors(&v)
	mono_select(&v, true)

	Case :: struct {
		attribute:  u8,
		foreground: u32,
		background: u32,
	}
	// Bit 7 is the blink bit and never selects a form, which is why 80h and 88h
	// are invisible alongside 00h and 08h.
	cases := [?]Case {
		{0x00, blank, blank},
		{0x08, blank, blank},
		{0x80, blank, blank},
		{0x88, blank, blank},
		{0x01, normal, blank},
		{0x07, normal, blank},
		{0x09, intense, blank},
		{0x0F, intense, blank},
		{0x70, blank, intense},
		{0xF0, blank, intense},
		{0x78, normal, intense},
		{0xF8, normal, intense},
		{0x77, normal, blank},
	}
	for item in cases {
		mono_text_cell(&v, 0, 'A', item.attribute)
		frame := vga_display_frame(&v)
		if !testing.expect(t, frame != nil) {return}
		testing.expectf(
			t,
			frame.pixels[0] == item.foreground,
			"attribute %2Xh foreground",
			item.attribute,
		)
		testing.expectf(
			t,
			frame.pixels[width] == item.background,
			"attribute %2Xh background",
			item.attribute,
		)
	}
}

// IBM 2-72. CRT Controller 14h names the scan line the underline lands on, and
// the underline exists only for the attribute whose low three bits are 1. It
// spans the whole cell, not just the glyph.
@(test)
vga_test_underline_lands_on_the_row_crtc_14h_names :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	width := mono_text_setup(&v)
	blank, normal, _ := mono_reference_colors(&v)
	mono_select(&v, true)
	mono_text_cell(&v, 0, 'A', 0x01)

	// Row 1 is blank in the glyph, so any foreground there is the underline.
	mono_crtc_out(&v, 0x14, 1)
	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	for x in 0 ..< 8 {testing.expect_value(t, frame.pixels[width + x], normal)}
	testing.expect_value(t, frame.pixels[2 * width], blank)

	// Moving the register moves the line and nothing else.
	mono_crtc_out(&v, 0x14, 5)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[width], blank)
	testing.expect_value(t, frame.pixels[5 * width], normal)

	// Only bits 0 to 4 are the location. The count-by-4 and doubleword bits above
	// them must not move it, which is where this diverges from the reference
	// implementation named in 86BOX_NOTICE.md.
	mono_crtc_out(&v, 0x14, 0x65)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[5 * width], normal)
}

// The underline belongs to one attribute and to monochrome emulation. A colour
// text mode has no underline at all, and neither does any other attribute.
@(test)
vga_test_underline_is_absent_outside_its_attribute_and_mode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	width := mono_text_setup(&v)
	blank, _, _ := mono_reference_colors(&v)
	mono_crtc_out(&v, 0x14, 1)
	mono_select(&v, true)

	// Low three bits of 7 rather than 1: normal text, no underline.
	mono_text_cell(&v, 0, 'A', 0x07)
	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[width], blank)

	// The underline attribute with monochrome emulation off is just colour 1, so
	// its glyph row differs from blank and its blank row does not.
	mono_text_cell(&v, 0, 'A', 0x01)
	mono_select(&v, false)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[width], blank)
	testing.expect(t, frame.pixels[0] != blank)
}

// Bit 7 blinks the foreground into the background, which takes the underline with
// it because the underline is drawn in the foreground the blink already resolved.
@(test)
vga_test_monochrome_blink_carries_the_underline :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	width := mono_text_setup(&v)
	blank, normal, _ := mono_reference_colors(&v)
	mono_crtc_out(&v, 0x14, 1)
	v.attr[0x10] = 0x08 // blink enable
	mono_select(&v, true)
	testing.expect_value(t, v.attr[0x10], u8(0x0A))
	mono_text_cell(&v, 0, 'A', 0x81)

	v.timing.elapsed_ns = 0
	vga_note_content_change(&v)
	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], normal)
	testing.expect_value(t, frame.pixels[width], normal)

	v.timing.elapsed_ns = 500_000_000
	vga_note_content_change(&v)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], blank)
	testing.expect_value(t, frame.pixels[width], blank)
}
