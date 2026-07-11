// SPDX-License-Identifier: GPL-3.0-only
package machine

// PCI mechanism #1 stub: i440FX host bridge (00:00.0) plus PIIX3 ISA bridge
// (00:01.0) and IDE (00:01.1). 256-byte config spaces freely writable —
// SeaBIOS setup writes are stored and read back (PAM accepted and ignored).
// IDE stays in legacy compatibility mode: BARs read 0, fixed 1F0/3F6 decode.

Pci :: struct {
	addr: u32,
	cfg:  [3][256]u8, // 0 = 00:00.0 host, 1 = 00:01.0 ISA, 2 = 00:01.1 IDE
}

@(private = "file")
pci_seed_id :: proc(c: ^[256]u8, device: u16) {
	c[0x00] = 0x86; c[0x01] = 0x80 // vendor 0x8086 (LE)
	c[0x02] = u8(device); c[0x03] = u8(device >> 8)
}

pci_init :: proc(p: ^Pci) {
	p^ = {}
	pci_seed_id(&p.cfg[0], 0x1237) // i440FX host bridge
	p.cfg[0][0x0B] = 0x06 // class 0x060000

	pci_seed_id(&p.cfg[1], 0x7000) // PIIX3 ISA bridge
	p.cfg[1][0x0A] = 0x01 // subclass: ISA
	p.cfg[1][0x0B] = 0x06
	p.cfg[1][0x0E] = 0x80 // header type: multifunction

	pci_seed_id(&p.cfg[2], 0x7010) // PIIX3 IDE
	p.cfg[2][0x09] = 0x80 // prog-if: legacy compatibility mode
	p.cfg[2][0x0A] = 0x01 // subclass: IDE
	p.cfg[2][0x0B] = 0x01 // class: mass storage
}

@(private = "file")
pci_size_mask :: proc(size: u8) -> u32 {
	return 0xFFFFFFFF >> (32 - 8 * u32(size))
}

// Maps the current config address to (function index, register), if present.
@(private = "file")
pci_decode :: proc(p: ^Pci, port: u16) -> (fn_idx: int, reg: u32, ok: bool) {
	if (p.addr & 0x8000_0000) == 0 { return 0, 0, false }
	bus := (p.addr >> 16) & 0xFF
	dev := (p.addr >> 11) & 0x1F
	fn := (p.addr >> 8) & 0x07
	if bus != 0 { return 0, 0, false }
	idx := -1
	switch {
	case dev == 0 && fn == 0: idx = 0
	case dev == 1 && fn == 0: idx = 1
	case dev == 1 && fn == 1: idx = 2
	}
	if idx < 0 { return 0, 0, false }
	return idx, (p.addr & 0xFC) + u32(port & 3), true
}

pci_in :: proc(p: ^Pci, port: u16, size: u8) -> u32 {
	if port >= 0xCF8 && port <= 0xCFB {
		off := u32(port) - 0xCF8
		return (p.addr >> (8 * off)) & pci_size_mask(size)
	}
	fn_idx, reg, ok := pci_decode(p, port)
	if !ok { return pci_size_mask(size) }
	v: u32 = 0
	for i in 0 ..< u32(size) {
		v |= u32(p.cfg[fn_idx][(reg + i) & 0xFF]) << (8 * i)
	}
	return v
}

pci_out :: proc(p: ^Pci, port: u16, size: u8, val: u32) {
	if port >= 0xCF8 && port <= 0xCFB {
		off := u32(port) - 0xCF8
		for i in 0 ..< u32(size) {
			pos := (off + i) & 3
			p.addr = (p.addr & ~(u32(0xFF) << (8 * pos))) | (u32(u8(val >> (8 * i))) << (8 * pos))
		}
		return
	}
	fn_idx, reg, ok := pci_decode(p, port)
	if !ok { return }
	for i in 0 ..< u32(size) {
		p.cfg[fn_idx][(reg + i) & 0xFF] = u8(val >> (8 * i))
	}
}
