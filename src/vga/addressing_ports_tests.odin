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
}

@(private = "file")
gfx_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3CE, index)
	vga_out(v, 0x3CF, value)
}

// A sixteen by four planar raster, programmed the way software would rather than
// poked into the timing struct: any CRT Controller write recalculates the timing
// from the registers, so a hand-set geometry does not survive the first port
// write of the test that needs it.
@(private = "file")
tiny_graphics_geometry :: proc(v: ^Vga) {
	vga_out(v, 0x3C2, 0xE3)
	vga_out(v, 0x3C4, 0x01)
	vga_out(v, 0x3C5, 0x01)
	gfx_out(v, 0x05, 0x00)
	gfx_out(v, 0x06, 0x05)
	attr_out(v, 0x10, 0x01)
	attr_out(v, 0x12, 0x0F)
	crtc_out(v, 0x11, 0x0C)
	crtc_out(v, 0x00, 0x03)
	crtc_out(v, 0x01, 0x01)
	crtc_out(v, 0x06, 0x10)
	crtc_out(v, 0x07, 0x10)
	crtc_out(v, 0x09, 0x40)
	crtc_out(v, 0x12, 0x03)
	crtc_out(v, 0x13, 0x01)
	crtc_out(v, 0x14, 0x00)
	crtc_out(v, 0x18, 0xFF)
}

// A sixteen dot planar row whose two bytes are distinguishable, so the pixels a
// row expands to name the plane offset the address path chose.
@(private = "file")
seed_address_pattern :: proc(v: ^Vga) {
	set_plane_byte(v, 0, 0, 0xF0)
	set_plane_byte(v, 0, 1, 0x0F)
	set_plane_byte(v, 0, 2, 0xCC)
	set_plane_byte(v, 0, 4, 0xAA)
}

// The palette resolution is file private in scanout.odin, so lit and unlit are
// taken from a rendered row rather than computed: the first character always
// resolves to plane offset zero, which the pattern above leaves as F0h.
@(private = "file")
row_reference :: proc(v: ^Vga) -> (on, off: u32) {
	frame := vga_display_frame(v)
	if len(frame.pixels) < 8 {return}
	return frame.pixels[0], frame.pixels[4]
}

@(private = "file")
expect_row_bits :: proc(t: ^testing.T, v: ^Vga, on, off: u32, first, count: int, bits: u8) {
	frame := vga_display_frame(v)
	if !testing.expect(t, len(frame.pixels) >= first + count) {return}
	if !testing.expect(t, on != off) {return}
	for i in 0 ..< count {
		want := bits & (u8(0x80) >> uint(i)) != 0 ? on : off
		testing.expect_value(t, frame.pixels[first + i], want)
	}
}

// IBM 2-62 and 2-64. Line Compare is ten bits spread across three registers.
// Bit 8 lives in Overflow, which CRT Controller 11h bit 7 protects, and bit 9 in
// Maximum Scan Line, which it does not.
@(test)
vga_test_line_compare_bits_reach_the_split_through_the_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	// Mode 12h parks the split out of range with all ten bits set.
	testing.expect_value(t, legacy_line_compare(&v), 1023)

	crtc_out(&v, 0x18, 0x0F)
	testing.expect_value(t, legacy_line_compare(&v), 783)

	// Overflow is protected, and bit 4 is the one exception the protection makes.
	testing.expect_value(t, v.crtc[0x11] & 0x80, u8(0x80))
	crtc_out(&v, 0x07, 0x00)
	testing.expect_value(t, v.crtc[0x07], u8(0x2E))
	testing.expect_value(t, legacy_line_compare(&v), 527)
	crtc_out(&v, 0x07, 0xFF)
	testing.expect_value(t, v.crtc[0x07], u8(0x3E))
	crtc_out(&v, 0x06, 0x00)
	testing.expect_value(t, v.crtc[0x06], u8(0x0B))

	crtc_out(&v, 0x09, 0x00)
	testing.expect_value(t, legacy_line_compare(&v), 271)
	crtc_out(&v, 0x07, 0x00)
	testing.expect_value(t, legacy_line_compare(&v), 15)

	// The split restarts the row address at zero, so the row that follows it
	// repeats the first row of memory rather than continuing down it.
	set_plane_byte(&v, 0, 0, 0xFF)
	vga_note_content_change(&v)
	frame := vga_display_frame(&v)
	testing.expect_value(t, frame.width, 640)
	lit := frame.pixels[0]
	testing.expect(t, lit != frame.pixels[640])
	testing.expect_value(t, frame.pixels[16 * 640], lit)

	// Lifting the split back out of range takes the repeat with it.
	crtc_out(&v, 0x18, 0xFF)
	frame = vga_display_frame(&v)
	testing.expect_value(t, frame.pixels[16 * 640], frame.pixels[640])
}

// IBM 2-64. The scan factor the expanded height divides by is the larger of
// Maximum Scan Line and the double-scan bit, both programmed through 3D5h.
@(test)
vga_test_scan_factor_follows_crtc_09h_through_the_ports :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	_, _, height := display_geometry(&v)
	testing.expect_value(t, height, 480)

	crtc_out(&v, 0x09, 0x80)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 240)

	crtc_out(&v, 0x09, 0x01)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 240)

	// The two fields combine with a maximum rather than a product, so asking for
	// both at once still halves the raster once.
	crtc_out(&v, 0x09, 0x81)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 240)

	crtc_out(&v, 0x09, 0x03)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 120)
}

// IBM 2-72 and 2-74 to 2-76. Word, byte, and doubleword modes and the two
// count-by fields all rewrite the same display address, and every one of them is
// reachable from 3D4h/3D5h.
@(test)
vga_test_display_address_modes_follow_crtc_14h_and_17h :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_graphics_geometry(&v)
	seed_address_pattern(&v)
	kind, width, height := display_geometry(&v)
	testing.expect_value(t, kind, Display_Kind.Planar_4)
	testing.expect_value(t, width, 16)
	testing.expect_value(t, height, 4)

	// Byte mode addresses plane offsets one for one.
	crtc_out(&v, 0x17, 0xE3)
	on, off := row_reference(&v)
	expect_row_bits(t, &v, on, off, 0, 8, 0xF0)
	expect_row_bits(t, &v, on, off, 8, 8, 0x0F)

	// Word mode doubles the address, so the second character reads offset two.
	crtc_out(&v, 0x17, 0xA3)
	expect_row_bits(t, &v, on, off, 8, 8, 0xCC)

	// Doubleword mode shifts it twice instead.
	crtc_out(&v, 0x14, 0x40)
	expect_row_bits(t, &v, on, off, 8, 8, 0xAA)

	// Count by four divides the character counter before the address is formed,
	// so both characters of this row resolve to offset zero.
	crtc_out(&v, 0x14, 0x20)
	crtc_out(&v, 0x17, 0xE3)
	expect_row_bits(t, &v, on, off, 8, 8, 0xF0)

	// Count by two does the same from the other register.
	crtc_out(&v, 0x14, 0x00)
	crtc_out(&v, 0x17, 0xEB)
	expect_row_bits(t, &v, on, off, 8, 8, 0xF0)
	crtc_out(&v, 0x17, 0xE3)
	expect_row_bits(t, &v, on, off, 8, 8, 0x0F)
}

// IBM 2-67, 2-75 and 2-99. The start address pair is latched at vertical retrace
// rather than taken immediately, and once latched it is large enough to reach
// the address bit that CRT Controller 17h bit 5 selects for the word-mode wrap.
@(test)
vga_test_address_wrap_bit_selects_which_address_bit_rotates :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_graphics_geometry(&v)
	seed_address_pattern(&v)
	set_plane_byte(&v, 0, 0x4000, 0x81)
	set_plane_byte(&v, 0, 0x4001, 0x18)
	crtc_out(&v, 0x17, 0xE3)
	on, off := row_reference(&v)
	crtc_out(&v, 0x17, 0xA3)

	crtc_out(&v, 0x0C, 0x20)
	crtc_out(&v, 0x0D, 0x00)
	testing.expect_value(t, display_start(&v), u16(0x2000))
	testing.expect_value(t, v.latched_start, u16(0))

	// One frame of device time carries the beam through vertical retrace.
	vga_sync_to(&v, v.timing.frame_period_ns + v.timing.frame_period_ns / 2)
	testing.expect_value(t, v.latched_start, u16(0x2000))

	// Bit 5 set selects address bit 15, which is clear here, so the rotated bit
	// leaves the offset even.
	vga_note_content_change(&v)
	expect_row_bits(t, &v, on, off, 0, 8, 0x81)

	// Bit 5 clear selects address bit 13, which this start address sets.
	crtc_out(&v, 0x17, 0x83)
	expect_row_bits(t, &v, on, off, 0, 8, 0x18)
}

// IBM 2-76. With either row-scan select bit clear the matching address bit comes
// from the row scan counter instead of the address, which is the interleave the
// CGA-compatible modes are built on.
@(test)
vga_test_row_scan_select_substitutes_the_interleave_bits :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_graphics_geometry(&v)
	seed_address_pattern(&v)
	set_plane_byte(&v, 0, 0x2002, 0x3C)
	set_plane_byte(&v, 0, 0x4004, 0xC3)

	// Both bits set leaves the address alone, so the rows walk offsets 0, 2, 4.
	crtc_out(&v, 0x17, 0xE3)
	on, off := row_reference(&v)
	expect_row_bits(t, &v, on, off, 16, 8, 0xCC)
	expect_row_bits(t, &v, on, off, 32, 8, 0xAA)

	// Bit 0 clear puts row scan bit 0 into address bit 13.
	crtc_out(&v, 0x17, 0xE2)
	expect_row_bits(t, &v, on, off, 16, 8, 0x3C)

	// Bit 1 clear does the same for row scan bit 1 and address bit 14.
	crtc_out(&v, 0x17, 0xE0)
	expect_row_bits(t, &v, on, off, 32, 8, 0xC3)
}

// IBM 2-75. Horizontal Retrace Select halves the row scan clock, so the raster
// covers half as many source rows. It combines with Maximum Scan Line rather
// than replacing it.
@(test)
vga_test_horizontal_retrace_select_halves_the_row_clock :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	_, _, height := display_geometry(&v)
	testing.expect_value(t, height, 480)

	crtc_out(&v, 0x17, v.crtc[0x17] | 0x04)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 240)

	crtc_out(&v, 0x09, 0x01)
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 120)

	crtc_out(&v, 0x17, v.crtc[0x17] & ~u8(0x04))
	_, _, height = display_geometry(&v)
	testing.expect_value(t, height, 240)
}

@(private = "file")
expect_row16 :: proc(t: ^testing.T, v: ^Vga, on, off: u32, row: int, bits: u16) {
	frame := vga_display_frame(v)
	if !testing.expect(t, len(frame.pixels) >= (row + 1) * 16) {return}
	for i in 0 ..< 16 {
		want := bits & (u16(0x8000) >> uint(i)) != 0 ? on : off
		testing.expect_value(t, frame.pixels[row * 16 + i], want)
	}
}

// IBM 2-95 and 2-102 to 2-103. The split screen, the byte pan in CRT Controller
// 08h, and the PEL pan in Attribute 13h all act on the same row address, and
// Attribute 10h bit 5 is what stops the two pans from following the raster below
// the split. Every register here is written through its own public port.
@(test)
vga_test_split_screen_combines_byte_pan_and_pel_pan :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	tiny_graphics_geometry(&v)
	set_plane_byte(&v, 0, 0, 0xAA)
	set_plane_byte(&v, 0, 1, 0xF0)
	crtc_out(&v, 0x17, 0xE3)
	crtc_out(&v, 0x08, 0x20)
	crtc_out(&v, 0x07, 0x00)
	crtc_out(&v, 0x09, 0x00)
	crtc_out(&v, 0x18, 0x01)
	attr_out(&v, 0x10, 0x21)
	attr_out(&v, 0x13, 0x02)
	vga_note_content_change(&v)
	testing.expect_value(t, legacy_line_compare(&v), 1)
	testing.expect_value(t, legacy_split_first_line(&v, .Planar_4), 2)

	frame := vga_display_frame(&v)
	if !testing.expect(t, len(frame.pixels) >= 48) {return}
	on, off := frame.pixels[32], frame.pixels[33]

	// Above the split the byte pan advances the row by one and the PEL pan
	// shifts it two dots further.
	expect_row16(t, &v, on, off, 0, 0xC000)
	// Below it both pans are held off, so the row starts at memory offset zero.
	expect_row16(t, &v, on, off, 2, 0xAAF0)

	// Clearing Attribute 10h bit 5 lets both pans follow the split rows too.
	attr_out(&v, 0x10, 0x01)
	vga_note_content_change(&v)
	expect_row16(t, &v, on, off, 2, 0xC000)
}
