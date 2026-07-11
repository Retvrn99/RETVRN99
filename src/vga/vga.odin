// SPDX-License-Identifier: GPL-3.0-only
package vga

// Dispositivo VGA en modo texto. El búfer B8000 es RAM ordinaria del huésped.

Vga :: struct {
	crtc:        [25]u8, // registros CRTC; se interpretan 0x0A/0x0B, 0x0C/0x0D, 0x0E/0x0F
	crtc_ix:     u8,
	misc:        u8,
	attr:        [32]u8,
	attr_ix:     u8,
	attr_flip:   bool, // false = índice, true = dato
	seq:         [8]u8,
	seq_ix:      u8,
	gfx:         [16]u8,
	gfx_ix:      u8,
	pel_mask:    u8,
	dac_read:    u8,
	dac_write:   u8,
	dac_sub:     u8,
	dac:         [256 * 3]u8,
	status_flip: bool, // alterna retrazado vertical en 0x3DA
}

Text_Snapshot :: struct {
	cells:      [80 * 25]u16, // carácter | atributo<<8
	cursor_row: int,
	cursor_col: int,
	cursor_on:  bool,
}

vga_out :: proc(v: ^Vga, port: u16, val: u8) {
	switch port {
	case 0x3D4:
		v.crtc_ix = val
	case 0x3D5:
		if int(v.crtc_ix) < len(v.crtc) { v.crtc[v.crtc_ix] = val }
	case 0x3C2:
		v.misc = val
	case 0x3C0:
		if v.attr_flip { v.attr[v.attr_ix & 0x1F] = val } else { v.attr_ix = val }
		v.attr_flip = !v.attr_flip
	case 0x3C4:
		v.seq_ix = val
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) { v.seq[v.seq_ix] = val }
	case 0x3CE:
		v.gfx_ix = val
	case 0x3CF:
		if int(v.gfx_ix) < len(v.gfx) { v.gfx[v.gfx_ix] = val }
	case 0x3C6:
		v.pel_mask = val
	case 0x3C7:
		v.dac_read = val
		v.dac_sub = 0
	case 0x3C8:
		v.dac_write = val
		v.dac_sub = 0
	case 0x3C9:
		v.dac[int(v.dac_write) * 3 + int(v.dac_sub)] = val
		v.dac_sub += 1
		if v.dac_sub == 3 {
			v.dac_sub = 0
			v.dac_write += 1
		}
	}
}

vga_in :: proc(v: ^Vga, port: u16) -> u8 {
	switch port {
	case 0x3D4:
		return v.crtc_ix
	case 0x3D5:
		if int(v.crtc_ix) < len(v.crtc) { return v.crtc[v.crtc_ix] }
		return 0
	case 0x3CC:
		return v.misc
	case 0x3DA:
		// alterna bit0|bit3; leer también reinicia el flip-flop del atributo
		v.attr_flip = false
		v.status_flip = !v.status_flip
		return v.status_flip ? 0x09 : 0x00
	case 0x3C0:
		return v.attr_ix
	case 0x3C1:
		return v.attr[v.attr_ix & 0x1F]
	case 0x3C4:
		return v.seq_ix
	case 0x3C5:
		if int(v.seq_ix) < len(v.seq) { return v.seq[v.seq_ix] }
		return 0
	case 0x3CE:
		return v.gfx_ix
	case 0x3CF:
		if int(v.gfx_ix) < len(v.gfx) { return v.gfx[v.gfx_ix] }
		return 0
	case 0x3C6:
		return v.pel_mask
	case 0x3C9:
		val := v.dac[int(v.dac_read) * 3 + int(v.dac_sub)]
		v.dac_sub += 1
		if v.dac_sub == 3 {
			v.dac_sub = 0
			v.dac_read += 1
		}
		return val
	}
	return 0xFF
}

vga_snapshot :: proc(v: ^Vga, guest_ram: []u8) -> Text_Snapshot {
	s: Text_Snapshot
	start := int(v.crtc[0x0C]) << 8 | int(v.crtc[0x0D])
	base := 0xB8000 + start * 2
	for i in 0 ..< 80 * 25 {
		off := base + i * 2
		if off + 1 < len(guest_ram) {
			s.cells[i] = u16(guest_ram[off]) | u16(guest_ram[off + 1]) << 8
		}
	}
	pos := int(v.crtc[0x0E]) << 8 | int(v.crtc[0x0F])
	rel := pos - start
	s.cursor_row = rel / 80
	s.cursor_col = rel % 80
	s.cursor_on = v.crtc[0x0A] & 0x20 == 0
	return s
}
