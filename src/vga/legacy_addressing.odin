// SPDX-License-Identifier: GPL-3.0-only
package vga

// Legacy display-address generation and split/pan formulas are selectively
// adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

Legacy_Row_Geometry :: struct {
	counter_line: int,
	row_scan:     int,
	row_base:     u32,
	below_split:  bool,
}

@(private = "package")
legacy_line_compare :: proc(v: ^Vga) -> int {
	line := int(v.crtc[0x18])
	if v.crtc[0x07] & 0x10 != 0 {line += 0x100}
	if v.crtc[0x09] & 0x40 != 0 {line += 0x200}
	return line
}

// IBM 2-75. Horizontal Retrace Select clocks the row scan counter at half the
// horizontal rate, so every character row covers twice the scan lines. No stock
// BIOS mode programs it; software that wants a doubled raster usually reaches
// for the double-scan bit beside Maximum Scan Line instead.
@(private = "package")
legacy_graphics_scan_factor :: proc(v: ^Vga) -> int {
	maximum_scan := int(v.crtc[0x09] & 0x1f) + 1
	double_scan := v.crtc[0x09] & 0x80 != 0 ? 2 : 1
	factor := max(maximum_scan, double_scan)
	if v.crtc[0x17] & 0x04 != 0 {factor *= 2}
	return factor
}

@(private = "file")
legacy_ega_split_delay :: proc(v: ^Vga, kind: Display_Kind) -> int {
	if kind != .Planar_4 || vga_vbe_enabled(v) {return 0}
	factor := legacy_graphics_scan_factor(v)
	source_height := max(v.timing.visible_lines / factor, 1)
	return source_height == 200 || source_height == 350 ? 2 : 0
}

@(private = "package")
legacy_split_first_line :: proc(v: ^Vga, kind: Display_Kind) -> int {
	return legacy_line_compare(v) + 1 + legacy_ega_split_delay(v, kind)
}

@(private = "package")
legacy_pan_resets_below_split :: proc(v: ^Vga, below_split: bool) -> bool {
	return below_split && v.attr[0x10] & 0x20 != 0
}

@(private = "package")
legacy_pel_pan :: proc(v: ^Vga, below_split: bool) -> int {
	if legacy_pan_resets_below_split(v, below_split) {return 0}
	return int(v.attr[0x13] & 0x0f)
}

@(private = "package")
legacy_text_pel_pan :: proc(v: ^Vga, below_split: bool, character_width: int) -> int {
	pan := legacy_pel_pan(v, below_split)
	if character_width == 9 && pan == 8 {return 0}
	return min(pan, max(character_width - 1, 0))
}

// IBM 2-95. A 256-colour pixel occupies two dot clocks and panning is specified
// in dot clocks, so only even register values are meaningful and the shift is
// half the programmed value: 0h, 2h, 4h, and 6h move 0, 1, 2, and 3 pixels. The
// same two-dots-per-pixel ratio is why display_geometry reports half the dot
// count as the pixel width in these modes.
@(private = "package")
legacy_indexed_pel_pan :: proc(v: ^Vga, below_split: bool) -> int {
	return (legacy_pel_pan(v, below_split) >> 1) & 3
}

@(private = "package")
legacy_byte_pan :: proc(v: ^Vga, below_split: bool) -> int {
	if legacy_pan_resets_below_split(v, below_split) {return 0}
	return int((v.crtc[0x08] >> 5) & 3)
}

// The CGA persona drives a 6845, whose register 8 selects interlace rather than
// a preset row scan, and `cga_seed_crtc` programs it as one. Reading it as a VGA
// preset row would push every CGA text row two scan lines down its cell.
@(private = "package")
legacy_preset_row :: proc(v: ^Vga, below_split: bool) -> int {
	if v.cga.active {return 0}
	return below_split ? 0 : int(v.crtc[0x08] & 0x1f)
}

@(private = "package")
legacy_graphics_row :: proc(v: ^Vga, kind: Display_Kind, y: int) -> Legacy_Row_Geometry {
	factor := legacy_graphics_scan_factor(v)
	counter_line := max(y, 0) * factor
	first_line := legacy_split_first_line(v, kind)
	below_split := counter_line >= first_line
	origin_line := below_split ? first_line : 0
	start := below_split ? u32(0) : u32(display_start(v))
	row_scan := counter_line - origin_line + legacy_preset_row(v, below_split)
	source_row := row_scan / factor
	row_base := start + u32(source_row * int(v.crtc[0x13]) * 2 + legacy_byte_pan(v, below_split))
	return {
		counter_line = counter_line,
		row_scan = row_scan,
		row_base = row_base,
		below_split = below_split,
	}
}

@(private = "package")
legacy_display_counter :: proc(v: ^Vga, row_base, column: u32) -> u32 {
	divisor := u32(1)
	if v.crtc[0x14] & 0x20 != 0 {
		divisor = 4
	} else if v.crtc[0x17] & 0x08 != 0 {
		divisor = 2
	}
	return row_base + column / divisor
}

@(private = "package")
legacy_display_offset :: proc(v: ^Vga, address: u32, row_scan: int) -> int {
	result: u32
	if v.crtc[0x17] & 0x40 != 0 {
		result = address
	} else if v.crtc[0x14] & 0x40 != 0 {
		result = address << 2
	} else {
		wrap_bit := v.crtc[0x17] & 0x20 != 0 ? u32(15) : u32(13)
		result = address << 1 | (address >> wrap_bit) & 1
	}
	if v.crtc[0x17] & 0x01 == 0 {
		result = result & ~u32(1 << 13) | u32(row_scan & 1) << 13
	}
	if v.crtc[0x17] & 0x02 == 0 {
		result = result & ~u32(1 << 14) | u32((row_scan >> 1) & 1) << 14
	}
	return int(result & (LEGACY_PLANE_SIZE - 1))
}

@(private = "package")
legacy_text_byte :: proc(v: ^Vga, raw_offset: int) -> u8 {
	offset := raw_offset & 0x7fff
	return plane_byte(v, offset & 1, offset >> 1)
}
