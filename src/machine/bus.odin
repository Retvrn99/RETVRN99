// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:log"

Io_Handler :: struct {
	ctx:   rawptr,
	read:  proc(ctx: rawptr, port: u16, size: u8) -> u32,
	write: proc(ctx: rawptr, port: u16, size: u8, val: u32),
}

Bus :: struct {
	io:         map[u16]Io_Handler,
	whitelist:  map[u16]bool,
	frozen:     bool,
	freeze_msg: string,
}

bus_init :: proc(b: ^Bus) { b.io = {}; b.whitelist = {} }
bus_destroy :: proc(b: ^Bus) { delete(b.io); delete(b.whitelist) }

bus_register :: proc(b: ^Bus, first, last: u16, h: Io_Handler) {
	for p := int(first); p <= int(last); p += 1 { b.io[u16(p)] = h }
}

bus_whitelist :: proc(b: ^Bus, ports: ..u16) {
	for p in ports { b.whitelist[p] = true }
}

bus_freeze :: proc(b: ^Bus, msg: string) {
	b.frozen = true
	b.freeze_msg = msg
	log.errorf("VM frozen: %s", msg)
}

bus_io_read :: proc(b: ^Bus, port: u16, size: u8) -> u32 {
	if h, ok := b.io[port]; ok { return h.read(h.ctx, port, size) }
	if b.whitelist[port] { return 0xFFFFFFFF >> (32 - 8*u32(size)) }
	bus_freeze(b, "unknown port read")
	return 0xFF
}

bus_io_write :: proc(b: ^Bus, port: u16, size: u8, val: u32) {
	if h, ok := b.io[port]; ok { h.write(h.ctx, port, size, val); return }
	if b.whitelist[port] { return }
	bus_freeze(b, "unknown port write")
}
