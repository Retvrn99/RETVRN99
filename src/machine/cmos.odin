// SPDX-License-Identifier: GPL-3.0-only
package machine

Cmos :: struct {
	ram:     [128]u8,
	index:   u8,
	h, m, s: u8,
}

cmos_bcd :: proc(v: u8) -> u8 { return (v / 10) << 4 | v % 10 }

// Static config SeaBIOS expects; memory sizes derived from ram_bytes
cmos_init :: proc(c: ^Cmos, ram_bytes: u64) {
	c.ram[0x0A] = 0x26 // RTC OK
	c.ram[0x0B] = 0x02 // BCD, 24h
	c.ram[0x0D] = 0x80 // battery OK
	c.ram[0x0E] = 0x00 // diagnostics
	c.ram[0x10] = 0x40 // floppy A: 1.44M
	c.ram[0x12] = 0x00 // hard disks via IDE, not CMOS
	c.ram[0x14] = 0x2D // equipment: FPU+video+1 floppy
	c.ram[0x15] = 0x80 // 640K base
	c.ram[0x16] = 0x02

	// KB between 1M and 16M, capped at the standard 15M = 0x3C00
	ext_kb: u64 = 0
	if ram_bytes > 0x100000 { ext_kb = (ram_bytes - 0x100000) / 1024 }
	if ext_kb > 0x3C00 { ext_kb = 0x3C00 }
	c.ram[0x17] = u8(ext_kb)
	c.ram[0x18] = u8(ext_kb >> 8)
	c.ram[0x30] = u8(ext_kb)
	c.ram[0x31] = u8(ext_kb >> 8)

	// 64K units above 16M
	above16: u64 = 0
	if ram_bytes > 0x1000000 { above16 = (ram_bytes - 0x1000000) / 0x10000 }
	if above16 > 0xFFFF { above16 = 0xFFFF }
	c.ram[0x34] = u8(above16)
	c.ram[0x35] = u8(above16 >> 8)
}

cmos_set_time :: proc(c: ^Cmos, h, m, s: u8) {
	c.h = h; c.m = m; c.s = s
}

cmos_out :: proc(c: ^Cmos, port: u16, val: u8) {
	switch port {
	case 0x70: c.index = val & 0x7F // NMI bit masked off
	case 0x71: c.ram[c.index] = val
	}
}

cmos_in :: proc(c: ^Cmos, port: u16) -> u8 {
	if port != 0x71 { return 0xFF }
	switch c.index {
	case 0x00: return cmos_bcd(c.s)
	case 0x02: return cmos_bcd(c.m)
	case 0x04: return cmos_bcd(c.h)
	case 0x0C: return 0x00 // no interrupt pending
	}
	return c.ram[c.index]
}
