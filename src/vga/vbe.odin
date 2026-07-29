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
DISPI_ID1 :: u16(0xB0C1)
DISPI_ID2 :: u16(0xB0C2)
DISPI_ID3 :: u16(0xB0C3)
DISPI_ID4 :: u16(0xB0C4)
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

Vbe_Bank_Alias :: struct {
	offset: int,
	size:   int,
}

dispi_bank_granularity :: proc(v: ^Vga) -> int {
	return v.dispi[DISPI_INDEX_ENABLE] & DISPI_BANK_GRANULARITY_32K != 0 ? 32 * 1024 : 64 * 1024
}

vga_vbe_enabled :: proc(v: ^Vga) -> bool {
	return v.dispi[DISPI_INDEX_ENABLE] & DISPI_ENABLED != 0
}

vga_vbe_lfb_enabled :: proc(v: ^Vga) -> bool {
	return vga_vbe_enabled(v) && v.dispi[DISPI_INDEX_ENABLE] & DISPI_LFB_ENABLED != 0
}

// Chain 4 with an untouched graphics controller addresses video memory byte for
// byte: `vga_planar_backing_range` resolves `(raw >> 2) * 4 + (raw & 3)`, which
// is `raw`, and `write_mode_result` collapses to a copy of the stored value.
// Every register named here is reached through a port write, and every port
// write refreshes the alias, so the guest cannot leave the identity armed under
// a configuration that no longer holds.
@(private = "file")
vga_chain4_identity_aperture :: proc(v: ^Vga) -> bool {
	// Chain 4 on, and the window based at A0000h so the aperture offset is the
	// backing offset. Map selects 2 and 3 move the window to B0000h/B8000h.
	if v.seq[4] & 0x08 == 0 {return false}
	if (v.gfx[6] >> 2) & 3 > 1 {return false}
	// Every plane writable. Chain 4 narrows the map mask to the plane the address
	// selects, so a cleared bit would drop one address in four: unlike VirtualBox,
	// which checks two bits, all four have to be set.
	if v.seq[2] & 0x0F != 0x0F {return false}
	// Write mode 0 and read mode 0.
	if v.gfx[5] & 0x03 != 0 || v.gfx[5] & 0x08 != 0 {return false}
	// Set/reset off, no rotation, replace, full bit mask: the write reduces to the
	// value the guest stored, with the latches unread.
	if v.gfx[1] & 0x0F != 0 {return false}
	if v.gfx[3] != 0 {return false}
	if v.gfx[8] != 0xFF {return false}
	return true
}

vga_vbe_bank_alias :: proc(v: ^Vga) -> (Vbe_Bank_Alias, bool) {
	if v == nil || v.vram == nil || !v.pci_memory_enabled || !legacy_video_memory_enabled(v) {
		return {}, false
	}
	if !vga_vbe_enabled(v) {
		if !vga_chain4_identity_aperture(v) || DISPI_BANK_SIZE > len(v.vram) {return {}, false}
		return Vbe_Bank_Alias{offset = 0, size = DISPI_BANK_SIZE}, true
	}
	if dispi_effective_bpp(v.dispi[DISPI_INDEX_BPP]) == 4 || v.bank_read != v.bank_write {
		return {}, false
	}
	offset := int(v.bank_read) * dispi_bank_granularity(v)
	if offset < 0 || offset + DISPI_BANK_SIZE > len(v.vram) {return {}, false}
	return Vbe_Bank_Alias{offset = offset, size = DISPI_BANK_SIZE}, true
}

vga_publish_external_lfb_writes :: proc(v: ^Vga, dirty: bool) -> bool {
	if v == nil || !dirty || !vga_vbe_lfb_enabled(v) {return false}
	vga_note_content_change(v)
	return true
}

vga_publish_external_vbe_writes :: proc(v: ^Vga, dirty: bool) -> bool {
	if v == nil || !dirty || !vga_vbe_enabled(v) {return false}
	vga_note_content_change(v)
	return true
}

vga_publish_external_backing_writes :: proc(v: ^Vga, dirty: bool) -> bool {
	if v == nil || !dirty {return false}
	vga_note_memory_change(v)
	return true
}

vga_publish_external_backing_writes_paired :: proc(v: ^Vga, g: ^Gsw_Vga, dirty: bool) -> bool {
	gsw_dirty := gsw_presentation_publish_external_backing_writes(g, dirty)
	legacy_dirty := vga_publish_external_backing_writes(v, dirty)
	return gsw_dirty || legacy_dirty
}

vga_vbe_pitch :: proc(v: ^Vga) -> int {
	width := int(v.dispi[DISPI_INDEX_VIRT_WIDTH])
	if width == 0 {width = int(v.dispi[DISPI_INDEX_XRES])}
	return dispi_pitch(width, int(dispi_effective_bpp(v.dispi[DISPI_INDEX_BPP])))
}

@(private = "package")
dispi_pitch :: proc(width, bpp: int) -> int {
	switch bpp {
	case 4:
		return (width + 7) / 8
	case 8:
		return width
	case 15, 16:
		return width * 2
	case 24:
		return width * 3
	case 32:
		return width * 4
	}
	return 0
}

@(private = "package")
dispi_effective_bpp :: proc(bpp: u16) -> u16 {
	return bpp == 0 ? 8 : bpp
}

@(private = "package")
dispi_supported_bpp :: proc(bpp: u16) -> bool {
	return bpp == 4 || bpp == 8 || bpp == 15 || bpp == 16 || bpp == 24 || bpp == 32
}

@(private = "package")
dispi_supported_bpp_for_id :: proc(id, bpp: u16) -> bool {
	effective := dispi_effective_bpp(bpp)
	if id < DISPI_ID2 {return effective == 8}
	return dispi_supported_bpp(effective)
}

@(private = "package")
dispi_index_available :: proc(v: ^Vga, index: u16) -> bool {
	id := v.dispi[DISPI_INDEX_ID]
	switch int(index) {
	case DISPI_INDEX_ID,
	     DISPI_INDEX_XRES,
	     DISPI_INDEX_YRES,
	     DISPI_INDEX_BPP,
	     DISPI_INDEX_ENABLE,
	     DISPI_INDEX_BANK:
		return id >= DISPI_ID0
	case DISPI_INDEX_VIRT_WIDTH,
	     DISPI_INDEX_VIRT_HEIGHT,
	     DISPI_INDEX_X_OFFSET,
	     DISPI_INDEX_Y_OFFSET:
		return id >= DISPI_ID1
	case DISPI_INDEX_DDC:
		return id >= DISPI_ID5
	case DISPI_INDEX_VIDEO_MEMORY_64K:
		// The selected ID gates features, never capacity. The memory-size
		// register stays readable at every ID so a guest that negotiates an
		// older feature level can still discover the true size instead of
		// reading open bus. See ADR 0011.
		return true
	}
	return false
}

@(private = "package")
dispi_enable_mask :: proc(v: ^Vga) -> u16 {
	mask := DISPI_ENABLED
	id := v.dispi[DISPI_INDEX_ID]
	if id >= DISPI_ID2 {mask |= DISPI_LFB_ENABLED | DISPI_NOCLEARMEM}
	if id >= DISPI_ID3 {mask |= DISPI_GETCAPS | DISPI_8BIT_DAC}
	if id >= DISPI_ID5 {mask |= DISPI_BANK_GRANULARITY_32K}
	return mask
}

@(private = "package")
dispi_virtual_height :: proc(regs: ^[12]u16) -> int {
	pitch := dispi_pitch(
		int(regs[DISPI_INDEX_VIRT_WIDTH]),
		int(dispi_effective_bpp(regs[DISPI_INDEX_BPP])),
	)
	if pitch <= 0 {return 0}
	available := dispi_effective_bpp(regs[DISPI_INDEX_BPP]) == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
	return available / pitch
}

@(private = "package")
dispi_adjust_virtual_width :: proc(regs: ^[12]u16, requested: u16) -> u16 {
	x := int(regs[DISPI_INDEX_XRES])
	y := max(int(regs[DISPI_INDEX_YRES]), 1)
	bpp := int(dispi_effective_bpp(regs[DISPI_INDEX_BPP]))
	if x <= 0 || !dispi_supported_bpp(u16(bpp)) {return requested}
	available := bpp == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
	max_pitch := available / y
	max_width: int
	switch bpp {
	case 4:
		max_width = max_pitch * 8
	case 8:
		max_width = max_pitch
	case 15, 16:
		max_width = max_pitch / 2
	case 24:
		max_width = max_pitch / 3
	case 32:
		max_width = max_pitch / 4
	}
	if max_width <= 0 {return requested}
	width := int(requested)
	if width == 0 || width < x {width = x}
	// VBE 2.0 4.9 answers with the achievable width rather than the requested
	// one. Eight pixels share a byte at four bits per pixel, so a width that is
	// not a multiple of eight has no byte pitch: rounding it up here is what
	// keeps the firmware's own pitch arithmetic, which floors, agreeing with the
	// layout `dispi_pitch` lays down, which rounds up.
	if bpp == 4 {width = (width + 7) / 8 * 8}
	width = min(width, max_width, int(max(u16)))
	return u16(width)
}

@(private = "package")
dispi_clamp_offsets :: proc(regs: ^[12]u16) {
	virtual_width := int(regs[DISPI_INDEX_VIRT_WIDTH])
	if virtual_width == 0 {virtual_width = int(regs[DISPI_INDEX_XRES])}
	virtual_height := dispi_virtual_height(regs)
	max_x := max(virtual_width - int(regs[DISPI_INDEX_XRES]), 0)
	max_y := max(virtual_height - int(regs[DISPI_INDEX_YRES]), 0)
	regs[DISPI_INDEX_X_OFFSET] = u16(min(int(regs[DISPI_INDEX_X_OFFSET]), max_x))
	regs[DISPI_INDEX_Y_OFFSET] = u16(min(int(regs[DISPI_INDEX_Y_OFFSET]), max_y))
}

@(private = "package")
dispi_mode_valid :: proc(regs: ^[12]u16) -> bool {
	x := int(regs[DISPI_INDEX_XRES])
	y := int(regs[DISPI_INDEX_YRES])
	bpp := int(dispi_effective_bpp(regs[DISPI_INDEX_BPP]))
	virtual_width := int(regs[DISPI_INDEX_VIRT_WIDTH])
	if virtual_width == 0 {virtual_width = x}
	if x <= 0 ||
	   x > DISPI_MAX_XRES ||
	   y <= 0 ||
	   y > DISPI_MAX_YRES ||
	   !dispi_supported_bpp(u16(bpp)) {return false}
	if virtual_width < x {return false}
	pitch := dispi_pitch(virtual_width, bpp)
	if pitch <= 0 || pitch > VRAM_SIZE {return false}
	available := bpp == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
	virtual_height := available / pitch
	if virtual_height < y {return false}
	xoff := int(regs[DISPI_INDEX_X_OFFSET])
	yoff := int(regs[DISPI_INDEX_Y_OFFSET])
	if xoff < 0 || yoff < 0 || xoff + x > virtual_width || yoff + y > virtual_height {return false}
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
	if size == 1 {return u32(value & 0xFF)}
	return u32(value)
}

dispi_read_register :: proc(v: ^Vga, index: u16) -> u16 {
	if index >= u16(len(v.dispi)) {return 0xFFFF}
	if !dispi_index_available(v, index) {return 0xFFFF}
	if v.dispi[DISPI_INDEX_ENABLE] & DISPI_GETCAPS != 0 && v.dispi[DISPI_INDEX_ID] >= DISPI_ID3 {
		switch int(index) {
		case DISPI_INDEX_XRES:
			return DISPI_MAX_XRES
		case DISPI_INDEX_YRES:
			return DISPI_MAX_YRES
		case DISPI_INDEX_BPP:
			return 32
		case DISPI_INDEX_BANK:
			return DISPI_BANK_GRANULARITY_32K << 8
		}
	}
	switch int(index) {
	case DISPI_INDEX_DDC:
		return ddc_read_register(v)
	case DISPI_INDEX_BANK:
		return v.bank_read
	case DISPI_INDEX_VIRT_HEIGHT:
		return u16(min(dispi_virtual_height(&v.dispi), 0xFFFF))
	case DISPI_INDEX_VIDEO_MEMORY_64K:
		return u16(VRAM_SIZE / 65536)
	}
	return v.dispi[index]
}

dispi_write_register :: proc(v: ^Vga, index, value: u16) -> bool {
	if index >= u16(len(v.dispi)) {return false}
	if !dispi_index_available(v, index) {return false}
	switch int(index) {
	case DISPI_INDEX_ID:
		if value < DISPI_ID0 || value > DISPI_ID5 {return false}
		v.dispi[index] = value
		return true
	case DISPI_INDEX_ENABLE:
		flags := value & dispi_enable_mask(v)
		candidate := v.dispi
		candidate[DISPI_INDEX_ENABLE] = flags
		candidate[DISPI_INDEX_BPP] = dispi_effective_bpp(candidate[DISPI_INDEX_BPP])
		if flags & DISPI_ENABLED != 0 {
			candidate[DISPI_INDEX_VIRT_WIDTH] = candidate[DISPI_INDEX_XRES]
			candidate[DISPI_INDEX_X_OFFSET] = 0
			candidate[DISPI_INDEX_Y_OFFSET] = 0
		}
		if flags & DISPI_ENABLED != 0 &&
		   (!dispi_supported_bpp_for_id(candidate[DISPI_INDEX_ID], candidate[DISPI_INDEX_BPP]) ||
				   !dispi_mode_valid(&candidate)) {
			return false
		}
		was_enabled := vga_vbe_enabled(v)
		if !was_enabled &&
		   flags & DISPI_ENABLED != 0 &&
		   flags & DISPI_NOCLEARMEM == 0 &&
		   v.vram != nil {
			for &b in v.vram {b = 0}
		}
		v.dispi = candidate
		vga_recalculate_timing(v)
		return true
	case DISPI_INDEX_XRES, DISPI_INDEX_YRES, DISPI_INDEX_BPP:
		if vga_vbe_enabled(v) {return false}
		stored := int(index) == DISPI_INDEX_BPP ? dispi_effective_bpp(value) : value
		if int(index) == DISPI_INDEX_BPP &&
		   !dispi_supported_bpp_for_id(v.dispi[DISPI_INDEX_ID], stored) {
			return false
		}
		v.dispi[index] = stored
		if int(index) == DISPI_INDEX_XRES {
			v.dispi[DISPI_INDEX_VIRT_WIDTH] = stored
		}
		return true
	case DISPI_INDEX_VIRT_WIDTH:
		candidate := v.dispi
		candidate[index] = dispi_adjust_virtual_width(&candidate, value)
		dispi_clamp_offsets(&candidate)
		if !dispi_mode_valid(&candidate) {return false}
		v.dispi = candidate
		return true
	case DISPI_INDEX_X_OFFSET, DISPI_INDEX_Y_OFFSET:
		candidate := v.dispi
		candidate[index] = value
		if !dispi_mode_valid(&candidate) {return false}
		v.dispi[index] = value
		return true
	case DISPI_INDEX_BANK:
		bank := value & 0x3FFF
		available := dispi_effective_bpp(v.dispi[DISPI_INDEX_BPP]) == 4 ? VRAM_SIZE / 4 : VRAM_SIZE
		if int(bank) * dispi_bank_granularity(v) + DISPI_BANK_SIZE > available {return false}
		direction := value & DISPI_BANK_RW
		old_read, old_write := v.bank_read, v.bank_write
		if direction == 0 || direction & DISPI_BANK_RD != 0 {v.bank_read = bank}
		if direction == 0 || direction & DISPI_BANK_WR != 0 {v.bank_write = bank}
		v.bank_program_count += 1
		read_changed := old_read != v.bank_read
		write_changed := old_write != v.bank_write
		if read_changed {v.bank_read_change_count += 1}
		if write_changed {v.bank_write_change_count += 1}
		if read_changed || write_changed {v.bank_change_count += 1}
		v.dispi[index] = bank
		return true
	case DISPI_INDEX_DDC:
		return ddc_write_register(v, value)
	case DISPI_INDEX_VIRT_HEIGHT, DISPI_INDEX_VIDEO_MEMORY_64K:
		return false
	}
	return false
}
