// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import "../vga"

@(test)
host_test_glyph_pixel :: proc(t: ^testing.T) {
	// 'A' row 7 is 0xFE: columns 0-6 set, column 7 clear
	testing.expect(t, glyph_pixel('A', 0, 7))
	testing.expect(t, glyph_pixel('A', 6, 7))
	testing.expect(t, !glyph_pixel('A', 7, 7))
	// 'A' is outside 0xC0-0xDF: 9th column is background
	testing.expect(t, !glyph_pixel('A', 8, 7))
	// space glyph is empty
	for y in 0 ..< CELL_H {
		for x in 0 ..< CELL_W {
			testing.expect(t, !glyph_pixel(' ', x, y))
		}
	}
}

@(test)
host_test_glyph_ninth_column :: proc(t: ^testing.T) {
	// 0xC4 (box-drawing horizontal) row 7 is 0xFF: column 8 duplicates column 7
	testing.expect(t, glyph_pixel(0xC4, 7, 7))
	testing.expect(t, glyph_pixel(0xC4, 8, 7))
	// row 6 is 0x00: column 8 stays off
	testing.expect(t, !glyph_pixel(0xC4, 8, 6))
	// 0xDB (full block) duplicates on every row
	for y in 0 ..< CELL_H {
		testing.expect(t, glyph_pixel(0xDB, 8, y))
	}
}

@(test)
host_test_attr_colors :: proc(t: ^testing.T) {
	fg, bg := attr_colors(0x07)
	testing.expect_value(t, fg, u32(0xFFAAAAAA)) // light gray
	testing.expect_value(t, bg, u32(0xFF000000)) // black
	// blink bit acts as bright background: 0x9E = yellow on light blue
	fg, bg = attr_colors(0x9E)
	testing.expect_value(t, fg, u32(0xFFFFFF55))
	testing.expect_value(t, bg, u32(0xFF5555FF))
}

@(test)
host_test_cursor_rect :: proc(t: ^testing.T) {
	x, y, w, h := cursor_px_rect(1, 2)
	testing.expect_value(t, x, 2 * CELL_W)
	testing.expect_value(t, y, CELL_H + CURSOR_TOP)
	testing.expect_value(t, w, CELL_W)
	testing.expect_value(t, h, CURSOR_LINES)
}

@(test)
host_test_render_snapshot :: proc(t: ^testing.T) {
	snap: vga.Text_Snapshot
	snap.cells[0] = u16('A') | 0x1E << 8      // yellow on blue
	snap.cells[1] = u16(' ') | 0x07 << 8      // gray on black
	snap.cursor_row = 0
	snap.cursor_col = 1
	snap.cursor_on = true

	buf := make([]u32, TEXT_W * TEXT_H)
	defer delete(buf)
	render_snapshot(buf[:], TEXT_W, &snap)

	// 'A' row 7 col 0 is set -> foreground yellow
	testing.expect_value(t, buf[7 * TEXT_W + 0], u32(0xFFFFFF55))
	// 'A' row 0 col 0 is clear -> background blue
	testing.expect_value(t, buf[0 * TEXT_W + 0], u32(0xFF0000AA))
	// cursor underline at cell (0,1): rows CURSOR_TOP..+CURSOR_LINES in cell fg
	testing.expect_value(t, buf[CURSOR_TOP * TEXT_W + CELL_W], u32(0xFFAAAAAA))
	testing.expect_value(t, buf[(CURSOR_TOP + 1) * TEXT_W + CELL_W], u32(0xFFAAAAAA))
	// row just above the underline stays background black
	testing.expect_value(t, buf[(CURSOR_TOP - 1) * TEXT_W + CELL_W], u32(0xFF000000))

	// cursor off -> underline area is background
	snap.cursor_on = false
	render_snapshot(buf[:], TEXT_W, &snap)
	testing.expect_value(t, buf[CURSOR_TOP * TEXT_W + CELL_W], u32(0xFF000000))
}
