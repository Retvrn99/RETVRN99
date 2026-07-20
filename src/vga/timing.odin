// SPDX-License-Identifier: GPL-3.0-only
package vga

VBE_FRAME_PERIOD_NS :: u64(16_666_667)

@(private = "file")
vga_timing_set_fallback_blanking :: proc(timing: ^Video_Timing) {
	timing.hblank_start = timing.visible_dots
	timing.hblank_end = timing.total_dots
	timing.hretrace_start =
		timing.visible_dots + max((timing.total_dots - timing.visible_dots) / 3, 1)
	timing.hretrace_end = min(
		timing.hretrace_start + max((timing.total_dots - timing.visible_dots) / 4, 1),
		timing.total_dots,
	)
	timing.vblank_start = timing.visible_lines
	timing.vblank_end = timing.total_lines
}

@(private = "package")
vga_recalculate_timing :: proc(v: ^Vga) {
	if vga_vbe_enabled(v) {
		visible := max(int(v.dispi[DISPI_INDEX_YRES]), 1)
		total := visible + max(20, visible / 20)
		v.timing.frame_period_ns = VBE_FRAME_PERIOD_NS
		v.timing.line_period_ns = max(VBE_FRAME_PERIOD_NS / u64(total), 1)
		v.timing.total_lines = total
		v.timing.visible_lines = visible
		v.timing.visible_dots = max(int(v.dispi[DISPI_INDEX_XRES]), 1)
		v.timing.total_dots = v.timing.visible_dots + max(80, v.timing.visible_dots / 5)
		v.timing.retrace_start = visible + max(1, (total - visible) / 3)
		v.timing.retrace_end = min(v.timing.retrace_start + 3, total)
		vga_timing_set_fallback_blanking(&v.timing)
		return
	}
	if v.cga.active {
		character_dots := cga_character_width(v)
		total_dots := max((int(v.crtc[0x00]) + 1) * character_dots, 1)
		visible_dots := max(int(v.crtc[0x01]) * character_dots, 1)
		scanlines := max(int(v.crtc[0x09] & 0x1F) + 1, 1)
		total_lines := max((int(v.crtc[0x04]) + 1) * scanlines + int(v.crtc[0x05]), 1)
		visible_lines := min(max(int(v.crtc[0x06]) * scanlines, 1), total_lines)
		retrace_start := min(int(v.crtc[0x07]) * scanlines, total_lines - 1)
		retrace_end := min(retrace_start + 2, total_lines)
		pixel_clock: u64 = 7_159_090
		if v.cga.mode_control & (CGA_MODE_80_COLUMNS | CGA_MODE_HIGH_RES) != 0 {
			pixel_clock = 14_318_180
		}
		line_ns := max(u64(total_dots) * 1_000_000_000 / pixel_clock, u64(1))
		v.timing.line_period_ns = line_ns
		v.timing.frame_period_ns = line_ns * u64(total_lines)
		v.timing.total_lines = total_lines
		v.timing.visible_lines = visible_lines
		v.timing.visible_dots = min(visible_dots, total_dots)
		v.timing.total_dots = total_dots
		v.timing.retrace_start = retrace_start
		v.timing.retrace_end = retrace_end
		vga_timing_set_fallback_blanking(&v.timing)
		return
	}
	char_dots := v.seq[1] & 1 != 0 ? 8 : 9
	total_dots := max((int(v.crtc[0]) + 5) * char_dots, 1)
	visible_dots := max((int(v.crtc[1]) + 1) * char_dots, 1)
	total_chars := max(total_dots / char_dots, 1)
	hblank_start := int(v.crtc[0x02])
	hblank_end := vga_wrapped_end(
		hblank_start,
		int(v.crtc[0x03] & 0x1F) | (v.crtc[0x05] & 0x80 != 0 ? 0x20 : 0),
		0x3F,
		total_chars,
	)
	hretrace_delay := int((v.crtc[0x05] >> 5) & 3)
	hretrace_start := int(v.crtc[0x04]) + hretrace_delay
	hretrace_end := vga_wrapped_end(
		hretrace_start,
		int(v.crtc[0x05] & 0x1F) + hretrace_delay,
		0x1F,
		total_chars,
	)
	vertical_total := int(v.crtc[6]) + 2
	if v.crtc[7] & 0x01 != 0 {vertical_total += 0x100}
	if v.crtc[7] & 0x20 != 0 {vertical_total += 0x200}
	vertical_display := int(v.crtc[0x12]) + 1
	if v.crtc[7] & 0x02 != 0 {vertical_display += 0x100}
	if v.crtc[7] & 0x40 != 0 {vertical_display += 0x200}
	retrace_start := int(v.crtc[0x10])
	if v.crtc[7] & 0x04 != 0 {retrace_start += 0x100}
	if v.crtc[7] & 0x80 != 0 {retrace_start += 0x200}
	retrace_end := (retrace_start & 0x7FFFFFF0) | int(v.crtc[0x11] & 0x0F)
	if retrace_end <= retrace_start {retrace_end += 16}
	vblank_start := int(v.crtc[0x15])
	if v.crtc[0x07] & 0x08 != 0 {vblank_start += 0x100}
	if v.crtc[0x09] & 0x20 != 0 {vblank_start += 0x200}
	vblank_start += 1
	vblank_end := vga_wrapped_end(vblank_start, int(v.crtc[0x16]), 0xFF, max(vertical_total, 1))
	clock_select := (v.misc >> 2) & 3
	pixel_clock: u64 = 25_175_000
	if clock_select == 1 {pixel_clock = 28_322_000}
	if v.seq[1] & 0x08 != 0 {pixel_clock /= 2}
	line_ns := max(u64(total_dots) * 1_000_000_000 / pixel_clock, u64(1))
	v.timing.line_period_ns = line_ns
	v.timing.frame_period_ns = line_ns * u64(max(vertical_total, 1))
	v.timing.total_lines = max(vertical_total, 1)
	v.timing.visible_lines = min(max(vertical_display, 1), v.timing.total_lines)
	v.timing.visible_dots = min(visible_dots, total_dots)
	v.timing.total_dots = total_dots
	v.timing.hblank_start = min(hblank_start * char_dots, v.timing.total_dots - 1)
	v.timing.hblank_end = min(hblank_end * char_dots, v.timing.total_dots)
	v.timing.hretrace_start = min(hretrace_start * char_dots, v.timing.total_dots - 1)
	v.timing.hretrace_end = min(hretrace_end * char_dots, v.timing.total_dots)
	v.timing.vblank_start = min(vblank_start, v.timing.total_lines - 1)
	v.timing.vblank_end = min(vblank_end, v.timing.total_lines)
	v.timing.retrace_start = min(retrace_start, v.timing.total_lines - 1)
	v.timing.retrace_end = min(retrace_end, v.timing.total_lines)
}

// now_ns is an absolute device time. Repeating a timestamp is a no-op and a
// backwards timestamp is ignored, so callers may synchronize at every exit.
vga_sync_to :: proc(v: ^Vga, now_ns: u64) {
	if now_ns <= v.timing.elapsed_ns {return}
	if now_ns / 500_000_000 != v.timing.elapsed_ns / 500_000_000 {
		vga_note_animation_change(v)
	}
	period := max(v.timing.frame_period_ns, u64(1))
	old_frame := v.timing.elapsed_ns / period
	new_frame := now_ns / period
	vga_update_vertical_interrupt(v, v.timing.elapsed_ns, now_ns)
	scanout_sync(v, v.timing.elapsed_ns, now_ns)
	if new_frame > old_frame {
		v.timing.generation += new_frame - old_frame
	}
	v.timing.elapsed_ns = now_ns
}

vga_begin_raster_change :: proc(v: ^Vga, now_ns: u64) {
	if v == nil {return}
	period := max(v.timing.frame_period_ns, u64(1))
	was_active := v.raster_fallback
	v.raster_fallback = true
	v.raster_change_frame = now_ns / period
	if !was_active && now_ns <= v.timing.elapsed_ns {scanout_begin_raster_change(v, now_ns)}
	vga_sync_to(v, now_ns)
}

vga_advance :: proc(v: ^Vga, now_ns: u64) {
	vga_sync_to(v, now_ns)
}

vga_current_line :: proc(v: ^Vga) -> int {
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	return min(int((v.timing.elapsed_ns % period) / line_ns), max(v.timing.total_lines - 1, 0))
}
