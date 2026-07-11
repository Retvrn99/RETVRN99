// SPDX-License-Identifier: GPL-3.0-only
package machine

Dma_Channel :: struct {
	addr:   u16,
	count:  u16, // bytes - 1
	page:   u8,
	mode:   u8,
	masked: bool,
}

Dma :: struct {
	ch:        [4]Dma_Channel,
	flip_flop: bool,
	status:    u8, // bits 0-3: TC por canal
}

dma_out :: proc(d: ^Dma, port: u16, v: u8) {
	switch port {
	case 0x00, 0x02, 0x04, 0x06:
		c := &d.ch[port >> 1]
		if !d.flip_flop { c.addr = (c.addr & 0xFF00) | u16(v) } else { c.addr = (c.addr & 0x00FF) | u16(v) << 8 }
		d.flip_flop = !d.flip_flop
	case 0x01, 0x03, 0x05, 0x07:
		c := &d.ch[port >> 1]
		if !d.flip_flop { c.count = (c.count & 0xFF00) | u16(v) } else { c.count = (c.count & 0x00FF) | u16(v) << 8 }
		d.flip_flop = !d.flip_flop
	case 0x08: // registro de comando: ignorado
	case 0x0A:
		d.ch[v & 3].masked = v & 4 != 0
	case 0x0B:
		d.ch[v & 3].mode = v
	case 0x0C:
		d.flip_flop = false
	case 0x0D: // master clear
		d.flip_flop = false
		d.status = 0
		for &c in d.ch { c.masked = true }
	case 0x0E:
		for &c in d.ch { c.masked = false }
	case 0x0F:
		for &c, i in d.ch { c.masked = v & (1 << u8(i)) != 0 }
	case 0x81:
		d.ch[2].page = v
	}
}

dma_in :: proc(d: ^Dma, port: u16) -> u8 {
	switch port {
	case 0x00, 0x02, 0x04, 0x06:
		c := &d.ch[port >> 1]
		b := d.flip_flop ? u8(c.addr >> 8) : u8(c.addr)
		d.flip_flop = !d.flip_flop
		return b
	case 0x01, 0x03, 0x05, 0x07:
		c := &d.ch[port >> 1]
		b := d.flip_flop ? u8(c.count >> 8) : u8(c.count)
		d.flip_flop = !d.flip_flop
		return b
	case 0x08: // leer estado limpia los bits TC
		s := d.status
		d.status &= 0xF0
		return s
	case 0x81:
		return d.ch[2].page
	}
	return 0xFF
}

// dispositivo → RAM del invitado
dma_write_mem :: proc(d: ^Dma, ch: int, ram: []u8, data: []u8) {
	c := &d.ch[ch]
	for b in data {
		addr := int(c.page) << 16 | int(c.addr)
		if addr < len(ram) { ram[addr] = b }
		c.addr += 1
		if c.count == 0 { d.status |= 1 << u8(ch); break }
		c.count -= 1
	}
}

// RAM del invitado → dispositivo
dma_read_mem :: proc(d: ^Dma, ch: int, ram: []u8, n: int, allocator := context.allocator) -> []u8 {
	c := &d.ch[ch]
	out := make([]u8, n, allocator)
	for i in 0 ..< n {
		addr := int(c.page) << 16 | int(c.addr)
		if addr < len(ram) { out[i] = ram[addr] }
		c.addr += 1
		if c.count == 0 { d.status |= 1 << u8(ch); return out[:i + 1] }
		c.count -= 1
	}
	return out
}
