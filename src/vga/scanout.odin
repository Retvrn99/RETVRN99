// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

// Pixel expansion follows the VGA memory organization documented by and
// selectively adapted from DOSBox-X vga_draw.cpp at commit f3483ce. See
// DOSBOX_X_NOTICE.md for copyright and license provenance.

vga_text_snapshot :: proc(v: ^Vga) -> Text_Snapshot {
	snapshot: Text_Snapshot
	if v.vram == nil {return snapshot}
	kind, width, height := display_geometry(v)
	if kind != .Text || width <= 0 || height <= 0 {return snapshot}
	character_width := v.cga.active ? 8 : (v.seq[1] & 1 != 0 ? 8 : 9)
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	columns := clamp(width / max(character_width, 1), 1, TEXT_SNAPSHOT_MAX_COLUMNS)
	rows := clamp(height / character_height, 1, TEXT_SNAPSHOT_MAX_ROWS)
	snapshot.columns = columns
	snapshot.rows = rows
	snapshot.cell_count = columns * rows
	start := int(display_start(v))
	pitch := v.cga.active ? columns : int(v.crtc[0x13]) * 2
	if pitch <= 0 {pitch = columns}
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			cell := (start + row * pitch + column) & 0x3fff
			character := plane_byte(v, 0, cell)
			attribute := plane_byte(v, 1, cell)
			snapshot.cells[row * columns + column] = u16(character) | u16(attribute) << 8
		}
	}
	cursor := int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])
	relative := (cursor - start) & 0xffff
	if pitch > 0 {
		snapshot.cursor_row = relative / pitch
		snapshot.cursor_col = relative % pitch
	}
	snapshot.cursor_on =
		pitch > 0 &&
		v.crtc[0x0A] & 0x20 == 0 &&
		snapshot.cursor_row >= 0 &&
		snapshot.cursor_row < rows &&
		snapshot.cursor_col >= 0 &&
		snapshot.cursor_col < columns
	return snapshot
}

// Compatibility with the old text-only interface. Text is always decoded
// from VGA planes; guest_ram is deliberately ignored.
vga_snapshot :: proc(v: ^Vga, guest_ram: []u8) -> Text_Snapshot {
	_ = guest_ram
	return vga_text_snapshot(v)
}

vga_display_frame :: proc(v: ^Vga) -> ^Display_Frame {
	return vga_display_frame_replay(v, nil)
}

// A nil or empty journal expands exactly as before; otherwise the mid-frame
// deltas are replayed scan line by scan line as expansion passes them.
@(private = "package")
vga_display_frame_replay :: proc(v: ^Vga, journal: ^Raster_Journal) -> ^Display_Frame {
	replay := raster_journal_active(journal)
	output_enabled := video_output_enabled(v)
	if !replay && v.frame_valid && output_enabled {return &v.frame}
	if !output_enabled {v.frame_valid = false}
	kind, width, height := display_geometry(v)
	if width <= 0 || height <= 0 || width > DISPI_MAX_XRES || height > DISPI_MAX_YRES {
		v.frame = {}
		return &v.frame
	}
	needed := width * height
	if len(v.frame_pixels) != needed {
		if v.frame_pixels != nil {delete(v.frame_pixels, v.allocator)}
		v.frame_pixels = make([]u32, needed, v.allocator)
	}
	for &pixel in v.frame_pixels {pixel = 0xFF000000}
	v.frame.kind = kind
	v.frame.width = width
	v.frame.height = height
	v.frame.aspect_width = width
	v.frame.aspect_height = height
	if !vga_vbe_enabled(v) {
		v.frame.aspect_width = 4
		v.frame.aspect_height = 3
	}
	v.frame.generation = v.timing.generation
	v.frame.content_generation = v.content_generation
	v.frame.guest_activity_generation = v.guest_activity_generation
	v.frame.pixels = v.frame_pixels
	v.frame.text = {}
	v.frame.dirty = contract.rect_set_full({u32(width), u32(height)})
	v.frame.updated_pixels = u64(needed)
	v.frame.overscan = overscan_color(v)
	v.frame.border = vga_frame_border(v)
	if !output_enabled {return &v.frame}
	if replay {
		raster_journal_render(v, journal, v.frame_pixels, kind, width, height)
		if kind == .Text {v.frame.text = vga_text_snapshot(v)}
		v.full_frame_renders += 1
		v.frame_valid = true
		return &v.frame
	}
	switch kind {
	case .Text:
		v.frame.text = vga_text_snapshot(v)
		render_text(v, v.frame_pixels, width, height)
	case .Planar_4:
		if vga_vbe_enabled(
			v,
		) {render_vbe(v, v.frame_pixels, width, height)} else {render_planar(v, v.frame_pixels, width, height)}
	case .Cga_2:
		render_cga(v, v.frame_pixels, width, height)
	case .Cga_1:
		render_cga_1(v, v.frame_pixels, width, height)
	case .Indexed_8:
		if vga_vbe_enabled(
			v,
		) {render_vbe(v, v.frame_pixels, width, height)} else {render_indexed_legacy(v, v.frame_pixels, width, height)}
	case .Rgb_555, .Rgb_565, .Rgb_888, .Xrgb_8888:
		render_vbe(v, v.frame_pixels, width, height)
	case .Invalid:
	}
	v.full_frame_renders += 1
	v.frame_valid = true
	return &v.frame
}

@(private = "package")
scanout_sync :: proc(v: ^Vga, old_ns, now_ns: u64) {
	period := max(v.timing.frame_period_ns, u64(1))
	old_frame := old_ns / period
	new_frame := now_ns / period
	start_latch := start_retrace_crossed(v, old_ns, now_ns)
	if v.defer_scanout_conversion {
		v.raster_valid = false
		if start_latch {latch_display_start(v)}
		if v.raster_fallback && new_frame >= v.raster_change_frame + 3 {
			v.raster_fallback = false
		}
		return
	}
	if !v.raster_fallback {
		v.raster_valid = false
		if start_latch {latch_display_start(v)}
		return
	}
	if !video_output_enabled(v) || period < 1_000_000 {
		v.raster_valid = false
		if start_latch {latch_display_start(v)}
		return
	}
	scanout_prepare(v, old_frame)
	if !v.raster_valid {return}
	if new_frame == old_frame {
		scanout_capture_through_time(v, now_ns % period)
		if start_latch {latch_display_start(v)}
		return
	}
	scanout_capture_through_line(v, v.raster_height - 1)
	scanout_finalize(v)
	if start_latch {latch_display_start(v)}
	if new_frame >= v.raster_change_frame + 3 {
		v.raster_fallback = false
		v.raster_valid = false
		return
	}
	scanout_prepare(v, new_frame)
	scanout_capture_through_time(v, now_ns % period)
}

@(private = "package")
scanout_begin_raster_change :: proc(v: ^Vga, now_ns: u64) {
	if v.defer_scanout_conversion {return}
	period := max(v.timing.frame_period_ns, u64(1))
	scanout_prepare(v, now_ns / period)
	if v.raster_valid {scanout_capture_through_time(v, now_ns % period)}
}

@(private = "file")
scanout_prepare :: proc(v: ^Vga, frame_number: u64) {
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {v.raster_valid = false; return}
	changed :=
		!v.raster_valid ||
		v.raster_kind != kind ||
		v.raster_width != width ||
		v.raster_height != height ||
		v.raster_frame != frame_number
	if !changed {return}
	needed := width * height
	if len(v.raster_pixels) != needed {
		if v.raster_pixels != nil {delete(v.raster_pixels, v.allocator)}
		v.raster_pixels = make([]u32, needed, v.allocator)
	}
	for &pixel in v.raster_pixels {pixel = 0xFF000000}
	v.raster_kind = kind
	v.raster_width = width
	v.raster_height = height
	v.raster_next_line = 0
	v.raster_frame = frame_number
	v.raster_valid = true
}

@(private = "file")
scanout_capture_through_time :: proc(v: ^Vga, frame_time_ns: u64) {
	line_ns := max(v.timing.line_period_ns, u64(1))
	physical_line := min(int(frame_time_ns / line_ns), max(v.timing.visible_lines - 1, 0))
	logical_line := physical_line * v.raster_height / max(v.timing.visible_lines, 1)
	scanout_capture_through_line(v, logical_line)
}

@(private = "file")
scanout_capture_through_line :: proc(v: ^Vga, last_line: int) {
	if !v.raster_valid {return}
	last := min(last_line, v.raster_height - 1)
	for y := v.raster_next_line; y <= last; y += 1 {
		render_scanline(v, v.raster_pixels, v.raster_kind, v.raster_width, v.raster_height, y)
		v.raster_pixels_rendered += u64(v.raster_width)
	}
	v.raster_next_line = max(v.raster_next_line, last + 1)
}

@(private = "file")
scanout_finalize :: proc(v: ^Vga) {
	if !v.raster_valid {return}
	temporary := v.frame_pixels
	v.frame_pixels = v.raster_pixels
	v.raster_pixels = temporary
	v.present_generation += 1
	v.frame.kind = v.raster_kind
	v.frame.width = v.raster_width
	v.frame.height = v.raster_height
	v.frame.aspect_width = v.raster_width
	v.frame.aspect_height = v.raster_height
	if !vga_vbe_enabled(v) {v.frame.aspect_width = 4; v.frame.aspect_height = 3}
	v.frame.generation = v.present_generation
	v.frame.content_generation = v.content_generation
	v.frame.guest_activity_generation = v.guest_activity_generation
	v.frame.pixels = v.frame_pixels
	v.frame.text = v.raster_kind == .Text ? vga_text_snapshot(v) : Text_Snapshot{}
	v.frame.overscan = overscan_color(v)
	v.frame.border = vga_frame_border(v)
	v.frame_valid = true
	v.raster_valid = false
}

render_scanline :: proc(v: ^Vga, pixels: []u32, kind: Display_Kind, width, height, y: int) {
	render_scanline_span(v, pixels, kind, width, height, y, 0, width)
}

@(private = "package")
render_scanline_span :: proc(
	v: ^Vga,
	pixels: []u32,
	kind: Display_Kind,
	width, height, y, x0, x1: int,
) {
	start := clamp(x0, 0, width)
	end := clamp(x1, start, width)
	if start >= end || y < 0 || y >= height {return}
	if !video_output_enabled(v) {
		for x in start ..< end {pixels[y * width + x] = 0xFF000000}
		return
	}
	switch kind {
	case .Text:
		render_text_scanline(v, pixels, width, height, y, start, end)
	case .Planar_4:
		if vga_vbe_enabled(
			v,
		) {render_vbe_scanline(v, pixels, width, y, start, end)} else {render_planar_scanline(v, pixels, width, y, start, end)}
	case .Cga_2:
		render_cga_scanline(v, pixels, width, y, start, end)
	case .Cga_1:
		render_cga_1_scanline(v, pixels, width, y, start, end)
	case .Indexed_8:
		if vga_vbe_enabled(
			v,
		) {render_vbe_scanline(v, pixels, width, y, start, end)} else {render_indexed_scanline(v, pixels, width, y, start, end)}
	case .Rgb_555, .Rgb_565, .Rgb_888, .Xrgb_8888:
		render_vbe_scanline(v, pixels, width, y, start, end)
	case .Invalid:
	}
}

@(private = "file")
render_text_scanline :: proc(v: ^Vga, pixels: []u32, width, height, y, x0, x1: int) {
	character_width := v.cga.active ? 8 : (v.seq[1] & 1 != 0 ? 8 : 9)
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	columns := width / character_width
	if y < 0 || y >= height {return}
	first_line := legacy_split_first_line(v, .Text)
	below_split := y >= first_line
	origin_line := below_split ? first_line : 0
	start := below_split ? 0 : int(display_start(v))
	effective_line := y - origin_line + legacy_preset_row(v, below_split)
	row := effective_line / character_height
	glyph_y := effective_line % character_height
	pitch := v.cga.active ? columns * 2 : int(v.crtc[0x13]) * 2
	byte_pan := v.cga.active ? 0 : legacy_byte_pan(v, below_split)
	pan := v.cga.active ? 0 : legacy_text_pel_pan(v, below_split, character_width)
	font_a, font_b := font_blocks(v)
	blink_on := (v.timing.elapsed_ns / 500_000_000) & 1 == 0
	cursor := int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])
	cursor = (cursor + int(v.crtc[0x0B] >> 5 & 3)) & 0x3fff
	cursor_raw := cursor * 2
	cursor_start := int(v.crtc[0x0A] & 0x1F)
	cursor_end := int(v.crtc[0x0B] & 0x1F)
	// The CRT Controller drives the cursor from a latch rather than a range
	// compare. It sets at Cursor Start and clears at Cursor End or at the last
	// scan line of the character cell, so an end below the start runs to the
	// bottom of the cell instead of wrapping into the top of it.
	cursor_line :=
		glyph_y >= cursor_start && (cursor_end < cursor_start || glyph_y <= cursor_end)
	// Attribute Controller 10h bit 1 reinterprets the attribute byte with
	// monochrome semantics, which is also the only mode in which the underline
	// attribute exists. CRT Controller 14h names the scan line it lands on.
	monochrome := !v.cga.active && v.attr[0x10] & 0x02 != 0
	underline_row := int(v.crtc[0x14] & 0x1F)
	// The CGA compatibility persona owns one 16 KiB page and its display counter
	// wraps inside it instead of running on into the rest of video memory.
	page_mask := v.cga.active ? 0x3fff : 0x7fff
	for column in 0 ..= columns {
		cell_origin := column * character_width - pan
		if cell_origin + character_width <= x0 || cell_origin >= x1 {continue}
		cell := (start + row * pitch + column) & (page_mask >> 1)
		raw := (cell * 2 + byte_pan) & page_mask
		character := legacy_text_byte(v, raw)
		attribute := legacy_text_byte(v, raw + 1)
		foreground := attribute & 0x0F
		font_base := (attribute & 0x08 != 0 ? font_b : font_a) * 8192
		if v.cga.active {font_base = 0}
		if !v.cga.active && font_a != font_b {foreground &= 7}
		background := attribute >> 4
		blink_enabled :=
			v.cga.active ? v.cga.mode_control & CGA_MODE_BLINK != 0 : v.attr[0x10] & 0x08 != 0
		if monochrome {
			// Bit 3 intensifies here even when a second font block is loaded, which
			// is why the colour path's font-select masking above is left behind.
			foreground, background = legacy_monochrome_attribute(attribute)
			if blink_enabled && attribute & 0x80 != 0 && !blink_on {foreground = background}
		} else if blink_enabled {
			background &= 7
			if attribute & 0x80 != 0 && !blink_on {foreground = background}
		}
		fg := v.cga.active ? CGA_COLORS[int(foreground & 0x0F)] : attribute_color(v, foreground)
		bg := v.cga.active ? CGA_COLORS[int(background & 0x0F)] : attribute_color(v, background)
		cursor_here := v.crtc[0x0A] & 0x20 == 0 && blink_on && cursor_line && raw == cursor_raw
		if cursor_here {temporary := fg; fg = bg; bg = temporary}
		bits := plane_byte(v, 2, font_base + int(character) * 32 + min(glyph_y, 31))
		// The underline runs the full width of the cell, ninth dot included, and
		// blinks with the character because it is drawn in the foreground the blink
		// already resolved.
		underline := monochrome && glyph_y == underline_row && attribute & 0x07 == 0x01
		for glyph_x in 0 ..< character_width {
			x := cell_origin + glyph_x
			if x < x0 || x >= x1 {continue}
			set := glyph_x < 8 && bits & (u8(0x80) >> uint(glyph_x)) != 0
			if glyph_x == 8 &&
			   character >= 0xC0 &&
			   character <= 0xDF &&
			   v.attr[0x10] & 0x04 != 0 {set = bits & 1 != 0}
			pixels[y * width + x] = set || underline ? fg : bg
		}
	}
}

// The status multiplexer wants the Attribute Controller output for a single
// pixel rather than a whole scan line, so it resolves one cell here. Everything
// character-specific uses the same helpers render_text_scanline does.
@(private = "file")
text_palette_index :: proc(v: ^Vga, x, y: int) -> u8 {
	character_width := v.seq[1] & 1 != 0 ? 8 : 9
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	first_line := legacy_split_first_line(v, .Text)
	below_split := y >= first_line
	origin_line := below_split ? first_line : 0
	start := below_split ? 0 : int(display_start(v))
	effective_line := y - origin_line + legacy_preset_row(v, below_split)
	row := effective_line / character_height
	glyph_y := effective_line % character_height
	panned := x + legacy_text_pel_pan(v, below_split, character_width)
	column := panned / character_width
	glyph_x := panned % character_width
	cell := (start + row * int(v.crtc[0x13]) * 2 + column) & 0x3fff
	raw := (cell * 2 + legacy_byte_pan(v, below_split)) & 0x7fff
	character := legacy_text_byte(v, raw)
	attribute := legacy_text_byte(v, raw + 1)
	font_a, font_b := font_blocks(v)
	font_base := (attribute & 0x08 != 0 ? font_b : font_a) * 8192
	foreground := attribute & 0x0F
	if font_a != font_b {foreground &= 7}
	background := attribute >> 4
	blink_enabled := v.attr[0x10] & 0x08 != 0
	blink_on := (v.timing.elapsed_ns / 500_000_000) & 1 == 0
	if v.attr[0x10] & 0x02 != 0 {
		foreground, background = legacy_monochrome_attribute(attribute)
		if blink_enabled && attribute & 0x80 != 0 && !blink_on {foreground = background}
	} else if blink_enabled {
		background &= 7
		if attribute & 0x80 != 0 && !blink_on {foreground = background}
	}
	cursor := int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])
	cursor = (cursor + int(v.crtc[0x0B] >> 5 & 3)) & 0x3fff
	cursor_start := int(v.crtc[0x0A] & 0x1F)
	cursor_end := int(v.crtc[0x0B] & 0x1F)
	cursor_line :=
		glyph_y >= cursor_start && (cursor_end < cursor_start || glyph_y <= cursor_end)
	if v.crtc[0x0A] & 0x20 == 0 && blink_on && cursor_line && raw == cursor * 2 {
		foreground, background = background, foreground
	}
	bits := plane_byte(v, 2, font_base + int(character) * 32 + min(glyph_y, 31))
	set := glyph_x < 8 && bits & (u8(0x80) >> uint(glyph_x)) != 0
	if glyph_x == 8 && character >= 0xC0 && character <= 0xDF && v.attr[0x10] & 0x04 != 0 {
		set = bits & 1 != 0
	}
	underline := v.attr[0x10] & 0x02 != 0 && glyph_y == int(v.crtc[0x14] & 0x1F) &&
		attribute & 0x07 == 0x01
	return attribute_palette_index(v, set || underline ? foreground : background)
}

// IBM 2-15 to 2-17. A monochrome attribute carries no colour. Bits 0-2 and 4-6
// select one of three cell forms, bit 3 intensifies the foreground and bit 7
// blinks it, and the resulting index still resolves through the internal palette
// and the DAC like any other. Everything with foreground and background both
// blank is invisible, the one reverse-video combination puts a blank foreground
// on a bright background, and every other combination is foreground on blank.
// Behaviour derived from the 86Box EGA text renderer; see 86BOX_NOTICE.md.
@(private = "file")
legacy_monochrome_attribute :: proc(attribute: u8) -> (foreground, background: u8) {
	intense := attribute & 0x08 != 0 ? u8(15) : u8(7)
	switch attribute & 0x77 {
	case 0x00:
		return 0, 0
	case 0x70:
		return attribute & 0x08 != 0 ? 7 : 0, 15
	}
	return intense, 0
}

@(private = "file")
render_planar_scanline :: proc(v: ^Vga, pixels: []u32, width, y, x0, x1: int) {
	geometry := legacy_graphics_row(v, .Planar_4, y)
	pan := legacy_pel_pan(v, geometry.below_split)
	for x in x0 ..< x1 {
		source_x := x + pan
		address := legacy_display_counter(v, geometry.row_base, u32(source_x / 8))
		offset := legacy_display_offset(v, address, geometry.row_scan)
		bit := u8(0x80) >> uint(source_x & 7)
		color: u8
		for plane in 0 ..< 4 {
			if v.attr[0x12] & (u8(1) << uint(plane)) != 0 &&
			   plane_byte(v, plane, offset) & bit != 0 {color |= u8(1) << uint(plane)}
		}
		pixels[y * width + x] = attribute_color(v, color)
	}
}

@(private = "file")
render_indexed_scanline :: proc(v: ^Vga, pixels: []u32, width, y, x0, x1: int) {
	geometry := legacy_graphics_row(v, .Indexed_8, y)
	pan := legacy_indexed_pel_pan(v, geometry.below_split)
	chained := v.seq[4] & 0x08 != 0
	for x in x0 ..< x1 {
		source_x := x + pan
		plane := source_x & 3
		offset: int
		if chained {
			offset = int(geometry.row_base + u32(source_x / 4)) & (LEGACY_PLANE_SIZE - 1)
		} else {
			address := legacy_display_counter(v, geometry.row_base, u32(source_x / 4))
			offset = legacy_display_offset(v, address, geometry.row_scan)
		}
		pixels[y * width + x] = dac_color(v, plane_byte(v, plane, offset))
	}
}

@(private = "file")
render_cga_scanline :: proc(v: ^Vga, pixels: []u32, width, y, x0, x1: int) {
	pitch := max(width / 4, 1)
	start := int(display_start(v)) * 2
	row := (y & 1) * 0x2000 + (y >> 1) * pitch
	for x in x0 ..< x1 {
		value := legacy_linear_byte(v, (start + row + x / 4) & 0x3fff)
		shift := uint(6 - (x & 3) * 2)
		pixel := (value >> shift) & 3
		pixels[y * width + x] = v.cga.active ? cga_color(v, pixel) : attribute_color(v, pixel)
	}
}

@(private = "file")
render_vbe_scanline :: proc(v: ^Vga, pixels: []u32, width, y, x0, x1: int) {
	pitch := vga_vbe_pitch(v)
	x_offset := int(v.dispi[DISPI_INDEX_X_OFFSET])
	row := (y + int(v.dispi[DISPI_INDEX_Y_OFFSET])) * pitch
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	for x in x0 ..< x1 {
		source_x := x + x_offset
		pixels[y * width + x] = vbe_pixel(v, row, source_x, bpp)
	}
}

@(private = "file")
vbe_pixel :: proc(v: ^Vga, row, source_x, bpp: int) -> u32 {
	switch bpp {
	case 4:
		byte_offset := row + source_x / 8
		bit := u8(0x80) >> uint(source_x & 7)
		index: u8
		for plane in 0 ..< 4 {if plane_byte(v, plane, byte_offset) & bit != 0 {index |= u8(1) << uint(plane)}}
		return dac_color(v, index)
	case 8:
		return dac_color(v, v.vram[row + source_x])
	case 15:
		offset := row + source_x * 2
		value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
		r := u8((value >> 10) & 0x1F); g := u8((value >> 5) & 0x1F); b := u8(value & 0x1F)
		return(
			0xFF000000 |
			u32(r << 3 | r >> 2) << 16 |
			u32(g << 3 | g >> 2) << 8 |
			u32(b << 3 | b >> 2) \
		)
	case 16:
		offset := row + source_x * 2
		value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
		r := u8((value >> 11) & 0x1F); g := u8((value >> 5) & 0x3F); b := u8(value & 0x1F)
		return(
			0xFF000000 |
			u32(r << 3 | r >> 2) << 16 |
			u32(g << 2 | g >> 4) << 8 |
			u32(b << 3 | b >> 2) \
		)
	case 24:
		offset := row + source_x * 3
		return(
			0xFF000000 |
			u32(v.vram[offset + 2]) << 16 |
			u32(v.vram[offset + 1]) << 8 |
			u32(v.vram[offset]) \
		)
	case 32:
		offset := row + source_x * 4
		return(
			0xFF000000 |
			u32(v.vram[offset + 2]) << 16 |
			u32(v.vram[offset + 1]) << 8 |
			u32(v.vram[offset]) \
		)
	}
	return 0xFF000000
}

@(private = "package")
display_start :: proc(v: ^Vga) -> u16 {
	if v.start_pending && v.timing.elapsed_ns == 0 {return v.pending_start}
	return v.latched_start
}

@(private = "package")
display_geometry :: proc(v: ^Vga) -> (Display_Kind, int, int) {
	if vga_vbe_enabled(v) {
		kind: Display_Kind
		switch v.dispi[DISPI_INDEX_BPP] {
		case 4:
			kind = .Planar_4
		case 8:
			kind = .Indexed_8
		case 15:
			kind = .Rgb_555
		case 16:
			kind = .Rgb_565
		case 24:
			kind = .Rgb_888
		case 32:
			kind = .Xrgb_8888
		case:
			return .Invalid, 0, 0
		}
		return kind, int(v.dispi[DISPI_INDEX_XRES]), int(v.dispi[DISPI_INDEX_YRES])
	}
	if v.cga.active {
		columns := max(int(v.crtc[0x01]), 1)
		character_width := cga_character_width(v)
		height := max(int(v.crtc[0x06]) * (int(v.crtc[0x09] & 0x1F) + 1), 1)
		if v.cga.mode_control & CGA_MODE_GRAPHICS != 0 {
			kind :=
				v.cga.mode_control & CGA_MODE_HIGH_RES != 0 ? Display_Kind.Cga_1 : Display_Kind.Cga_2
			return kind, columns * character_width, height
		}
		return .Text, columns * 8, height
	}
	graphics := v.gfx[6] & 1 != 0 || v.attr[0x10] & 1 != 0
	if !graphics {
		character_width := v.seq[1] & 1 != 0 ? 8 : 9
		character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
		columns := max(int(v.crtc[1]) + 1, 1)
		rows := max(v.timing.visible_lines / character_height, 1)
		return .Text, columns * character_width, rows * character_height
	}
	width := max(v.timing.visible_dots, 1)
	height := max(v.timing.visible_lines, 1)
	shift := v.gfx[5] & 0x60
	if shift == 0x40 {width = max(width / 2, 1)}
	repeat := legacy_graphics_scan_factor(v)
	height = max(height / repeat, 1)
	if shift == 0x40 {return .Indexed_8, width, height}
	if shift == 0x20 {return .Cga_2, width, height}
	if (v.gfx[6] >> 2) & 3 == 3 {return .Cga_1, width, height}
	return .Planar_4, width, height
}

@(private = "package")
video_output_enabled :: proc(v: ^Vga) -> bool {
	if !legacy_video_subsystem_enabled(v) {return false}
	if v.seq[0] & 3 != 3 {return false}
	if v.cga.active && !vga_vbe_enabled(v) {
		return v.cga.mode_control & CGA_MODE_VIDEO_ENABLE != 0
	}
	return v.video_on && v.seq[1] & 0x20 == 0
}

@(private = "file")
start_retrace_crossed :: proc(v: ^Vga, old_ns, now_ns: u64) -> bool {
	if !v.start_pending || now_ns <= old_ns {return false}
	period := max(v.timing.frame_period_ns, u64(1))
	offset := u64(max(v.timing.retrace_start, 0)) * max(v.timing.line_period_ns, u64(1))
	offset = min(offset, period - 1)
	crossing := old_ns / period * period + offset
	if crossing <= old_ns {crossing += period}
	return crossing <= now_ns
}

@(private = "package")
latch_display_start :: proc(v: ^Vga) {
	if !v.start_pending {return}
	changed := v.latched_start != v.pending_start
	v.latched_start = v.pending_start
	v.start_pending = false
	if changed {
		vga_damage_record_full(v, .Pixel_Memory, .Mode_Boundary)
		vga_note_recorded_change(v, true)
	}
}

@(private = "file")
font_block :: proc(selection: u8) -> int {
	return int((selection & 3) << 1 | (selection >> 2) & 1)
}

@(private = "package")
font_blocks :: proc(v: ^Vga) -> (a, b: int) {
	a_select := v.seq[3] & 3 | (v.seq[3] >> 2) & 4
	b_select := (v.seq[3] >> 2) & 3 | (v.seq[3] >> 3) & 4
	return font_block(a_select), font_block(b_select)
}

@(private = "file")
dac_color :: proc(v: ^Vga, index: u8) -> u32 {
	palette_index := index & v.pel_mask
	i := int(palette_index) * 3
	r := v.dac[i + 0]
	g := v.dac[i + 1]
	b := v.dac[i + 2]
	if v.dispi[DISPI_INDEX_ENABLE] & DISPI_8BIT_DAC == 0 {
		r = r << 2 | r >> 4
		g = g << 2 | g >> 4
		b = b << 2 | b >> 4
	}
	return 0xFF000000 | u32(r) << 16 | u32(g) << 8 | u32(b)
}

@(private = "package")
attribute_palette_index :: proc(v: ^Vga, color: u8) -> u8 {
	palette := v.attr[color & v.attr[0x12] & 0x0F] & 0x3F
	if v.attr[0x10] & 0x80 != 0 {
		palette = (palette & 0x0F) | (v.attr[0x14] & 0x0F) << 4
	} else {
		palette |= (v.attr[0x14] & 0x0C) << 4
	}
	return palette & v.pel_mask
}

@(private = "file")
attribute_color :: proc(v: ^Vga, color: u8) -> u32 {
	return dac_color(v, attribute_palette_index(v, color))
}

// The border colour the display shows outside the active image. The CGA
// persona takes it from the colour-select register; every other persona takes
// it from Attribute Controller 11h. A blanked or reset subsystem shows black.
@(private = "package")
overscan_color :: proc(v: ^Vga) -> u32 {
	if !video_output_enabled(v) {return 0xFF00_0000}
	if v.cga.active && !vga_vbe_enabled(v) {
		return CGA_COLORS[int(v.cga.color_select & 0x0F)]
	}
	if vga_vbe_enabled(v) {return 0xFF00_0000}
	return attribute_color(v, v.attr[0x11])
}

// The published border in the shape a frame carries it.
@(private = "file")
vga_frame_border :: proc(v: ^Vga) -> contract.Border {
	left, right, top, bottom := border_extents(v)
	return {u32(left), u32(right), u32(top), u32(bottom)}
}

// The border the display shows around the active image, in image pixels per side
// (ADR 0012). A raster line runs active, trailing border, blanking, then leading
// border before the next line's active area, so the trailing side is the gap
// between display end and blank start and the leading side is the gap between
// blank end and the end of the line. The vertical axis works the same way.
//
// The pixel buffer never carries border pixels; presentation paints a border of
// this proportion around the scaled canvas instead. Stock VGA modes program a few
// pixels of it, so the common frame is very nearly unchanged.
@(private = "package")
border_extents :: proc(v: ^Vga) -> (left, right, top, bottom: int) {
	if v == nil {return}
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {return}
	dots := max(v.timing.visible_dots, 1)
	lines := max(v.timing.visible_lines, 1)
	// A border wider than the image it surrounds is a misprogrammed raster rather
	// than an effect, so each side is clamped instead of being allowed to swallow
	// the canvas the host scales into it.
	side :: proc(span, visible, image: int) -> int {
		return min(max(span, 0) * image / visible, image)
	}
	left = side(v.timing.total_dots - v.timing.hblank_end, dots, width)
	right = side(v.timing.hblank_start - v.timing.visible_dots, dots, width)
	top = side(v.timing.total_lines - v.timing.vblank_end, lines, height)
	bottom = side(v.timing.vblank_start - v.timing.visible_lines, lines, height)
	return
}

@(private = "file")
render_text :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height {render_text_scanline(v, pixels, width, height, y, 0, width)}
}

@(private = "file")
render_planar :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height {render_planar_scanline(v, pixels, width, y, 0, width)}
}

@(private = "file")
render_indexed_legacy :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height {render_indexed_scanline(v, pixels, width, y, 0, width)}
}

@(private = "file")
legacy_linear_byte :: proc(v: ^Vga, raw: int) -> u8 {
	if v.seq[4] & 0x08 != 0 {return plane_byte(v, raw & 3, raw >> 2)}
	if v.seq[4] & 0x04 == 0 {return plane_byte(v, raw & 1, raw >> 1)}
	return plane_byte(v, 0, raw)
}

@(private = "file")
render_cga :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height {render_cga_scanline(v, pixels, width, y, 0, width)}
}

@(private = "file")
render_cga_1 :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height {render_cga_1_scanline(v, pixels, width, y, 0, width)}
}

@(private = "file")
render_cga_1_scanline :: proc(v: ^Vga, pixels: []u32, width, y, x0, x1: int) {
	pitch := max(width / 8, 1)
	start := int(display_start(v)) * 2
	row := (y & 1) * 0x2000 + (y >> 1) * pitch
	for x in x0 ..< x1 {
		value := legacy_linear_byte(v, (start + row + x / 8) & 0x3fff)
		index := value & (u8(0x80) >> uint(x & 7)) != 0 ? u8(1) : u8(0)
		pixels[y * width + x] = v.cga.active ? cga_color(v, index) : attribute_color(v, index)
	}
}

@(private = "package")
vga_status_mux_bits :: proc(v: ^Vga, physical_line, physical_dot: int) -> u8 {
	kind, width, height := display_geometry(v)
	if width <= 0 || height <= 0 || v.timing.visible_dots <= 0 || v.timing.visible_lines <= 0 {
		return 0
	}
	x := min(physical_dot * width / v.timing.visible_dots, width - 1)
	y := min(physical_line * height / v.timing.visible_lines, height - 1)
	color: u8
	#partial switch kind {
	case .Planar_4:
		geometry := legacy_graphics_row(v, kind, y)
		source_x := x + legacy_pel_pan(v, geometry.below_split)
		address := legacy_display_counter(v, geometry.row_base, u32(source_x / 8))
		offset := legacy_display_offset(v, address, geometry.row_scan)
		bit := u8(0x80) >> uint(source_x & 7)
		for plane in 0 ..< 4 {
			if v.attr[0x12] & (u8(1) << uint(plane)) != 0 &&
			   plane_byte(v, plane, offset) & bit != 0 {color |= u8(1) << uint(plane)}
		}
		color = attribute_palette_index(v, color)
	case .Indexed_8:
		geometry := legacy_graphics_row(v, kind, y)
		source_x := x + legacy_indexed_pel_pan(v, geometry.below_split)
		plane := source_x & 3
		offset := int(geometry.row_base + u32(source_x / 4)) & (LEGACY_PLANE_SIZE - 1)
		if v.seq[4] & 0x08 == 0 {
			address := legacy_display_counter(v, geometry.row_base, u32(source_x / 4))
			offset = legacy_display_offset(v, address, geometry.row_scan)
		}
		color = plane_byte(v, plane, offset) & v.pel_mask
	case .Text:
		color = text_palette_index(v, x, y)
	case:
		return 0
	}
	pair: u8
	switch (v.attr[0x12] >> 4) & 3 {
	case 0:
		pair = (color >> 2 & 1) << 1 | color & 1
	case 1:
		pair = color >> 4 & 3
	case 2:
		pair = (color >> 3 & 1) << 1 | color >> 1 & 1
	case 3:
		pair = color >> 6 & 3
	}
	return pair << 4
}

@(private = "file")
render_vbe :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	pitch := vga_vbe_pitch(v)
	x_offset := int(v.dispi[DISPI_INDEX_X_OFFSET])
	y_offset := int(v.dispi[DISPI_INDEX_Y_OFFSET])
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	for y in 0 ..< height {
		row := (y + y_offset) * pitch
		for x in 0 ..< width {
			source_x := x + x_offset
			color: u32
			switch bpp {
			case 4:
				byte_offset := row + source_x / 8
				bit := u8(0x80) >> uint(source_x & 7)
				index: u8
				for plane in 0 ..< 4 {
					if plane_byte(v, plane, byte_offset) & bit != 0 {index |= u8(1) << uint(plane)}
				}
				color = dac_color(v, index)
			case 8:
				color = dac_color(v, v.vram[row + source_x])
			case 15:
				offset := row + source_x * 2
				value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
				r := u8((value >> 10) & 0x1F); g := u8((value >> 5) & 0x1F); b := u8(value & 0x1F)
				color =
					0xFF000000 |
					u32(r << 3 | r >> 2) << 16 |
					u32(g << 3 | g >> 2) << 8 |
					u32(b << 3 | b >> 2)
			case 16:
				offset := row + source_x * 2
				value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
				r := u8((value >> 11) & 0x1F); g := u8((value >> 5) & 0x3F); b := u8(value & 0x1F)
				color =
					0xFF000000 |
					u32(r << 3 | r >> 2) << 16 |
					u32(g << 2 | g >> 4) << 8 |
					u32(b << 3 | b >> 2)
			case 24:
				offset := row + source_x * 3
				color =
					0xFF000000 |
					u32(v.vram[offset + 2]) << 16 |
					u32(v.vram[offset + 1]) << 8 |
					u32(v.vram[offset])
			case 32:
				offset := row + source_x * 4
				color =
					0xFF000000 |
					u32(v.vram[offset + 2]) << 16 |
					u32(v.vram[offset + 1]) << 8 |
					u32(v.vram[offset])
			}
			pixels[y * width + x] = color
		}
	}
}
