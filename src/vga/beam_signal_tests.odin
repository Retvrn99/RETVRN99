// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Programs a CRT Controller register through the public index and data ports.
// Mode 12h selects the colour address with Miscellaneous Output bit 0, so the
// pair is 3D4h and 3D5h.
@(private = "file")
crtc_out :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3D4, index)
	vga_out(v, 0x3D5, value)
}

// CRT Controller 11h bit 7 write protects 00h through 07h, so software lifting
// it is part of programming those registers. Clearing it here keeps the stock
// vertical retrace end nibble and leaves the interrupt disarmed.
@(private = "file")
crtc_unprotect :: proc(v: ^Vga) {
	crtc_out(v, 0x11, v.crtc[0x11] & 0x7F)
}

// Advances device time to the next raster position at the given scan line and
// dot clock. The offset lands mid dot so the truncation in `vga_beam_position`
// cannot round back into the neighbouring one.
@(private = "file")
beam_seek :: proc(v: ^Vga, line, dot: int) {
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	total := u64(max(v.timing.total_dots, 1))
	offset := u64(line) * line_ns + (u64(dot) * 2 + 1) * line_ns / (total * 2)
	at := v.timing.elapsed_ns / period * period + offset
	for at <= v.timing.elapsed_ns {at += period}
	vga_sync_to(v, at)
}

@(private = "file")
status_at :: proc(v: ^Vga, line, dot: int) -> u8 {
	beam_seek(v, line, dot)
	return vga_in(v, 0x3DA)
}

// IBM 2-58. Input Status 1 bit 0 reports display enable, which is off for the
// whole blanking interval and back on for the border between blank end and the
// end of the line. Mode 12h blanks characters 80 through 97 of 100.
@(test)
vga_test_display_enable_follows_the_horizontal_blank_window :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	testing.expect_value(t, v.timing.hblank_start, 640)
	testing.expect_value(t, v.timing.hblank_end, 784)

	testing.expect_value(t, status_at(&v, 100, 320) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 100, 639) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 100, 640) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 100, 783) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 100, 784) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 100, 799) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))

	// CRT Controller 11h bit 7 is still set, so the write is dropped.
	crtc_out(&v, 0x03, 0x83)
	testing.expect_value(t, v.crtc[0x03], u8(0x82))
	testing.expect_value(t, v.timing.hblank_end, 784)

	// The end field carries the low bits of the character the blank ends on, so
	// 03h low five bits 3 against a start of 80 resolves to character 99.
	crtc_unprotect(&v)
	crtc_out(&v, 0x03, 0x83)
	testing.expect_value(t, v.timing.hblank_end, 792)
	testing.expect_value(t, status_at(&v, 100, 784) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 100, 791) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 100, 792) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
}

// IBM 2-60. Bit 7 of 05h extends the End Horizontal Blanking field by one bit.
// Dropping it takes the reconstructed end below the start, which wraps past the
// horizontal total: blanking then runs to the end of the line and the left
// border disappears.
@(test)
vga_test_end_horizontal_blanking_bit_5_lives_in_crtc_05h :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	left, _, _, _ := border_extents(&v)
	testing.expect_value(t, left, 16)

	crtc_unprotect(&v)
	crtc_out(&v, 0x05, 0x00)
	testing.expect_value(t, v.timing.hblank_end, 800)
	testing.expect_value(t, status_at(&v, 100, 784) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 100, 799) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	left, _, _, _ = border_extents(&v)
	testing.expect_value(t, left, 0)

	// Restoring the bit restores the sixteen dot clock border it was hiding.
	crtc_out(&v, 0x05, 0x80)
	testing.expect_value(t, v.timing.hblank_end, 784)
	testing.expect_value(t, status_at(&v, 100, 790) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
}

// IBM 2-59 and 2-60. Input Status 1 exposes display enable and vertical retrace
// only, so the horizontal retrace window is asserted where it is produced: 04h
// starts it, the 05h delay field offsets both edges by whole characters, and
// the 05h end field carries the low five bits of the character it ends on.
@(test)
vga_test_horizontal_retrace_window_follows_crtc_04h_and_05h :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	testing.expect_value(t, v.timing.hretrace_start, 672)
	testing.expect_value(t, v.timing.hretrace_end, 768)

	crtc_unprotect(&v)
	crtc_out(&v, 0x05, 0x99)
	testing.expect_value(t, v.timing.hretrace_start, 672)
	testing.expect_value(t, v.timing.hretrace_end, 712)

	// A delay of three characters moves both edges by twenty four dot clocks.
	crtc_out(&v, 0x05, 0xF9)
	testing.expect_value(t, v.timing.hretrace_start, 696)
	testing.expect_value(t, v.timing.hretrace_end, 736)

	crtc_out(&v, 0x05, 0x99)
	crtc_out(&v, 0x04, 0x50)
	testing.expect_value(t, v.timing.hretrace_start, 640)
	testing.expect_value(t, v.timing.hretrace_end, 712)

	// An end below the start wraps past the horizontal total, so retrace runs to
	// the end of the line.
	crtc_out(&v, 0x04, 0x5A)
	testing.expect_value(t, v.timing.hretrace_start, 720)
	testing.expect_value(t, v.timing.hretrace_end, 800)
}

// IBM 2-73. End Vertical Blanking is eight bits against a nine bit start, so the
// stock mode 12h pair of start 488 and end field 04h already wraps once past 256
// to reach line 516.
@(test)
vga_test_display_enable_follows_the_vertical_blank_window :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	testing.expect_value(t, v.timing.vblank_start, 488)
	testing.expect_value(t, v.timing.vblank_end, 516)

	testing.expect_value(t, status_at(&v, 100, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 487, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 488, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 515, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 516, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))
	testing.expect_value(t, status_at(&v, 524, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))

	// An end field above the start's low byte needs no wrap at all.
	crtc_out(&v, 0x16, 0xF0)
	testing.expect_value(t, v.timing.vblank_end, 496)
	testing.expect_value(t, status_at(&v, 495, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 496, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))

	crtc_out(&v, 0x16, 0x0C)
	testing.expect_value(t, v.timing.vblank_end, 524)
	testing.expect_value(t, status_at(&v, 516, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 523, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
	testing.expect_value(t, status_at(&v, 524, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0))

	// A wrap that lands past the vertical total blanks the rest of the frame.
	crtc_out(&v, 0x16, 0xE0)
	testing.expect_value(t, v.timing.vblank_end, 525)
	testing.expect_value(t, status_at(&v, 524, 100) & VGA_STATUS1_DISPLAY_DISABLED, u8(0x01))
}

// IBM 2-69 and 2-70. Input Status 1 bit 3 is the vertical retrace signal. 10h
// with the two overflow bits in 07h starts it and the low nibble of 11h ends it,
// wrapping past sixteen lines when the nibble falls below the start's own.
@(test)
vga_test_vertical_retrace_signal_follows_crtc_10h_and_11h :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	testing.expect_value(t, v.timing.retrace_start, 490)
	testing.expect_value(t, v.timing.retrace_end, 492)

	testing.expect_value(t, status_at(&v, 489, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))
	testing.expect_value(t, status_at(&v, 490, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 491, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 492, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))

	// Nibble 2 against a start of 490 resolves to 482, which wraps to 498.
	crtc_out(&v, 0x11, 0x02)
	testing.expect_value(t, v.timing.retrace_end, 498)
	testing.expect_value(t, status_at(&v, 497, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 498, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))

	// 10h is the low eight bits; mode 12h already carries bit 8 in 07h bit 2.
	crtc_out(&v, 0x10, 0xF0)
	testing.expect_value(t, v.timing.retrace_start, 496)
	testing.expect_value(t, v.timing.retrace_end, 498)
	testing.expect_value(t, status_at(&v, 495, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))
	testing.expect_value(t, status_at(&v, 496, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 497, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 498, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))

	crtc_out(&v, 0x11, 0x0F)
	testing.expect_value(t, v.timing.retrace_end, 511)
	testing.expect_value(t, status_at(&v, 510, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0x08))
	testing.expect_value(t, status_at(&v, 511, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))

	// CRT Controller 17h bit 7 gates the signal without moving the window.
	crtc_out(&v, 0x17, v.crtc[0x17] & 0x7F)
	testing.expect_value(t, status_at(&v, 497, 100) & VGA_STATUS1_VERTICAL_RETRACE, u8(0))
}
