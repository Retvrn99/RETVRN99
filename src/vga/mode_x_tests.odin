// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// The 320x240 Mode X switch as software performs it: start from BIOS mode 13h,
// then reach the unchained mode entirely through the public ports. Register
// values follow the widely used sequence, which sets 480-line vertical timing
// with double scanning to reach 240 rows.
@(private = "package")
mode_x_program_320x240 :: proc(v: ^Vga) {
	// 480-line vertical timing.
	vga_out(v, 0x3C2, 0xE3)
	// Sequencer 04h: chain 4 off, odd/even off, extended memory on.
	vga_out(v, 0x3C4, 0x04)
	vga_out(v, 0x3C5, 0x06)
	// Vertical Retrace End bit 7 write protects CRT Controller 00h-07h.
	crtc_out(v, 0x11, 0x0C)
	crtc_out(v, 0x06, 0x0D) // vertical total
	crtc_out(v, 0x07, 0x3E) // overflow
	crtc_out(v, 0x09, 0x41) // double scan, two lines per row
	crtc_out(v, 0x10, 0xEA) // vertical retrace start
	crtc_out(v, 0x11, 0xAC) // vertical retrace end, protection back on
	crtc_out(v, 0x12, 0xDF) // vertical display end
	crtc_out(v, 0x15, 0xE7) // vertical blank start
	crtc_out(v, 0x16, 0x06) // vertical blank end
	crtc_out(v, 0x14, 0x00) // underline: doubleword addressing off
	crtc_out(v, 0x17, 0xE3) // mode control: byte addressing
	vga_note_content_change(v)
}

@(private = "file")
crtc_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
}

// An unchained pixel lives in plane x & 3 at offset y * 80 + x / 4, reached
// through the Map Mask and the A0000h aperture exactly as software reaches it.
@(private = "file")
mode_x_plot :: proc(v: ^Vga, x, y: int, index: u8) -> bool {
	vga_out(v, 0x3C4, 0x02)
	vga_out(v, 0x3C5, u8(1) << uint(x & 3))
	return vga_memory_write_byte(v, 0xA0000 + u64(y * 80 + x / 4), index)
}

// The unchained 320x240 tuple, programmed rather than assigned. Mode 13h reaches
// 320x200 by chaining four planes into a linear byte per pixel; Mode X turns the
// chain off, so consecutive pixels sit in consecutive planes and a row costs
// eighty bytes per plane instead of three hundred and twenty.
@(test)
vga_test_mode_x_320x240_is_reached_through_the_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	kind, width, height := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Indexed_8)
	testing.expect_value(t, width, 320)
	testing.expect_value(t, height, 200)

	mode_x_program_320x240(&v)
	kind, width, height = display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Indexed_8)
	testing.expect_value(t, width, 320)
	testing.expect_value(t, height, 240)
	// 480 scan lines doubled into 240 rows, which is where the extra forty rows
	// over mode 13h come from.
	testing.expect_value(t, v.timing.visible_lines, 480)
	testing.expect_value(t, legacy_graphics_scan_factor(&v), 2)

	// Four adjacent pixels land in four different planes, and the fifth returns
	// to plane 0. Distinct indices prove the planes are read in that order rather
	// than one byte being smeared across the group.
	for x in 0 ..< 4 {testing.expect(t, mode_x_plot(&v, x, 0, u8(x + 1)))}
	testing.expect(t, mode_x_plot(&v, 4, 0, 1))
	// The last pixel of the last row proves the eighty-byte pitch and the row
	// count together: at any other pitch this address belongs to another row.
	testing.expect(t, mode_x_plot(&v, 0, 239, 1))
	testing.expect(t, mode_x_plot(&v, 319, 239, 2))
	vga_note_content_change(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil && frame.height == 240) {return}
	for x in 1 ..< 4 {
		for earlier in 0 ..< x {
			testing.expect(t, frame.pixels[x] != frame.pixels[earlier])
		}
	}
	testing.expect_value(t, frame.pixels[4], frame.pixels[0])
	last := 239 * 320
	testing.expect_value(t, frame.pixels[last], frame.pixels[0])
	testing.expect_value(t, frame.pixels[last + 319], frame.pixels[1])
}

// Mode 13h chains the four planes, so a single byte written through the aperture
// is one pixel and the four pixels above would need four consecutive addresses.
// Running the same plot sequence without the Mode X switch must therefore not
// produce the same image, which is what makes the test above a proof of
// unchaining rather than of addressing that happened to work either way.
@(test)
vga_test_mode_13h_chaining_differs_from_mode_x :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	for x in 0 ..< 4 {testing.expect(t, mode_x_plot(&v, x, 0, u8(x + 1)))}
	vga_note_content_change(&v)

	frame := vga_display_frame(&v)
	if !testing.expect(t, frame != nil) {return}
	// Chained, all four writes address the same linear byte through different
	// planes, so the first four pixels do not carry four distinct indices.
	distinct_count := 0
	for x in 0 ..< 4 {
		seen := false
		for earlier in 0 ..< x {if frame.pixels[x] == frame.pixels[earlier] {seen = true}}
		if !seen {distinct_count += 1}
	}
	testing.expect(t, distinct_count < 4)
}
