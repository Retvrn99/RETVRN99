// SPDX-License-Identifier: GPL-3.0-only
package vga

@(rodata) SEQ_MASKS := [8]u8{0x03, 0x3D, 0x0F, 0x3F, 0x0E, 0x00, 0x00, 0x00}
@(rodata) GFX_MASKS := [16]u8{0x0F, 0x0F, 0x0F, 0x1F, 0x03, 0x7B, 0x0F, 0x0F, 0xFF, 0, 0, 0, 0, 0, 0, 0}
@(rodata) ATTR_MASKS := [32]u8{
	0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F,
	0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F, 0x3F,
	0xFF, 0x3F, 0x0F, 0x0F, 0x0F, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
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
	if port == DISPI_PORT_INDEX || port == DISPI_PORT_DATA {
		dispi_io_write(v, port, size, value)
		return
	}
	for i in 0 ..< int(max(size, 1)) {
		standard_port_write(v, port + u16(i), u8(value >> uint(i * 8)))
	}
}

vga_io_read :: proc(v: ^Vga, port: u16, size: u8) -> u32 {
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
standard_port_write :: proc(v: ^Vga, port: u16, value: u8) {
	crtc_port := active_crtc_index_port(v)
	switch port {
	case 0x3B4, 0x3D4:
		if port == crtc_port { v.crtc_ix = value & 0x1F }
	case 0x3B5, 0x3D5:
		if port == crtc_port + 1 { crtc_write(v, v.crtc_ix, value) }
	case 0x3C0:
		if !v.attr_flip {
			v.attr_ix = value & 0x1F
			v.video_on = value & 0x20 != 0
		} else if int(v.attr_ix) < len(v.attr) {
			v.attr[v.attr_ix] = value & ATTR_MASKS[v.attr_ix]
			vga_recalculate_timing(v)
		}
		v.attr_flip = !v.attr_flip
	case 0x3C2:
		v.misc = value
		vga_recalculate_timing(v)
	case 0x3C4:
		v.seq_ix = value & 7
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) {
			v.seq[v.seq_ix] = value & SEQ_MASKS[v.seq_ix]
			vga_recalculate_timing(v)
		}
	case 0x3C6:
		v.pel_mask = value
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
		if v.dispi[DISPI_INDEX_ENABLE] & DISPI_8BIT_DAC == 0 { dac_value &= 0x3F }
		v.dac[int(v.dac_write) * 3 + int(v.dac_sub)] = dac_value
		v.dac_sub += 1
		if v.dac_sub == 3 {
			v.dac_sub = 0
			v.dac_write += 1
		}
	case 0x3CE:
		v.gfx_ix = value & 0x0F
	case 0x3CF:
		if int(v.gfx_ix) < len(v.gfx) {
			v.gfx[v.gfx_ix] = value & GFX_MASKS[v.gfx_ix]
			vga_recalculate_timing(v)
		}
	case 0x3DA, 0x3BA:
		v.feature = value & 3
	}
}

@(private = "file")
standard_port_read :: proc(v: ^Vga, port: u16) -> u8 {
	crtc_port := active_crtc_index_port(v)
	switch port {
	case 0x3B4, 0x3D4:
		if port == crtc_port { return v.crtc_ix }
	case 0x3B5, 0x3D5:
		if port == crtc_port + 1 && int(v.crtc_ix) < len(v.crtc) { return v.crtc[v.crtc_ix] }
	case 0x3BA, 0x3DA:
		if port == active_status_port(v) {
			v.attr_flip = false
			return vga_status_1(v)
		}
	case 0x3C0:
		return v.attr_ix | (v.video_on ? 0x20 : 0)
	case 0x3C1:
		if int(v.attr_ix) < len(v.attr) { return v.attr[v.attr_ix] }
	case 0x3C2:
		return 0x10
	case 0x3C4:
		return v.seq_ix
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) { return v.seq[v.seq_ix] }
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
		if int(v.gfx_ix) < len(v.gfx) { return v.gfx[v.gfx_ix] }
	}
	return 0xFF
}

@(private = "file")
crtc_write :: proc(v: ^Vga, index, value: u8) {
	if int(index) >= len(v.crtc) { return }
	if index <= 7 && v.crtc[0x11] & 0x80 != 0 {
		if index == 7 { v.crtc[7] = (v.crtc[7] & ~u8(0x10)) | (value & 0x10) }
		return
	}
	v.crtc[index] = value
	if index == 0x0C || index == 0x0D {
		v.pending_start = u16(v.crtc[0x0C]) << 8 | u16(v.crtc[0x0D])
		v.start_pending = true
	}
	vga_recalculate_timing(v)
}
