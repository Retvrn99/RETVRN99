// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:testing"

Whpx_Memory_Test_Probe :: struct {
	calls:  int,
	gpa:    [4]u64,
	write:  [4]bool,
	size:   [4]int,
	bytes:  [4][8]u8,
}

whpx_memory_test_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	probe := (^Whpx_Memory_Test_Probe)(ctx)
	call := probe.calls
	probe.calls += 1
	if call >= len(probe.gpa) {
		return
	}
	probe.gpa[call] = gpa
	probe.write[call] = write
	probe.size[call] = len(data)
	if write {
		copy(probe.bytes[call][:], data)
	} else {
		for &byte, i in data {
			byte = 0xA0 + u8(i)
		}
	}
}

@(test)
test_whpx_memory_splits_ram_to_reserved_write :: proc(t: ^testing.T) {
	ram := make([]u8, 0xC1000)
	defer delete(ram)
	vm := Vm{ram = ram}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = 0xA0000, size = 0x20000})
	defer delete(vm.mmio_reservations)
	probe: Whpx_Memory_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_memory_test_mmio
	vm.ram[0xA0000] = 0xCC
	vm.ram[0xA0001] = 0xDD

	access := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0x9FFFE,
		Direction  = 1,
		AccessSize = 4,
	}
	copy(access.Data[:], []u8{0x11, 0x22, 0x33, 0x44})
	testing.expect(t, whpx_emulate_memory_access(&vm, &access) >= 0)
	testing.expect_value(t, vm.ram[0x9FFFE], u8(0x11))
	testing.expect_value(t, vm.ram[0x9FFFF], u8(0x22))
	testing.expect_value(t, vm.ram[0xA0000], u8(0xCC))
	testing.expect_value(t, vm.ram[0xA0001], u8(0xDD))
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.gpa[0], u64(0xA0000))
	testing.expect(t, probe.write[0])
	testing.expect_value(t, probe.size[0], 2)
	testing.expect_value(t, probe.bytes[0][0], u8(0x33))
	testing.expect_value(t, probe.bytes[0][1], u8(0x44))
}

@(test)
test_whpx_memory_splits_reserved_to_ram_read :: proc(t: ^testing.T) {
	ram := make([]u8, 0xC1000)
	defer delete(ram)
	vm := Vm{ram = ram}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = 0xA0000, size = 0x20000})
	defer delete(vm.mmio_reservations)
	probe: Whpx_Memory_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_memory_test_mmio
	vm.ram[0xC0000] = 0x33
	vm.ram[0xC0001] = 0x44

	access := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0xBFFFE,
		AccessSize = 4,
	}
	testing.expect(t, whpx_emulate_memory_access(&vm, &access) >= 0)
	testing.expect_value(t, access.Data[0], u8(0xA0))
	testing.expect_value(t, access.Data[1], u8(0xA1))
	testing.expect_value(t, access.Data[2], u8(0x33))
	testing.expect_value(t, access.Data[3], u8(0x44))
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.gpa[0], u64(0xBFFFE))
	testing.expect(t, !probe.write[0])
	testing.expect_value(t, probe.size[0], 2)
}

@(test)
test_whpx_memory_preserves_reserved_operand_width :: proc(t: ^testing.T) {
	ram := make([]u8, 0xC0000)
	defer delete(ram)
	vm := Vm{ram = ram}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = 0xA0000, size = 0x20000})
	defer delete(vm.mmio_reservations)
	probe: Whpx_Memory_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_memory_test_mmio

	access := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0xA0100,
		Direction  = 1,
		AccessSize = 4,
	}
	copy(access.Data[:], []u8{1, 2, 3, 4})
	testing.expect(t, whpx_emulate_memory_access(&vm, &access) >= 0)
	testing.expect_value(t, probe.calls, 1)
	testing.expect_value(t, probe.gpa[0], u64(0xA0100))
	testing.expect_value(t, probe.size[0], 4)
}

@(test)
test_whpx_memory_splits_a20_hma_wrap_read :: proc(t: ^testing.T) {
	ram := make([]u8, 0x100000)
	defer delete(ram)
	vm := Vm{ram = ram, a20_enabled = false}
	vm.ram[0xFFFFE] = 0x11
	vm.ram[0xFFFFF] = 0x22
	vm.ram[0] = 0x33
	vm.ram[1] = 0x44

	access := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0xFFFFE,
		AccessSize = 4,
	}
	testing.expect(t, whpx_emulate_memory_access(&vm, &access) >= 0)
	testing.expect_value(t, access.Data[0], u8(0x11))
	testing.expect_value(t, access.Data[1], u8(0x22))
	testing.expect_value(t, access.Data[2], u8(0x33))
	testing.expect_value(t, access.Data[3], u8(0x44))
}
