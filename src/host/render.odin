// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:c"
import sdl3 "vendor:sdl3"
import "../vga"

CELL_W :: 9
CELL_H :: 16
TEXT_COLS :: 80
TEXT_ROWS :: 25
TEXT_W :: TEXT_COLS * CELL_W // 720
TEXT_H :: TEXT_ROWS * CELL_H // 400
CURSOR_TOP :: 14 // first underline scanline
CURSOR_LINES :: 2

// standard 16-color VGA palette, ARGB8888
PALETTE :: [16]u32 {
	0xFF000000, 0xFF0000AA, 0xFF00AA00, 0xFF00AAAA,
	0xFFAA0000, 0xFFAA00AA, 0xFFAA5500, 0xFFAAAAAA,
	0xFF555555, 0xFF5555FF, 0xFF55FF55, 0xFF55FFFF,
	0xFFFF5555, 0xFFFF55FF, 0xFFFFFF55, 0xFFFFFFFF,
}

// blink bit treated as bright background (no blinking in M1)
attr_colors :: proc(attr: u8) -> (fg, bg: u32) {
	pal := PALETTE
	return pal[attr & 0x0F], pal[attr >> 4]
}

cursor_px_rect :: proc(row, col: int) -> (x, y, w, h: int) {
	return col * CELL_W, row * CELL_H + CURSOR_TOP, CELL_W, CURSOR_LINES
}

// Pure rasterizer: 80x25 cells into a TEXT_W x TEXT_H ARGB buffer.
render_snapshot :: proc(pixels: []u32, pitch_px: int, snap: ^vga.Text_Snapshot) {
	for r in 0 ..< TEXT_ROWS {
		for cc in 0 ..< TEXT_COLS {
			cell := snap.cells[r * TEXT_COLS + cc]
			ch := u8(cell)
			fg, bg := attr_colors(u8(cell >> 8))
			for y in 0 ..< CELL_H {
				base := (r * CELL_H + y) * pitch_px + cc * CELL_W
				for x in 0 ..< CELL_W {
					pixels[base + x] = glyph_pixel(ch, x, y) ? fg : bg
				}
			}
		}
	}
	// steady underline cursor
	if snap.cursor_on &&
	   snap.cursor_row >= 0 && snap.cursor_row < TEXT_ROWS &&
	   snap.cursor_col >= 0 && snap.cursor_col < TEXT_COLS {
		cell := snap.cells[snap.cursor_row * TEXT_COLS + snap.cursor_col]
		fg, _ := attr_colors(u8(cell >> 8))
		x, y, w, h := cursor_px_rect(snap.cursor_row, snap.cursor_col)
		for yy in y ..< y + h {
			for xx in x ..< x + w {
				pixels[yy * pitch_px + xx] = fg
			}
		}
	}
}

// Thin SDL wrapper: upload the rasterized grid and present at 2x below the menu bar.
render_text :: proc(h: ^Host, snap: ^vga.Text_Snapshot) {
	render_grid(h, snap)
	sdl3.RenderPresent(h.ren)
}

// Como render_text pero sin presentar: la GUI dibuja ImGui encima antes del present.
render_grid :: proc(h: ^Host, snap: ^vga.Text_Snapshot) {
	raw: rawptr
	pitch: c.int
	if !sdl3.LockTexture(h.tex, nil, &raw, &pitch) {
		return
	}
	pitch_px := int(pitch) / size_of(u32)
	pixels := ([^]u32)(raw)[:pitch_px * TEXT_H]
	render_snapshot(pixels, pitch_px, snap)
	sdl3.UnlockTexture(h.tex)

	sdl3.SetRenderDrawColor(h.ren, 0, 0, 0, 255)
	sdl3.RenderClear(h.ren)
	dst := sdl3.FRect{0, MENU_H, TEXT_W * 2, TEXT_H * 2}
	sdl3.RenderTexture(h.ren, h.tex, nil, &dst)
}
