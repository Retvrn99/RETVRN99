// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import persona "../persona"

// Register behavior selectively adapted from IzarraVM d930de57acccbc6a70cda8cc5a603173bf23cd1c.

GSW_PCI_VENDOR_ID :: u16(0xFFFE) // private development ID; not PCI-SIG assigned
GSW_VGA_PCI_DEVICE_ID :: u16(0x0002)
GSW_SOUND_PCI_DEVICE_ID :: u16(0x0003)
GSW_VGA_CAPABILITY_OFFSET :: 0x40
GSW_VGA_CAPABILITY_SIGNATURE :: u32(0x5657_5347) // "GSWV"
GSW_VGA_CAPABILITY_VERSION :: u16(2)
GSW_VGA_CAPABILITY_LENGTH :: u16(0x14)
GSW_VGA_CONTROL_BAR :: u32(0xF100_0000)
GSW_VGA_FRAMEBUFFER_BAR :: u32(0xE000_0000)
GSW_SOUND_CONTROL_BAR :: u32(sound.GSW_PCM_DEFAULT_CONTROL_BASE)
GSW_SOUND_PCI_EXPOSED_BY_DEFAULT :: false

PCI_CONFIG_ADDRESS_MASK :: u32(0x80FF_FFFC)
PCI_FUNCTION_COUNT :: 5
PCI_PIRQ_COUNT :: 4
PCI_PIRQ_A :: u8(0)
PCI_PIRQ_B :: u8(1)
PCI_PIRQ_C :: u8(2)
PCI_PIRQ_D :: u8(3)
PCI_GSW_VGA_PIRQ :: PCI_PIRQ_B
PCI_AMD756_IDE_PIRQ :: PCI_PIRQ_C
PCI_GSW_SOUND_PIRQ :: PCI_PIRQ_C
@(rodata)
PCI_PIRQ_IRQS := [PCI_PIRQ_COUNT]u8{10, 11, 10, 11}
AMD756_ISA_REVISION_ID :: u8(0x01)
AMD756_IDE_REVISION_ID :: u8(0x03)
AMD756_IDE_PROGRAMMING_INTERFACE :: u8(0x8A)
AMD756_IDE_PRIMARY_NATIVE_MODE :: u8(0x01)
AMD756_IDE_SECONDARY_NATIVE_MODE :: u8(0x04)
AMD756_IDE_PRIMARY_COMMAND_BAR_DEFAULT :: u32(0x0000_01F1)
AMD756_IDE_PRIMARY_CONTROL_BAR_DEFAULT :: u32(0x0000_03F5)
AMD756_IDE_SECONDARY_COMMAND_BAR_DEFAULT :: u32(0x0000_0171)
AMD756_IDE_SECONDARY_CONTROL_BAR_DEFAULT :: u32(0x0000_0375)
AMD756_IDE_BMIBA_DEFAULT :: u32(0x0000_CC01)
AMD756_ISA_BUS_CONTROL_1 :: 0x40
AMD756_ISA_ROM_DECODE_CONTROL :: 0x43
// ROMW gates ROMCS#; low BIOS-space MEMW# remains active when it is clear.
AMD756_ISA_ROM_WRITE_ENABLE :: u8(0x01)
AMD756_ISA_HIGH_BIOS_128K_DECODE :: u8(0x80)
AMD756_ISA_IDE_DISABLE :: u8(0x02)
AMD756_IDE_SECONDARY_CHANNEL_ENABLE :: u8(0x01)
AMD756_IDE_PRIMARY_CHANNEL_ENABLE :: u8(0x02)
AMD756_IDE_CHANNEL_ENABLE_FIXED :: u8(0x08)
AMD756_IDE_UDMA_TIMING_RESET :: u8(0x03)

PCI_HOST_FUNCTION_INDEX :: 0
PCI_ISA_FUNCTION_INDEX :: 1
PCI_IDE_FUNCTION_INDEX :: 2
PCI_GSW_VGA_FUNCTION_INDEX :: 3
PCI_GSW_SOUND_FUNCTION_INDEX :: 4

Pci_Pirq_Source :: enum u8 {
	Legacy,
	Gsw_Vga,
	Amd756_Ide,
	Gsw_Sound,
	Count,
}

Pci_Irq_Line_Proc :: proc(ctx: rawptr, irq: u8, asserted: bool)

Pci_Function :: struct {
	present:       bool,
	bus:           u8,
	device:        u8,
	function:      u8,
	cfg:           [256]u8,
	write_mask:    [256]u8,
	w1c_mask:      [256]u8,
	sticky_mask:   [256]u8,
	bar_size_mask: [6]u32,
	bar_probe:     [6]bool,
}

Pci :: struct {
	addr:             u32,
	functions:        [PCI_FUNCTION_COUNT]Pci_Function,
	pirq_source_counts: [PCI_PIRQ_COUNT][int(Pci_Pirq_Source.Count)]u16,
	pirq_routed_mask: u16,
	irq_line_ctx:     rawptr,
	irq_line:         Pci_Irq_Line_Proc,
}

@(private = "file")
pci_seed_u16 :: proc(c: ^[256]u8, offset: int, value: u16) {
	c[offset] = u8(value)
	c[offset + 1] = u8(value >> 8)
}

@(private = "file")
pci_seed_function :: proc(f: ^Pci_Function, bus, device, function: u8, vendor_id, device_id: u16) {
	f.present = true
	f.bus = bus
	f.device = device
	f.function = function
	pci_seed_u16(&f.cfg, 0x00, vendor_id)
	pci_seed_u16(&f.cfg, 0x02, device_id)
}

@(private = "file")
pci_seed_amd751_host_masks :: proc(f: ^Pci_Function) {
	f.write_mask[0x0D] = 0xFF
}

@(private = "file")
pci_seed_amd756_isa_masks :: proc(f: ^Pci_Function) {
	f.write_mask[0x40] = 0x0B
	f.write_mask[0x41] = 0xA9
	f.write_mask[AMD756_ISA_ROM_DECODE_CONTROL] = 0xFF
	f.write_mask[0x45] = 0x7F
	f.write_mask[0x46] = 0x01
	f.write_mask[0x47] = 0xF0
	f.write_mask[0x48] = 0x8F
	f.write_mask[0x49] = 0x4F
	f.sticky_mask[0x49] = 0x06
	f.write_mask[0x4A] = 0x8F
	f.write_mask[0x4B] = 0x1F
	for reg in 0x4C ..= 0x53 {f.write_mask[reg] = 0xFF}
	dma_registers := [?]int{0x60, 0x62, 0x64, 0x66, 0x6A, 0x6C, 0x6E}
	for reg in dma_registers {
		f.write_mask[reg] = 0xF8
		f.write_mask[reg + 1] = 0xFF
	}
}

@(private = "file")
pci_seed_amd756_ide_masks :: proc(f: ^Pci_Function) {
	f.write_mask[0x09] = AMD756_IDE_PRIMARY_NATIVE_MODE | AMD756_IDE_SECONDARY_NATIVE_MODE
	f.write_mask[0x0D] = 0xFF
	for reg in 0x10 ..= 0x13 {f.write_mask[reg] = 0xFF}
	f.write_mask[0x10] = 0xF8
	for reg in 0x14 ..= 0x17 {f.write_mask[reg] = 0xFF}
	f.write_mask[0x14] = 0xFC
	for reg in 0x18 ..= 0x1B {f.write_mask[reg] = 0xFF}
	f.write_mask[0x18] = 0xF8
	for reg in 0x1C ..= 0x1F {f.write_mask[reg] = 0xFF}
	f.write_mask[0x1C] = 0xFC
	f.write_mask[0x20] = 0xF0
	f.write_mask[0x21] = 0xFF
	f.write_mask[0x22] = 0xFF
	f.write_mask[0x23] = 0xFF
	f.write_mask[0x40] = 0x03
	f.write_mask[0x41] = 0xF0
	for reg in 0x48 ..= 0x4C {f.write_mask[reg] = 0xFF}
	for reg in 0x4E ..= 0x4F {f.write_mask[reg] = 0xFF}
	for reg in 0x50 ..= 0x53 {f.write_mask[reg] = 0xC7}
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

pci_init :: proc(p: ^Pci, expose_gsw_sound := GSW_SOUND_PCI_EXPOSED_BY_DEFAULT) {
	p^ = {}

	host := &p.functions[PCI_HOST_FUNCTION_INDEX]
	pci_seed_function(host, 0, 0, 0, 0x1022, 0x7006)
	host.cfg[0x08] = 0x21
	host.cfg[0x0B] = 0x06
	host.cfg[0x0E] = 0x80
	pci_seed_amd751_host_masks(host)
	pci_seed_command_status(host, 0x0004, 0x0102, 0x0200, 0x7800)

	isa := &p.functions[PCI_ISA_FUNCTION_INDEX]
	pci_seed_function(isa, 0, 7, 0, 0x1022, 0x7408)
	isa.cfg[0x08] = AMD756_ISA_REVISION_ID
	isa.cfg[0x0A] = 0x01
	isa.cfg[0x0B] = 0x06
	isa.cfg[0x0E] = 0x80
	pci_seed_command_status(isa, 0x000F, 0x0008, 0x0200, 0x3000)
	isa.cfg[0x48] = 0x01
	isa.cfg[0x49] = 0x08
	isa.cfg[0x4A] = 0x84
	isa.cfg[0x4F] = 0x03
	pci_seed_amd756_isa_masks(isa)

	ide := &p.functions[PCI_IDE_FUNCTION_INDEX]
	pci_seed_function(ide, 0, 7, 1, 0x1022, 0x7409)
	ide.cfg[0x08] = AMD756_IDE_REVISION_ID
	ide.cfg[0x09] = AMD756_IDE_PROGRAMMING_INTERFACE
	ide.cfg[0x0A] = 0x01
	ide.cfg[0x0B] = 0x01
	pci_seed_command_status(ide, 0x0000, 0x0005, 0x0200, 0x3000)
	ide_bars := [?]u32 {
		AMD756_IDE_PRIMARY_COMMAND_BAR_DEFAULT,
		AMD756_IDE_PRIMARY_CONTROL_BAR_DEFAULT,
		AMD756_IDE_SECONDARY_COMMAND_BAR_DEFAULT,
		AMD756_IDE_SECONDARY_CONTROL_BAR_DEFAULT,
	}
	for bar, bar_index in ide_bars {
		offset := 0x10 + bar_index * 4
		for byte in 0 ..< 4 {ide.cfg[offset + byte] = u8(bar >> (8 * uint(byte)))}
	}
	ide.bar_size_mask[0] = 0xFFFF_FFF9
	ide.bar_size_mask[1] = 0xFFFF_FFFD
	ide.bar_size_mask[2] = 0xFFFF_FFF9
	ide.bar_size_mask[3] = 0xFFFF_FFFD
	ide.cfg[0x20] = u8(AMD756_IDE_BMIBA_DEFAULT & 0xFF)
	ide.cfg[0x21] = u8((AMD756_IDE_BMIBA_DEFAULT >> 8) & 0xFF)
	ide.cfg[0x22] = u8((AMD756_IDE_BMIBA_DEFAULT >> 16) & 0xFF)
	ide.cfg[0x23] = u8((AMD756_IDE_BMIBA_DEFAULT >> 24) & 0xFF)
	ide.bar_size_mask[4] = 0xFFFF_FFF1
	ide.cfg[0x40] = AMD756_IDE_CHANNEL_ENABLE_FIXED
	for reg in 0x48 ..= 0x4B {ide.cfg[reg] = 0xA8}
	ide.cfg[0x4C] = 0xFF
	ide.cfg[0x4E] = 0xFF
	ide.cfg[0x4F] = 0xFF
	for reg in 0x50 ..= 0x53 {ide.cfg[reg] = AMD756_IDE_UDMA_TIMING_RESET}
	pci_seed_amd756_ide_masks(ide)

	graphics := &p.functions[PCI_GSW_VGA_FUNCTION_INDEX]
	pci_seed_function(graphics, 0, 2, 0, GSW_PCI_VENDOR_ID, GSW_VGA_PCI_DEVICE_ID)
	graphics.cfg[0x08] = 0x01
	graphics.cfg[0x0A] = 0x00
	graphics.cfg[0x0B] = 0x03
	pci_seed_command_status(graphics, 0x0006, 0x0007, 0x0200, 0x7800)
	pci_seed_u16(&graphics.cfg, 0x2C, GSW_PCI_VENDOR_ID)
	pci_seed_u16(&graphics.cfg, 0x2E, GSW_VGA_PCI_DEVICE_ID)
	for i in 0 ..< 4 {
		graphics.cfg[0x10 + i] = u8(GSW_VGA_CONTROL_BAR >> (8 * uint(i)))
		graphics.cfg[0x14 + i] = u8(GSW_VGA_FRAMEBUFFER_BAR >> (8 * uint(i)))
	}
	graphics.bar_size_mask[0] = 0xFFFF_F000
	graphics.bar_size_mask[1] = 0xFE00_0000
	graphics.write_mask[0x11] = 0xF0
	graphics.write_mask[0x12] = 0xFF
	graphics.write_mask[0x13] = 0xFF
	graphics.write_mask[0x17] = 0xFE
	graphics.cfg[0x3C] = 11
	graphics.cfg[0x3D] = 1
	cap := GSW_VGA_CAPABILITY_OFFSET
	for i in 0 ..< 4 {graphics.cfg[cap + i] = u8(GSW_VGA_CAPABILITY_SIGNATURE >> (8 * uint(i)))}
	pci_seed_u16(&graphics.cfg, cap + 4, GSW_VGA_CAPABILITY_VERSION)
	pci_seed_u16(&graphics.cfg, cap + 6, GSW_VGA_CAPABILITY_LENGTH)
	pci_seed_u16(&graphics.cfg, cap + 8, u16(persona.GUEST_PERSONA.vram_bytes / (1024 * 1024)))
	pci_seed_u16(&graphics.cfg, cap + 10, persona.GUEST_PERSONA.graphics_core_mhz)
	graphics.cfg[cap + 12] = persona.GUEST_PERSONA.graphics_agp_rate
	graphics.cfg[cap + 13] = u8(GSW_VGA_CAPABILITY_VERSION)
	graphics.cfg[cap + 14] = 0x03

	if expose_gsw_sound {
		audio := &p.functions[PCI_GSW_SOUND_FUNCTION_INDEX]
		pci_seed_function(audio, 0, 3, 0, GSW_PCI_VENDOR_ID, GSW_SOUND_PCI_DEVICE_ID)
		audio.cfg[0x08] = 0x01
		audio.cfg[0x0A] = 0x01
		audio.cfg[0x0B] = 0x04
		pci_seed_command_status(audio, 0x0006, 0x0006, 0x0200, 0x7800)
		pci_seed_u16(&audio.cfg, 0x2C, GSW_PCI_VENDOR_ID)
		pci_seed_u16(&audio.cfg, 0x2E, GSW_SOUND_PCI_DEVICE_ID)
		for i in 0 ..< 4 {audio.cfg[0x10 + i] = u8(GSW_SOUND_CONTROL_BAR >> (8 * uint(i)))}
		audio.bar_size_mask[0] = 0xFFFF_F000
		audio.write_mask[0x11] = 0xF0
		audio.write_mask[0x12] = 0xFF
		audio.write_mask[0x13] = 0xFF
		audio.cfg[0x3C] = 10
		audio.cfg[0x3D] = 1
	}
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
pci_access_aligned :: proc(port: u16, size: u8) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	return u32(port) & (u32(size) - 1) == 0
}

@(private = "file")
pci_access_overlaps :: proc(port: u16, size: u8, first_port, last_port: u16) -> bool {
	if size != 1 && size != 2 && size != 4 {return false}
	access_last := u32(port) + u32(size) - 1
	return u32(port) <= u32(last_port) && access_last >= u32(first_port)
}

pci_amd756_ide_enabled :: proc(p: ^Pci) -> bool {
	return p != nil && p.functions[PCI_ISA_FUNCTION_INDEX].cfg[0x48] & AMD756_ISA_IDE_DISABLE == 0
}

@(private = "file")
pci_function_find :: proc(p: ^Pci, bus, device, function: u8) -> ^Pci_Function {
	if bus == 0 && device == 7 && function == 1 && !pci_amd756_ide_enabled(p) {return nil}
	for i in 0 ..< len(p.functions) {
		candidate := &p.functions[i]
		if candidate.present &&
		   candidate.bus == bus && candidate.device == device && candidate.function == function {
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
pci_function_is_amd756_ide :: proc(f: ^Pci_Function) -> bool {
	return f != nil && f.bus == 0 && f.device == 7 && f.function == 1
}

@(private = "file")
pci_amd756_ide_channel_native :: proc(f: ^Pci_Function, channel: int) -> bool {
	if !pci_function_is_amd756_ide(f) || channel < 0 || channel > 1 {return false}
	mask := channel == 0 ? AMD756_IDE_PRIMARY_NATIVE_MODE : AMD756_IDE_SECONDARY_NATIVE_MODE
	return f.cfg[0x09] & mask != 0
}

@(private = "file")
pci_amd756_ide_bar_visible :: proc(f: ^Pci_Function, bar: int) -> bool {
	if !pci_function_is_amd756_ide(f) || bar < 0 || bar >= 4 {return true}
	return pci_amd756_ide_channel_native(f, bar / 2)
}

@(private = "file")
pci_amd756_ide_any_native :: proc(f: ^Pci_Function) -> bool {
	return pci_amd756_ide_channel_native(f, 0) || pci_amd756_ide_channel_native(f, 1)
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
			if !pci_amd756_ide_bar_visible(f, bar) {
				byte = 0
			} else if f.bar_probe[bar] {
				byte = u8(f.bar_size_mask[bar] >> (8 * ((index - 0x10) & 3)))
			}
		}
		if pci_function_is_amd756_ide(f) {
			if index == 0x3C && !pci_amd756_ide_any_native(f) {byte = 0}
			if index == 0x3D {byte = pci_amd756_ide_any_native(f) ? 1 : 0}
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
		if f.bar_size_mask[bar] != 0 && pci_amd756_ide_bar_visible(f, bar) {
			f.bar_probe[bar] = value == 0xFFFF_FFFF
			if f.bar_probe[bar] {return}
		}
	}
	for i in 0 ..< u32(size) {
		index := reg + i
		if index >= 0x10 && index < 0x28 {
			bar := int((index - 0x10) / 4)
			if !pci_amd756_ide_bar_visible(f, bar) {continue}
			if f.bar_size_mask[bar] != 0 {f.bar_probe[bar] = false}
		}
		if pci_function_is_amd756_ide(f) && index == 0x3C && !pci_amd756_ide_any_native(f) {
			continue
		}
		old := f.cfg[index]
		incoming := u8(value >> (8 * i))
		writable := f.write_mask[index] & ~f.w1c_mask[index]
		next := (old & ~writable) | (incoming & writable)
		next &= ~(incoming & f.w1c_mask[index])
		next |= old & f.sticky_mask[index]
		f.cfg[index] = next
	}
	if pci_function_is_amd756_ide(f) {
		for bar in 0 ..< 4 {
			if !pci_amd756_ide_bar_visible(f, bar) {f.bar_probe[bar] = false}
		}
	}
	if f.bus == 0 && f.device == 7 && f.function == 0 {
		for i in 0 ..< 4 {f.cfg[0x2C + i] = f.cfg[0x50 + i]}
	}
}

pci_pirq_route :: proc(p: ^Pci, pirq: u8) -> (irq: u8, routed: bool) {
	if pirq >= PCI_PIRQ_COUNT {return 0, false}
	return PCI_PIRQ_IRQS[pirq], true
}

pci_slot_pirq :: proc(device, pin: u8) -> (pirq: u8, valid: bool) {
	if device == 0 || pin < 1 || pin > 4 {return 0, false}
	return u8((u16(pin) - 1 + u16(device) - 1) & 3), true
}

pci_pirq_link :: proc(pirq: u8) -> (link: u8, valid: bool) {
	if pirq >= PCI_PIRQ_COUNT {return 0, false}
	return pirq + 1, true
}

pci_pirq_irq_bitmap :: proc(pirq: u8) -> (bitmap: u16, valid: bool) {
	irq, routed := pci_pirq_route(nil, pirq)
	if !routed {return 0, false}
	return u16(1) << irq, true
}

pci_amd756_bios_write_enabled :: proc(p: ^Pci) -> bool {
	return(
		p != nil &&
		p.functions[PCI_ISA_FUNCTION_INDEX].cfg[AMD756_ISA_BUS_CONTROL_1] &
				AMD756_ISA_ROM_WRITE_ENABLE !=
			0 \
	)
}

@(private = "file")
pci_pirq_compute_routed_mask :: proc(p: ^Pci) -> u16 {
	mask: u16
	for pirq in u8(0) ..< PCI_PIRQ_COUNT {
		active := false
		for count in p.pirq_source_counts[pirq] {
			if count > 0 {active = true; break}
		}
		if !active {continue}
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
	return pci_pirq_set_source_level(p, pirq, .Legacy, asserted)
}

pci_pirq_set_source_level :: proc(
	p: ^Pci,
	pirq: u8,
	source: Pci_Pirq_Source,
	asserted: bool,
) -> bool {
	if p == nil || pirq >= PCI_PIRQ_COUNT || source >= .Count {return false}
	count := &p.pirq_source_counts[pirq][int(source)]
	next := asserted ? u16(1) : u16(0)
	if count^ == next {return true}
	count^ = next
	pci_pirq_sync(p)
	return true
}

pci_pirq_assert_source :: proc(p: ^Pci, pirq: u8, source: Pci_Pirq_Source) -> bool {
	if p == nil || pirq >= PCI_PIRQ_COUNT || source >= .Count {return false}
	count := &p.pirq_source_counts[pirq][int(source)]
	if count^ == max(u16) {return false}
	count^ += 1
	if count^ == 1 {pci_pirq_sync(p)}
	return true
}

pci_pirq_release_source :: proc(p: ^Pci, pirq: u8, source: Pci_Pirq_Source) -> bool {
	if p == nil || pirq >= PCI_PIRQ_COUNT || source >= .Count {return false}
	count := &p.pirq_source_counts[pirq][int(source)]
	if count^ == 0 {return false}
	count^ -= 1
	if count^ == 0 {pci_pirq_sync(p)}
	return true
}

pci_pirq_source_assertion_count :: proc(p: ^Pci, pirq: u8, source: Pci_Pirq_Source) -> u16 {
	if p == nil || pirq >= PCI_PIRQ_COUNT || source >= .Count {return 0}
	return p.pirq_source_counts[pirq][int(source)]
}

pci_pirq_is_asserted :: proc(p: ^Pci, pirq: u8) -> bool {
	if p == nil || pirq >= PCI_PIRQ_COUNT {return false}
	for count in p.pirq_source_counts[pirq] {if count > 0 {return true}}
	return false
}

pci_pirq_source_is_asserted :: proc(p: ^Pci, pirq: u8, source: Pci_Pirq_Source) -> bool {
	if p == nil || pirq >= PCI_PIRQ_COUNT || source >= .Count {return false}
	return p.pirq_source_counts[pirq][int(source)] > 0
}

pci_pirq_active_irq_mask :: proc(p: ^Pci) -> u16 {
	return p.pirq_routed_mask
}

@(private = "file")
pci_ide_command :: proc(p: ^Pci) -> u16 {
	if !pci_amd756_ide_enabled(p) {return 0}
	ide := &p.functions[PCI_IDE_FUNCTION_INDEX]
	return u16(ide.cfg[0x04]) | u16(ide.cfg[0x05]) << 8
}

pci_ide_io_enabled :: proc(p: ^Pci) -> bool {
	return (pci_ide_command(p) & 0x0001) != 0
}

pci_ide_bus_master_enabled :: proc(p: ^Pci) -> bool {
	return (pci_ide_command(p) & 0x0004) != 0
}

pci_ide_channel_enabled :: proc(p: ^Pci, channel: int) -> bool {
	if !pci_amd756_ide_enabled(p) || channel < 0 || channel > 1 {return false}
	mask := channel == 0 ? AMD756_IDE_PRIMARY_CHANNEL_ENABLE : AMD756_IDE_SECONDARY_CHANNEL_ENABLE
	return p.functions[PCI_IDE_FUNCTION_INDEX].cfg[0x40] & mask != 0
}

pci_ide_channel_native :: proc(p: ^Pci, channel: int) -> bool {
	if !pci_amd756_ide_enabled(p) || channel < 0 || channel > 1 {return false}
	return pci_amd756_ide_channel_native(&p.functions[PCI_IDE_FUNCTION_INDEX], channel)
}

@(private = "file")
pci_gsw_vga_command :: proc(p: ^Pci) -> u16 {
	graphics := &p.functions[PCI_GSW_VGA_FUNCTION_INDEX]
	return u16(graphics.cfg[0x04]) | u16(graphics.cfg[0x05]) << 8
}

pci_gsw_vga_io_enabled :: proc(p: ^Pci) -> bool {
	return p != nil && (pci_gsw_vga_command(p) & 0x0001) != 0
}

pci_gsw_vga_memory_enabled :: proc(p: ^Pci) -> bool {
	return p != nil && (pci_gsw_vga_command(p) & 0x0002) != 0
}

@(private = "file")
pci_gsw_vga_memory_bar :: proc(p: ^Pci, bar_index: int) -> u64 {
	if p == nil || bar_index < 0 || bar_index > 1 {return 0}
	graphics := &p.functions[PCI_GSW_VGA_FUNCTION_INDEX]
	offset := 0x10 + bar_index * 4
	value :=
		u32(graphics.cfg[offset]) |
		u32(graphics.cfg[offset + 1]) << 8 |
		u32(graphics.cfg[offset + 2]) << 16 |
		u32(graphics.cfg[offset + 3]) << 24
	return u64(value & 0xFFFF_FFF0)
}

pci_gsw_vga_control_base :: proc(p: ^Pci) -> u64 {
	return pci_gsw_vga_memory_bar(p, 0)
}

pci_gsw_vga_framebuffer_base :: proc(p: ^Pci) -> u64 {
	return pci_gsw_vga_memory_bar(p, 1)
}

@(private = "file")
pci_gsw_sound_command :: proc(p: ^Pci) -> u16 {
	if !pci_gsw_sound_present(p) {return 0}
	audio := &p.functions[PCI_GSW_SOUND_FUNCTION_INDEX]
	return u16(audio.cfg[0x04]) | u16(audio.cfg[0x05]) << 8
}

pci_gsw_sound_memory_enabled :: proc(p: ^Pci) -> bool {
	return pci_gsw_sound_command(p) & 0x0002 != 0
}

pci_gsw_sound_bus_master_enabled :: proc(p: ^Pci) -> bool {
	return pci_gsw_sound_command(p) & 0x0004 != 0
}

pci_gsw_sound_present :: proc(p: ^Pci) -> bool {
	return p != nil && p.functions[PCI_GSW_SOUND_FUNCTION_INDEX].present
}

pci_gsw_sound_control_base :: proc(p: ^Pci) -> u64 {
	if !pci_gsw_sound_present(p) {return 0}
	audio := &p.functions[PCI_GSW_SOUND_FUNCTION_INDEX]
	value :=
		u32(audio.cfg[0x10]) |
		u32(audio.cfg[0x11]) << 8 |
		u32(audio.cfg[0x12]) << 16 |
		u32(audio.cfg[0x13]) << 24
	return u64(value & 0xFFFF_FFF0)
}

pci_ide_bus_master_io_base :: proc(p: ^Pci) -> (base: u16, valid: bool) {
	if !pci_amd756_ide_enabled(p) {return 0, false}
	ide := &p.functions[PCI_IDE_FUNCTION_INDEX]
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
	if !pci_ide_io_enabled(p) || pci_access_overlaps(port, size, 0xCF8, 0xCFF) {
		return 0, false
	}
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
	if !pci_access_aligned(port, size) {return nil, 0, false}
	bus := u8(p.addr >> 16)
	device := u8((p.addr >> 11) & 0x1F)
	function := u8((p.addr >> 8) & 0x07)
	f = pci_function_find(p, bus, device, function)
	return f, (p.addr & 0xFC) + u32(port - 0xCFC), f != nil
}

pci_in :: proc(p: ^Pci, port: u16, size: u8) -> u32 {
	if port == 0xCF8 {
		if size == 4 {return p.addr}
		return pci_size_mask(size)
	}
	if port >= 0xCF8 && port <= 0xCFB {return pci_size_mask(size)}
	f, reg, ok := pci_decode_mechanism_1(p, port, size)
	if !ok {return pci_size_mask(size)}
	return pci_config_read(f, reg, size)
}

pci_out :: proc(p: ^Pci, port: u16, size: u8, value: u32) {
	if port == 0xCF8 {
		if size == 4 {p.addr = value & PCI_CONFIG_ADDRESS_MASK}
		return
	}
	if port >= 0xCF8 && port <= 0xCFB {return}
	f, reg, ok := pci_decode_mechanism_1(p, port, size)
	if !ok {return}
	pci_config_write(f, reg, size, value)
	pci_pirq_sync(p)
}
