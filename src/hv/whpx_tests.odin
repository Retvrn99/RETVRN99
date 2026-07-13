// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"
import "core:time"

Whpx_Test_Probe :: struct {
	mmio_reads:      int,
	mmio_writes:     int,
	mmio_gpa:        u64,
	mmio_value:      u8,
	io_values:       [8]u8,
	io_ports:        [8]u16,
	io_count:        int,
	io_attempts:     int,
	io_reject:       bool,
	io_reject_after: int,
	io_read_values:  [8]u32,
	io_read_count:   int,
	io_last_size:    u8,
	io_last_value:   u32,
}

Whpx_A20_Probe :: struct {
	vm:              ^Vm,
	called:          bool,
	applied_in_call: bool,
	requested:       bool,
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

whpx_test_io_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool {
	probe := (^Whpx_Test_Probe)(ctx)
	attempt := probe.io_attempts
	probe.io_attempts += 1
	if probe.io_reject && attempt >= probe.io_reject_after {return false}
	probe.io_last_size = size
	probe.io_last_value = val
	if size == 1 && probe.io_count < len(probe.io_values) {
		probe.io_ports[probe.io_count] = port
		probe.io_values[probe.io_count] = u8(val)
		probe.io_count += 1
	}
	return true
}

whpx_test_io_read :: proc(ctx: rawptr, port: u16, size: u8) -> (u32, bool) {
	probe := (^Whpx_Test_Probe)(ctx)
	if probe.io_read_count >= len(probe.io_read_values) {return 0, false}
	value := probe.io_read_values[probe.io_read_count]
	probe.io_read_count += 1
	probe.io_last_size = size
	probe.io_last_value = value
	return value, true
}

whpx_test_a20_write :: proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool {
	probe := (^Whpx_A20_Probe)(ctx)
	if port != 0x92 || size != 1 {return true}
	probe.called = true
	_ = set_a20(probe.vm, val & 2 != 0)
	probe.applied_in_call = probe.vm.a20_enabled
	probe.requested = probe.vm.a20_requested
	return true
}

whpx_test_write_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

whpx_test_manual_io_context :: proc(
	t: ^testing.T,
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	io: ^WHV_X64_IO_PORT_ACCESS_CONTEXT,
	rax, rcx, rsi, rdi, rip, rflags: u64,
) -> bool {
	code := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFFFFFF,
		Selector   = 8,
		Attributes = 0xC09B,
	}
	data := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFFFFFF,
		Selector   = 16,
		Attributes = 0xC093,
	}
	names := [?]WHV_REGISTER_NAME {
		.Cs,
		.Ds,
		.Es,
		.Ss,
		.Fs,
		.Gs,
		.Rax,
		.Rcx,
		.Rsi,
		.Rdi,
		.Rip,
		.Rflags,
		.Rsp,
		.Cr0,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Segment = code
	for i in 1 ..< 6 {values[i].Segment = data}
	values[6].Reg64 = rax
	values[7].Reg64 = rcx
	values[8].Reg64 = rsi
	values[9].Reg64 = rdi
	values[10].Reg64 = rip
	values[11].Reg64 = rflags
	values[12].Reg64 = 0x8000
	values[13].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {
		return false
	}
	vp^ = WHV_VP_EXIT_CONTEXT {
		Cs     = code,
		Rip    = rip,
		Rflags = rflags,
	}
	io^ = WHV_X64_IO_PORT_ACCESS_CONTEXT {
		Rax = rax,
		Rcx = rcx,
		Rsi = rsi,
		Rdi = rdi,
		Ds  = data,
		Es  = data,
	}
	return true
}

whpx_test_manual_io_instruction :: proc(
	vp: ^WHV_VP_EXIT_CONTEXT,
	io: ^WHV_X64_IO_PORT_ACCESS_CONTEXT,
	instruction: []u8,
	access_info: u32,
	port: u16,
) {
	vp.InstructionLengthCr8 = u8(len(instruction))
	io.InstructionByteCount = u8(len(instruction))
	copy(io.InstructionBytes[:], instruction)
	io.AccessInfo = access_info
	io.PortNumber = port
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
	if !testing.expect(t, ok) {return}
	// mov ax, 0x1234; hlt   (at 0x0000:0x7C00)
	copy(vm.ram[0x7C00:], []u8{0xB8, 0x34, 0x12, 0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Halt)
	testing.expect_value(t, u16(reg_rax(&vm)), u16(0x1234))
}

@(test)
test_whpx_a20_hma_alias :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	vm.ram[0x500] = 0x11
	vm.ram[0x100500] = 0x22
	// mov ax,ffff; mov ds,ax; mov al,[0510]; hlt
	copy(vm.ram[0x7C00:], []u8{0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0xA0, 0x10, 0x05, 0xF4})

	set_realmode_entry(&vm, 0, 0x7C00)
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect_value(t, u8(reg_rax(&vm)), u8(0x22))

	testing.expect(t, set_a20(&vm, false))
	testing.expect(t, vm.a20_enabled && !vm.a20_requested)
	set_realmode_entry(&vm, 0, 0x7C00)
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect(t, !vm.a20_enabled && !vm.a20_requested)
	testing.expect_value(t, u8(reg_rax(&vm)), u8(0x11))

	testing.expect(t, set_a20(&vm, true))
	testing.expect(t, !vm.a20_enabled && vm.a20_requested)
	set_realmode_entry(&vm, 0, 0x7C00)
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect(t, vm.a20_enabled && vm.a20_requested)
	testing.expect_value(t, u8(reg_rax(&vm)), u8(0x22))
}

@(test)
test_whpx_a20_remap_waits_for_io_emulation_to_return :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	probe := Whpx_A20_Probe {
		vm = &vm,
	}
	vm.io_ctx = &probe
	vm.io_write = whpx_test_a20_write
	vm.ram[0x500] = 0x11
	vm.ram[0x100500] = 0x22
	// Set DS=ffff, close A20 through port 92h, then read the wrapped HMA byte.
	copy(
		vm.ram[0x7C00:],
		[]u8{0xB8, 0xFF, 0xFF, 0x8E, 0xD8, 0x30, 0xC0, 0xE6, 0x92, 0xA0, 0x10, 0x05, 0xF4},
	)
	set_realmode_entry(&vm, 0, 0x7C00)
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect(t, probe.called)
	testing.expect(t, probe.applied_in_call)
	testing.expect(t, !probe.requested)
	testing.expect(t, !vm.a20_enabled && !vm.a20_requested)
	testing.expect_value(t, u8(reg_rax(&vm)), u8(0x11))
}

@(test)
test_whpx_a20_requests_coalesce_before_run :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	testing.expect(t, set_a20(&vm, false))
	testing.expect(t, set_a20(&vm, true))
	testing.expect(t, vm.a20_enabled && vm.a20_requested)
	copy(vm.ram[0x7C00:], []u8{0xF4})
	set_realmode_entry(&vm, 0, 0x7C00)
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect(t, vm.a20_enabled && vm.a20_requested)
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
	vm := Vm {
		ram = ram,
	}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = 0xA0000, size = 0x20000})
	defer delete(vm.mmio_reservations)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_mmio

	write := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0xA0000,
		Direction  = 1,
		AccessSize = 1,
	}
	write.Data[0] = 0x5A
	testing.expect(t, whpx_emu_mmio(&vm, &write) >= 0)
	testing.expect_value(t, probe.mmio_writes, 1)
	testing.expect_value(t, probe.mmio_value, u8(0x5A))
	testing.expect_value(t, vm.ram[0xA0000], u8(0))

	read := WHV_EMULATOR_MEMORY_ACCESS_INFO {
		GpaAddress = 0xA0000,
		AccessSize = 1,
	}
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
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
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
	copy(
		vm.ram[0x7C00:],
		[]u8{0xB8, 0x00, 0xA0, 0x8E, 0xD8, 0xC6, 0x06, 0x00, 0x00, 0x5A, 0xA0, 0x00, 0x00, 0xF4},
	)
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) {return}
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
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	device, ok := map_device_memory(&vm, 0xE0000000, 0x1000)
	if !testing.expect(t, ok) {return}
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

	code_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFFFFFF,
		Selector   = 8,
		Attributes = 0xC09B,
	}
	data_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFFFFFF,
		Selector   = 16,
		Attributes = 0xC093,
	}
	names := [?]WHV_REGISTER_NAME {
		.Cs,
		.Ds,
		.Es,
		.Ss,
		.Fs,
		.Gs,
		.Rip,
		.Rflags,
		.Rsi,
		.Rcx,
		.Rdx,
		.Cr0,
		.Cr3,
		.Cr4,
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
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0,
	) {return}

	translation_result: WHV_TRANSLATE_GVA_RESULT_CODE
	translated_gpa: u64
	if !testing.expect(
		t,
		whpx_emu_translate(&vm, 0x00400000, 1, &translation_result, &translated_gpa) >= 0,
	) {return}
	testing.expect_value(t, translation_result, WHV_TRANSLATE_GVA_RESULT_CODE.Success)
	testing.expect_value(t, translated_gpa, u64(0xE0000000))

	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write
	ex := run(&vm)
	testing.expect_value(t, ex.detail, "")
	if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, device[4], u8(0x5A))
	testing.expect_value(t, probe.io_count, 4)
	want := [4]u8{0x11, 0x22, 0x33, 0x44}
	for value, i in want {
		testing.expect_value(t, probe.io_ports[i], u16(0x1234))
		testing.expect_value(t, probe.io_values[i], value)
	}
}

@(test)
test_whpx_16_bit_protected_mode_rep_outsb_uses_dx_port :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	code_base := u64(0x20000)
	data_base := u64(0x30000)
	copy(
		vm.ram[code_base:],
		[]u8{0xBA, 0x34, 0x12, 0xBE, 0x00, 0x01, 0xB9, 0x04, 0x00, 0xFC, 0xF3, 0x6E, 0xF4},
	)
	copy(vm.ram[data_base + 0x100:], []u8{0x11, 0x22, 0x33, 0x44})

	code_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = code_base,
		Limit      = 0xFFFF,
		Selector   = 0x233D,
		Attributes = 0x009B,
	}
	data_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = data_base,
		Limit      = 0xFFFF,
		Selector   = 0x40CF,
		Attributes = 0x0093,
	}
	stack_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0x40000,
		Limit      = 0xFFFF,
		Selector   = 0x2323,
		Attributes = 0x0093,
	}
	names := [?]WHV_REGISTER_NAME{.Cs, .Ds, .Es, .Ss, .Fs, .Gs, .Rip, .Rflags, .Rsp, .Cr0}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	vals[1].Segment = data_seg
	vals[2].Segment = data_seg
	vals[3].Segment = stack_seg
	vals[4].Segment = data_seg
	vals[5].Segment = data_seg
	vals[6].Reg64 = 0
	vals[7].Reg64 = 0x2
	vals[8].Reg64 = 0x8000
	vals[9].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0,
	) {return}

	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write
	ex := run(&vm)
	testing.expect_value(t, ex.detail, "")
	if !testing.expect_value(t, ex.kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, probe.io_count, 4)
	want := [4]u8{0x11, 0x22, 0x33, 0x44}
	for value, i in want {
		testing.expect_value(t, probe.io_ports[i], u16(0x1234))
		testing.expect_value(t, probe.io_values[i], value)
	}
}

@(test)
test_whpx_manual_rep_outsb_honors_direction_flag :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	copy(vm.ram[0x9000:], []u8{0x11, 0x22, 0x33, 0x44})
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 4, 0x9003, 0xAABB, 0x7000, 0x402) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x1234)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_attempts, 4)
	want := [4]u8{0x44, 0x33, 0x22, 0x11}
	for value, i in want {testing.expect_value(t, probe.io_values[i], value)}
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x8FFF))
	testing.expect_value(t, regs.rdi, u64(0xAABB))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x7002))
}

@(test)
test_whpx_manual_rep_insw_writes_guest_memory :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	for &byte in vm.ram[0x9100:0x9104] {byte = 0xCC}
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0xDEAD, 2, 0xAABB, 0x9100, 0x7100, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6D}, 0x34, 0x2345)
	probe: Whpx_Test_Probe
	probe.io_read_values[0] = 0x1122
	probe.io_read_values[1] = 0x3344
	vm.io_ctx = &probe
	vm.io_read = whpx_test_io_read

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_read_count, 2)
	testing.expect_value(t, probe.io_last_size, u8(2))
	want := [4]u8{0x22, 0x11, 0x44, 0x33}
	for value, i in want {testing.expect_value(t, vm.ram[0x9100 + i], value)}
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rax, u64(0xDEAD))
	testing.expect_value(t, regs.rsi, u64(0xAABB))
	testing.expect_value(t, regs.rdi, u64(0x9104))
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rip, u64(0x7102))
}

@(test)
test_whpx_manual_address_override_wraps_16_bit_rep_indices :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vm.ram[0xFFFE] = 0xA1
	vm.ram[0xFFFF] = 0xB2
	vm.ram[0] = 0xC3
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 0xBEEF0003, 0xA5A5FFFE, 0, 0x7200, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0x67, 0xF3, 0x6E}, 0x33, 0x3456)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	want := [3]u8{0xA1, 0xB2, 0xC3}
	for value, i in want {testing.expect_value(t, probe.io_values[i], value)}
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0xA5A50001))
	testing.expect_value(t, regs.rcx, u64(0xBEEF0000))
	testing.expect_value(t, regs.rip, u64(0x7203))
}

@(test)
test_whpx_manual_zero_count_rep_advances_without_port_access :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(
		t,
		&vm,
		&vp,
		&io,
		0x1122,
		0x1234567800000000,
		0x89ABCDEF,
		0x76543210,
		0x7300,
		0x2,
	) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x4567)
	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, ok)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.io_attempts, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rax, u64(0x1122))
	testing.expect_value(t, regs.rcx, u64(0x1234567800000000))
	testing.expect_value(t, regs.rsi, u64(0x89ABCDEF))
	testing.expect_value(t, regs.rdi, u64(0x76543210))
	testing.expect_value(t, regs.rip, u64(0x7302))
}

@(test)
test_whpx_manual_rejected_rep_element_preserves_partial_progress :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	copy(vm.ram[0x9200:], []u8{0x10, 0x20, 0x30, 0x40})
	vp: WHV_VP_EXIT_CONTEXT
	io: WHV_X64_IO_PORT_ACCESS_CONTEXT
	if !whpx_test_manual_io_context(t, &vm, &vp, &io, 0, 4, 0x9200, 0xBEEF, 0x7400, 0x2) {
		return
	}
	whpx_test_manual_io_instruction(&vp, &io, []u8{0xF3, 0x6E}, 0x33, 0x5678)
	probe := Whpx_Test_Probe {
		io_reject       = true,
		io_reject_after = 2,
	}
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write

	ok, detail := whpx_emulate_io(&vm, &vp, &io)
	testing.expect(t, !ok)
	testing.expect_value(t, detail, "string I/O write rejected at port 0x5678")
	testing.expect_value(t, probe.io_attempts, 3)
	testing.expect_value(t, probe.io_count, 2)
	testing.expect_value(t, probe.io_values[0], u8(0x10))
	testing.expect_value(t, probe.io_values[1], u8(0x20))
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rsi, u64(0x9202))
	testing.expect_value(t, regs.rdi, u64(0xBEEF))
	testing.expect_value(t, regs.rcx, u64(2))
	testing.expect_value(t, regs.rip, u64(0x7400))
}

@(test)
test_whpx_non_string_out_preserves_unreported_registers :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	code_base := u64(0x20000)
	copy(
		vm.ram[code_base:],
		[]u8 {
			0xBE,
			0xFC,
			0x0C,
			0x00,
			0x00, // mov esi,0cfch
			0xBA,
			0xF8,
			0x0C,
			0x00,
			0x00, // mov edx,0cf8h
			0xB8,
			0x00,
			0x08,
			0x00,
			0x80, // mov eax,80000800h
			0xEF, // out dx,eax
			0xF4, // hlt
		},
	)
	code_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = code_base,
		Limit      = 0xFFFFFFFF,
		Selector   = 8,
		Attributes = 0xC09B,
	}
	data_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFFFFFF,
		Selector   = 16,
		Attributes = 0xC093,
	}
	names := [?]WHV_REGISTER_NAME{.Cs, .Ds, .Es, .Ss, .Fs, .Gs, .Rip, .Rflags, .Rsp, .Cr0}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	for i in 1 ..< 6 {vals[i].Segment = data_seg}
	vals[6].Reg64 = 0
	vals[7].Reg64 = 0x2
	vals[8].Reg64 = 0x8000
	vals[9].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0,
	) {return}

	probe: Whpx_Test_Probe
	vm.io_ctx = &probe
	vm.io_write = whpx_test_io_write
	if !testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt) {return}
	testing.expect_value(t, probe.io_last_size, u8(4))
	testing.expect_value(t, probe.io_last_value, u32(0x80000800))
	check_names := [?]WHV_REGISTER_NAME{.Rsi, .Rdx}
	check: [len(check_names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(
			vm.part,
			0,
			&check_names[0],
			u32(len(check_names)),
			&check[0],
		) >=
		0,
	) {return}
	testing.expect_value(t, check[0].Reg64, u64(0x0CFC))
	testing.expect_value(t, check[1].Reg64, u64(0x0CF8))
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
	if !testing.expect(t, ok) {return}
	// mov dx, 0x80; l: in al, dx; jmp l   (guest polls a port forever)
	copy(vm.ram[0x7C00:], []u8{0xBA, 0x80, 0x00, 0xEC, 0xEB, 0xFD})
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Io)
}

@(test)
test_whpx_triple_fault_requests_reset :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	// Load an empty IDT, then raise an exception whose handlers cannot be found.
	copy(
		vm.ram[0x7C00:],
		[]u8{0xFA, 0x31, 0xC0, 0x8E, 0xD8, 0x0F, 0x01, 0x1E, 0x10, 0x7C, 0xCC, 0xF4},
	)
	for i in 0 ..< 6 {vm.ram[0x7C10 + i] = 0}
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	testing.expect_value(t, ex.kind, Exit_Kind.Reset)
	testing.expect_value(t, ex.detail, "unrecoverable exception (triple fault)")
}

@(test)
test_whpx_cpu_reset_preserves_ram_and_restarts_at_reset_vector :: proc(t: ^testing.T) {
	if !available() {
		log.warn("WHPX not available")
		return
	}
	testing.set_fail_timeout(t, 10 * time.Second)
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	reset_page := make([]u8, 0x1000)
	defer delete(reset_page)
	// Write through the retained device mapping, then leave a register marker.
	copy(reset_page[0xFF0:], []u8{0xC6, 0x06, 0x00, 0x00, 0x6B, 0xB8, 0x34, 0x12, 0xF4})
	if !testing.expect(t, map_rom(&vm, 0xFFFFF000, reset_page)) {return}
	device, device_ok := map_device_memory(&vm, 0xE0000000, 0x1000)
	if !testing.expect(t, device_ok) {return}
	vm.ram[0x500] = 0xA5
	device[0] = 0x5A

	names := [?]WHV_REGISTER_NAME{.Cr0, .Cr3, .Idtr, .PendingInterruption}
	baseline: [len(names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &baseline[0]) >= 0,
	) {return}
	copy(
		vm.ram[0x7C00:],
		[]u8 {
			0xFA,
			0x31,
			0xC0,
			0x8E,
			0xD8,
			0x0F,
			0x01,
			0x16,
			0xF0,
			0x7C, // lgdt [7cf0h]
			0x66,
			0xB8,
			0x00,
			0x10,
			0x00,
			0x00, // mov eax, 1000h
			0x0F,
			0x22,
			0xD8, // mov cr3, eax
			0x0F,
			0x20,
			0xC0, // mov eax, cr0
			0x66,
			0x83,
			0xC8,
			0x01, // or eax, 1
			0x0F,
			0x22,
			0xC0, // mov cr0, eax
			0xEA,
			0x30,
			0x7C,
			0x08,
			0x00, // jmp 0008:7c30h
		},
	)
	copy(
		vm.ram[0x7C30:],
		[]u8 {
			0xB8,
			0x10,
			0x00, // mov ax, 10h
			0x8E,
			0xD8, // mov ds, ax
			0x8E,
			0xD0, // mov ss, ax
			0xBC,
			0x00,
			0x70, // mov sp, 7000h
			0x0F,
			0x01,
			0x1E,
			0xF6,
			0x7C, // lidt [7cf6h]
			0xCC,
		},
	)
	copy(vm.ram[0x7CF0:], []u8{0x17, 0x00, 0x00, 0x7D, 0x00, 0x00})
	for i in 0 ..< 6 {vm.ram[0x7CF6 + i] = 0}
	copy(
		vm.ram[0x7D00:],
		[]u8 {
			0,
			0,
			0,
			0,
			0,
			0,
			0,
			0,
			0xFF,
			0xFF,
			0,
			0,
			0,
			0x9A,
			0,
			0,
			0xFF,
			0xFF,
			0,
			0,
			0,
			0x92,
			0,
			0,
		},
	)
	set_realmode_entry(&vm, 0, 0x7C00)
	ex := run(&vm)
	if !testing.expect_value(t, ex.kind, Exit_Kind.Reset) {return}
	dirty: [len(names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &dirty[0]) >= 0,
	) {return}
	testing.expect(t, dirty[0].Reg64 & 1 != 0)
	testing.expect_value(t, dirty[1].Reg64, u64(0x1000))
	testing.expect_value(t, dirty[2].Table.Limit, u16(0))
	if !testing.expect(t, reset_cpu(&vm)) {return}
	after: [len(names)]WHV_REGISTER_VALUE
	if !testing.expect(
		t,
		WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &after[0]) >= 0,
	) {return}
	testing.expect_value(t, after[0].Reg64, baseline[0].Reg64)
	testing.expect_value(t, after[1].Reg64, baseline[1].Reg64)
	testing.expect_value(t, after[2].Table, baseline[2].Table)
	testing.expect_value(t, after[3].Reg64, baseline[3].Reg64)
	device_ds_name := WHV_REGISTER_NAME.Ds
	device_ds: WHV_REGISTER_VALUE
	device_ds.Segment = WHV_X64_SEGMENT_REGISTER {
		Base       = 0xE0000000,
		Limit      = 0xFFFF,
		Selector   = 0,
		Attributes = 0x0093,
	}
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &device_ds_name, 1, &device_ds) >= 0,
	) {return}
	testing.expect_value(t, run(&vm).kind, Exit_Kind.Halt)
	testing.expect_value(t, u16(reg_rax(&vm)), u16(0x1234))
	testing.expect_value(t, vm.ram[0x500], u8(0xA5))
	testing.expect_value(t, device[0], u8(0x6B))
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
	if !testing.expect(t, ok) {return}

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
