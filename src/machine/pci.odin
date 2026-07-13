// SPDX-License-Identifier: GPL-3.0-only
package machine

GSW_PCI_VENDOR_ID :: u16(0xFFFE) // private development ID; not PCI-SIG assigned
GSW_CHIPSET_PCI_DEVICE_ID :: u16(0x0001)

PCI_CONFIG_ADDRESS_MASK :: u32(0x80FF_FFFC)
PCI_FUNCTION_COUNT :: 4

Pci_Function :: struct {
	bus:        u8,
	device:     u8,
	function:   u8,
	cfg:        [256]u8,
	write_mask: [256]u8,
	w1c_mask:   [256]u8,
}

Pci :: struct {
	addr:               u32,
	mechanism_2_enable: u8,
	mechanism_2_bus:    u8,
	functions:          [PCI_FUNCTION_COUNT]Pci_Function,
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
pci_seed_intel_write_masks :: proc(f: ^Pci_Function) {
	f.write_mask[0x04] = 0x07
	f.write_mask[0x0C] = 0xFF
	f.write_mask[0x0D] = 0xFF
	f.write_mask[0x3C] = 0xFF
	f.w1c_mask[0x07] = 0xF9
	for i in 0x40 ..= 0xFF {f.write_mask[i] = 0xFF}
}

pci_init :: proc(p: ^Pci) {
	p^ = {}

	host := &p.functions[0]
	pci_seed_function(host, 0, 0, 0, 0x8086, 0x1237)
	host.cfg[0x0B] = 0x06
	pci_seed_intel_write_masks(host)

	isa := &p.functions[1]
	pci_seed_function(isa, 0, 1, 0, 0x8086, 0x7000)
	isa.cfg[0x0A] = 0x01
	isa.cfg[0x0B] = 0x06
	isa.cfg[0x0E] = 0x80
	pci_seed_intel_write_masks(isa)

	ide := &p.functions[2]
	pci_seed_function(ide, 0, 1, 1, 0x8086, 0x7010)
	ide.cfg[0x09] = 0x00
	ide.cfg[0x0A] = 0x01
	ide.cfg[0x0B] = 0x01
	pci_seed_intel_write_masks(ide)

	chipset := &p.functions[3]
	pci_seed_function(chipset, 0, 3, 0, GSW_PCI_VENDOR_ID, GSW_CHIPSET_PCI_DEVICE_ID)
	chipset.cfg[0x08] = 0x01
	chipset.cfg[0x0A] = 0x80
	chipset.cfg[0x0B] = 0x08
	pci_seed_u16(&chipset.cfg, 0x2C, GSW_PCI_VENDOR_ID)
	pci_seed_u16(&chipset.cfg, 0x2E, GSW_CHIPSET_PCI_DEVICE_ID)
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
	for i in 0 ..< u32(size) {value |= u32(f.cfg[reg + i]) << (8 * i)}
	return value
}

@(private = "file")
pci_config_write :: proc(f: ^Pci_Function, reg: u32, size: u8, value: u32) {
	if f == nil || !pci_config_access_valid(reg, size) {return}
	for i in 0 ..< u32(size) {
		index := reg + i
		old := f.cfg[index]
		incoming := u8(value >> (8 * i))
		writable := f.write_mask[index]
		next := (old & ~writable) | (incoming & writable)
		next &= ~(incoming & f.w1c_mask[index])
		f.cfg[index] = next
	}
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
	if (p.mechanism_2_enable & 0xF0) == 0 ||
	   (p.mechanism_2_enable & 0x01) != 0 ||
	   !pci_access_valid(port, 0xC000, 0xCFFF, size) {
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
		if ok {pci_config_write(f, reg, size, value)}
		return
	}
	f, reg, ok := pci_decode_mechanism_1(p, port, size)
	if !ok {return}
	pci_config_write(f, reg, size, value)
}
