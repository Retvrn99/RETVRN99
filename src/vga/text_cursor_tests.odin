// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// A blank cell whose attribute has distinct foreground and background. The
// cursor swaps the pair, so a cursor scan line reads as the foreground colour
// and every other scan line reads as the background colour.
TEXT_CURSOR_ATTRIBUTE :: 0x1F00
TEXT_CURSOR_CELL_HEIGHT :: 16

// Scan lines of cell (0,0) that differ from the same cell rendered with the
// cursor disabled. Using a cursor-off render as the baseline avoids depending
// on how an attribute maps to a colour.
@(private = "file")
text_cursor_scan_lines :: proc(v: ^Vga, column := 0) -> (lines: bit_set[0 ..< 32]) {
	baseline: [TEXT_CURSOR_CELL_HEIGHT]u32
	saved := v.crtc[0x0A]
	v.crtc[0x0A] = saved | 0x20
	vga_note_content_change(v)
	off := vga_display_frame(v)
	if off == nil || off.width <= 0 {return}
	width := off.width
	for line in 0 ..< min(TEXT_CURSOR_CELL_HEIGHT, off.height) {
		baseline[line] = off.pixels[line * width + column * 9]
	}

	v.crtc[0x0A] = saved
	vga_note_content_change(v)
	on := vga_display_frame(v)
	if on == nil {return}
	for line in 0 ..< min(TEXT_CURSOR_CELL_HEIGHT, on.height) {
		if on.pixels[line * width + column * 9] != baseline[line] {lines += {line}}
	}
	return
}

@(private = "file")
text_cursor_prepare :: proc(t: ^testing.T, v: ^Vga) {
	// A space at cell (0,0) with the cursor addressed to it.
	testing.expect(t, vga_mmio_write(v, 0xB8000, 2, u32(TEXT_CURSOR_ATTRIBUTE | 0x20)))
	v.crtc[0x0E] = 0
	v.crtc[0x0F] = 0
	v.crtc[0x0B] = 0
}

// IBM 2-65 and 2-66. The cursor sets at Cursor Start and clears at Cursor End
// or at the bottom of the character cell.
@(test)
vga_test_text_cursor_start_and_end_matrix :: proc(t: ^testing.T) {
	Case :: struct {
		start, end: u8,
		expected:   bit_set[0 ..< 32],
	}
	cases := [?]Case {
		// An ordinary underline near the bottom of the cell.
		{13, 14, {13, 14}},
		// A single scan line when start and end agree.
		{7, 7, {7}},
		// A full height block.
		{0, 15, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}},
		// End below start runs to the bottom of the cell and must not wrap
		// into the top of it.
		{6, 3, {6, 7, 8, 9, 10, 11, 12, 13, 14, 15}},
		{14, 0, {14, 15}},
		// A start beyond the cell can never latch.
		{20, 31, {}},
	}
	for entry in cases {
		v: Vga
		backing := test_vga_init(t, &v)
		defer delete(backing)
		defer vga_destroy(&v)
		text_cursor_prepare(t, &v)
		v.crtc[0x0A] = entry.start
		v.crtc[0x0B] = entry.end
		actual := text_cursor_scan_lines(&v)
		if actual != entry.expected {
			testing.expectf(
				t,
				false,
				"cursor start %d end %d expected scan lines %v, got %v",
				entry.start,
				entry.end,
				entry.expected,
				actual,
			)
		}
	}
}

// Cursor Start bit 5 disables the cursor regardless of the scan line range.
@(test)
vga_test_text_cursor_off_bit_overrides_range :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	text_cursor_prepare(t, &v)

	v.crtc[0x0A] = 13
	v.crtc[0x0B] = 14
	testing.expect(t, text_cursor_scan_lines(&v) == {13, 14})
	v.crtc[0x0A] = 13 | 0x20
	testing.expect(t, text_cursor_scan_lines(&v) == {})
	// The off bit must not be mistaken for part of the start value.
	v.crtc[0x0A] = 13
	testing.expect(t, text_cursor_scan_lines(&v) == {13, 14})
}

// Cursor End bits 5 and 6 skew the cursor to a later character cell.
@(test)
vga_test_text_cursor_skew_shifts_the_addressed_cell :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	text_cursor_prepare(t, &v)
	v.crtc[0x0A] = 13

	for skew in u8(0) ..= 3 {
		v.crtc[0x0B] = 14 | skew << 5
		// Cell (0,0) only carries the cursor when the skew is zero; a skew
		// moves it to a later cell.
		testing.expect(t, (text_cursor_scan_lines(&v) != {}) == (skew == 0))
	}
}
