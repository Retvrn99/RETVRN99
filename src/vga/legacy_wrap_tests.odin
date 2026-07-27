// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(private = "file")
seq_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3C4, index)
	vga_out(v, 0x3C5, value)
}

@(private = "file")
gfx_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3CE, index)
	vga_out(v, 0x3CF, value)
}

@(private = "file")
cga_crtc_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
	vga_note_content_change(v)
}

@(private = "file")
advance_one_frame :: proc(v: ^Vga) {
	period := max(v.timing.frame_period_ns, u64(1))
	vga_sync_to(v, v.timing.elapsed_ns + period + period / 2)
	vga_note_content_change(v)
}

// IBM CGA. The compatibility persona owns a single 16 KiB page. A display
// counter pushed past it by the start address wraps back to the top of the page
// rather than reading whatever else is in video memory.
@(test)
vga_test_cga_graphics_wraps_inside_its_page :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	// 320x200 four colour, video enabled, through the CGA mode control port.
	vga_out(&v, 0x3D8, 0x0A)
	testing.expect(t, v.cga.active)
	kind, width, height := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Cga_2)
	testing.expect_value(t, width, 320)
	testing.expect_value(t, height, 200)

	// Two different bytes one page apart, both written through the aperture.
	testing.expect(t, vga_memory_write_byte(&v, 0xB8000, 0xC0))
	testing.expect(t, vga_memory_write_byte(&v, 0xBC000, 0x40))
	vga_note_content_change(&v)
	frame := vga_display_frame(&v)
	inside := frame.pixels[0]

	// A start address of 2000h puts the byte counter at 4000h, one page on.
	cga_crtc_out(&v, 0x0C, 0x20)
	cga_crtc_out(&v, 0x0D, 0x00)
	advance_one_frame(&v)
	testing.expect_value(t, display_start(&v), u16(0x2000))
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], inside)

	// Half a page on it reads the second byte, so the wrap above is a wrap and
	// not a frozen counter.
	cga_crtc_out(&v, 0x0C, 0x10)
	cga_crtc_out(&v, 0x0D, 0x00)
	advance_one_frame(&v)
	frame = vga_display_frame(&v)
	testing.expect(t, frame.pixels[0] != inside)
}

// The same page holds the text buffer, where it bounds cells rather than bytes.
@(test)
vga_test_cga_text_wraps_inside_its_page :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	vga_out(&v, 0x3D8, 0x08)
	testing.expect(t, v.cga.active)
	kind, _, _ := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Text)

	// A glyph for character 01h, then that character in the first cell of the
	// page and a blank one in the cell 8 KiB later.
	set_plane_byte(&v, 2, 32, 0xFF)
	testing.expect(t, vga_memory_write_byte(&v, 0xB8000, 0x01))
	testing.expect(t, vga_memory_write_byte(&v, 0xB8001, 0x0F))
	testing.expect(t, vga_memory_write_byte(&v, 0xBA000, 0x20))
	testing.expect(t, vga_memory_write_byte(&v, 0xBA001, 0x0F))
	vga_note_content_change(&v)
	frame := vga_display_frame(&v)
	lit := frame.pixels[0]
	// The glyph starts at the top of its cell. A 6845 has no preset row scan, so
	// the interlace value the persona seeds into CRT Controller 08h must not be
	// read as one.
	testing.expect(t, lit != frame.pixels[319])

	cga_crtc_out(&v, 0x0C, 0x10)
	cga_crtc_out(&v, 0x0D, 0x00)
	advance_one_frame(&v)
	frame = vga_display_frame(&v)
	testing.expect(t, frame.pixels[0] != lit)

	// One whole page of cells brings the counter back where it started.
	cga_crtc_out(&v, 0x0C, 0x20)
	cga_crtc_out(&v, 0x0D, 0x00)
	advance_one_frame(&v)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[0], lit)
}

// IBM 2-24 to 2-34. Graphics 06h selects which window of host memory the
// adapter answers to, and nothing outside it decodes.
@(test)
vga_test_aperture_windows_bound_the_legacy_decode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	seq_out(&v, 0x04, 0x06)
	seq_out(&v, 0x02, 0x0F)

	Window :: struct {
		select:      u8,
		first, last: u64,
	}
	windows := [?]Window {
		{0, 0xA0000, 0xBFFFF},
		{1, 0xA0000, 0xAFFFF},
		{2, 0xB0000, 0xB7FFF},
		{3, 0xB8000, 0xBFFFF},
	}
	for window in windows {
		gfx_out(&v, 0x06, window.select << 2 | 0x01)
		testing.expect(t, vga_memory_write_byte(&v, window.first, 0x11))
		testing.expect(t, vga_memory_write_byte(&v, window.last, 0x22))
		if window.first > 0xA0000 {
			testing.expect(t, !vga_memory_write_byte(&v, window.first - 1, 0x33))
		}
		if window.last < 0xBFFFF {
			testing.expect(t, !vga_memory_write_byte(&v, window.last + 1, 0x44))
		}
	}

	// Miscellaneous Output bit 1 gates the whole legacy aperture regardless of
	// which window is selected.
	gfx_out(&v, 0x06, 0x05)
	testing.expect(t, vga_memory_write_byte(&v, 0xA0000, 0x55))
	vga_out(&v, 0x3C2, 0xE1)
	testing.expect(t, !vga_memory_write_byte(&v, 0xA0000, 0x66))
	_, decoded := vga_memory_read_byte(&v, 0xA0000)
	testing.expect(t, !decoded)
}

// IBM 2-54. Chain-4 and odd/even each reroute both directions of the aperture,
// and they layer on top of the read map and the map mask rather than replacing
// them. This walks the four combinations for a write and a read.
@(test)
vga_test_chain4_and_odd_even_route_reads_and_writes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	gfx_out(&v, 0x05, 0x00)
	gfx_out(&v, 0x06, 0x05)
	seq_out(&v, 0x02, 0x0F)

	for plane in 0 ..< 4 {set_plane_byte(&v, plane, 0x40, u8(0xB0 + plane))}

	// Chain 4 takes the low two address bits as the plane in both directions.
	seq_out(&v, 0x04, 0x0E)
	for offset in 0 ..< 4 {
		value, decoded := vga_memory_read_byte(&v, u64(0xA0100 + offset))
		testing.expect(t, decoded)
		testing.expect_value(t, value, u8(0xB0 + offset))
	}
	testing.expect(t, vga_memory_write_byte(&v, 0xA0102, 0x7E))
	testing.expect_value(t, plane_byte(&v, 2, 0x40), u8(0x7E))
	testing.expect_value(t, plane_byte(&v, 1, 0x40), u8(0xB1))

	// Odd/even needs the Graphics 05h and 06h chain bits with it, and then the
	// read map selects which half of the pair answers.
	seq_out(&v, 0x04, 0x02)
	gfx_out(&v, 0x05, 0x10)
	gfx_out(&v, 0x06, 0x07)
	gfx_out(&v, 0x04, 0x00)
	value, decoded := vga_memory_read_byte(&v, 0xA0080)
	testing.expect(t, decoded)
	testing.expect_value(t, value, u8(0xB0))
	value, _ = vga_memory_read_byte(&v, 0xA0081)
	testing.expect_value(t, value, u8(0xB1))
	gfx_out(&v, 0x04, 0x02)
	value, _ = vga_memory_read_byte(&v, 0xA0080)
	testing.expect_value(t, value, u8(0x7E))

	// With neither chain the read map alone decides and the offset is linear.
	seq_out(&v, 0x04, 0x06)
	gfx_out(&v, 0x05, 0x00)
	gfx_out(&v, 0x06, 0x05)
	gfx_out(&v, 0x04, 0x03)
	value, _ = vga_memory_read_byte(&v, 0xA0040)
	testing.expect_value(t, value, u8(0xB3))
	gfx_out(&v, 0x04, 0x01)
	value, _ = vga_memory_read_byte(&v, 0xA0040)
	testing.expect_value(t, value, u8(0xB1))
}
