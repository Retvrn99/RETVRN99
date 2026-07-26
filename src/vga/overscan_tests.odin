// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Programs Attribute Controller 11h through the public flip-flop. Writing an
// index with bit 5 clear turns off the Palette Address Source and blanks the
// display, so the sequence ends by writing 20h to re-enable video, exactly as
// software must.
@(private = "file")
overscan_select :: proc(v: ^Vga, index: u8) {
	_ = vga_in(v, 0x3DA)
	vga_out(v, 0x3C0, 0x11)
	vga_out(v, 0x3C0, index)
	vga_out(v, 0x3C0, 0x20)
	vga_note_content_change(v)
}

// IBM 2-94. Attribute Controller 11h selects the border colour, and it
// resolves through the same palette and DAC path as an image pixel carrying
// the same index. Comparing the two avoids depending on DAC scaling.
@(test)
vga_test_overscan_color_follows_attribute_11h_through_public_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)

	// Pixel (0,0) carries colour index 5 from planes 0 and 2.
	set_plane_byte(&v, 0, 0, 0x80)
	set_plane_byte(&v, 2, 0, 0x80)
	// Give DAC entry 5 a value the default palette does not carry.
	vga_out(&v, 0x3C8, 5)
	vga_out(&v, 0x3C9, 0x3F)
	vga_out(&v, 0x3C9, 0x15)
	vga_out(&v, 0x3C9, 0x2A)

	overscan_select(&v, 5)
	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.overscan, overscan_color(&v))
	// The border resolves exactly like a pixel of the same index.
	testing.expect_value(t, frame.overscan, frame.pixels[0])
	testing.expect(t, frame.overscan != 0xFF00_0000)

	// A different index must move the border and leave the image alone.
	image := frame.pixels[0]
	overscan_select(&v, 1)
	frame = vga_display_frame(&v)
	testing.expect(t, frame.overscan != image)
	testing.expect_value(t, frame.pixels[0], image)
}

// The border is part of the displayed signal, so anything that disables output
// blanks it as well.
@(test)
vga_test_overscan_is_black_while_output_is_disabled :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	vga_out(&v, 0x3C8, 5)
	vga_out(&v, 0x3C9, 0x3F)
	vga_out(&v, 0x3C9, 0x15)
	vga_out(&v, 0x3C9, 0x2A)
	overscan_select(&v, 5)
	testing.expect(t, overscan_color(&v) != 0xFF00_0000)

	// Sequencer 00h reset gates the whole output, border included.
	vga_out(&v, 0x3C4, 0)
	vga_out(&v, 0x3C5, 0x01)
	testing.expect_value(t, overscan_color(&v), u32(0xFF00_0000))
	vga_out(&v, 0x3C5, 0x03)
	testing.expect(t, overscan_color(&v) != 0xFF00_0000)

	// Sequencer 01h screen off does the same.
	vga_out(&v, 0x3C4, 1)
	vga_out(&v, 0x3C5, v.seq[1] | 0x20)
	testing.expect_value(t, overscan_color(&v), u32(0xFF00_0000))
}

// The CGA persona takes its border from the colour-select register instead.
@(test)
vga_test_overscan_uses_cga_color_select_in_cga_modes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x04)
	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
	for border in u8(0) ..= 15 {
		vga_out(&v, 0x3D9, border)
		vga_note_content_change(&v)
		testing.expect_value(t, overscan_color(&v), CGA_COLORS[int(border)])
		frame := vga_display_frame(&v)
		if testing.expect(t, frame != nil) {
			testing.expect_value(t, frame.overscan, CGA_COLORS[int(border)])
		}
	}
}

// The published legacy frame header carries the border colour so presentation
// can paint the surround without reading device state.
@(test)
vga_test_legacy_frame_header_publishes_the_overscan_color :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	vga_out(&v, 0x3C8, 7)
	vga_out(&v, 0x3C9, 0x2A)
	vga_out(&v, 0x3C9, 0x3F)
	vga_out(&v, 0x3C9, 0x05)
	overscan_select(&v, 7)

	update := vga_legacy_frame_update(&v)
	testing.expect_value(t, update.header.overscan, overscan_color(&v))
	testing.expect(t, update.header.overscan != 0xFF00_0000)
}
