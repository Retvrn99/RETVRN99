// SPDX-License-Identifier: GPL-3.0-only
package host

// 256 glyphs x 16 rows, 1 byte per row (IBM VGA 8x16)
@(rodata)
FONT := #load("../../assets/font/vga8x16.bin")

// 9x16 cell: columns 0-7 from the bitmap; column 8 duplicates column 7
// for box-drawing glyphs 0xC0-0xDF, background otherwise.
glyph_pixel :: proc(ch: u8, col, row: int) -> bool {
	bits := FONT[int(ch) * 16 + row]
	if col < 8 {
		return bits & (0x80 >> u8(col)) != 0
	}
	if ch >= 0xC0 && ch <= 0xDF {
		return bits & 0x01 != 0
	}
	return false
}
