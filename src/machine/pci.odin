// SPDX-License-Identifier: GPL-3.0-only
package machine

// Stub PCI mecanismo #1: sólo el host bridge i440FX (bus 0, dev 0, fn 0).
// Espacio de config de 256 bytes libremente escribible (PAM aceptado e ignorado).

Pci :: struct {
	addr:       u32,
	hostbridge: [256]u8,
}

pci_init :: proc(p: ^Pci) {
	p.addr = 0
	p.hostbridge = {}
	p.hostbridge[0x00] = 0x86 // vendor 0x8086 (LE)
	p.hostbridge[0x01] = 0x80
	p.hostbridge[0x02] = 0x37 // device 0x1237 (LE)
	p.hostbridge[0x03] = 0x12
	p.hostbridge[0x0B] = 0x06 // clase 0x060000: host bridge
	p.hostbridge[0x0E] = 0x00 // header type
}

@(private = "file")
pci_size_mask :: proc(size: u8) -> u32 {
	return 0xFFFFFFFF >> (32 - 8 * u32(size))
}

// Devuelve reg efectivo si la dirección apunta al host bridge.
@(private = "file")
pci_decode :: proc(p: ^Pci, port: u16) -> (reg: u32, ok: bool) {
	if (p.addr & 0x8000_0000) == 0 { return 0, false }
	bus := (p.addr >> 16) & 0xFF
	dev := (p.addr >> 11) & 0x1F
	fn := (p.addr >> 8) & 0x07
	if bus != 0 || dev != 0 || fn != 0 { return 0, false }
	return (p.addr & 0xFC) + u32(port & 3), true
}

pci_in :: proc(p: ^Pci, port: u16, size: u8) -> u32 {
	if port >= 0xCF8 && port <= 0xCFB {
		off := u32(port) - 0xCF8
		return (p.addr >> (8 * off)) & pci_size_mask(size)
	}
	reg, ok := pci_decode(p, port)
	if !ok { return pci_size_mask(size) }
	v: u32 = 0
	for i in 0 ..< u32(size) {
		v |= u32(p.hostbridge[(reg + i) & 0xFF]) << (8 * i)
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
	reg, ok := pci_decode(p, port)
	if !ok { return }
	for i in 0 ..< u32(size) {
		p.hostbridge[(reg + i) & 0xFF] = u8(val >> (8 * i))
	}
}
