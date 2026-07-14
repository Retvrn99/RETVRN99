// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:fmt"
import "core:log"

BUS_UNCLASSIFIED_HISTORY :: 64
BUS_UNCLASSIFIED_MMIO_HISTORY :: 32

Io_Width_Policy :: enum {
	Native,
	Byte_Decomposed,
}

Io_Handler :: struct {
	ctx:   rawptr,
	read:  proc(ctx: rawptr, port: u16, size: u8) -> u32,
	write: proc(ctx: rawptr, port: u16, size: u8, val: u32),
	stream_read:  proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int,
	stream_write: proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> int,
	width: Io_Width_Policy,
}

Unclassified_Io :: struct {
	port:  u16,
	write: bool,
	size:  u8,
	value: u32,
}

Unclassified_Mmio :: struct {
	gpa:   u64,
	write: bool,
	size:  u32,
}

Bus :: struct {
	io:                   []Io_Handler,
	passive:              []u16,
	unclassified_seen:    map[u64]bool,
	unclassified_mmio_seen: map[u64]bool,
	unclassified_history: [BUS_UNCLASSIFIED_HISTORY]Unclassified_Io,
	unclassified_mmio_history: [BUS_UNCLASSIFIED_MMIO_HISTORY]Unclassified_Mmio,
	modeled_count:        u64,
	passive_count:        u64,
	unclassified_count:   u64,
	unclassified_mmio_count: u64,
	strict_io:            bool,
	log_unclassified:     bool,
	diagnostic_tracing:   bool,
	frozen:               bool,
	freeze_msg:           string,
}

bus_init :: proc(b: ^Bus) {
	b.io = make([]Io_Handler, 0x1_0000)
	b.passive = make([]u16, 0x1_0000)
	b.unclassified_seen = {}
	b.unclassified_mmio_seen = {}
}

bus_destroy :: proc(b: ^Bus) {
	delete(b.io)
	delete(b.passive)
	delete(b.unclassified_seen)
	delete(b.unclassified_mmio_seen)
}

bus_set_strict_io :: proc(b: ^Bus, strict: bool) {
	b.strict_io = strict
	if strict {b.diagnostic_tracing = true}
}

bus_set_log_unclassified :: proc(b: ^Bus, enabled: bool) {
	b.log_unclassified = enabled
	if enabled {b.diagnostic_tracing = true}
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
	for p in ports {b.passive[int(p)] = u16(value) + 1}
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
	b.unclassified_count += 1
	if !b.diagnostic_tracing {return}
	b.unclassified_history[(b.unclassified_count - 1) % BUS_UNCLASSIFIED_HISTORY] = access
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

bus_record_unclassified_mmio :: proc(b: ^Bus, access: Unclassified_Mmio) {
	b.unclassified_mmio_count += 1
	if !b.diagnostic_tracing {return}
	b.unclassified_mmio_history[(b.unclassified_mmio_count - 1) % BUS_UNCLASSIFIED_MMIO_HISTORY] = access
	key := access.gpa &~ u64(0xFFF) | u64(access.write ? 1 : 0)
	if b.unclassified_mmio_seen[key] {return}
	b.unclassified_mmio_seen[key] = true
	if b.log_unclassified {
		log.warnf(
			"open-bus MMIO %s gpa=0x%x size=%d",
			access.write ? "write" : "read",
			access.gpa,
			access.size,
		)
	}
}

@(private = "file")
bus_decomposed_read :: proc(b: ^Bus, port: u16, size: u8) -> (u32, bool) {
	value: u32
	for i in 0 ..< int(size) {
		byte_port := port + u16(i)
		h := b.io[int(byte_port)]
		if h.read == nil || h.width != .Byte_Decomposed {return 0, false}
		value |= (h.read(h.ctx, byte_port, 1) & 0xFF) << (8 * u32(i))
	}
	return value, true
}

@(private = "file")
bus_decomposed_write :: proc(b: ^Bus, port: u16, size: u8, value: u32) -> bool {
	for i in 0 ..< int(size) {
		byte_port := port + u16(i)
		h := b.io[int(byte_port)]
		if h.write == nil || h.width != .Byte_Decomposed {return false}
		h.write(h.ctx, byte_port, 1, value >> (8 * u32(i)))
	}
	return true
}

bus_io_read :: proc(b: ^Bus, port: u16, size: u8) -> u32 {
	h := b.io[int(port)]
	if h.read != nil {
		b.modeled_count += 1
		if h.width == .Byte_Decomposed && size > 1 {
			if value, decomposed := bus_decomposed_read(b, port, size); decomposed {return value}
		}
		return h.read(h.ctx, port, size)
	}
	value: u32
	passive := true
	for i in 0 ..< int(size) {
		encoded := b.passive[int(port + u16(i))]
		if encoded == 0 {passive = false; break}
		value |= u32(encoded - 1) << (8 * u32(i))
	}
	if passive {
		b.passive_count += 1
		return value
	}
	access := Unclassified_Io{port = port, size = size, value = bus_open_value(size)}
	bus_record_unclassified(b, access)
	if b.strict_io {bus_freeze(b, fmt.tprintf("unclassified port read 0x%04x size %d", port, size))}
	return access.value
}

bus_io_write :: proc(b: ^Bus, port: u16, size: u8, val: u32) {
	h := b.io[int(port)]
	if h.write != nil {
		b.modeled_count += 1
		if h.width == .Byte_Decomposed && size > 1 && bus_decomposed_write(b, port, size, val) {return}
		h.write(h.ctx, port, size, val)
		return
	}
	passive := true
	for i in 0 ..< int(size) {
		if b.passive[int(port + u16(i))] == 0 {passive = false; break}
	}
	if passive {
		b.passive_count += 1
		return
	}
	access := Unclassified_Io{port = port, write = true, size = size, value = val}
	bus_record_unclassified(b, access)
	if b.strict_io {
		bus_freeze(b, fmt.tprintf("unclassified port write 0x%04x size %d val 0x%x", port, size, val))
	}
}

bus_io_stream_read :: proc(b: ^Bus, port: u16, size: u8, data: []u8) -> (int, bool) {
	if size == 0 || len(data) % int(size) != 0 {return 0, false}
	h := b.io[int(port)]
	if h.stream_read == nil {return 0, false}
	completed := clamp(h.stream_read(h.ctx, port, size, data), 0, len(data) / int(size))
	b.modeled_count += u64(completed)
	return completed, true
}

bus_io_stream_write :: proc(b: ^Bus, port: u16, size: u8, data: []u8) -> (int, bool) {
	if size == 0 || len(data) % int(size) != 0 {return 0, false}
	h := b.io[int(port)]
	if h.stream_write == nil {return 0, false}
	completed := clamp(h.stream_write(h.ctx, port, size, data), 0, len(data) / int(size))
	b.modeled_count += u64(completed)
	return completed, true
}
