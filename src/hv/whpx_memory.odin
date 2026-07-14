// SPDX-License-Identifier: GPL-3.0-only
package hv

Whpx_Memory_Region_Kind :: enum {
	Reserved,
	Open_Bus,
	Ram,
	Device,
	Rom,
	Fallback,
}

Whpx_Memory_Region :: struct {
	kind:  Whpx_Memory_Region_Kind,
	index: int,
}

@(private = "file")
whpx_memory_effective_gpa :: proc(vm: ^Vm, gpa: u64) -> u64 {
	if !vm.a20_enabled {return gpa &~ WHPX_A20_BIT}
	return gpa
}

@(private = "file")
whpx_memory_region_at :: proc(vm: ^Vm, gpa: u64, write: bool) -> Whpx_Memory_Region {
	for reservation, i in vm.mmio_reservations {
		if gpa >= reservation.gpa && gpa - reservation.gpa < reservation.size {
			kind := reservation.kind == .Open_Bus ? Whpx_Memory_Region_Kind.Open_Bus : .Reserved
			return Whpx_Memory_Region{kind = kind, index = i}
		}
	}
	if gpa < u64(len(vm.ram)) {
		return Whpx_Memory_Region{kind = .Ram}
	}
	for mapping, i in vm.device_mappings {
		if gpa >= mapping.gpa && gpa - mapping.gpa < u64(mapping.size) {
			return Whpx_Memory_Region{kind = .Device, index = i}
		}
	}
	if !write {
		for rom, i in vm.roms {
			if gpa >= rom.gpa && gpa - rom.gpa < u64(rom.size) {
				return Whpx_Memory_Region{kind = .Rom, index = i}
			}
		}
	}
	return Whpx_Memory_Region{kind = .Fallback}
}

@(private = "file")
whpx_memory_region_access :: proc(
	vm: ^Vm,
	region: Whpx_Memory_Region,
	gpa: u64,
	write: bool,
	data: []u8,
) {
	switch region.kind {
	case .Ram:
		offset := int(gpa)
		if write {
			copy(vm.ram[offset:], data)
		} else {
			copy(data, vm.ram[offset:offset + len(data)])
		}
	case .Device:
		mapping := &vm.device_mappings[region.index]
		bytes := ([^]u8)(mapping.host)[:mapping.size]
		offset := int(gpa - mapping.gpa)
		if write {
			copy(bytes[offset:], data)
		} else {
			copy(data, bytes[offset:offset + len(data)])
		}
	case .Rom:
		rom := &vm.roms[region.index]
		offset := int(gpa - rom.gpa)
		copy(data, ([^]u8)(rom.host)[offset:][:len(data)])
	case .Open_Bus:
		if !write {
			for &byte in data {byte = 0xFF}
		}
	case .Reserved, .Fallback:
		if vm.mmio != nil {
			vm.mmio(vm.io_ctx, gpa, write, data)
		} else if !write {
			for &byte in data {
				byte = 0xFF
			}
		}
	}
}

whpx_emulate_memory_access :: proc(vm: ^Vm, mem: ^WHV_EMULATOR_MEMORY_ACCESS_INFO) -> HRESULT {
	size := min(int(mem.AccessSize), len(mem.Data))
	if size <= 0 {
		return 0
	}
	write := mem.Direction == 1
	start := 0
	for start < size {
		gpa := whpx_memory_effective_gpa(vm, mem.GpaAddress + u64(start))
		region := whpx_memory_region_at(vm, gpa, write)
		end := start + 1
		for end < size {
			next_gpa := whpx_memory_effective_gpa(vm, mem.GpaAddress + u64(end))
			if next_gpa != gpa + u64(end - start) ||
			   whpx_memory_region_at(vm, next_gpa, write) != region {
				break
			}
			end += 1
		}
		whpx_memory_region_access(vm, region, gpa, write, mem.Data[start:end])
		start = end
	}
	return 0
}

whpx_physical_ram_read :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	if vm == nil || gpa > u64(len(vm.ram)) || u64(len(data)) > u64(len(vm.ram)) - gpa {
		return false
	}
	end := gpa + u64(len(data))
	for reservation in vm.mmio_reservations {
		reservation_end := reservation.gpa + reservation.size
		if gpa < reservation_end && reservation.gpa < end {return false}
	}
	copy(data, vm.ram[int(gpa):int(end)])
	return true
}

whpx_physical_ram_write :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	if vm == nil || gpa > u64(len(vm.ram)) || u64(len(data)) > u64(len(vm.ram)) - gpa {
		return false
	}
	end := gpa + u64(len(data))
	for reservation in vm.mmio_reservations {
		reservation_end := reservation.gpa + reservation.size
		if gpa < reservation_end && reservation.gpa < end {return false}
	}
	copy(vm.ram[int(gpa):int(end)], data)
	return true
}
