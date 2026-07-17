// SPDX-License-Identifier: GPL-3.0-only
package vga

// CGA register behavior is adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9.

CGA_MODE_80_COLUMNS :: u8(0x01)
CGA_MODE_GRAPHICS :: u8(0x02)
CGA_MODE_BW :: u8(0x04)
CGA_MODE_VIDEO_ENABLE :: u8(0x08)
CGA_MODE_HIGH_RES :: u8(0x10)
CGA_MODE_BLINK :: u8(0x20)

Cga_State :: struct {
	active:              bool,
	mode_control:        u8,
	color_select:        u8,
	light_pen_triggered: bool,
	light_pen_latch:     u16,
}

@(rodata)
CGA_COLORS := [16]u32 {
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

legacy_video_subsystem_enabled :: proc(v: ^Vga) -> bool {
	return v != nil && v.video_subsystem_enable & 1 != 0
}

legacy_video_memory_enabled :: proc(v: ^Vga) -> bool {
	return legacy_video_subsystem_enabled(v) && v.misc & 0x02 != 0
}

cga_seed_crtc :: proc(v: ^Vga, control: u8) {
	graphics := control & CGA_MODE_GRAPHICS != 0
	eighty_columns := control & CGA_MODE_80_COLUMNS != 0
	if graphics {
		v.crtc[0x00] = 0x38
		v.crtc[0x01] = 0x28
		v.crtc[0x02] = 0x2D
		v.crtc[0x03] = 0x0A
		v.crtc[0x04] = 0x7F
		v.crtc[0x05] = 0x06
		v.crtc[0x06] = 0x64
		v.crtc[0x07] = 0x70
		v.crtc[0x08] = 0x02
		v.crtc[0x09] = 0x01
	} else {
		v.crtc[0x00] = eighty_columns ? 0x71 : 0x38
		v.crtc[0x01] = eighty_columns ? 0x50 : 0x28
		v.crtc[0x02] = eighty_columns ? 0x5A : 0x2D
		v.crtc[0x03] = 0x0A
		v.crtc[0x04] = 0x1F
		v.crtc[0x05] = 0x06
		v.crtc[0x06] = 0x19
		v.crtc[0x07] = 0x1C
		v.crtc[0x08] = 0x02
		v.crtc[0x09] = 0x07
	}
	for i in 0x0A ..< len(v.crtc) {v.crtc[i] = 0}
	v.crtc[0x0A] = 0x06
	v.crtc[0x0B] = 0x07
	v.latched_start = 0
	v.pending_start = 0
	v.start_pending = false
	// The B800 aperture stays byte-linear through the existing odd/even layout.
	v.seq[2] = 0x03
	v.seq[4] = 0x02
	v.gfx[5] = 0x10
	v.gfx[6] = graphics ? 0x0F : 0x0E
	v.gfx[7] = 0x0F
	v.gfx[8] = 0xFF
}

cga_set_mode_control :: proc(v: ^Vga, value: u8) -> bool {
	masked := value & 0x3F
	was_active := v.cga.active
	changed := !was_active || v.cga.mode_control != masked
	if !was_active {cga_seed_crtc(v, masked)}
	v.cga.active = true
	v.cga.mode_control = masked
	vga_recalculate_timing(v)
	return changed
}

cga_set_color_select :: proc(v: ^Vga, value: u8) -> bool {
	masked := value & 0x3F
	changed := v.cga.color_select != masked
	v.cga.color_select = masked
	return changed
}

cga_leave_personality :: proc(v: ^Vga) {
	if v != nil {v.cga.active = false}
}

cga_crtc_write :: proc(v: ^Vga, index, value: u8) -> bool {
	if int(index) >= len(v.crtc) {return false}
	masked := value
	switch index {
	case 0x03:
		masked &= 0x0F
	case 0x04, 0x06, 0x07, 0x0A:
		masked &= 0x7F
	case 0x05, 0x09, 0x0B:
		masked &= 0x1F
	case 0x08:
		masked &= 0x03
	case 0x0C, 0x0E:
		masked &= 0x3F
	case 0x10, 0x11:
		return false
	case:
	}
	changed := v.crtc[index] != masked
	v.crtc[index] = masked
	if index == 0x0C || index == 0x0D {
		v.pending_start = u16(v.crtc[0x0C]) << 8 | u16(v.crtc[0x0D])
		v.start_pending = true
	}
	if index <= 0x09 {vga_recalculate_timing(v)}
	return changed
}

cga_crtc_read :: proc(v: ^Vga, index: u8) -> (u8, bool) {
	switch index {
	case 0x0E, 0x0F:
		return v.crtc[index], true
	case 0x10:
		return u8(v.cga.light_pen_latch >> 8), true
	case 0x11:
		return u8(v.cga.light_pen_latch), true
	}
	return 0xFF, false
}

cga_latch_light_pen :: proc(v: ^Vga) {
	if v == nil || !v.cga.active || v.cga.light_pen_triggered {return}
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	frame_pos := v.timing.elapsed_ns % period
	line := min(int(frame_pos / line_ns), max(v.timing.total_lines - 1, 0))
	line_pos := frame_pos % line_ns
	dot := int(line_pos * u64(max(v.timing.total_dots, 1)) / line_ns)
	rows_per_character := max(int(v.crtc[0x09] & 0x1F) + 1, 1)
	columns := max(int(v.crtc[0x01]), 1)
	character_width := cga_character_width(v)
	row := line / rows_per_character
	column := min(dot / max(character_width, 1), columns - 1)
	v.cga.light_pen_latch = (display_start(v) + u16(row * columns + column)) & 0x3FFF
	v.cga.light_pen_triggered = true
}

cga_character_width :: proc(v: ^Vga) -> int {
	if v.cga.mode_control & CGA_MODE_GRAPHICS != 0 &&
	   v.cga.mode_control & CGA_MODE_HIGH_RES != 0 {return 16}
	return 8
}

cga_palette_index :: proc(v: ^Vga, pixel: u8) -> u8 {
	if v.cga.mode_control & CGA_MODE_HIGH_RES != 0 {
		return pixel & 1 != 0 ? v.cga.color_select & 0x0F : 0
	}
	if pixel & 3 == 0 {return v.cga.color_select & 0x0F}
	intense := v.cga.color_select & 0x10 != 0
	palette: [3]u8
	if v.cga.mode_control & CGA_MODE_BW != 0 {
		palette = intense ? [3]u8{11, 12, 15} : [3]u8{3, 4, 7}
	} else if v.cga.color_select & 0x20 != 0 {
		palette = intense ? [3]u8{11, 13, 15} : [3]u8{3, 5, 7}
	} else {
		palette = intense ? [3]u8{10, 12, 14} : [3]u8{2, 4, 6}
	}
	return palette[int((pixel & 3) - 1)]
}

cga_color :: proc(v: ^Vga, pixel: u8) -> u32 {
	return CGA_COLORS[int(cga_palette_index(v, pixel) & 0x0F)]
}
