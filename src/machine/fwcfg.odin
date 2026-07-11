// SPDX-License-Identifier: GPL-3.0-only
package machine

// fw_cfg mínimo estilo QEMU: selector en 0x510, flujo de bytes en 0x511

FWCFG_PORT_SEL :: 0x510
FWCFG_PORT_DATA :: 0x511

FWCFG_SIGNATURE :: 0x0000
FWCFG_ID :: 0x0001
FWCFG_UUID :: 0x0002
FWCFG_NB_CPUS :: 0x0005
FWCFG_FILE_DIR :: 0x0019
FWCFG_E820 :: 0x0020

Fwcfg :: struct {
	items: map[u16][]u8,
	sel:   u16,
	pos:   int,
}

fwcfg_put_be16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v >> 8), u8(v))
}

fwcfg_put_be32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

fwcfg_put_le32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

fwcfg_put_le64 :: proc(b: ^[dynamic]u8, v: u64) {
	for i in u64(0) ..< 8 { append(b, u8(v >> (8 * i))) }
}

fwcfg_init :: proc(f: ^Fwcfg, ram_bytes: u64) {
	f^ = {}

	sig := make([]u8, 4)
	copy(sig, "QEMU")
	f.items[FWCFG_SIGNATURE] = sig

	id: [dynamic]u8
	fwcfg_put_le32(&id, 0x00000001)
	f.items[FWCFG_ID] = id[:]

	f.items[FWCFG_UUID] = make([]u8, 16)

	cpus: [dynamic]u8
	append(&cpus, 1, 0) // u16 LE
	f.items[FWCFG_NB_CPUS] = cpus[:]

	// tabla e820: {addr u64, len u64, tipo u32} LE
	e820: [dynamic]u8
	fwcfg_put_le64(&e820, 0)
	fwcfg_put_le64(&e820, 0xA0000)
	fwcfg_put_le32(&e820, 1)
	fwcfg_put_le64(&e820, 0x100000)
	fwcfg_put_le64(&e820, ram_bytes - 0x100000)
	fwcfg_put_le32(&e820, 1)
	f.items[FWCFG_E820] = e820[:]

	// directorio: count u32 BE + por fichero {size u32 BE, select u16 BE, reservado u16, nombre[56]}
	dir: [dynamic]u8
	fwcfg_put_be32(&dir, 1)
	fwcfg_put_be32(&dir, u32(len(e820)))
	fwcfg_put_be16(&dir, FWCFG_E820)
	fwcfg_put_be16(&dir, 0)
	name: [56]u8
	copy(name[:], "etc/e820")
	append(&dir, ..name[:])
	f.items[FWCFG_FILE_DIR] = dir[:]
}

fwcfg_destroy :: proc(f: ^Fwcfg) {
	for _, blob in f.items { delete(blob) }
	delete(f.items)
	f^ = {}
}

fwcfg_out :: proc(f: ^Fwcfg, port: u16, size: u8, val: u32) {
	if port == FWCFG_PORT_SEL {
		f.sel = u16(val)
		f.pos = 0
	}
	// escrituras al puerto de datos: ignoradas
}

fwcfg_in :: proc(f: ^Fwcfg, port: u16, size: u8) -> u32 {
	if port != FWCFG_PORT_DATA { return 0 }
	v: u32
	for i in u8(0) ..< size {
		v |= u32(fwcfg_read_byte(f)) << (8 * u32(i))
	}
	return v
}

// selectores desconocidos o agotados leen 0x00
fwcfg_read_byte :: proc(f: ^Fwcfg) -> u8 {
	blob, ok := f.items[f.sel]
	if !ok || f.pos >= len(blob) { return 0 }
	b := blob[f.pos]
	f.pos += 1
	return b
}
