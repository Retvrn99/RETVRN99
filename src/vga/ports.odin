// SPDX-License-Identifier: GPL-3.0-only
package vga

@(rodata)
SEQ_MASKS := [8]u8{0x03, 0x3D, 0x0F, 0x3F, 0x0E, 0x00, 0x00, 0x00}
@(rodata)
GFX_MASKS := [16]u8{0x0F, 0x0F, 0x0F, 0x1F, 0x03, 0x7B, 0x0F, 0x0F, 0xFF, 0, 0, 0, 0, 0, 0, 0}
@(rodata)
ATTR_MASKS := [32]u8 {
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0x3F,
	0xFF,
	0x3F,
	0x0F,
	0x0F,
	0x0F,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
	0x00,
}

@(private = "file")
active_crtc_index_port :: proc(v: ^Vga) -> u16 {
	return v.misc & 1 != 0 ? 0x3D4 : 0x3B4
}

@(private = "file")
active_status_port :: proc(v: ^Vga) -> u16 {
	return v.misc & 1 != 0 ? 0x3DA : 0x3BA
}

vga_out :: proc(v: ^Vga, port: u16, val: u8) {
	vga_io_write(v, port, 1, u32(val))
}

vga_in :: proc(v: ^Vga, port: u16) -> u8 {
	return u8(vga_io_read(v, port, 1))
}

vga_io_write :: proc(v: ^Vga, port: u16, size: u8, value: u32) {
	if v == nil || !v.pci_io_enabled {return}
	if port == DISPI_PORT_INDEX || port == DISPI_PORT_DATA {
		if dispi_io_write(v, port, size, value) {vga_note_content_change(v)}
		return
	}
	changed := false
	for i in 0 ..< int(max(size, 1)) {
		changed = standard_port_write(v, port + u16(i), u8(value >> uint(i * 8))) || changed
	}
	if changed {vga_note_content_change(v)}
}

vga_io_read :: proc(v: ^Vga, port: u16, size: u8) -> u32 {
	if v == nil || !v.pci_io_enabled {
		switch size {
		case 1:
			return 0xFF
		case 2:
			return 0xFFFF
		}
		return 0xFFFF_FFFF
	}
	if port == DISPI_PORT_INDEX || port == DISPI_PORT_DATA {
		return dispi_io_read(v, port, size)
	}
	value: u32
	for i in 0 ..< int(max(size, 1)) {
		value |= u32(standard_port_read(v, port + u16(i))) << uint(i * 8)
	}
	return value
}

@(private = "file")
standard_port_write :: proc(v: ^Vga, port: u16, value: u8) -> bool {
	if v.cga.active {
		switch port {
		case 0x3D0, 0x3D2, 0x3D4, 0x3D6:
			v.crtc_ix = value & 0x1F
			return false
		case 0x3D1, 0x3D3, 0x3D5, 0x3D7:
			return cga_crtc_write(v, v.crtc_ix, value)
		}
	}
	crtc_port := active_crtc_index_port(v)
	switch port {
	case 0x3B4, 0x3D4:
		if port == crtc_port {v.crtc_ix = value & 0x1F}
	case 0x3B5, 0x3D5:
		if port == crtc_port + 1 {return crtc_write(v, v.crtc_ix, value)}
	case 0x3C0:
		if !v.attr_flip {
			old_video_on := v.video_on
			v.attr_ix = value & 0x1F
			v.video_on = value & 0x20 != 0
			v.attr_flip = true
			return old_video_on != v.video_on
		} else if int(v.attr_ix) < len(v.attr) {
			masked := value & ATTR_MASKS[v.attr_ix]
			changed := v.attr[v.attr_ix] != masked
			v.attr[v.attr_ix] = masked
			vga_recalculate_timing(v)
			v.attr_flip = false
			return changed
		}
		v.attr_flip = !v.attr_flip
	case 0x3C2:
		changed := v.misc != value || v.cga.active
		cga_leave_personality(v)
		v.misc = value
		vga_recalculate_timing(v)
		return changed
	case 0x3C3:
		masked := value & 1
		changed := v.video_subsystem_enable != masked
		v.video_subsystem_enable = masked
		return changed
	case 0x3C4:
		v.seq_ix = value & 7
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) {
			masked := value & SEQ_MASKS[v.seq_ix]
			changed := v.seq[v.seq_ix] != masked
			v.seq[v.seq_ix] = masked
			vga_recalculate_timing(v)
			return changed
		}
	case 0x3C6:
		changed := v.pel_mask != value
		v.pel_mask = value
		return changed
	case 0x3C7:
		v.dac_read = value
		v.dac_sub = 0
		v.dac_state = 3
	case 0x3C8:
		v.dac_write = value
		v.dac_sub = 0
		v.dac_state = 0
	case 0x3C9:
		dac_value := value
		if v.dispi[DISPI_INDEX_ENABLE] & DISPI_8BIT_DAC == 0 {dac_value &= 0x3F}
		index := int(v.dac_write) * 3 + int(v.dac_sub)
		changed := v.dac[index] != dac_value
		v.dac[index] = dac_value
		v.dac_sub += 1
		if v.dac_sub == 3 {
			v.dac_sub = 0
			v.dac_write += 1
		}
		return changed
	case 0x3CE:
		v.gfx_ix = value & 0x0F
	case 0x3CF:
		if int(v.gfx_ix) < len(v.gfx) {
			masked := value & GFX_MASKS[v.gfx_ix]
			changed := v.gfx[v.gfx_ix] != masked
			v.gfx[v.gfx_ix] = masked
			vga_recalculate_timing(v)
			return changed
		}
	case 0x3DA, 0x3BA:
		v.feature = value & 3
	case 0x3D8:
		return cga_set_mode_control(v, value)
	case 0x3D9:
		return cga_set_color_select(v, value)
	case 0x3DB:
		changed := v.cga.light_pen_triggered
		v.cga.light_pen_triggered = false
		return changed
	case 0x3DC:
		was_triggered := v.cga.light_pen_triggered
		cga_latch_light_pen(v)
		return !was_triggered && v.cga.light_pen_triggered
	}
	return false
}

@(private = "file")
standard_port_read :: proc(v: ^Vga, port: u16) -> u8 {
	if v.cga.active {
		switch port {
		case 0x3D0, 0x3D2, 0x3D4, 0x3D6:
			return 0xFF
		case 0x3D1, 0x3D3, 0x3D5, 0x3D7:
			value, readable := cga_crtc_read(v, v.crtc_ix)
			return readable ? value : 0xFF
		}
	}
	crtc_port := active_crtc_index_port(v)
	switch port {
	case 0x3B4, 0x3D4:
		if port == crtc_port {return v.crtc_ix}
	case 0x3B5, 0x3D5:
		if port == crtc_port + 1 && int(v.crtc_ix) < len(v.crtc) {return v.crtc[v.crtc_ix]}
	case 0x3BA, 0x3DA:
		if port == active_status_port(v) {
			v.attr_flip = false
			return vga_status_1(v)
		}
	case 0x3C0:
		return v.attr_ix | (v.video_on ? 0x20 : 0)
	case 0x3C1:
		if int(v.attr_ix) < len(v.attr) {return v.attr[v.attr_ix]}
	case 0x3C2:
		return vga_status_0(v)
	case 0x3C3:
		return v.video_subsystem_enable & 1
	case 0x3C4:
		return v.seq_ix
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) {return v.seq[v.seq_ix]}
	case 0x3C6:
		return v.pel_mask
	case 0x3C7:
		return v.dac_state
	case 0x3C8:
		return v.dac_write
	case 0x3C9:
		value := v.dac[int(v.dac_read) * 3 + int(v.dac_sub)]
		v.dac_sub += 1
		if v.dac_sub == 3 {
			v.dac_sub = 0
			v.dac_read += 1
		}
		return value
	case 0x3CA:
		return v.feature
	case 0x3CC:
		return v.misc
	case 0x3CE:
		return v.gfx_ix
	case 0x3CF:
		if int(v.gfx_ix) < len(v.gfx) {return v.gfx[v.gfx_ix]}
	case 0x3DB:
		v.cga.light_pen_triggered = false
		return 0xFF
	case 0x3DC:
		cga_latch_light_pen(v)
		return 0xFF
	}
	return 0xFF
}

@(private = "file")
crtc_write :: proc(v: ^Vga, index, value: u8) -> bool {
	if int(index) >= len(v.crtc) {return false}
	if index <= 7 && v.crtc[0x11] & 0x80 != 0 {
		if index == 7 {
			updated := (v.crtc[7] & ~u8(0x10)) | (value & 0x10)
			changed := v.crtc[7] != updated
			v.crtc[7] = updated
			return changed
		}
		return false
	}
	changed := v.crtc[index] != value
	v.crtc[index] = value
	if index == 0x0C || index == 0x0D {
		v.pending_start = u16(v.crtc[0x0C]) << 8 | u16(v.crtc[0x0D])
		v.start_pending = true
	}
	vga_recalculate_timing(v)
	return changed
}
