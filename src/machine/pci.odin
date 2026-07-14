// SPDX-License-Identifier: GPL-3.0-only
package machine

import persona "../persona"

// Register behavior selectively adapted from IzarraVM d930de57acccbc6a70cda8cc5a603173bf23cd1c.

GSW_PCI_VENDOR_ID :: u16(0xFFFE) // private development ID; not PCI-SIG assigned
GSW_CHIPSET_PCI_DEVICE_ID :: u16(0x0001)
GSW_CHIPSET_CAPABILITY_OFFSET :: 0x40
GSW_CHIPSET_CAPABILITY_SIGNATURE :: u32(0x4357_5347) // "GSWC"
GSW_CHIPSET_CAPABILITY_VERSION :: u16(2)
GSW_CHIPSET_CAPABILITY_LENGTH :: u16(0x14)
GSW_CHIPSET_RAM_MIB :: persona.GUEST_PERSONA.ram_mib
GSW_CHIPSET_CPU_MHZ :: persona.GUEST_PERSONA.cpu_mhz
GSW_CHIPSET_MAX_UDMA_MODE :: persona.GUEST_PERSONA.max_udma_mode
GSW_CHIPSET_CD_SPEED :: persona.GUEST_PERSONA.cd_speed
GSW_CHIPSET_DVD_SPEED :: persona.GUEST_PERSONA.dvd_speed
GSW_CHIPSET_FLAG_PC133 :: u8(1 << 0)
GSW_CHIPSET_FLAG_BUS_MASTER_IDE :: u8(1 << 1)
GSW_CHIPSET_FLAG_DVD :: u8(1 << 2)
GSW_CHIPSET_FLAG_LEGACY_PC_AT :: u8(1 << 3)
GSW_CHIPSET_CAPABILITY_FLAGS ::
	GSW_CHIPSET_FLAG_PC133 |
	GSW_CHIPSET_FLAG_BUS_MASTER_IDE |
	GSW_CHIPSET_FLAG_DVD |
	GSW_CHIPSET_FLAG_LEGACY_PC_AT
GSW_CHIPSET_RESERVED_TIMELINE :: u16(0)
GSW_VGA_PCI_DEVICE_ID :: u16(0x0002)
GSW_VGA_CAPABILITY_OFFSET :: 0x40
GSW_VGA_CAPABILITY_SIGNATURE :: u32(0x5657_5347) // "GSWV"
GSW_VGA_CAPABILITY_VERSION :: u16(1)
GSW_VGA_CAPABILITY_LENGTH :: u16(0x14)
GSW_VGA_CONTROL_BAR :: u32(0xF100_0000)
GSW_VGA_FRAMEBUFFER_BAR :: u32(0xE000_0000)

PCI_CONFIG_ADDRESS_MASK :: u32(0x80FF_FFFC)
PCI_FUNCTION_COUNT :: 5
PCI_MECHANISM_2_KEY_MASK :: u8(0xF1)
PCI_MECHANISM_2_KEY :: u8(0xF0)
PIIX3_PIRQ_COUNT :: 4
PIIX3_IDE_BMIBA_DEFAULT :: u32(0x0000_C001)

Pci_Irq_Line_Proc :: proc(ctx: rawptr, irq: u8, asserted: bool)

Pci_Function :: struct {
	bus:        u8,
	device:     u8,
	function:   u8,
	cfg:        [256]u8,
	write_mask: [256]u8,
	w1c_mask:   [256]u8,
	bar_size_mask: [6]u32,
	bar_probe:     [6]bool,
}

Pci :: struct {
	addr:               u32,
	mechanism_2_enable: u8,
	mechanism_2_bus:    u8,
	functions:          [PCI_FUNCTION_COUNT]Pci_Function,
	pirq_asserted:      [PIIX3_PIRQ_COUNT]bool,
	pirq_routed_mask:   u16,
	irq_line_ctx:       rawptr,
	irq_line:           Pci_Irq_Line_Proc,
}

@(private = "file")
pci_seed_u16 :: proc(c: ^[256]u8, offset: int, value: u16) {
	c[offset] = u8(value)
	c[offset + 1] = u8(value >> 8)
}

@(private = "file")
pci_seed_function :: proc(f: ^Pci_Function, bus, device, function: u8, vendor_id, device_id: u16) {
	f.bus = bus
	f.device = device
	f.function = function
	pci_seed_u16(&f.cfg, 0x00, vendor_id)
	pci_seed_u16(&f.cfg, 0x02, device_id)
}

@(private = "file")
pci_seed_intel_common_write_masks :: proc(f: ^Pci_Function) {
	f.write_mask[0x0C] = 0xFF
	f.write_mask[0x0D] = 0xFF
	f.write_mask[0x3C] = 0xFF
}

@(private = "file")
pci_seed_command_status :: proc(
	f: ^Pci_Function,
	command, command_write_mask, status, status_w1c_mask: u16,
) {
	pci_seed_u16(&f.cfg, 0x04, command)
	pci_seed_u16(&f.cfg, 0x06, status)
	f.write_mask[0x04] = u8(command_write_mask)
	f.write_mask[0x05] = u8(command_write_mask >> 8)
	f.w1c_mask[0x06] = u8(status_w1c_mask)
	f.w1c_mask[0x07] = u8(status_w1c_mask >> 8)
}

@(private = "file")
pci_seed_intel_extended_write_masks :: proc(f: ^Pci_Function) {
	for i in 0x40 ..= 0xFF {f.write_mask[i] = 0xFF}
}

pci_init :: proc(p: ^Pci) {
	p^ = {}

	host := &p.functions[0]
	pci_seed_function(host, 0, 0, 0, 0x8086, 0x1237)
	host.cfg[0x0B] = 0x06
	pci_seed_intel_common_write_masks(host)
	pci_seed_intel_extended_write_masks(host)
	pci_seed_command_status(host, 0x0006, 0x0140, 0x0280, 0xF900)

	isa := &p.functions[1]
	pci_seed_function(isa, 0, 1, 0, 0x8086, 0x7000)
	isa.cfg[0x0A] = 0x01
	isa.cfg[0x0B] = 0x06
	isa.cfg[0x0E] = 0x80
	pci_seed_intel_common_write_masks(isa)
	pci_seed_intel_extended_write_masks(isa)
	pci_seed_command_status(isa, 0x0007, 0x0108, 0x0200, 0x7800)
	for i in 0 ..< PIIX3_PIRQ_COUNT {
		isa.cfg[0x60 + i] = 0x80
		isa.write_mask[0x60 + i] = 0x8F
	}

	ide := &p.functions[2]
	pci_seed_function(ide, 0, 1, 1, 0x8086, 0x7010)
	ide.cfg[0x09] = 0x80
	ide.cfg[0x0A] = 0x01
	ide.cfg[0x0B] = 0x01
	pci_seed_intel_common_write_masks(ide)
	pci_seed_command_status(ide, 0x0005, 0x0005, 0x0280, 0x3800)
	for i in 0x40 ..= 0x44 {ide.write_mask[i] = 0xFF}
	ide.cfg[0x20] = u8(PIIX3_IDE_BMIBA_DEFAULT & 0xFF)
	ide.cfg[0x21] = u8((PIIX3_IDE_BMIBA_DEFAULT >> 8) & 0xFF)
	ide.cfg[0x22] = u8((PIIX3_IDE_BMIBA_DEFAULT >> 16) & 0xFF)
	ide.cfg[0x23] = u8((PIIX3_IDE_BMIBA_DEFAULT >> 24) & 0xFF)
	ide.write_mask[0x20] = 0xF0
	ide.write_mask[0x21] = 0xFF
	ide.write_mask[0x22] = 0xFF
	ide.write_mask[0x23] = 0xFF

	chipset := &p.functions[3]
	pci_seed_function(chipset, 0, 3, 0, GSW_PCI_VENDOR_ID, GSW_CHIPSET_PCI_DEVICE_ID)
	chipset.cfg[0x08] = 0x01
	chipset.cfg[0x0A] = 0x80
	chipset.cfg[0x0B] = 0x08
	pci_seed_u16(&chipset.cfg, 0x2C, GSW_PCI_VENDOR_ID)
	pci_seed_u16(&chipset.cfg, 0x2E, GSW_CHIPSET_PCI_DEVICE_ID)
	cap := GSW_CHIPSET_CAPABILITY_OFFSET
	chipset.cfg[cap + 0] = u8(GSW_CHIPSET_CAPABILITY_SIGNATURE & 0xFF)
	chipset.cfg[cap + 1] = u8((GSW_CHIPSET_CAPABILITY_SIGNATURE >> 8) & 0xFF)
	chipset.cfg[cap + 2] = u8((GSW_CHIPSET_CAPABILITY_SIGNATURE >> 16) & 0xFF)
	chipset.cfg[cap + 3] = u8(GSW_CHIPSET_CAPABILITY_SIGNATURE >> 24)
	pci_seed_u16(&chipset.cfg, cap + 4, GSW_CHIPSET_CAPABILITY_VERSION)
	pci_seed_u16(&chipset.cfg, cap + 6, GSW_CHIPSET_CAPABILITY_LENGTH)
	pci_seed_u16(&chipset.cfg, cap + 8, GSW_CHIPSET_RAM_MIB)
	pci_seed_u16(&chipset.cfg, cap + 10, GSW_CHIPSET_CPU_MHZ)
	chipset.cfg[cap + 12] = GSW_CHIPSET_MAX_UDMA_MODE
	chipset.cfg[cap + 13] = GSW_CHIPSET_CD_SPEED
	chipset.cfg[cap + 14] = GSW_CHIPSET_DVD_SPEED
	chipset.cfg[cap + 15] = GSW_CHIPSET_CAPABILITY_FLAGS
	pci_seed_u16(&chipset.cfg, cap + 16, GSW_CHIPSET_RESERVED_TIMELINE)

	graphics := &p.functions[4]
	pci_seed_function(graphics, 0, 2, 0, GSW_PCI_VENDOR_ID, GSW_VGA_PCI_DEVICE_ID)
	graphics.cfg[0x08] = 0x01
	graphics.cfg[0x0A] = 0x00
	graphics.cfg[0x0B] = 0x03
	pci_seed_command_status(graphics, 0x0006, 0x0006, 0x0200, 0x7800)
	pci_seed_u16(&graphics.cfg, 0x2C, GSW_PCI_VENDOR_ID)
	pci_seed_u16(&graphics.cfg, 0x2E, GSW_VGA_PCI_DEVICE_ID)
	for i in 0 ..< 4 {
		graphics.cfg[0x10 + i] = u8(GSW_VGA_CONTROL_BAR >> (8 * uint(i)))
		graphics.cfg[0x14 + i] = u8(GSW_VGA_FRAMEBUFFER_BAR >> (8 * uint(i)))
	}
	graphics.bar_size_mask[0] = 0xFFFF_F000
	graphics.bar_size_mask[1] = 0xFE00_0000
	graphics.cfg[0x3C] = 11
	graphics.cfg[0x3D] = 1
	cap = GSW_VGA_CAPABILITY_OFFSET
	for i in 0 ..< 4 {graphics.cfg[cap + i] = u8(GSW_VGA_CAPABILITY_SIGNATURE >> (8 * uint(i)))}
	pci_seed_u16(&graphics.cfg, cap + 4, GSW_VGA_CAPABILITY_VERSION)
	pci_seed_u16(&graphics.cfg, cap + 6, GSW_VGA_CAPABILITY_LENGTH)
	pci_seed_u16(&graphics.cfg, cap + 8, u16(persona.GUEST_PERSONA.vram_bytes / (1024 * 1024)))
	pci_seed_u16(&graphics.cfg, cap + 10, persona.GUEST_PERSONA.graphics_core_mhz)
	graphics.cfg[cap + 12] = persona.GUEST_PERSONA.graphics_agp_rate
	graphics.cfg[cap + 13] = 1
	graphics.cfg[cap + 14] = 0x03
}

@(private = "file")
pci_size_mask :: proc(size: u8) -> u32 {
	switch size {
	case 1:
		return 0x0000_00FF
	case 2:
		return 0x0000_FFFF
	case 4:
		return 0xFFFF_FFFF
	}
	return 0xFFFF_FFFF
}

@(private = "file")
pci_access_valid :: proc(port, first_port, last_port: u16, size: u8) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	return port >= first_port && u32(port) + u32(size) - 1 <= u32(last_port)
}

@(private = "file")
pci_function_find :: proc(p: ^Pci, bus, device, function: u8) -> ^Pci_Function {
	for i in 0 ..< len(p.functions) {
		candidate := &p.functions[i]
		if candidate.bus == bus && candidate.device == device && candidate.function == function {
			return candidate
		}
	}
	return nil
}

@(private = "file")
pci_config_access_valid :: proc(reg: u32, size: u8) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	return reg < 256 && reg + u32(size) <= 256
}

@(private = "file")
pci_config_read :: proc(f: ^Pci_Function, reg: u32, size: u8) -> u32 {
	if f == nil || !pci_config_access_valid(reg, size) {return pci_size_mask(size)}
	value: u32
	for i in 0 ..< u32(size) {
		index := reg + i
		byte := f.cfg[index]
		if index >= 0x10 && index < 0x28 {
			bar := int((index - 0x10) / 4)
			if f.bar_probe[bar] {
				byte = u8(f.bar_size_mask[bar] >> (8 * ((index - 0x10) & 3)))
			}
		}
		value |= u32(byte) << (8 * i)
	}
	return value
}

@(private = "file")
pci_config_write :: proc(f: ^Pci_Function, reg: u32, size: u8, value: u32) {
	if f == nil || !pci_config_access_valid(reg, size) {return}
	if size == 4 && reg >= 0x10 && reg < 0x28 && reg & 3 == 0 {
		bar := int((reg - 0x10) / 4)
		if f.bar_size_mask[bar] != 0 {
			f.bar_probe[bar] = value == 0xFFFF_FFFF
			return
		}
	}
	for i in 0 ..< u32(size) {
		index := reg + i
		if index >= 0x10 && index < 0x28 {
			bar := int((index - 0x10) / 4)
			if f.bar_size_mask[bar] != 0 {f.bar_probe[bar] = false}
		}
		old := f.cfg[index]
		incoming := u8(value >> (8 * i))
		writable := f.write_mask[index] & ~f.w1c_mask[index]
		next := (old & ~writable) | (incoming & writable)
		next &= ~(incoming & f.w1c_mask[index])
		f.cfg[index] = next
	}
}

pci_mechanism_2_active :: proc(p: ^Pci) -> bool {
	return (p.mechanism_2_enable & PCI_MECHANISM_2_KEY_MASK) == PCI_MECHANISM_2_KEY
}

pci_mechanism_2_claims :: proc(p: ^Pci, port: u16, size: u8) -> bool {
	return pci_mechanism_2_active(p) && pci_access_valid(port, 0xC000, 0xCFFF, size)
}

pci_pirq_route :: proc(p: ^Pci, pirq: u8) -> (irq: u8, routed: bool) {
	if pirq >= PIIX3_PIRQ_COUNT {return 0, false}
	value := p.functions[1].cfg[0x60 + int(pirq)]
	irq = value & 0x0F
	if (value & 0x80) != 0 {return irq, false}
	switch irq {
	case 3, 4, 5, 6, 7, 9, 10, 11, 12, 14, 15:
		return irq, true
	}
	return irq, false
}

@(private = "file")
pci_pirq_compute_routed_mask :: proc(p: ^Pci) -> u16 {
	mask: u16
	for pirq in u8(0) ..< PIIX3_PIRQ_COUNT {
		if !p.pirq_asserted[pirq] {continue}
		if irq, routed := pci_pirq_route(p, pirq); routed {mask |= u16(1) << irq}
	}
	return mask
}

@(private = "file")
pci_pirq_drive_mask :: proc(p: ^Pci, old_mask, new_mask: u16) {
	if p.irq_line == nil {return}
	removed := old_mask &~ new_mask
	added := new_mask &~ old_mask
	for irq in u8(0) ..< 16 {
		bit := u16(1) << irq
		if removed & bit != 0 {p.irq_line(p.irq_line_ctx, irq, false)}
	}
	for irq in u8(0) ..< 16 {
		bit := u16(1) << irq
		if added & bit != 0 {p.irq_line(p.irq_line_ctx, irq, true)}
	}
}

@(private = "file")
pci_pirq_sync :: proc(p: ^Pci) {
	next := pci_pirq_compute_routed_mask(p)
	previous := p.pirq_routed_mask
	if previous == next {return}
	p.pirq_routed_mask = next
	pci_pirq_drive_mask(p, previous, next)
}

pci_set_irq_line_adapter :: proc(p: ^Pci, ctx: rawptr, line: Pci_Irq_Line_Proc) {
	if p.irq_line != nil {pci_pirq_drive_mask(p, p.pirq_routed_mask, 0)}
	p.irq_line_ctx = ctx
	p.irq_line = line
	if p.irq_line != nil {pci_pirq_drive_mask(p, 0, p.pirq_routed_mask)}
}

@(private = "file")
pci_pic_irq_line :: proc(ctx: rawptr, irq: u8, asserted: bool) {
	pic_set_irq_source_level((^Pic_Pair)(ctx), irq, .Pci_Pirq, asserted)
}

pci_connect_pic :: proc(p: ^Pci, pic: ^Pic_Pair) {
	pci_set_irq_line_adapter(p, pic, pic == nil ? nil : pci_pic_irq_line)
}

pci_pirq_set_level :: proc(p: ^Pci, pirq: u8, asserted: bool) -> bool {
	if pirq >= PIIX3_PIRQ_COUNT {return false}
	if p.pirq_asserted[pirq] == asserted {return true}
	p.pirq_asserted[pirq] = asserted
	pci_pirq_sync(p)
	return true
}

pci_pirq_is_asserted :: proc(p: ^Pci, pirq: u8) -> bool {
	return pirq < PIIX3_PIRQ_COUNT && p.pirq_asserted[pirq]
}

pci_pirq_active_irq_mask :: proc(p: ^Pci) -> u16 {
	return p.pirq_routed_mask
}

@(private = "file")
pci_ide_command :: proc(p: ^Pci) -> u16 {
	ide := &p.functions[2]
	return u16(ide.cfg[0x04]) | u16(ide.cfg[0x05]) << 8
}

pci_ide_io_enabled :: proc(p: ^Pci) -> bool {
	return (pci_ide_command(p) & 0x0001) != 0
}

pci_ide_bus_master_enabled :: proc(p: ^Pci) -> bool {
	return (pci_ide_command(p) & 0x0004) != 0
}

pci_gsw_vga_memory_enabled :: proc(p: ^Pci) -> bool {
	graphics := &p.functions[4]
	command := u16(graphics.cfg[0x04]) | u16(graphics.cfg[0x05]) << 8
	return command & 0x0002 != 0
}

pci_ide_bus_master_io_base :: proc(p: ^Pci) -> (base: u16, valid: bool) {
	ide := &p.functions[2]
	bar :=
		u32(ide.cfg[0x20]) |
		u32(ide.cfg[0x21]) << 8 |
		u32(ide.cfg[0x22]) << 16 |
		u32(ide.cfg[0x23]) << 24
	if (bar & 1) == 0 {return 0, false}
	address := bar & 0xFFFF_FFF0
	if address == 0 || address > 0x0000_FFF0 {return 0, false}
	return u16(address), true
}

pci_ide_bus_master_decode :: proc(p: ^Pci, port: u16, size: u8) -> (offset: u8, claimed: bool) {
	if !pci_ide_io_enabled(p) || pci_mechanism_2_claims(p, port, size) {return 0, false}
	base, valid := pci_ide_bus_master_io_base(p)
	if !valid || !pci_access_valid(port, base, base + 0x0F, size) {return 0, false}
	return u8(port - base), true
}

@(private = "file")
pci_decode_mechanism_1 :: proc(
	p: ^Pci,
	port: u16,
	size: u8,
) -> (
	f: ^Pci_Function,
	reg: u32,
	ok: bool,
) {
	if (p.addr & 0x8000_0000) == 0 || !pci_access_valid(port, 0xCFC, 0xCFF, size) {
		return nil, 0, false
	}
	bus := u8(p.addr >> 16)
	device := u8((p.addr >> 11) & 0x1F)
	function := u8((p.addr >> 8) & 0x07)
	f = pci_function_find(p, bus, device, function)
	return f, (p.addr & 0xFC) + u32(port - 0xCFC), f != nil
}

@(private = "file")
pci_decode_mechanism_2 :: proc(
	p: ^Pci,
	port: u16,
	size: u8,
) -> (
	f: ^Pci_Function,
	reg: u32,
	ok: bool,
) {
	if !pci_mechanism_2_claims(p, port, size) {
		return nil, 0, false
	}
	config_reg := u32(port & 0x00FF)
	if !pci_config_access_valid(config_reg, size) {return nil, 0, false}
	device := u8((port >> 8) & 0x0F)
	function := (p.mechanism_2_enable >> 1) & 0x07
	f = pci_function_find(p, p.mechanism_2_bus, device, function)
	return f, config_reg, f != nil
}

pci_in :: proc(p: ^Pci, port: u16, size: u8) -> u32 {
	if port == 0xCF8 {
		if size == 1 {return u32(p.mechanism_2_enable)}
		if size == 4 {return p.addr}
		return pci_size_mask(size)
	}
	if port == 0xCFA {
		if size == 1 {return u32(p.mechanism_2_bus)}
		return pci_size_mask(size)
	}
	if port >= 0xCF8 && port <= 0xCFB {return pci_size_mask(size)}
	if port >= 0xC000 && port <= 0xCFFF {
		f, reg, ok := pci_decode_mechanism_2(p, port, size)
		if !ok {return pci_size_mask(size)}
		return pci_config_read(f, reg, size)
	}
	f, reg, ok := pci_decode_mechanism_1(p, port, size)
	if !ok {return pci_size_mask(size)}
	return pci_config_read(f, reg, size)
}

pci_out :: proc(p: ^Pci, port: u16, size: u8, value: u32) {
	if port == 0xCF8 {
		if size == 1 {p.mechanism_2_enable = u8(value)}
		if size == 4 {p.addr = value & PCI_CONFIG_ADDRESS_MASK}
		return
	}
	if port == 0xCFA {
		if size == 1 {p.mechanism_2_bus = u8(value)}
		return
	}
	if port >= 0xCF8 && port <= 0xCFB {return}
	if port >= 0xC000 && port <= 0xCFFF {
		f, reg, ok := pci_decode_mechanism_2(p, port, size)
		if ok {
			pci_config_write(f, reg, size, value)
			pci_pirq_sync(p)
		}
		return
	}
	f, reg, ok := pci_decode_mechanism_1(p, port, size)
	if !ok {return}
	pci_config_write(f, reg, size, value)
	pci_pirq_sync(p)
}
