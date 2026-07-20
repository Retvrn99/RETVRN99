// SPDX-License-Identifier: GPL-3.0-only
package vga

VGA_STATUS0_SWITCH_SENSE :: u8(0x10)
VGA_STATUS0_CRT_INTERRUPT :: u8(0x80)
VGA_STATUS1_DISPLAY_DISABLED :: u8(0x01)
VGA_STATUS1_LIGHT_PEN_TRIGGERED :: u8(0x02)
VGA_STATUS1_CGA_LIGHT_PEN_SWITCH :: u8(0x04)
VGA_STATUS1_VERTICAL_RETRACE :: u8(0x08)
VGA_CRTC11_CLEAR_VERTICAL_INTERRUPT :: u8(0x10)
VGA_CRTC11_DISABLE_VERTICAL_INTERRUPT :: u8(0x20)

@(private = "package")
vga_wrapped_end :: proc(start, end_low, mask, total: int) -> int {
	if total <= 0 {return 0}
	window_start := clamp(start, 0, total - 1)
	end := (window_start & ~mask) | (end_low & mask)
	for end <= window_start {end += mask + 1}
	return min(end, total)
}

@(private = "package")
vga_beam_position :: proc(v: ^Vga) -> (line, dot: int) {
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	frame_pos := v.timing.elapsed_ns % period
	line = min(int(frame_pos / line_ns), max(v.timing.total_lines - 1, 0))
	line_pos := frame_pos % line_ns
	dot = int(line_pos * u64(max(v.timing.total_dots, 1)) / line_ns)
	return
}

@(private = "package")
vga_in_wrapped_window :: proc(position, start, end, total: int) -> bool {
	if total <= 0 {return false}
	p := clamp(position, 0, total - 1)
	s := clamp(start, 0, total - 1)
	e := clamp(end, 0, total)
	if e == s {return false}
	if e > s {return p >= s && p < e}
	return p >= s || p < e
}

@(private = "package")
vga_vertical_interrupt_enabled :: proc(v: ^Vga) -> bool {
	return v != nil && v.crtc[0x11] & VGA_CRTC11_DISABLE_VERTICAL_INTERRUPT == 0
}

@(private = "package")
vga_vertical_interrupt_armed :: proc(v: ^Vga) -> bool {
	return v != nil && v.crtc[0x11] & VGA_CRTC11_CLEAR_VERTICAL_INTERRUPT != 0
}

@(private = "package")
vga_refresh_legacy_irq :: proc(v: ^Vga) {
	if v == nil {return}
	asserted := v.vertical_interrupt_pending && vga_vertical_interrupt_enabled(v)
	if v.legacy_irq_asserted == asserted {return}
	v.legacy_irq_asserted = asserted
	if v.legacy_irq != nil {v.legacy_irq(v.legacy_irq_ctx, asserted)}
}

@(private = "package")
vga_clear_vertical_interrupt :: proc(v: ^Vga) {
	if v == nil {return}
	v.vertical_interrupt_pending = false
	vga_refresh_legacy_irq(v)
}

@(private = "package")
vga_set_vertical_interrupt :: proc(v: ^Vga) {
	if v == nil || v.vertical_interrupt_pending {return}
	v.vertical_interrupt_pending = true
	vga_refresh_legacy_irq(v)
}

@(private = "file")
vga_line_crossed :: proc(v: ^Vga, old_ns, now_ns: u64, line: int) -> bool {
	if v == nil || now_ns <= old_ns || v.timing.total_lines <= 0 {return false}
	period := max(v.timing.frame_period_ns, u64(1))
	line_ns := max(v.timing.line_period_ns, u64(1))
	target_line := clamp(line, 0, v.timing.total_lines - 1)
	offset := min(u64(target_line) * line_ns, period - 1)
	crossing := old_ns / period * period + offset
	if crossing <= old_ns {crossing += period}
	return crossing <= now_ns
}

@(private = "package")
vga_update_vertical_interrupt :: proc(v: ^Vga, old_ns, now_ns: u64) {
	if v == nil || !vga_vertical_interrupt_enabled(v) || !vga_vertical_interrupt_armed(v) {return}
	line := v.timing.vblank_start
	if line <= 0 || line >= v.timing.total_lines {line = v.timing.retrace_start}
	if vga_line_crossed(v, old_ns, now_ns, line) {vga_set_vertical_interrupt(v)}
}

@(private = "file")
vga_line_deadline_ns :: proc(v: ^Vga, line: int) -> (deadline_ns: u64, pending: bool) {
	if v == nil ||
	   v.timing.frame_period_ns == 0 ||
	   v.timing.line_period_ns == 0 ||
	   v.timing.total_lines <= 0 {
		return 0, false
	}
	target_line := clamp(line, 0, v.timing.total_lines - 1)
	offset := min(u64(target_line) * v.timing.line_period_ns, v.timing.frame_period_ns - 1)
	base := v.timing.elapsed_ns / v.timing.frame_period_ns * v.timing.frame_period_ns
	deadline_ns = base + offset
	if deadline_ns <= v.timing.elapsed_ns {deadline_ns += v.timing.frame_period_ns}
	return deadline_ns, true
}

vga_next_vertical_interrupt_ns :: proc(v: ^Vga) -> (deadline_ns: u64, pending: bool) {
	if v == nil ||
	   v.vertical_interrupt_pending ||
	   !vga_vertical_interrupt_enabled(v) ||
	   !vga_vertical_interrupt_armed(v) ||
	   v.timing.frame_period_ns == 0 ||
	   v.timing.line_period_ns == 0 ||
	   v.timing.total_lines <= 0 {
		return 0, false
	}
	line := v.timing.vblank_start
	if line <= 0 || line >= v.timing.total_lines {line = v.timing.retrace_start}
	return vga_line_deadline_ns(v, line)
}

vga_next_deadline_ns :: proc(v: ^Vga) -> (deadline_ns: u64, pending: bool) {
	if v == nil {return 0, false}
	deadline_ns = ~u64(0)
	if v.start_pending {
		if candidate, ok := vga_line_deadline_ns(v, v.timing.retrace_start); ok {
			deadline_ns = min(deadline_ns, candidate)
			pending = true
		}
	}
	if candidate, ok := vga_next_vertical_interrupt_ns(v); ok {
		deadline_ns = min(deadline_ns, candidate)
		pending = true
	}
	return deadline_ns, pending
}

@(private = "package")
vga_status_1 :: proc(v: ^Vga) -> u8 {
	line, dot := vga_beam_position(v)
	hblank := vga_in_wrapped_window(
		dot,
		v.timing.hblank_start,
		v.timing.hblank_end,
		v.timing.total_dots,
	)
	vblank := vga_in_wrapped_window(
		line,
		v.timing.vblank_start,
		v.timing.vblank_end,
		v.timing.total_lines,
	)
	vertical_retrace :=
		v.crtc[0x17] & 0x80 != 0 &&
		vga_in_wrapped_window(
			line,
			v.timing.retrace_start,
			v.timing.retrace_end,
			v.timing.total_lines,
		)
	active := !hblank && !vblank && video_output_enabled(v)
	status: u8
	if !active {status |= VGA_STATUS1_DISPLAY_DISABLED}
	if v.cga.active {
		if v.cga.light_pen_triggered {status |= VGA_STATUS1_LIGHT_PEN_TRIGGERED}
		status |= VGA_STATUS1_CGA_LIGHT_PEN_SWITCH
	}
	if vertical_retrace {status |= VGA_STATUS1_VERTICAL_RETRACE}
	if active && !v.cga.active {status |= vga_status_mux_bits(v, line, dot)}
	return status
}

@(private = "package")
vga_status_0 :: proc(v: ^Vga) -> u8 {
	status: u8
	selected := (v.misc >> 2) & 3
	if u8(0b0110) & (u8(1) << uint(selected)) != 0 {status |= VGA_STATUS0_SWITCH_SENSE}
	if v.vertical_interrupt_pending {status |= VGA_STATUS0_CRT_INTERRUPT}
	return status
}
