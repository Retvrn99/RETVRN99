// SPDX-License-Identifier: GPL-3.0-only
package vga

VBE_FRAME_PERIOD_NS :: u64(16_666_667)

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
		return
	}
	char_dots := v.seq[1] & 1 != 0 ? 8 : 9
	total_dots := max((int(v.crtc[0]) + 5) * char_dots, 1)
	visible_dots := max((int(v.crtc[1]) + 1) * char_dots, 1)
	vertical_total := int(v.crtc[6]) + 2
	if v.crtc[7] & 0x01 != 0 { vertical_total += 0x100 }
	if v.crtc[7] & 0x20 != 0 { vertical_total += 0x200 }
	vertical_display := int(v.crtc[0x12]) + 1
	if v.crtc[7] & 0x02 != 0 { vertical_display += 0x100 }
	if v.crtc[7] & 0x40 != 0 { vertical_display += 0x200 }
	retrace_start := int(v.crtc[0x10])
	if v.crtc[7] & 0x04 != 0 { retrace_start += 0x100 }
	if v.crtc[7] & 0x80 != 0 { retrace_start += 0x200 }
	retrace_end := (retrace_start & 0x7FFFFFF0) | int(v.crtc[0x11] & 0x0F)
	if retrace_end <= retrace_start { retrace_end += 16 }
	clock_select := (v.misc >> 2) & 3
	pixel_clock: u64 = 25_175_000
	if clock_select == 1 { pixel_clock = 28_322_000 }
	if v.seq[1] & 0x08 != 0 { pixel_clock /= 2 }
	line_ns := max(u64(total_dots) * 1_000_000_000 / pixel_clock, u64(1))
	v.timing.line_period_ns = line_ns
	v.timing.frame_period_ns = line_ns * u64(max(vertical_total, 1))
	v.timing.total_lines = max(vertical_total, 1)
	v.timing.visible_lines = min(max(vertical_display, 1), v.timing.total_lines)
	v.timing.visible_dots = min(visible_dots, total_dots)
	v.timing.total_dots = total_dots
	v.timing.retrace_start = min(retrace_start, v.timing.total_lines - 1)
	v.timing.retrace_end = min(retrace_end, v.timing.total_lines)
}

// now_ns is an absolute device time. Repeating a timestamp is a no-op and a
// backwards timestamp is ignored, so callers may synchronize at every exit.
vga_sync_to :: proc(v: ^Vga, now_ns: u64) {
	if now_ns <= v.timing.elapsed_ns { return }
	if now_ns / 500_000_000 != v.timing.elapsed_ns / 500_000_000 {
		vga_note_animation_change(v)
	}
	period := max(v.timing.frame_period_ns, u64(1))
	old_frame := v.timing.elapsed_ns / period
	new_frame := now_ns / period
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

@(private = "package")
vga_status_1 :: proc(v: ^Vga) -> u8 {
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	frame_pos := v.timing.elapsed_ns % period
	line := min(int(frame_pos / line_ns), max(v.timing.total_lines - 1, 0))
	line_pos := frame_pos % line_ns
	dot := int(line_pos * u64(max(v.timing.total_dots, 1)) / line_ns)
	active := line < v.timing.visible_lines && dot < v.timing.visible_dots && v.video_on && v.seq[1] & 0x20 == 0
	vertical_retrace := line >= v.timing.retrace_start && line < v.timing.retrace_end
	status: u8
	if !active { status |= 0x01 }
	if vertical_retrace { status |= 0x08 }
	return status
}
