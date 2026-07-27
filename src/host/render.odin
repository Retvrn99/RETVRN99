// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
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

snapshot_pixel_size :: proc(snap: ^vga.Text_Snapshot) -> (width, height: int) {
	return vga.text_snapshot_columns(snap) * CELL_W, vga.text_snapshot_rows(snap) * CELL_H
}

// Pure rasterizer: text snapshot cells into an ARGB buffer sized by snapshot_pixel_size.
render_snapshot :: proc(pixels: []u32, pitch_px: int, snap: ^vga.Text_Snapshot) {
	columns := vga.text_snapshot_columns(snap)
	rows := vga.text_snapshot_rows(snap)
	for r in 0 ..< rows {
		for cc in 0 ..< columns {
			cell := snap.cells[vga.text_snapshot_cell_index(snap, r, cc)]
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
	   snap.cursor_row < rows &&
	   snap.cursor_col >= 0 &&
	   snap.cursor_col < columns {
		cell := snap.cells[vga.text_snapshot_cell_index(snap, snap.cursor_row, snap.cursor_col)]
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
	return guest_view_rect_insets(
		aspect_width,
		aspect_height,
		output_width,
		output_height,
		{top = menu_height},
	)
}

guest_view_rect_insets :: proc(
	aspect_width, aspect_height: int,
	output_width, output_height: int,
	insets: Host_Client_Insets,
) -> sdl3.FRect {
	aw := max(1, aspect_width)
	ah := max(1, aspect_height)
	max_width := f32(max(1, output_width))
	max_height := f32(max(1, output_height))
	left := clamp(insets.left, f32(0), max_width - 1)
	top := clamp(insets.top, f32(0), max_height - 1)
	right := clamp(insets.right, f32(0), max_width - left - 1)
	bottom := clamp(insets.bottom, f32(0), max_height - top - 1)
	area_w := max(f32(1), max_width - left - right)
	area_h := max(f32(1), max_height - top - bottom)
	target := f32(aw) / f32(ah)
	w, h := area_w, area_h
	if area_w / area_h > target {
		w = area_h * target
	} else {
		h = area_w / target
	}
	return {left + (area_w - w) * 0.5, top + (area_h - h) * 0.5, w, h}
}

host_border_from_contract :: proc(border: contract.Border) -> Host_Border {
	return {int(border.left), int(border.right), int(border.top), int(border.bottom)}
}

// The published border travels as a proportion rather than as pixels: the canvas
// shrinks inside its view rect and the surround, already painted in the border
// colour, shows through (ADR 0012). The whole raster keeps the display aspect, so
// the active image inside it is the part that is no longer exactly 4:3, which is
// what the hardware does.
host_guest_canvas_rect :: proc(h: ^Host, output_width, output_height: int) -> sdl3.FRect {
	return guest_canvas_rect(
		h.aspect_width,
		h.aspect_height,
		h.border,
		output_width,
		output_height,
		host_client_insets(h),
	)
}

// Taken apart from the Host so the offscreen compositor can reach the same
// arithmetic. Host is far too large to place on a stack just to ask it where the
// canvas goes.
guest_canvas_rect :: proc(
	aspect_width, aspect_height: int,
	border: Host_Border,
	output_width, output_height: int,
	insets: Host_Client_Insets,
) -> sdl3.FRect {
	rect := guest_view_rect_insets(
		aspect_width,
		aspect_height,
		output_width,
		output_height,
		insets,
	)
	if border == {} {return rect}
	total_width := max(aspect_width + border.left + border.right, 1)
	total_height := max(aspect_height + border.top + border.bottom, 1)
	left := rect.w * f32(max(border.left, 0)) / f32(total_width)
	right := rect.w * f32(max(border.right, 0)) / f32(total_width)
	top := rect.h * f32(max(border.top, 0)) / f32(total_height)
	bottom := rect.h * f32(max(border.bottom, 0)) / f32(total_height)
	return {
		rect.x + left,
		rect.y + top,
		max(rect.w - left - right, 1),
		max(rect.h - top - bottom, 1),
	}
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
	return true
}

@(private = "package")
host_cpu_frame_metadata_publish :: proc(h: ^Host, aspect_width, aspect_height: int) {
	if h == nil {return}
	if h.presentation_state.selector.active.kind == .None {h.gpu_present = {}}
	h.aspect_width = aspect_width
	h.aspect_height = aspect_height
	h.has_frame = true
}

@(private = "file")
host_render_texture_region :: proc(
	h: ^Host,
	texture: ^sdl3.Texture,
	texture_width, texture_height: int,
	source: sdl3.FRect,
	has_source: bool,
	destination: sdl3.FRect,
) -> bool {
	if h == nil || texture == nil || texture_width <= 0 || texture_height <= 0 {return false}
	shader_active := host_shader_begin(h, texture_width, texture_height)
	source_rect := source
	destination_rect := destination
	source_ptr: Maybe(^sdl3.FRect)
	if has_source {source_ptr = &source_rect}
	ok := sdl3.RenderTexture(h.ren, texture, source_ptr, &destination_rect)
	if shader_active {host_shader_end(h)}
	return ok
}

@(private = "file")
host_render_resident_composition :: proc(h: ^Host, guest_view: sdl3.FRect) -> bool {
	if h == nil || h.presentation_state.selector.active.source_kind != .Gsw_Resident {return false}
	resident := h.presentation_state.gsw
	ok := true
	needs_desktop := host_presentation_resident_requires_desktop(resident)
	desktop_drawn := !needs_desktop
	desktop := h.presentation_state.gsw_snapshot
	if needs_desktop && host_presentation_gsw_desktop_available(h, resident.header) {
		source := sdl3.FRect {
			f32(desktop.header.source.x),
			f32(desktop.header.source.y),
			f32(desktop.header.source.width),
			f32(desktop.header.source.height),
		}
		destination, valid := host_presentation_guest_rect(
			guest_view,
			desktop.header.destination,
			desktop.header.canvas_extent,
		)
		if valid {
			ok =
				host_render_texture_region(
					h,
					h.presentation_state.gsw_texture,
					h.presentation_state.gsw_texture_width,
					h.presentation_state.gsw_texture_height,
					source,
					true,
					destination,
				) &&
				ok
			desktop_drawn = true
		}
	}
	if !desktop_drawn &&
	   h.tex != nil &&
	   h.presentation_state.selector.has_last_good_legacy &&
	   contract.mode_key_equal(
		   contract.output_mode_key(h.presentation_state.selector.last_good_legacy.header),
		   contract.output_mode_key(resident.header),
	   ) {
		ok =
			host_render_texture_region(
				h,
				h.tex,
				h.tex_width,
				h.tex_height,
				{},
				false,
				guest_view,
			) &&
			ok
	}
	texture, _, has_texture, _ := host_active_gpu_texture(h)
	if texture == nil || !has_texture {return false}
	texture_width, texture_height, valid_extent := host_presentation_resident_texture_extent(
		resident,
	)
	if !valid_extent {return false}
	plan := host_presentation_build_resident_draw_plan(resident, guest_view)
	if !plan.valid {return false}
	for i in 0 ..< int(plan.count) {
		segment := plan.segments[i]
		ok =
			host_render_texture_region(
				h,
				texture,
				texture_width,
				texture_height,
				segment.source,
				true,
				segment.destination,
			) &&
			ok
	}
	return ok
}

host_render_guest :: proc(h: ^Host, machine_running: bool) -> bool {
	if h == nil || !sdl3.IsMainThread() {return false}
	// The surround outside the guest canvas shows the border colour the
	// Attribute Controller selected, not a fixed black.
	red := u8(h.overscan >> 16)
	green := u8(h.overscan >> 8)
	blue := u8(h.overscan)
	if !machine_running || !h.has_frame {red, green, blue = 0, 0, 0}
	ok := sdl3.SetRenderDrawColor(h.ren, red, green, blue, 255)
	ok = sdl3.RenderClear(h.ren) && ok
	output_width, output_height := WIN_W, WIN_H
	w, hh: c.int
	if sdl3.GetRenderOutputSize(h.ren, &w, &hh) {
		output_width = int(w)
		output_height = int(hh)
	}
	if !machine_running {
		host_clear_frame(h)
		host_render_stopped_screen(h, output_width, output_height)
		return ok
	}
	active := h.presentation_state.selector.active
	if active.kind == .Gsw && active.source_kind == .Gsw_Resident && h.has_frame {
		dst := host_guest_canvas_rect(h, output_width, output_height)
		return host_render_resident_composition(h, dst) && ok
	}
	texture, source, has_source, gpu_present := host_active_texture(h)
	if texture != nil && h.has_frame {
		texture_width, texture_height := h.tex_width, h.tex_height
		if active.kind == .Gsw && active.source_kind == .Gsw_Snapshot {
			texture_width = h.presentation_state.gsw_texture_width
			texture_height = h.presentation_state.gsw_texture_height
		} else if gpu_present != nil {
			if surface := host_gpu_surface_find(h, gpu_present.surface_id); surface != nil {
				texture_width = int(surface.descriptor.width)
				texture_height = int(surface.descriptor.height)
			}
		}
		dst := host_guest_canvas_rect(h, output_width, output_height)
		if gpu_present != nil {
			dst = host_gpu_present_destination(dst, gpu_present^)
		} else {
			dst = host_presentation_destination(h, dst)
		}
		ok =
			host_render_texture_region(
				h,
				texture,
				texture_width,
				texture_height,
				source,
				has_source,
				dst,
			) &&
			ok
	}
	return ok
}

host_clear_frame :: proc(h: ^Host) {
	if h != nil {host_presentation_stop(h)}
}

// Upload the rasterized grid at 2x below the menu bar without presenting:
// the GUI draws ImGui on top first.
render_grid :: proc(h: ^Host, snap: ^vga.Text_Snapshot) {
	width, height := snapshot_pixel_size(snap)
	if !host_ensure_texture(h, width, height) {return}
	raw: rawptr
	pitch: c.int
	if !sdl3.LockTexture(h.tex, nil, &raw, &pitch) {
		return
	}
	pitch_px := int(pitch) / size_of(u32)
	pixels := ([^]u32)(raw)[:pitch_px * height]
	render_snapshot(pixels, pitch_px, snap)
	sdl3.UnlockTexture(h.tex)
	h.gpu_present = {}
	h.aspect_width = 4
	h.aspect_height = 3
	h.has_frame = true
	_ = host_render_guest(h, true)
}
