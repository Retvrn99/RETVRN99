// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:fmt"
import "core:log"

BUS_UNCLASSIFIED_HISTORY :: 64

Io_Width_Policy :: enum {
	Native,
	Byte_Decomposed,
}

Io_Handler :: struct {
	ctx:   rawptr,
	read:  proc(ctx: rawptr, port: u16, size: u8) -> u32,
	write: proc(ctx: rawptr, port: u16, size: u8, val: u32),
	width: Io_Width_Policy,
}

Unclassified_Io :: struct {
	port:  u16,
	write: bool,
	size:  u8,
	value: u32,
}

Bus :: struct {
	io:                   map[u16]Io_Handler,
	passive:              map[u16]u8,
	unclassified_seen:    map[u64]bool,
	unclassified_history: [BUS_UNCLASSIFIED_HISTORY]Unclassified_Io,
	unclassified_count:   u64,
	strict_io:            bool,
	log_unclassified:     bool,
	frozen:               bool,
	freeze_msg:           string,
}

bus_init :: proc(b: ^Bus) {
	b.io = {}
	b.passive = {}
	b.unclassified_seen = {}
}

bus_destroy :: proc(b: ^Bus) {
	delete(b.io)
	delete(b.passive)
	delete(b.unclassified_seen)
}

bus_set_strict_io :: proc(b: ^Bus, strict: bool) {
	b.strict_io = strict
}

bus_set_log_unclassified :: proc(b: ^Bus, enabled: bool) {
	b.log_unclassified = enabled
}

bus_register :: proc(b: ^Bus, first, last: u16, h: Io_Handler) {
	for p := int(first); p <= int(last); p += 1 { b.io[u16(p)] = h }
}

bus_register_byte_decomposed :: proc(b: ^Bus, first, last: u16, h: Io_Handler) {
	handler := h
	handler.width = .Byte_Decomposed
	bus_register(b, first, last, handler)
}

bus_register_passive :: proc(b: ^Bus, value: u8, ports: ..u16) {
	for p in ports {b.passive[p] = value}
}

bus_whitelist :: proc(b: ^Bus, ports: ..u16) {
	bus_register_passive(b, 0xFF, ..ports)
}

bus_freeze :: proc(b: ^Bus, msg: string) {
	if b.frozen { return } // keep the first cause: later exits pile up behind it
	b.frozen = true
	b.freeze_msg = msg
	log.errorf("VM frozen: %s", msg)
}

@(private = "file")
bus_open_value :: proc(size: u8) -> u32 {
	if size == 0 || size > 4 {return 0xFFFF_FFFF}
	return 0xFFFF_FFFF >> (32 - 8*u32(size))
}

@(private = "file")
bus_unclassified_key :: proc(port: u16, write: bool, size: u8) -> u64 {
	return u64(port) | u64(size) << 16 | u64(write ? 1 : 0) << 24
}

@(private = "file")
bus_record_unclassified :: proc(b: ^Bus, access: Unclassified_Io) {
	b.unclassified_history[b.unclassified_count % BUS_UNCLASSIFIED_HISTORY] = access
	b.unclassified_count += 1
	key := bus_unclassified_key(access.port, access.write, access.size)
	if !b.unclassified_seen[key] {
		b.unclassified_seen[key] = true
		if b.log_unclassified {
			log.warnf(
				"open-bus %s port 0x%04x size %d%s",
				access.write ? "write" : "read",
				access.port,
				access.size,
				access.write ? fmt.tprintf(" value 0x%x", access.value) : "",
			)
		}
	}
}

@(private = "file")
bus_decomposed_read :: proc(b: ^Bus, port: u16, size: u8) -> (u32, bool) {
	value: u32
	for i in 0 ..< int(size) {
		byte_port := port + u16(i)
		h, ok := b.io[byte_port]
		if !ok || h.width != .Byte_Decomposed {return 0, false}
		value |= (h.read(h.ctx, byte_port, 1) & 0xFF) << (8 * u32(i))
	}
	return value, true
}

@(private = "file")
bus_decomposed_write :: proc(b: ^Bus, port: u16, size: u8, value: u32) -> bool {
	for i in 0 ..< int(size) {
		byte_port := port + u16(i)
		h, ok := b.io[byte_port]
		if !ok || h.width != .Byte_Decomposed {return false}
		h.write(h.ctx, byte_port, 1, value >> (8 * u32(i)))
	}
	return true
}

bus_io_read :: proc(b: ^Bus, port: u16, size: u8) -> u32 {
	if h, ok := b.io[port]; ok {
		if h.width == .Byte_Decomposed && size > 1 {
			if value, decomposed := bus_decomposed_read(b, port, size); decomposed {return value}
		}
		return h.read(h.ctx, port, size)
	}
	value: u32
	passive := true
	for i in 0 ..< int(size) {
		byte, ok := b.passive[port + u16(i)]
		if !ok {passive = false; break}
		value |= u32(byte) << (8 * u32(i))
	}
	if passive {return value}
	access := Unclassified_Io{port = port, size = size, value = bus_open_value(size)}
	bus_record_unclassified(b, access)
	if b.strict_io {bus_freeze(b, fmt.tprintf("unclassified port read 0x%04x size %d", port, size))}
	return access.value
}

bus_io_write :: proc(b: ^Bus, port: u16, size: u8, val: u32) {
	if h, ok := b.io[port]; ok {
		if h.width == .Byte_Decomposed && size > 1 && bus_decomposed_write(b, port, size, val) {return}
		h.write(h.ctx, port, size, val)
		return
	}
	passive := true
	for i in 0 ..< int(size) {
		if _, ok := b.passive[port + u16(i)]; !ok {passive = false; break}
	}
	if passive {return}
	access := Unclassified_Io{port = port, write = true, size = size, value = val}
	bus_record_unclassified(b, access)
	if b.strict_io {
		bus_freeze(b, fmt.tprintf("unclassified port write 0x%04x size %d val 0x%x", port, size, val))
	}
}
