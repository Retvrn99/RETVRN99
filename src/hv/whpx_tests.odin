// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"

Whpx_Test_Probe :: struct {
	mmio_reads:  int,
	mmio_writes: int,
	mmio_gpa:    u64,
	mmio_value:  u8,
	io_values:   [8]u8,
	io_count:    int,
}

whpx_test_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	probe := (^Whpx_Test_Probe)(ctx)
	probe.mmio_gpa = gpa
	if write {
		probe.mmio_writes += 1
		if len(data) > 0 {
			probe.mmio_value = data[0]
		}
	} else {
		probe.mmio_reads += 1
		if len(data) > 0 {
			data[0] = 0xA5
		}
	}
}

whpx_test_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) {
	probe := (^Whpx_Test_Probe)(ctx)
	if port == 0x1234 && size == 1 && probe.io_count < len(probe.io_values) {
		probe.io_values[probe.io_count] = u8(val)
		probe.io_count += 1
	}
}

whpx_test_write_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

@(test)
test_whpx_realmode_blob :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	ok := create(&vm, 64 * 1024 * 1024)
	defer destroy(&vm)
	if !testing.expect(t, ok) { return }
	// mov ax, 0x1234; hlt   (at 0x0000:0x7C00)
	copy(vm.ram[0x7C00:], []u8{0xB8, 0x34, 0x12, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Halt)
	testing.expect_value(t, u16(reg_rax(&vm)), u16(0x1234))
}

// SDK 10.0.26100 C_ASSERT values (WinHvPlatformDefs.h)
@(test)
test_whpx_struct_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(WHV_X64_IO_PORT_ACCESS_CONTEXT), 96)
	testing.expect_value(t, size_of(WHV_MEMORY_ACCESS_CONTEXT), 40)
	testing.expect_value(t, size_of(WHV_VP_EXIT_CONTEXT), 40)
	testing.expect_value(t, size_of(WHV_RUN_VP_EXIT_CONTEXT), 224)
	testing.expect_value(t, size_of(WHV_REGISTER_VALUE), 16)
	testing.expect_value(t, size_of(WHV_X64_SEGMENT_REGISTER), 16)
	testing.expect_value(t, size_of(WHV_TRANSLATE_GVA_RESULT), 8)
}

@(test)
test_whpx_reserved_range_precedes_ram_callback :: proc(t: ^testing.T) {
	ram := make([]u8, 0x100000)
	defer delete(ram)
	vm := Vm{ram = ram}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = 0xA0000, size = 0x20000})
	defer delete(vm.mmio_reservations)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_mmio

	write := WHV_EMULATOR_MEMORY_ACCESS_INFO{GpaAddress = 0xA0000, Direction = 1, AccessSize = 1}
	write.Data[0] = 0x5A
	testing.expect(t, whpx_emu_mmio(&vm, &write) >= 0)
	testing.expect_value(t, probe.mmio_writes, 1)
	testing.expect_value(t, probe.mmio_value, u8(0x5A))
	testing.expect_value(t, vm.ram[0xA0000], u8(0))

	read := WHV_EMULATOR_MEMORY_ACCESS_INFO{GpaAddress = 0xA0000, AccessSize = 1}
	testing.expect(t, whpx_emu_mmio(&vm, &read) >= 0)
	testing.expect_value(t, probe.mmio_reads, 1)
	testing.expect_value(t, read.Data[0], u8(0xA5))
}

@(test)
test_whpx_reserved_low_mmio_exits :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) { return }
	defer destroy(&vm)
	testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x20000))
	testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x20000))
	testing.expect(t, !reserve_mmio(&vm, 0xA1000, 0x1000))
	testing.expect(t, !reserve_mmio(&vm, 0xA0001, 0x1000))

	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_mmio
	vm.ram[0xA0000] = 0xCC
	// mov ax,a000; mov ds,ax; mov byte [0],5a; mov al,[0]; hlt
	copy(vm.ram[0x7C00:], []u8{0xB8, 0x00, 0xA0, 0x8E, 0xD8, 0xC6, 0x06, 0x00, 0x00, 0x5A, 0xA0, 0x00, 0x00, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) { return }
	testing.expect_value(t, probe.mmio_writes, 1)
	testing.expect_value(t, probe.mmio_reads, 1)
	testing.expect_value(t, probe.mmio_gpa, u64(0xA0000))
	testing.expect_value(t, probe.mmio_value, u8(0x5A))
	testing.expect_value(t, vm.ram[0xA0000], u8(0xCC))
	testing.expect_value(t, u8(reg_rax(&vm)), u8(0xA5))
}

@(test)
test_whpx_nonidentity_rep_outsb_from_device_memory :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) { return }
	defer destroy(&vm)
	device, ok := map_device_memory(&vm, 0xE0000000, 0x1000)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, uintptr(raw_data(device)) & 0xFFF, uintptr(0))
	copy(device, []u8{0x11, 0x22, 0x33, 0x44})
	_, duplicate_ok := map_device_memory(&vm, 0xE0000000, 0x1000)
	testing.expect(t, !duplicate_ok)

	// 4 KiB page tables: code is identity mapped, the I/O source is not.
	whpx_test_write_u32(vm.ram, 0x1000 + 0 * 4, 0x2003)
	whpx_test_write_u32(vm.ram, 0x1000 + 1 * 4, 0x3003)
	whpx_test_write_u32(vm.ram, 0x2000 + 7 * 4, 0x7003)
	whpx_test_write_u32(vm.ram, 0x3000 + 0 * 4, 0xE0000003)
	// mov byte [00400004],5a; cld; rep outsb; hlt
	copy(vm.ram[0x7000:], []u8{0xC6, 0x05, 0x04, 0x00, 0x40, 0x00, 0x5A, 0xFC, 0xF3, 0x6E, 0xF4})

	code_seg := WHV_X64_SEGMENT_REGISTER{Base = 0, Limit = 0xFFFFFFFF, Selector = 8, Attributes = 0xC09B}
	data_seg := WHV_X64_SEGMENT_REGISTER{Base = 0, Limit = 0xFFFFFFFF, Selector = 16, Attributes = 0xC093}
	names := [?]WHV_REGISTER_NAME{
		.Cs, .Ds, .Es, .Ss, .Fs, .Gs, .Rip, .Rflags, .Rsi, .Rcx, .Rdx, .Cr0, .Cr3, .Cr4,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	for i in 1 ..< 6 {
		vals[i].Segment = data_seg
	}
	vals[6].Reg64 = 0x7000
	vals[7].Reg64 = 0x2
	vals[8].Reg64 = 0x00400000
	vals[9].Reg64 = 4
	vals[10].Reg64 = 0x1234
	vals[11].Reg64 = 0x80000011
	vals[12].Reg64 = 0x1000
	vals[13].Reg64 = 0
	if !testing.expect(t, WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0) { return }

	translation_result: WHV_TRANSLATE_GVA_RESULT_CODE
	translated_gpa: u64
	if !testing.expect(t, whpx_emu_translate(&vm, 0x00400000, 1, &translation_result, &translated_gpa) >= 0) { return }
	testing.expect_value(t, translation_result, WHV_TRANSLATE_GVA_RESULT_CODE.Success)
	testing.expect_value(t, translated_gpa, u64(0xE0000000))

	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write
	ex := run(&vm)
	if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) { return }
	testing.expect_value(t, device[4], u8(0x5A))
	testing.expect_value(t, probe.io_count, 4)
	want := [4]u8{0x11, 0x22, 0x33, 0x44}
	for value, i in want {
		testing.expect_value(t, probe.io_values[i], value)
	}
}

@(test)
test_whpx_io_exit_budget :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	vm: Vm
	ok := create(&vm, 64 * 1024 * 1024)
	defer destroy(&vm)
	if !testing.expect(t, ok) { return }
	// mov dx, 0x80; l: in al, dx; jmp l   (guest polls a port forever)
	copy(vm.ram[0x7C00:], []u8{0xBA, 0x80, 0x00, 0xEC, 0xEB, 0xFD})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Io)
}

@(test)
test_whpx_can_inject_interrupt_shadow :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	ok := create(&vm, 64 * 1024 * 1024)
	defer destroy(&vm)
	if !testing.expect(t, ok) { return }

	// RFLAGS.IF set, nothing pending -> injectable
	name := WHV_REGISTER_NAME.Rflags
	val: WHV_REGISTER_VALUE
	val.Reg64 = 0x202
	testing.expect(t, WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val) >= 0)
	testing.expect(t, can_inject(&vm))

	// interrupt shadow set -> not injectable
	name = .InterruptState
	val.Reg64 = 0x1 // InterruptShadow (bit 0)
	testing.expect(t, WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val) >= 0)
	testing.expect(t, !can_inject(&vm))

}
