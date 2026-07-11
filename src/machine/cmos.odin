// SPDX-License-Identifier: GPL-3.0-only
package machine

Cmos :: struct {
	ram:     [128]u8,
	index:   u8,
	h, m, s: u8,
}

cmos_bcd :: proc(v: u8) -> u8 { return (v / 10) << 4 | v % 10 }

// Config estática que SeaBIOS espera leer
cmos_init :: proc(c: ^Cmos) {
	c.ram[0x0A] = 0x26 // RTC OK
	c.ram[0x0B] = 0x02 // BCD, 24h
	c.ram[0x0D] = 0x80 // batería OK
	c.ram[0x0E] = 0x00 // diagnóstico
	c.ram[0x10] = 0x40 // floppy A: 1.44M
	c.ram[0x12] = 0x00 // discos duros vía IDE, no CMOS
	c.ram[0x14] = 0x2D // equipo: FPU+video+1 floppy
	c.ram[0x15] = 0x80 // 640K base
	c.ram[0x16] = 0x02
	c.ram[0x17] = 0x00 // ext. 15360K (15M entre 1M–16M)
	c.ram[0x18] = 0x3C
	c.ram[0x30] = 0x00
	c.ram[0x31] = 0x3C
	c.ram[0x34] = 0x00 // 48M sobre 16M (total 64M)
	c.ram[0x35] = 0x0C
}

cmos_set_time :: proc(c: ^Cmos, h, m, s: u8) {
	c.h = h; c.m = m; c.s = s
}

cmos_out :: proc(c: ^Cmos, port: u16, val: u8) {
	switch port {
	case 0x70: c.index = val & 0x7F // bit NMI enmascarado
	case 0x71: c.ram[c.index] = val
	}
}

cmos_in :: proc(c: ^Cmos, port: u16) -> u8 {
	if port != 0x71 { return 0xFF }
	switch c.index {
	case 0x00: return cmos_bcd(c.s)
	case 0x02: return cmos_bcd(c.m)
	case 0x04: return cmos_bcd(c.h)
	case 0x0C: return 0x00 // sin interrupción pendiente
	}
	return c.ram[c.index]
}
