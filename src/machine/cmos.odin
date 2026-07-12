// SPDX-License-Identifier: GPL-3.0-only
package machine

CMOS_NVRAM_SIZE :: 128

Cmos :: struct {
	ram:     [CMOS_NVRAM_SIZE]u8,
	index:   u8,
	h, m, s: u8,
	pi_acc:  u64, // ns toward the next periodic interrupt
}

// Periodic-interrupt edges (IRQ8) elapsed over ns; SeaBIOS INT 15h AH=86
// waits halt forever without them. Latches PF|IRQF in reg C per edge.
cmos_advance :: proc(c: ^Cmos, ns: u64) -> int {
	rate := c.ram[0x0A] & 0x0F
	if c.ram[0x0B] & 0x40 == 0 || rate == 0 { c.pi_acc = 0; return 0 }
	period := (u64(1_000_000_000) << (rate - 1)) / 32768
	c.pi_acc += ns
	n := int(c.pi_acc / period)
	c.pi_acc %= period
	if n > 0 { c.ram[0x0C] |= 0xC0 } // PF | IRQF
	return n
}

cmos_bcd :: proc(v: u8) -> u8 { return (v / 10) << 4 | v % 10 }

@(private = "file")
cmos_apply_machine_config :: proc(c: ^Cmos, ram_bytes: u64) {
	c.ram[0x0A] = 0x26 // RTC OK
	c.ram[0x0B] = 0x02 // BCD, 24h
	c.ram[0x0C] = 0x00
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

// Static config SeaBIOS expects; memory sizes derived from ram_bytes
cmos_init :: proc(c: ^Cmos, ram_bytes: u64) {
	c^ = {}
	cmos_apply_machine_config(c, ram_bytes)
}

cmos_nvram_export :: proc(c: ^Cmos) -> [CMOS_NVRAM_SIZE]u8 {
	return c.ram
}

cmos_nvram_import :: proc(c: ^Cmos, data: []u8, ram_bytes: u64) -> bool {
	if len(data) != CMOS_NVRAM_SIZE { return false }
	copy(c.ram[:], data)
	c.index = 0
	c.pi_acc = 0
	cmos_apply_machine_config(c, ram_bytes)
	return true
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
	case 0x0C: v := c.ram[0x0C]; c.ram[0x0C] = 0; return v // flags clear on read
	}
	return c.ram[c.index]
}
