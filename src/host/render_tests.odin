// SPDX-License-Identifier: GPL-3.0-only
package host

import "../vga"
import "core:image/png"
import "core:testing"
import sdl3 "vendor:sdl3"

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
	snap.columns = TEXT_COLS
	snap.rows = TEXT_ROWS
	snap.cell_count = TEXT_COLS * TEXT_ROWS
	snap.cells[0] = u16('A') | 0x1E << 8 // yellow on blue
	snap.cells[1] = u16(' ') | 0x07 << 8 // gray on black
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

@(test)
host_test_render_snapshot_uses_snapshot_geometry :: proc(t: ^testing.T) {
	snap: vga.Text_Snapshot
	snap.columns = 2
	snap.rows = 1
	snap.cell_count = 2
	snap.cells[0] = u16('A') | 0x1E << 8
	snap.cells[1] = u16(' ') | 0x07 << 8
	width, height := snapshot_pixel_size(&snap)
	testing.expect_value(t, width, 2 * CELL_W)
	testing.expect_value(t, height, CELL_H)

	buf := make([]u32, width * height)
	defer delete(buf)
	render_snapshot(buf[:], width, &snap)
	testing.expect_value(t, buf[7 * width], u32(0xFFFFFF55))
	testing.expect_value(t, buf[0 * width + CELL_W], u32(0xFF000000))
}

@(test)
host_test_stopped_screen_uses_the_client_area :: proc(t: ^testing.T) {
	screen := stopped_screen_rect(
		WIN_W,
		WIN_H,
		{
			top = f32(MENU_BAR_H),
			right = f32(STORAGE_SIDEBAR_EXPANDED_W + STORAGE_SIDEBAR_GAP),
			bottom = f32(STATUS_BAR_H),
		},
	)
	testing.expect_value(t, screen.x, f32(0))
	testing.expect_value(t, screen.y, f32(MENU_BAR_H))
	testing.expect_value(t, screen.w, f32(TEXT_W * DEFAULT_WINDOW_SCALE))
	testing.expect_value(t, screen.h, f32(TEXT_H * DEFAULT_WINDOW_SCALE))
}

@(test)
host_test_stopped_screen_follows_the_collapsed_sidebar :: proc(t: ^testing.T) {
	h := Host {
		menu_reveal       = 1,
		sidebar_collapsed = true,
	}
	screen := stopped_screen_rect(WIN_W, WIN_H, host_client_insets(&h))
	testing.expect_value(
		t,
		screen.w,
		f32(WIN_W - STORAGE_SIDEBAR_COLLAPSED_W - STORAGE_SIDEBAR_GAP),
	)
	logo := stopped_logo_rect(screen, 460, 222)
	testing.expect_value(t, logo.x + logo.w + STOPPED_SCREEN_LOGO_MARGIN, screen.x + screen.w)
	testing.expect_value(t, logo.y + logo.h + STOPPED_SCREEN_LOGO_MARGIN, screen.y + screen.h)
}

@(test)
host_test_stopped_logo_is_inset_from_the_bottom_right :: proc(t: ^testing.T) {
	screen := sdl3.FRect{0, f32(MENU_BAR_H), 1440, 800}
	logo := stopped_logo_rect(screen, 460, 222)
	testing.expect_value(t, logo.x, f32(956))
	testing.expect_value(t, logo.y, f32(MENU_BAR_H + 554))
	testing.expect_value(t, logo.w, f32(460))
	testing.expect_value(t, logo.h, f32(222))
	testing.expect_value(t, logo.x + logo.w + STOPPED_SCREEN_LOGO_MARGIN, screen.x + screen.w)
	testing.expect_value(t, logo.y + logo.h + STOPPED_SCREEN_LOGO_MARGIN, screen.y + screen.h)
}

@(test)
host_test_stopped_logo_scales_down_with_the_screen :: proc(t: ^testing.T) {
	screen := sdl3.FRect{10, 20, 720, 400}
	logo := stopped_logo_rect(screen, 460, 222)
	testing.expect_value(t, logo.w, f32(230))
	testing.expect_value(t, logo.h, f32(111))
	testing.expect_value(t, logo.x, f32(488))
	testing.expect_value(t, logo.y, f32(297))
	testing.expect(t, logo.x >= screen.x && logo.y >= screen.y)
	testing.expect(t, logo.x + logo.w <= screen.x + screen.w)
	testing.expect(t, logo.y + logo.h <= screen.y + screen.h)
}

@(test)
host_test_stopped_logo_asset_decodes_at_native_size :: proc(t: ^testing.T) {
	img, err := png.load_from_bytes(STOPPED_SCREEN_LOGO_PNG, {.alpha_add_if_missing})
	defer png.destroy(img)
	if !testing.expect(t, err == nil && img != nil) {return}
	testing.expect_value(t, img.width, 460)
	testing.expect_value(t, img.height, 222)
}
