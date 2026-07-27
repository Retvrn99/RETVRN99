// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Attribute 00h-0Fh can only be reached with the Palette Address Source clear,
// which blanks the display, so the sequence restores it before anything is read.
@(private = "file")
internal_palette_write :: proc(v: ^Vga, index, value: u8) {
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, index & 0x1F)
	vga_out(v, 0x3C0, value)
	vga_out(v, 0x3C0, 0x20)
}

// Registers 10h and above are writable with the source still set, so the index
// carries bit 5 and the display never blanks.
@(private = "file")
attribute_mode_write :: proc(v: ^Vga, index, value: u8) {
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, index | 0x20)
	vga_out(v, 0x3C0, value)
}

@(private = "file")
dac_write :: proc(v: ^Vga, index, r, g, b: u8) {
	vga_out(v, 0x3C8, index)
	vga_out(v, 0x3C9, r)
	vga_out(v, 0x3C9, g)
	vga_out(v, 0x3C9, b)
}

// Two pixels differing only in palette bits 4 and 5: colour index 1 at x=0 and
// colour index 2 at x=1.
@(private = "file")
palette_select_surface :: proc(v: ^Vga) {
	test_bochs_legacy_mode(v, 0x12)
	set_plane_byte(v, 0, 0, 0x80)
	set_plane_byte(v, 1, 0, 0x40)
	vga_note_content_change(v)
}

// IBM 2-96. With Attribute 10h bit 7 clear, colour select supplies DAC index
// bits 6 and 7 from its own bits 2 and 3, and the palette register supplies the
// low six. Only DAC entry C1h can restore the original colour, which is what
// pins the index rather than merely showing that something moved.
@(test)
vga_test_color_select_supplies_the_high_dac_index_bits :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	palette_select_surface(&v)
	internal_palette_write(&v, 0x01, 0x01)
	attribute_mode_write(&v, 0x10, v.attr[0x10] & ~u8(0x80))
	attribute_mode_write(&v, 0x14, 0x00)
	dac_write(&v, 0x01, 0x3F, 0x15, 0x2A)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	through_low := frame.pixels[0]

	// Colour select bits 2 and 3 move the pixel to DAC index C1h.
	attribute_mode_write(&v, 0x14, 0x0C)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, frame.pixels[0] != through_low)

	// Giving C1h the same components restores it, and no other entry could.
	dac_write(&v, 0xC1, 0x3F, 0x15, 0x2A)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], through_low)
}

// IBM 2-92 and 2-96. Setting Attribute 10h bit 7 discards palette bits 4 and 5
// and takes DAC index bits 4 to 7 from colour select instead, so two pixels that
// differ only in those two bits collapse onto the same colour.
@(test)
vga_test_palette_bits_45_are_replaced_when_mode_control_bit_7_is_set :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	palette_select_surface(&v)
	// The two entries differ only in bit 4.
	internal_palette_write(&v, 0x01, 0x11)
	internal_palette_write(&v, 0x02, 0x01)
	attribute_mode_write(&v, 0x14, 0x00)
	attribute_mode_write(&v, 0x10, v.attr[0x10] & ~u8(0x80))
	dac_write(&v, 0x11, 0x3F, 0x00, 0x00)
	dac_write(&v, 0x01, 0x00, 0x00, 0x3F)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, frame.pixels[0] != frame.pixels[1])

	attribute_mode_write(&v, 0x10, v.attr[0x10] | 0x80)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], frame.pixels[1])
}

// IBM 2-94. Colour plane enable masks planes out of the index before the
// palette is consulted, so clearing a plane's bit makes a pixel that only that
// plane lit resolve as colour zero.
@(test)
vga_test_color_plane_enable_masks_the_index_before_the_palette :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	palette_select_surface(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	background := frame.pixels[2]
	testing.expect(t, frame.pixels[0] != background)
	testing.expect(t, frame.pixels[1] != background)

	// Drop plane 1 and the index-2 pixel falls to colour zero while index 1 stays.
	attribute_mode_write(&v, 0x12, 0x0D)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[1], background)
	testing.expect(t, frame.pixels[0] != background)

	// Drop plane 0 as well and both fall.
	attribute_mode_write(&v, 0x12, 0x0C)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], background)
	testing.expect_value(t, frame.pixels[1], background)
}

// IBM 2-92. With Attribute 10h bit 6 set the pixel value reaches the DAC as a
// whole byte and the internal palette is not consulted at all, so rewriting a
// palette entry must leave a 256-colour image untouched.
@(test)
vga_test_internal_palette_is_bypassed_in_256_color_mode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	testing.expect(t, v.attr[0x10] & 0x40 != 0)
	v.vram[0] = 1
	vga_note_content_change(&v)
	dac_write(&v, 0x01, 0x3F, 0x15, 0x2A)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	before := frame.pixels[0]

	// Sending entry 1 somewhere else changes nothing.
	internal_palette_write(&v, 0x01, 0x3F)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], before)

	// Moving DAC entry 1 does change it, which shows the pixel really is
	// resolving through the DAC and the check above is not vacuous.
	dac_write(&v, 0x01, 0x00, 0x3F, 0x00)
	frame = vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, frame.pixels[0] != before)
}
