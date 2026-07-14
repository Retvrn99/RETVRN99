// SPDX-License-Identifier: GPL-3.0-only
package vga

DISPI_PORT_INDEX :: u16(0x01CE)
DISPI_PORT_DATA :: u16(0x01CF)

DISPI_INDEX_ID :: 0
DISPI_INDEX_XRES :: 1
DISPI_INDEX_YRES :: 2
DISPI_INDEX_BPP :: 3
DISPI_INDEX_ENABLE :: 4
DISPI_INDEX_BANK :: 5
DISPI_INDEX_VIRT_WIDTH :: 6
DISPI_INDEX_VIRT_HEIGHT :: 7
DISPI_INDEX_X_OFFSET :: 8
DISPI_INDEX_Y_OFFSET :: 9
DISPI_INDEX_VIDEO_MEMORY_64K :: 10
DISPI_INDEX_DDC :: 11

DISPI_ID0 :: u16(0xB0C0)
DISPI_ID5 :: u16(0xB0C5)
DISPI_ENABLED :: u16(0x0001)
DISPI_GETCAPS :: u16(0x0002)
DISPI_BANK_GRANULARITY_32K :: u16(0x0010)
DISPI_8BIT_DAC :: u16(0x0020)
DISPI_LFB_ENABLED :: u16(0x0040)
DISPI_NOCLEARMEM :: u16(0x0080)
DISPI_BANK_WR :: u16(0x4000)
DISPI_BANK_RD :: u16(0x8000)
DISPI_BANK_RW :: u16(0xC000)

DISPI_MAX_XRES :: 2560
DISPI_MAX_YRES :: 1600
DISPI_BANK_SIZE :: 64 * 1024
DISPI_BANK_GRANULARITY :: 32 * 1024

dispi_bank_granularity :: proc(v: ^Vga) -> int {
	return v.dispi[DISPI_INDEX_ENABLE] & DISPI_BANK_GRANULARITY_32K != 0 ? 32 * 1024 : 64 * 1024
}

vga_vbe_enabled :: proc(v: ^Vga) -> bool {
	return v.dispi[DISPI_INDEX_ENABLE] & DISPI_ENABLED != 0
}

vga_vbe_lfb_enabled :: proc(v: ^Vga) -> bool {
	return vga_vbe_enabled(v) && v.dispi[DISPI_INDEX_ENABLE] & DISPI_LFB_ENABLED != 0
}

vga_vbe_pitch :: proc(v: ^Vga) -> int {
	width := int(v.dispi[DISPI_INDEX_VIRT_WIDTH])
	if width == 0 { width = int(v.dispi[DISPI_INDEX_XRES]) }
	return dispi_pitch(width, int(v.dispi[DISPI_INDEX_BPP]))
}

@(private = "package")
dispi_pitch :: proc(width, bpp: int) -> int {
	switch bpp {
	case 4:  return (width + 7) / 8
	case 8:  return width
	case 15, 16: return width * 2
	case 24: return width * 3
	case 32: return width * 4
	}
	return 0
}

@(private = "package")
dispi_supported_bpp :: proc(bpp: u16) -> bool {
	return bpp == 4 || bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32
}

@(private = "package")
dispi_mode_valid :: proc(regs: ^[12]u16) -> bool {
	x := int(regs[DISPI_INDEX_XRES])
	y := int(regs[DISPI_INDEX_YRES])
	bpp := int(regs[DISPI_INDEX_BPP])
	virtual_width := int(regs[DISPI_INDEX_VIRT_WIDTH])
	if virtual_width == 0 { virtual_width = x }
	if x <= 0 || x > DISPI_MAX_XRES || y <= 0 || y > DISPI_MAX_YRES || !dispi_supported_bpp(u16(bpp)) { return false }
	if virtual_width < x { return false }
	pitch := dispi_pitch(virtual_width, bpp)
	if pitch <= 0 || pitch > VRAM_SIZE { return false }
	available := bpp == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
	virtual_height := available / pitch
	if virtual_height < y { return false }
	xoff := int(regs[DISPI_INDEX_X_OFFSET])
	yoff := int(regs[DISPI_INDEX_Y_OFFSET])
	if xoff < 0 || yoff < 0 || xoff + x > virtual_width || yoff + y > virtual_height { return false }
	return true
}

@(private = "package")
dispi_io_write :: proc(v: ^Vga, port: u16, size: u8, value: u32) -> bool {
	mask: u32 = size >= 2 ? 0xFFFF : 0xFF
	if port == DISPI_PORT_INDEX {
		v.dispi_index = u16(value & mask)
		return false
	}
	if port != DISPI_PORT_DATA {return false}
	old := dispi_read_register(v, v.dispi_index)
	merged := size >= 2 ? u16(value) : (old & 0xFF00) | u16(value & 0xFF)
	before := v.dispi
	bank_read, bank_write := v.bank_read, v.bank_write
	if !dispi_write_register(v, v.dispi_index, merged) {return false}
	return before != v.dispi || bank_read != v.bank_read || bank_write != v.bank_write
}

@(private = "package")
dispi_io_read :: proc(v: ^Vga, port: u16, size: u8) -> u32 {
	value := port == DISPI_PORT_INDEX ? v.dispi_index : dispi_read_register(v, v.dispi_index)
	if size == 1 { return u32(value & 0xFF) }
	return u32(value)
}

dispi_read_register :: proc(v: ^Vga, index: u16) -> u16 {
	if index >= u16(len(v.dispi)) { return 0xFFFF }
	if v.dispi[DISPI_INDEX_ENABLE] & DISPI_GETCAPS != 0 {
		switch int(index) {
		case DISPI_INDEX_XRES: return DISPI_MAX_XRES
		case DISPI_INDEX_YRES: return DISPI_MAX_YRES
		case DISPI_INDEX_BPP: return 32
		case DISPI_INDEX_BANK: return DISPI_BANK_GRANULARITY_32K << 8
		}
	}
	switch int(index) {
	case DISPI_INDEX_BANK:
		return v.bank_read
	case DISPI_INDEX_VIRT_HEIGHT:
		pitch := vga_vbe_pitch(v)
		available := v.dispi[DISPI_INDEX_BPP] == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
		return pitch > 0 ? u16(min(available / pitch, 0xFFFF)) : 0
	case DISPI_INDEX_VIDEO_MEMORY_64K:
		return u16(VRAM_SIZE / 65536)
	}
	return v.dispi[index]
}

dispi_write_register :: proc(v: ^Vga, index, value: u16) -> bool {
	if index >= u16(len(v.dispi)) { return false }
	switch int(index) {
	case DISPI_INDEX_ID:
		if value < DISPI_ID0 || value > DISPI_ID5 { return false }
		v.dispi[index] = value
		return true
	case DISPI_INDEX_ENABLE:
		allowed := DISPI_ENABLED | DISPI_GETCAPS | DISPI_BANK_GRANULARITY_32K | DISPI_8BIT_DAC | DISPI_LFB_ENABLED | DISPI_NOCLEARMEM
		flags := value & allowed
		if flags & DISPI_ENABLED != 0 && !dispi_mode_valid(&v.dispi) { return false }
		was_enabled := vga_vbe_enabled(v)
		if !was_enabled && flags & DISPI_ENABLED != 0 && flags & DISPI_NOCLEARMEM == 0 && v.vram != nil {
			for &b in v.vram { b = 0 }
		}
		v.dispi[index] = flags
		vga_recalculate_timing(v)
		return true
	case DISPI_INDEX_XRES, DISPI_INDEX_YRES, DISPI_INDEX_BPP:
		if vga_vbe_enabled(v) { return false }
		v.dispi[index] = value
		if int(index) == DISPI_INDEX_XRES {
			v.dispi[DISPI_INDEX_VIRT_WIDTH] = value
		}
		return true
	case DISPI_INDEX_VIRT_WIDTH:
		candidate := v.dispi
		candidate[index] = value
		if value == 0 { candidate[index] = candidate[DISPI_INDEX_XRES] }
		if !dispi_mode_valid(&candidate) { return false }
		v.dispi[index] = candidate[index]
		return true
	case DISPI_INDEX_X_OFFSET, DISPI_INDEX_Y_OFFSET:
		candidate := v.dispi
		candidate[index] = value
		if !dispi_mode_valid(&candidate) { return false }
		v.dispi[index] = value
		return true
	case DISPI_INDEX_BANK:
		bank := value & 0x3FFF
		available := v.dispi[DISPI_INDEX_BPP] == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
		if int(bank) * dispi_bank_granularity(v) + DISPI_BANK_SIZE > available { return false }
		direction := value & DISPI_BANK_RW
		if direction == 0 || direction & DISPI_BANK_RD != 0 { v.bank_read = bank }
		if direction == 0 || direction & DISPI_BANK_WR != 0 { v.bank_write = bank }
		v.dispi[index] = bank
		return true
	case DISPI_INDEX_VIRT_HEIGHT, DISPI_INDEX_VIDEO_MEMORY_64K, DISPI_INDEX_DDC:
		return false
	}
	return false
}
