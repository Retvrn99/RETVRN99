// SPDX-License-Identifier: GPL-3.0-only
package vga

// Pixel expansion follows the VGA memory organization documented by and
// selectively adapted from DOSBox-X vga_draw.cpp at commit f3483ce. See
// DOSBOX_X_NOTICE.md for copyright and license provenance.

vga_text_snapshot :: proc(v: ^Vga) -> Text_Snapshot {
	snapshot: Text_Snapshot
	if v.vram == nil { return snapshot }
	start := int(display_start(v))
	for i in 0 ..< 80 * 25 {
		offset := start + i
		character := plane_byte(v, 0, offset)
		attribute := plane_byte(v, 1, offset)
		snapshot.cells[i] = u16(character) | u16(attribute) << 8
	}
	cursor := int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])
	relative := cursor - start
	snapshot.cursor_row = relative / 80
	snapshot.cursor_col = relative % 80
	snapshot.cursor_on = v.crtc[0x0A] & 0x20 == 0 && relative >= 0 && relative < 80 * 25
	return snapshot
}

// Compatibility with the old text-only interface. Text is always decoded
// from VGA planes; guest_ram is deliberately ignored.
vga_snapshot :: proc(v: ^Vga, guest_ram: []u8) -> Text_Snapshot {
	_ = guest_ram
	return vga_text_snapshot(v)
}

vga_display_frame :: proc(v: ^Vga) -> ^Display_Frame {
	output_enabled := video_output_enabled(v)
	if v.frame_valid && output_enabled { return &v.frame }
	if !output_enabled { v.frame_valid = false }
	kind, width, height := display_geometry(v)
	if width <= 0 || height <= 0 || width > DISPI_MAX_XRES || height > DISPI_MAX_YRES {
		v.frame = {}
		return &v.frame
	}
	needed := width * height
	if len(v.frame_pixels) != needed {
		if v.frame_pixels != nil { delete(v.frame_pixels, v.allocator) }
		v.frame_pixels = make([]u32, needed, v.allocator)
	}
	for &pixel in v.frame_pixels { pixel = 0xFF000000 }
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
	v.frame.pixels = v.frame_pixels
	v.frame.text = {}
	if !output_enabled { return &v.frame }
	switch kind {
	case .Text:
		v.frame.text = vga_text_snapshot(v)
		render_text(v, v.frame_pixels, width, height)
	case .Planar_4:
		if vga_vbe_enabled(v) { render_vbe(v, v.frame_pixels, width, height) }
		else { render_planar(v, v.frame_pixels, width, height) }
	case .Cga_2:
		render_cga(v, v.frame_pixels, width, height)
	case .Cga_1:
		render_cga_1(v, v.frame_pixels, width, height)
	case .Indexed_8:
		if vga_vbe_enabled(v) { render_vbe(v, v.frame_pixels, width, height) }
		else { render_indexed_legacy(v, v.frame_pixels, width, height) }
	case .Rgb_555, .Rgb_565, .Rgb_888, .Xrgb_8888:
		render_vbe(v, v.frame_pixels, width, height)
	case .Invalid:
	}
	return &v.frame
}

@(private = "package")
scanout_sync :: proc(v: ^Vga, old_ns, now_ns: u64) {
	period := max(v.timing.frame_period_ns, u64(1))
	old_frame := old_ns / period
	new_frame := now_ns / period
	start_latch := start_retrace_crossed(v, old_ns, now_ns)
	if !video_output_enabled(v) || period < 1_000_000 {
		v.raster_valid = false
		if start_latch { latch_display_start(v) }
		return
	}
	scanout_prepare(v, old_frame)
	if !v.raster_valid { return }
	if new_frame == old_frame {
		scanout_capture_through_time(v, now_ns % period)
		if start_latch { latch_display_start(v) }
		return
	}
	scanout_capture_through_line(v, v.raster_height - 1)
	scanout_finalize(v)
	if start_latch { latch_display_start(v) }
	scanout_prepare(v, new_frame)
	scanout_capture_through_time(v, now_ns % period)
}

@(private = "file")
scanout_prepare :: proc(v: ^Vga, frame_number: u64) {
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 { v.raster_valid = false; return }
	changed := !v.raster_valid || v.raster_kind != kind || v.raster_width != width || v.raster_height != height || v.raster_frame != frame_number
	if !changed { return }
	needed := width * height
	if len(v.raster_pixels) != needed {
		if v.raster_pixels != nil { delete(v.raster_pixels, v.allocator) }
		v.raster_pixels = make([]u32, needed, v.allocator)
	}
	for &pixel in v.raster_pixels { pixel = 0xFF000000 }
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
	if !v.raster_valid { return }
	last := min(last_line, v.raster_height - 1)
	for y := v.raster_next_line; y <= last; y += 1 {
		render_scanline(v, v.raster_pixels, v.raster_kind, v.raster_width, v.raster_height, y)
	}
	v.raster_next_line = max(v.raster_next_line, last + 1)
}

@(private = "file")
scanout_finalize :: proc(v: ^Vga) {
	if !v.raster_valid { return }
	temporary := v.frame_pixels
	v.frame_pixels = v.raster_pixels
	v.raster_pixels = temporary
	v.present_generation += 1
	v.frame.kind = v.raster_kind
	v.frame.width = v.raster_width
	v.frame.height = v.raster_height
	v.frame.aspect_width = v.raster_width
	v.frame.aspect_height = v.raster_height
	if !vga_vbe_enabled(v) { v.frame.aspect_width = 4; v.frame.aspect_height = 3 }
	v.frame.generation = v.present_generation
	v.frame.pixels = v.frame_pixels
	v.frame.text = v.raster_kind == .Text ? vga_text_snapshot(v) : Text_Snapshot{}
	v.frame_valid = true
	v.raster_valid = false
}

@(private = "file")
render_scanline :: proc(v: ^Vga, pixels: []u32, kind: Display_Kind, width, height, y: int) {
	if !video_output_enabled(v) {
		for x in 0 ..< width { pixels[y * width + x] = 0xFF000000 }
		return
	}
	switch kind {
	case .Text: render_text_scanline(v, pixels, width, height, y)
	case .Planar_4:
		if vga_vbe_enabled(v) { render_vbe_scanline(v, pixels, width, y) }
		else { render_planar_scanline(v, pixels, width, y) }
	case .Cga_2: render_cga_scanline(v, pixels, width, y)
	case .Cga_1: render_cga_1_scanline(v, pixels, width, y)
	case .Indexed_8:
		if vga_vbe_enabled(v) { render_vbe_scanline(v, pixels, width, y) }
		else { render_indexed_scanline(v, pixels, width, y) }
	case .Rgb_555, .Rgb_565, .Rgb_888, .Xrgb_8888:
		render_vbe_scanline(v, pixels, width, y)
	case .Invalid:
	}
}

@(private = "file")
render_text_scanline :: proc(v: ^Vga, pixels: []u32, width, height, y: int) {
	character_width := v.seq[1] & 1 != 0 ? 8 : 9
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	columns := width / character_width
	row := y / character_height
	glyph_y := y % character_height
	if row >= height / character_height { return }
	start := int(display_start(v))
	font_a, font_b := font_blocks(v)
	blink_on := (v.timing.elapsed_ns / 500_000_000) & 1 == 0
	cursor := (int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])) - start
	cursor_start := int(v.crtc[0x0A] & 0x1F)
	cursor_end := int(v.crtc[0x0B] & 0x1F)
	for column in 0 ..< columns {
		cell := row * columns + column
		character := plane_byte(v, 0, start + cell)
		attribute := plane_byte(v, 1, start + cell)
		foreground := attribute & 0x0F
		font_base := (attribute & 0x08 != 0 ? font_b : font_a) * 8192
		if font_a != font_b { foreground &= 7 }
		background := attribute >> 4
		if v.attr[0x10] & 0x08 != 0 {
			background &= 7
			if attribute & 0x80 != 0 && !blink_on { foreground = background }
		}
		fg := attribute_color(v, foreground)
		bg := attribute_color(v, background)
		bits := plane_byte(v, 2, font_base + int(character) * 32 + glyph_y)
		cursor_here := v.crtc[0x0A] & 0x20 == 0 && cursor == cell && glyph_y >= cursor_start && glyph_y <= cursor_end
		for glyph_x in 0 ..< character_width {
			set := glyph_x < 8 && bits & (u8(0x80) >> uint(glyph_x)) != 0
			if glyph_x == 8 && character >= 0xC0 && character <= 0xDF && v.attr[0x10] & 0x04 != 0 { set = bits & 1 != 0 }
			pixels[y * width + column * character_width + glyph_x] = cursor_here || set ? fg : bg
		}
	}
}

@(private = "file")
render_planar_scanline :: proc(v: ^Vga, pixels: []u32, width, y: int) {
	pitch := int(v.crtc[0x13]) * 2
	if pitch <= 0 { pitch = (width + 7) / 8 }
	memory_y := scanline_memory_y(v, y)
	row_start := int(display_start(v)) * 2
	pan := int(v.attr[0x13] & 7)
	if memory_y != y {
		row_start = 0
		if v.attr[0x10] & 0x20 != 0 { pan = 0 }
	}
	for x in 0 ..< width {
		source_x := x + pan
		offset := row_start + memory_y * pitch + source_x / 8
		bit := u8(0x80) >> uint(source_x & 7)
		color: u8
		for plane in 0 ..< 4 {
			if v.attr[0x12] & (u8(1) << uint(plane)) != 0 && plane_byte(v, plane, offset) & bit != 0 { color |= u8(1) << uint(plane) }
		}
		pixels[y * width + x] = attribute_color(v, color)
	}
}

@(private = "file")
render_indexed_scanline :: proc(v: ^Vga, pixels: []u32, width, y: int) {
	pitch := int(v.crtc[0x13]) * 2
	if pitch <= 0 { pitch = (width + 3) / 4 }
	memory_y := scanline_memory_y(v, y)
	row_start := int(display_start(v))
	pan := int(v.attr[0x13] & 7)
	if memory_y != y {
		row_start = 0
		if v.attr[0x10] & 0x20 != 0 { pan = 0 }
	}
	for x in 0 ..< width {
		source_x := x + pan
		plane := source_x & 3
		offset := row_start + memory_y * pitch + source_x / 4
		pixels[y * width + x] = dac_color(v, plane_byte(v, plane, offset))
	}
}

@(private = "file")
render_cga_scanline :: proc(v: ^Vga, pixels: []u32, width, y: int) {
	pitch := max(width / 4, 1)
	start := int(display_start(v)) * 2
	row := (y & 1) * 0x2000 + (y >> 1) * pitch
	for x in 0 ..< width {
		value := legacy_linear_byte(v, start + row + x / 4)
		shift := uint(6 - (x & 3) * 2)
		pixels[y * width + x] = attribute_color(v, (value >> shift) & 3)
	}
}

@(private = "file")
render_vbe_scanline :: proc(v: ^Vga, pixels: []u32, width, y: int) {
	pitch := vga_vbe_pitch(v)
	x_offset := int(v.dispi[DISPI_INDEX_X_OFFSET])
	row := (y + int(v.dispi[DISPI_INDEX_Y_OFFSET])) * pitch
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	for x in 0 ..< width {
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
		for plane in 0 ..< 4 { if plane_byte(v, plane, byte_offset) & bit != 0 { index |= u8(1) << uint(plane) } }
		return dac_color(v, index)
	case 8:
		return dac_color(v, v.vram[row + source_x])
	case 15:
		offset := row + source_x * 2
		value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
		r := u8((value >> 10) & 0x1F); g := u8((value >> 5) & 0x1F); b := u8(value & 0x1F)
		return 0xFF000000 | u32(r << 3 | r >> 2) << 16 | u32(g << 3 | g >> 2) << 8 | u32(b << 3 | b >> 2)
	case 16:
		offset := row + source_x * 2
		value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
		r := u8((value >> 11) & 0x1F); g := u8((value >> 5) & 0x3F); b := u8(value & 0x1F)
		return 0xFF000000 | u32(r << 3 | r >> 2) << 16 | u32(g << 2 | g >> 4) << 8 | u32(b << 3 | b >> 2)
	case 24:
		offset := row + source_x * 3
		return 0xFF000000 | u32(v.vram[offset + 2]) << 16 | u32(v.vram[offset + 1]) << 8 | u32(v.vram[offset])
	case 32:
		offset := row + source_x * 4
		return 0xFF000000 | u32(v.vram[offset + 2]) << 16 | u32(v.vram[offset + 1]) << 8 | u32(v.vram[offset])
	}
	return 0xFF000000
}

@(private = "file")
display_start :: proc(v: ^Vga) -> u16 {
	if v.start_pending && v.timing.elapsed_ns == 0 { return v.pending_start }
	return v.latched_start
}

@(private = "file")
display_geometry :: proc(v: ^Vga) -> (Display_Kind, int, int) {
	if vga_vbe_enabled(v) {
		kind: Display_Kind
		switch v.dispi[DISPI_INDEX_BPP] {
		case 4: kind = .Planar_4
		case 8: kind = .Indexed_8
		case 15: kind = .Rgb_555
		case 16: kind = .Rgb_565
		case 24: kind = .Rgb_888
		case 32: kind = .Xrgb_8888
		case: return .Invalid, 0, 0
		}
		return kind, int(v.dispi[DISPI_INDEX_XRES]), int(v.dispi[DISPI_INDEX_YRES])
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
	if shift == 0x40 { width = max(width / 2, 1) }
	repeat := max(int(v.crtc[9] & 0x1F) + 1, v.crtc[9] & 0x80 != 0 ? 2 : 1)
	height = max(height / repeat, 1)
	if shift == 0x40 { return .Indexed_8, width, height }
	if shift == 0x20 { return .Cga_2, width, height }
	if (v.gfx[6] >> 2) & 3 == 3 { return .Cga_1, width, height }
	return .Planar_4, width, height
}

@(private = "file")
video_output_enabled :: proc(v: ^Vga) -> bool {
	return v.video_on && v.seq[1] & 0x20 == 0
}

@(private = "file")
start_retrace_crossed :: proc(v: ^Vga, old_ns, now_ns: u64) -> bool {
	if !v.start_pending || now_ns <= old_ns { return false }
	period := max(v.timing.frame_period_ns, u64(1))
	offset := u64(max(v.timing.retrace_start, 0)) * max(v.timing.line_period_ns, u64(1))
	offset = min(offset, period - 1)
	crossing := old_ns / period * period + offset
	if crossing <= old_ns { crossing += period }
	return crossing <= now_ns
}

@(private = "file")
latch_display_start :: proc(v: ^Vga) {
	if !v.start_pending { return }
	v.latched_start = v.pending_start
	v.start_pending = false
}

@(private = "file")
font_block :: proc(selection: u8) -> int {
	return int((selection & 3) << 1 | (selection >> 2) & 1)
}

@(private = "package")
font_blocks :: proc(v: ^Vga) -> (a, b: int) {
	a_select := (v.seq[3] >> 2) & 3 | (v.seq[3] >> 3) & 4
	b_select := v.seq[3] & 3 | (v.seq[3] >> 2) & 4
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

@(private = "file")
attribute_color :: proc(v: ^Vga, color: u8) -> u32 {
	palette := v.attr[color & 0x0F] & 0x3F
	if v.attr[0x10] & 0x80 != 0 {
		palette = (palette & 0x0F) | (v.attr[0x14] & 0x0F) << 4
	} else {
		palette |= (v.attr[0x14] & 0x0C) << 4
	}
	return dac_color(v, palette)
}

@(private = "file")
render_text :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	character_width := v.seq[1] & 1 != 0 ? 8 : 9
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	columns := width / character_width
	rows := height / character_height
	start := int(display_start(v))
	font_a, font_b := font_blocks(v)
	blink_on := (v.timing.elapsed_ns / 500_000_000) & 1 == 0
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			cell_index := row * columns + column
			character := plane_byte(v, 0, start + cell_index)
			attribute := plane_byte(v, 1, start + cell_index)
			foreground := attribute & 0x0F
			font_base := (attribute & 0x08 != 0 ? font_b : font_a) * 8192
			if font_a != font_b { foreground &= 7 }
			background := attribute >> 4
			if v.attr[0x10] & 0x08 != 0 {
				background &= 7
				if attribute & 0x80 != 0 && !blink_on { foreground = background }
			}
			fg := attribute_color(v, foreground)
			bg := attribute_color(v, background)
			for glyph_y in 0 ..< character_height {
				bits := plane_byte(v, 2, font_base + int(character) * 32 + glyph_y)
				for glyph_x in 0 ..< character_width {
					set := glyph_x < 8 && bits & (u8(0x80) >> uint(glyph_x)) != 0
					if glyph_x == 8 && character >= 0xC0 && character <= 0xDF && v.attr[0x10] & 0x04 != 0 { set = bits & 1 != 0 }
					pixels[(row * character_height + glyph_y) * width + column * character_width + glyph_x] = set ? fg : bg
				}
			}
		}
	}
	if v.crtc[0x0A] & 0x20 != 0 { return }
	cursor := (int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])) - start
	if cursor < 0 || cursor >= rows * columns { return }
	start_line := min(int(v.crtc[0x0A] & 0x1F), character_height - 1)
	end_line := min(int(v.crtc[0x0B] & 0x1F), character_height - 1)
	if end_line < start_line { return }
	attribute := plane_byte(v, 1, start + cursor)
	color := attribute_color(v, attribute & 0x0F)
	cursor_row := cursor / columns
	cursor_column := cursor % columns
	for y in start_line ..= end_line {
		for x in 0 ..< character_width { pixels[(cursor_row * character_height + y) * width + cursor_column * character_width + x] = color }
	}
}

@(private = "file")
scanline_memory_y :: proc(v: ^Vga, y: int) -> int {
	line_compare := int(v.crtc[0x18])
	if v.crtc[7] & 0x10 != 0 { line_compare += 0x100 }
	if v.crtc[9] & 0x40 != 0 { line_compare += 0x200 }
	if y > line_compare { return y - line_compare - 1 }
	return y
}

@(private = "file")
render_planar :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	pitch := int(v.crtc[0x13]) * 2
	if pitch <= 0 { pitch = (width + 7) / 8 }
	start := int(display_start(v)) * 2
	pan := int(v.attr[0x13] & 7)
	for y in 0 ..< height {
		memory_y := scanline_memory_y(v, y)
		row_start := start
		line_pan := pan
		if memory_y != y {
			row_start = 0
			if v.attr[0x10] & 0x20 != 0 { line_pan = 0 }
		}
		for x in 0 ..< width {
			source_x := x + line_pan
			offset := row_start + memory_y * pitch + source_x / 8
			bit := u8(0x80) >> uint(source_x & 7)
			color: u8
			for plane in 0 ..< 4 {
				if v.attr[0x12] & (u8(1) << uint(plane)) != 0 && plane_byte(v, plane, offset) & bit != 0 { color |= u8(1) << uint(plane) }
			}
			pixels[y * width + x] = attribute_color(v, color)
		}
	}
}

@(private = "file")
render_indexed_legacy :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	pitch := int(v.crtc[0x13]) * 2
	if pitch <= 0 { pitch = (width + 3) / 4 }
	start := int(display_start(v))
	pan := int(v.attr[0x13] & 7)
	for y in 0 ..< height {
		memory_y := scanline_memory_y(v, y)
		row_start := start
		line_pan := pan
		if memory_y != y {
			row_start = 0
			if v.attr[0x10] & 0x20 != 0 { line_pan = 0 }
		}
		for x in 0 ..< width {
			source_x := x + line_pan
			plane := source_x & 3
			offset := row_start + memory_y * pitch + source_x / 4
			pixels[y * width + x] = dac_color(v, plane_byte(v, plane, offset))
		}
	}
}

@(private = "file")
legacy_linear_byte :: proc(v: ^Vga, raw: int) -> u8 {
	if v.seq[4] & 0x08 != 0 { return plane_byte(v, raw & 3, raw >> 2) }
	if v.seq[4] & 0x04 == 0 { return plane_byte(v, raw & 1, raw >> 1) }
	return plane_byte(v, 0, raw)
}

@(private = "file")
render_cga :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	pitch := max(width / 4, 1)
	start := int(display_start(v)) * 2
	for y in 0 ..< height {
		row := (y & 1) * 0x2000 + (y >> 1) * pitch
		for x in 0 ..< width {
			value := legacy_linear_byte(v, start + row + x / 4)
			shift := uint(6 - (x & 3) * 2)
			pixels[y * width + x] = attribute_color(v, (value >> shift) & 3)
		}
	}
}

@(private = "file")
render_cga_1 :: proc(v: ^Vga, pixels: []u32, width, height: int) {
	for y in 0 ..< height { render_cga_1_scanline(v, pixels, width, y) }
}

@(private = "file")
render_cga_1_scanline :: proc(v: ^Vga, pixels: []u32, width, y: int) {
	pitch := max(width / 8, 1)
	start := int(display_start(v)) * 2
	row := (y & 1) * 0x2000 + (y >> 1) * pitch
	for x in 0 ..< width {
		value := legacy_linear_byte(v, start + row + x / 8)
		index := value & (u8(0x80) >> uint(x & 7)) != 0 ? u8(1) : u8(0)
		pixels[y * width + x] = attribute_color(v, index)
	}
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
					if plane_byte(v, plane, byte_offset) & bit != 0 { index |= u8(1) << uint(plane) }
				}
				color = dac_color(v, index)
			case 8:
				color = dac_color(v, v.vram[row + source_x])
			case 15:
				offset := row + source_x * 2
				value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
				r := u8((value >> 10) & 0x1F); g := u8((value >> 5) & 0x1F); b := u8(value & 0x1F)
				color = 0xFF000000 | u32(r << 3 | r >> 2) << 16 | u32(g << 3 | g >> 2) << 8 | u32(b << 3 | b >> 2)
			case 16:
				offset := row + source_x * 2
				value := u16(v.vram[offset]) | u16(v.vram[offset + 1]) << 8
				r := u8((value >> 11) & 0x1F); g := u8((value >> 5) & 0x3F); b := u8(value & 0x1F)
				color = 0xFF000000 | u32(r << 3 | r >> 2) << 16 | u32(g << 2 | g >> 4) << 8 | u32(b << 3 | b >> 2)
			case 24:
				offset := row + source_x * 3
				color = 0xFF000000 | u32(v.vram[offset + 2]) << 16 | u32(v.vram[offset + 1]) << 8 | u32(v.vram[offset])
			case 32:
				offset := row + source_x * 4
				color = 0xFF000000 | u32(v.vram[offset + 2]) << 16 | u32(v.vram[offset + 1]) << 8 | u32(v.vram[offset])
			}
			pixels[y * width + x] = color
		}
	}
}
