// SPDX-License-Identifier: GPL-3.0-only
package host

import "../vga"
import "core:c"
import sdl3 "vendor:sdl3"

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
	0xFF000000,
	0xFF0000AA,
	0xFF00AA00,
	0xFF00AAAA,
	0xFFAA0000,
	0xFFAA00AA,
	0xFFAA5500,
	0xFFAAAAAA,
	0xFF555555,
	0xFF5555FF,
	0xFF55FF55,
	0xFF55FFFF,
	0xFFFF5555,
	0xFFFF55FF,
	0xFFFFFF55,
	0xFFFFFFFF,
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
	   snap.cursor_row >= 0 &&
	   snap.cursor_row < TEXT_ROWS &&
	   snap.cursor_col >= 0 &&
	   snap.cursor_col < TEXT_COLS {
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

guest_view_rect :: proc(
	aspect_width, aspect_height: int,
	output_width: int = WIN_W,
	output_height: int = WIN_H,
	menu_height: f32 = f32(MENU_BAR_H),
) -> sdl3.FRect {
	aw := max(1, aspect_width)
	ah := max(1, aspect_height)
	area_w := f32(max(1, output_width))
	menu_h := clamp(menu_height, f32(0), f32(max(0, output_height - 1)))
	area_h := max(f32(1), f32(output_height) - menu_h)
	target := f32(aw) / f32(ah)
	w, h := area_w, area_h
	if area_w / area_h > target {
		w = area_h * target
	} else {
		h = area_w / target
	}
	return {(area_w - w) * 0.5, menu_h + (area_h - h) * 0.5, w, h}
}

host_ensure_texture :: proc(h: ^Host, width, height: int) -> bool {
	if width <= 0 || height <= 0 {return false}
	if h.tex != nil && h.tex_width == width && h.tex_height == height {return true}
	if h.tex != nil {sdl3.DestroyTexture(h.tex)}
	h.tex = sdl3.CreateTexture(h.ren, .ARGB8888, .STREAMING, i32(width), i32(height))
	if h.tex == nil {
		h.tex_width = 0
		h.tex_height = 0
		return false
	}
	sdl3.SetTextureScaleMode(h.tex, h.visual_shader == .None ? .NEAREST : .LINEAR)
	h.tex_width = width
	h.tex_height = height
	return true
}

host_upload_frame :: proc(h: ^Host, frame: ^vga.Display_Frame) -> bool {
	if frame == nil || len(frame.pixels) < frame.width * frame.height {return false}
	if !host_ensure_texture(h, frame.width, frame.height) {return false}
	raw: rawptr
	pitch: c.int
	if !sdl3.LockTexture(h.tex, nil, &raw, &pitch) {return false}
	pitch_px := int(pitch) / size_of(u32)
	dst := ([^]u32)(raw)[:pitch_px * frame.height]
	for y in 0 ..< frame.height {
		copy(dst[y * pitch_px:][:frame.width], frame.pixels[y * frame.width:][:frame.width])
	}
	sdl3.UnlockTexture(h.tex)
	h.aspect_width = frame.aspect_width > 0 ? frame.aspect_width : frame.width
	h.aspect_height = frame.aspect_height > 0 ? frame.aspect_height : frame.height
	h.has_frame = true
	return true
}

host_render_guest :: proc(h: ^Host) {
	sdl3.SetRenderDrawColor(h.ren, 0, 0, 0, 255)
	sdl3.RenderClear(h.ren)
	if h.tex != nil && h.has_frame {
		output_width, output_height := WIN_W, WIN_H
		w, hh: c.int
		if sdl3.GetRenderOutputSize(h.ren, &w, &hh) {
			output_width = int(w)
			output_height = int(hh)
		}
		dst := guest_view_rect(
			h.aspect_width,
			h.aspect_height,
			output_width,
			output_height,
			f32(MENU_BAR_H) * h.menu_reveal,
		)
		shader_active := host_shader_begin(h)
		sdl3.RenderTexture(h.ren, h.tex, nil, &dst)
		if shader_active {host_shader_end(h)}
	}
}

host_clear_frame :: proc(h: ^Host) {
	if h != nil {h.has_frame = false}
}

// Upload the rasterized grid at 2x below the menu bar without presenting:
// the GUI draws ImGui on top first.
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
	h.aspect_width = 4
	h.aspect_height = 3
	h.has_frame = true
	host_render_guest(h)
}
