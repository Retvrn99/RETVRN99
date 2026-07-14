// SPDX-License-Identifier: GPL-3.0-only
package vga

// The planar latch and write-mode operations are adapted from DOSBox-X
// src/hardware/vga_memory.cpp at commit f3483ce. Copyright 2002-2021 The
// DOSBox Team, GPL-2.0-or-later. See DOSBOX_X_NOTICE.md in this directory.

vga_mmio_contains :: proc(gpa: u64, size: u8) -> bool {
	n := u64(max(size, 1))
	if gpa > max(u64) - n { return false }
	end := gpa + n
	return (gpa >= LEGACY_APERTURE_BASE && end <= LEGACY_APERTURE_END) ||
	       (gpa >= VBE_LFB_BASE && end <= VBE_LFB_END)
}

vga_mmio_read :: proc(v: ^Vga, gpa: u64, size: u8) -> (u32, bool) {
	if !vga_mmio_contains(gpa, size) || v.vram == nil { return 0, false }
	value: u32
	for i in 0 ..< int(max(size, 1)) {
		byte, ok := vga_memory_read_byte(v, gpa + u64(i))
		if !ok { return 0, false }
		value |= u32(byte) << uint(i * 8)
	}
	return value, true
}

vga_mmio_write :: proc(v: ^Vga, gpa: u64, size: u8, value: u32) -> bool {
	if !vga_mmio_contains(gpa, size) || v.vram == nil { return false }
	wrote := false
	for i in 0 ..< int(max(size, 1)) {
		if !vga_memory_write_byte(v, gpa + u64(i), u8(value >> uint(i * 8))) {
			if wrote {vga_note_content_change(v)}
			return false
		}
		wrote = true
	}
	if wrote {vga_note_content_change(v)}
	return true
}

@(private = "package")
vga_memory_read_byte :: proc(v: ^Vga, gpa: u64) -> (u8, bool) {
	if gpa >= VBE_LFB_BASE && gpa < VBE_LFB_END {
		return v.vram[int(gpa - VBE_LFB_BASE)], true
	}
	if vga_vbe_enabled(v) && gpa >= 0xA0000 && gpa < 0xB0000 {
		offset := int(v.bank_read) * dispi_bank_granularity(v) + int(gpa - 0xA0000)
		if v.dispi[DISPI_INDEX_BPP] == 4 { return planar_read(v, offset, false), true }
		if offset >= 0 && offset < len(v.vram) { return v.vram[offset], true }
		return 0xFF, false
	}
	raw, ok := legacy_aperture_offset(v, gpa)
	if !ok { return 0xFF, false }
	return legacy_planar_read(v, raw), true
}

@(private = "package")
vga_memory_write_byte :: proc(v: ^Vga, gpa: u64, value: u8) -> bool {
	if gpa >= VBE_LFB_BASE && gpa < VBE_LFB_END {
		v.vram[int(gpa - VBE_LFB_BASE)] = value
		return true
	}
	if vga_vbe_enabled(v) && gpa >= 0xA0000 && gpa < 0xB0000 {
		offset := int(v.bank_write) * dispi_bank_granularity(v) + int(gpa - 0xA0000)
		if v.dispi[DISPI_INDEX_BPP] == 4 { planar_write(v, offset, value, false); return true }
		if offset >= 0 && offset < len(v.vram) { v.vram[offset] = value; return true }
		return false
	}
	raw, ok := legacy_aperture_offset(v, gpa)
	if !ok { return false }
	legacy_planar_write(v, raw, value)
	return true
}

@(private = "package")
legacy_aperture_offset :: proc(v: ^Vga, gpa: u64) -> (int, bool) {
	map_select := (v.gfx[6] >> 2) & 3
	switch map_select {
	case 0:
		if gpa >= 0xA0000 && gpa < 0xC0000 { return int(gpa - 0xA0000), true }
	case 1:
		if gpa >= 0xA0000 && gpa < 0xB0000 { return int(gpa - 0xA0000), true }
	case 2:
		if gpa >= 0xB0000 && gpa < 0xB8000 { return int(gpa - 0xB0000), true }
	case 3:
		if gpa >= 0xB8000 && gpa < 0xC0000 { return int(gpa - 0xB8000), true }
	}
	return 0, false
}

@(private = "package")
plane_byte :: proc(v: ^Vga, plane, offset: int) -> u8 {
	index := offset * 4 + plane
	if index < 0 || index >= len(v.vram) { return 0 }
	return v.vram[index]
}

@(private = "package")
set_plane_byte :: proc(v: ^Vga, plane, offset: int, value: u8) {
	index := offset * 4 + plane
	if index >= 0 && index < len(v.vram) { v.vram[index] = value }
}

@(private = "file")
load_latches :: proc(v: ^Vga, offset: int) {
	for plane in 0 ..< 4 { v.latch[plane] = plane_byte(v, plane, offset) }
}

@(private = "file")
legacy_planar_read :: proc(v: ^Vga, raw: int) -> u8 {
	return planar_read(v, raw, true)
}

@(private = "file")
planar_read :: proc(v: ^Vga, raw: int, wrap_legacy: bool) -> u8 {
	offset := raw
	plane := int(v.gfx[4] & 3)
	if v.seq[4] & 0x08 != 0 {
		plane = raw & 3
		offset = raw >> 2
	} else if v.gfx[5] & 0x10 != 0 && v.gfx[6] & 0x02 != 0 {
		plane = int(v.gfx[4] & 2) | (raw & 1)
		offset = raw >> 1
	}
	if wrap_legacy { offset &= LEGACY_PLANE_SIZE - 1 }
	load_latches(v, offset)
	if v.gfx[5] & 0x08 == 0 { return v.latch[plane] }
	compare := v.gfx[2] & 0x0F
	dont_care := v.gfx[7] & 0x0F
	result := u8(0xFF)
	for p in 0 ..< 4 {
		if dont_care & (u8(1) << uint(p)) != 0 {
			expected := compare & (u8(1) << uint(p)) != 0 ? u8(0xFF) : u8(0)
			result &= ~(v.latch[p] ~ expected)
		}
	}
	return result
}

@(private = "file")
legacy_planar_write :: proc(v: ^Vga, raw: int, value: u8) {
	planar_write(v, raw, value, true)
}

@(private = "file")
planar_write :: proc(v: ^Vga, raw: int, value: u8, wrap_legacy: bool) {
	offset := raw
	plane_mask := v.seq[2] & 0x0F
	if v.seq[4] & 0x08 != 0 {
		plane := raw & 3
		offset = raw >> 2
		plane_mask &= u8(1) << uint(plane)
	} else if v.seq[4] & 0x04 == 0 && v.gfx[6] & 0x02 != 0 {
		offset = raw >> 1
		plane_mask &= u8(0x05) << uint(raw & 1)
	}
	if wrap_legacy { offset &= LEGACY_PLANE_SIZE - 1 }
	result := write_mode_result(v, value)
	for plane in 0 ..< 4 {
		if plane_mask & (u8(1) << uint(plane)) != 0 { set_plane_byte(v, plane, offset, result[plane]) }
	}
}

@(private = "file")
rotate_right_8 :: proc(value: u8, count: u8) -> u8 {
	n := uint(count & 7)
	if n == 0 { return value }
	return value >> n | value << (8 - n)
}

@(private = "file")
raster_operation :: proc(op: u8, source, latch: u8) -> u8 {
	switch op & 3 {
	case 0: return source
	case 1: return source & latch
	case 2: return source | latch
	case 3: return source ~ latch
	}
	return source
}

@(private = "file")
write_mode_result :: proc(v: ^Vga, value: u8) -> [4]u8 {
	result: [4]u8
	mode := v.gfx[5] & 3
	rotated := rotate_right_8(value, v.gfx[3] & 7)
	operation := (v.gfx[3] >> 3) & 3
	for plane in 0 ..< 4 {
		latch := v.latch[plane]
		source: u8
		mask := v.gfx[8]
		switch mode {
		case 0:
			if v.gfx[1] & (u8(1) << uint(plane)) != 0 {
				source = v.gfx[0] & (u8(1) << uint(plane)) != 0 ? 0xFF : 0
			} else { source = rotated }
		case 1:
			result[plane] = latch
			continue
		case 2:
			source = value & (u8(1) << uint(plane)) != 0 ? 0xFF : 0
		case 3:
			source = v.gfx[0] & (u8(1) << uint(plane)) != 0 ? 0xFF : 0
			mask &= rotated
		}
		rop := raster_operation(operation, source, latch)
		result[plane] = (rop & mask) | (latch & ~mask)
	}
	return result
}
