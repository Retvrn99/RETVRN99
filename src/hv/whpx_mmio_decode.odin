// SPDX-License-Identifier: GPL-3.0-only
package hv

Whpx_Mmio_Kind :: enum {
	Invalid,
	Scalar_Load,
	Scalar_Store_Register,
	Scalar_Store_Immediate,
	Movs,
	Stos,
	Lods,
}

Whpx_Mmio_Extension :: enum {
	None,
	Zero,
	Sign,
}

Whpx_Mmio_Address :: struct {
	address_bits:    int,
	base_present:   bool,
	base_register:  u8,
	index_present:  bool,
	index_register: u8,
	scale:           u8,
	displacement:    u64,
	segment:         WHV_REGISTER_NAME,
}

Whpx_Mmio_Instruction :: struct {
	kind:             Whpx_Mmio_Kind,
	address:          Whpx_Mmio_Address,
	memory_width:     u8,
	register_width:   u8,
	register:         u8,
	immediate:        u32,
	extension:        Whpx_Mmio_Extension,
	rep:              bool,
	segment_override: bool,
	length:           u8,
}

@(private = "file")
whpx_mmio_decode_u16 :: proc(bytes: []u8, cursor: ^int) -> (u16, bool) {
	if cursor^ + 2 > len(bytes) {return 0, false}
	value := u16(bytes[cursor^]) | u16(bytes[cursor^ + 1]) << 8
	cursor^ += 2
	return value, true
}

@(private = "file")
whpx_mmio_decode_u32 :: proc(bytes: []u8, cursor: ^int) -> (u32, bool) {
	if cursor^ + 4 > len(bytes) {return 0, false}
	value := u32(bytes[cursor^]) |
		u32(bytes[cursor^ + 1]) << 8 |
		u32(bytes[cursor^ + 2]) << 16 |
		u32(bytes[cursor^ + 3]) << 24
	cursor^ += 4
	return value, true
}

@(private = "file")
whpx_mmio_sign_extend_byte :: proc(value: u8, bits: int) -> u64 {
	if value & 0x80 == 0 {return u64(value)}
	if bits == 16 {return u64(value) | 0xFF00}
	return u64(value) | 0xFFFF_FF00
}

@(private = "file")
whpx_mmio_decode_modrm :: proc(
	bytes: []u8,
	cursor: ^int,
	address_bits: int,
	address: ^Whpx_Mmio_Address,
) -> (
	u8,
	bool,
	string,
) {
	if cursor^ >= len(bytes) {return 0, false, "missing ModRM byte"}
	modrm := bytes[cursor^]
	cursor^ += 1
	mode := modrm >> 6
	reg := modrm >> 3 & 7
	rm := modrm & 7
	if mode == 3 {return reg, false, "ModRM does not name memory"}
	address.address_bits = address_bits
	address.scale = 1
	address.segment = .Ds

	if address_bits == 16 {
		switch rm {
		case 0:
			address.base_present = true
			address.base_register = 3
			address.index_present = true
			address.index_register = 6
		case 1:
			address.base_present = true
			address.base_register = 3
			address.index_present = true
			address.index_register = 7
		case 2:
			address.base_present = true
			address.base_register = 5
			address.index_present = true
			address.index_register = 6
			address.segment = .Ss
		case 3:
			address.base_present = true
			address.base_register = 5
			address.index_present = true
			address.index_register = 7
			address.segment = .Ss
		case 4:
			address.base_present = true
			address.base_register = 6
		case 5:
			address.base_present = true
			address.base_register = 7
		case 6:
			if mode == 0 {
				value, ok := whpx_mmio_decode_u16(bytes, cursor)
				if !ok {return reg, false, "missing 16-bit displacement"}
				address.displacement = u64(value)
				return reg, true, ""
			}
			address.base_present = true
			address.base_register = 5
			address.segment = .Ss
		case 7:
			address.base_present = true
			address.base_register = 3
		}
		switch mode {
		case 0:
		case 1:
			if cursor^ >= len(bytes) {return reg, false, "missing 8-bit displacement"}
			address.displacement = whpx_mmio_sign_extend_byte(bytes[cursor^], 16)
			cursor^ += 1
		case 2:
			value, ok := whpx_mmio_decode_u16(bytes, cursor)
			if !ok {return reg, false, "missing 16-bit displacement"}
			address.displacement = u64(value)
		}
		return reg, true, ""
	}

	if rm == 4 {
		if cursor^ >= len(bytes) {return reg, false, "missing SIB byte"}
		sib := bytes[cursor^]
		cursor^ += 1
		address.scale = u8(1) << (sib >> 6)
		index := sib >> 3 & 7
		base := sib & 7
		if index != 4 {
			address.index_present = true
			address.index_register = index
		}
		if mode != 0 || base != 5 {
			address.base_present = true
			address.base_register = base
			if base == 4 || base == 5 {address.segment = .Ss}
		}
	} else if mode != 0 || rm != 5 {
		address.base_present = true
		address.base_register = rm
		if rm == 5 {address.segment = .Ss}
	}

	switch mode {
	case 0:
		if !address.base_present {
			value, ok := whpx_mmio_decode_u32(bytes, cursor)
			if !ok {return reg, false, "missing 32-bit displacement"}
			address.displacement = u64(value)
		}
	case 1:
		if cursor^ >= len(bytes) {return reg, false, "missing 8-bit displacement"}
		address.displacement = whpx_mmio_sign_extend_byte(bytes[cursor^], 32)
		cursor^ += 1
	case 2:
		value, ok := whpx_mmio_decode_u32(bytes, cursor)
		if !ok {return reg, false, "missing 32-bit displacement"}
		address.displacement = u64(value)
	}
	return reg, true, ""
}

whpx_decode_mmio_instruction :: proc(
	bytes: []u8,
	default_32: bool,
) -> (
	Whpx_Mmio_Instruction,
	bool,
	string,
) {
	decoded: Whpx_Mmio_Instruction
	if len(bytes) == 0 {return decoded, false, "instruction bytes unavailable"}
	operand_bits := default_32 ? 32 : 16
	address_bits := default_32 ? 32 : 16
	cursor := 0
	prefixes := true
	for prefixes && cursor < len(bytes) && cursor < 15 {
		switch bytes[cursor] {
		case 0x26:
			decoded.address.segment = .Es
			decoded.segment_override = true
		case 0x2E:
			decoded.address.segment = .Cs
			decoded.segment_override = true
		case 0x36:
			decoded.address.segment = .Ss
			decoded.segment_override = true
		case 0x3E:
			decoded.address.segment = .Ds
			decoded.segment_override = true
		case 0x64:
			decoded.address.segment = .Fs
			decoded.segment_override = true
		case 0x65:
			decoded.address.segment = .Gs
			decoded.segment_override = true
		case 0x66:
			operand_bits = default_32 ? 16 : 32
		case 0x67:
			address_bits = default_32 ? 16 : 32
		case 0xF2, 0xF3:
			decoded.rep = true
		case 0xF0:
			return decoded, false, "LOCK is unsupported for MMIO fallback"
		case:
			prefixes = false
			continue
		}
		cursor += 1
	}
	if cursor >= len(bytes) || cursor >= 15 {
		return decoded, false, "missing opcode"
	}
	override_segment := decoded.address.segment
	opcode := bytes[cursor]
	cursor += 1

	switch opcode {
	case 0x88, 0x89, 0x8A, 0x8B, 0xC6, 0xC7:
		reg, ok, reason := whpx_mmio_decode_modrm(bytes, &cursor, address_bits, &decoded.address)
		if !ok {return decoded, false, reason}
		if decoded.segment_override {decoded.address.segment = override_segment}
		decoded.memory_width = 1 if opcode == 0x88 || opcode == 0x8A || opcode == 0xC6 else u8(operand_bits / 8)
		decoded.register_width = decoded.memory_width
		decoded.register = reg
		switch opcode {
		case 0x88, 0x89:
			decoded.kind = .Scalar_Store_Register
		case 0x8A, 0x8B:
			decoded.kind = .Scalar_Load
		case 0xC6, 0xC7:
			if reg != 0 {return decoded, false, "MOV immediate requires ModRM /0"}
			decoded.kind = .Scalar_Store_Immediate
			if decoded.memory_width == 1 {
				if cursor >= len(bytes) {return decoded, false, "missing 8-bit immediate"}
				decoded.immediate = u32(bytes[cursor])
				cursor += 1
			} else if decoded.memory_width == 2 {
				value, immediate_ok := whpx_mmio_decode_u16(bytes, &cursor)
				if !immediate_ok {return decoded, false, "missing 16-bit immediate"}
				decoded.immediate = u32(value)
			} else {
				value, immediate_ok := whpx_mmio_decode_u32(bytes, &cursor)
				if !immediate_ok {return decoded, false, "missing 32-bit immediate"}
				decoded.immediate = value
			}
		}
	case 0xA0, 0xA1, 0xA2, 0xA3:
		decoded.address.address_bits = address_bits
		decoded.address.scale = 1
		if !decoded.segment_override {decoded.address.segment = .Ds}
		if address_bits == 16 {
			value, ok := whpx_mmio_decode_u16(bytes, &cursor)
			if !ok {return decoded, false, "missing 16-bit moffs address"}
			decoded.address.displacement = u64(value)
		} else {
			value, ok := whpx_mmio_decode_u32(bytes, &cursor)
			if !ok {return decoded, false, "missing 32-bit moffs address"}
			decoded.address.displacement = u64(value)
		}
		decoded.memory_width = 1 if opcode == 0xA0 || opcode == 0xA2 else u8(operand_bits / 8)
		decoded.register_width = decoded.memory_width
		decoded.register = 0
		decoded.kind = .Scalar_Load if opcode == 0xA0 || opcode == 0xA1 else .Scalar_Store_Register
	case 0xA4, 0xA5, 0xAA, 0xAB, 0xAC, 0xAD:
		decoded.address.address_bits = address_bits
		decoded.address.scale = 1
		decoded.memory_width = 1 if opcode == 0xA4 || opcode == 0xAA || opcode == 0xAC else u8(operand_bits / 8)
		decoded.register_width = decoded.memory_width
		switch opcode {
		case 0xA4, 0xA5:
			decoded.kind = .Movs
			if !decoded.segment_override {decoded.address.segment = .Ds}
		case 0xAA, 0xAB:
			decoded.kind = .Stos
			decoded.address.segment = .Es
		case 0xAC, 0xAD:
			decoded.kind = .Lods
			if !decoded.segment_override {decoded.address.segment = .Ds}
		}
	case 0x0F:
		if cursor >= len(bytes) {return decoded, false, "missing two-byte opcode"}
		extended_opcode := bytes[cursor]
		cursor += 1
		if extended_opcode != 0xB6 && extended_opcode != 0xB7 &&
		   extended_opcode != 0xBE && extended_opcode != 0xBF {
			return decoded, false, "unsupported two-byte MMIO opcode"
		}
		reg, ok, reason := whpx_mmio_decode_modrm(bytes, &cursor, address_bits, &decoded.address)
		if !ok {return decoded, false, reason}
		if decoded.segment_override {decoded.address.segment = override_segment}
		decoded.memory_width = 1 if extended_opcode == 0xB6 || extended_opcode == 0xBE else 2
		decoded.register_width = u8(operand_bits / 8)
		if decoded.memory_width == decoded.register_width {
			return decoded, false, "MOV extension has no wider destination"
		}
		decoded.register = reg
		decoded.extension = .Zero if extended_opcode == 0xB6 || extended_opcode == 0xB7 else .Sign
		decoded.kind = .Scalar_Load
	case:
		return decoded, false, "unsupported MMIO opcode"
	}

	if cursor > 15 {return decoded, false, "instruction exceeds 15 bytes"}
	decoded.length = u8(cursor)
	return decoded, true, ""
}
