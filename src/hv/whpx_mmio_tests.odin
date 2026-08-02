// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:strings"
import "core:testing"

Whpx_Mmio_Fallback_Probe :: struct {
	reads:              int,
	writes:             int,
	call_count:         int,
	call_gpas:          [8]u64,
	call_sizes:         [8]int,
	written:            [32]u8,
	written_len:        int,
	read_data:          [8]u8,
	budget:             u64,
	begin_count:        int,
	end_count:          int,
	budget_begin_count: int,
}

@(private = "package")
whpx_test_fallback_budget :: proc(ctx: rawptr) -> u64 {
	probe := (^Whpx_Mmio_Fallback_Probe)(ctx)
	probe.budget_begin_count = probe.begin_count
	return probe.budget
}

@(private = "package")
whpx_test_fallback_begin :: proc(ctx: rawptr) {
	(^Whpx_Mmio_Fallback_Probe)(ctx).begin_count += 1
}

@(private = "package")
whpx_test_fallback_end :: proc(ctx: rawptr) {
	(^Whpx_Mmio_Fallback_Probe)(ctx).end_count += 1
}

whpx_test_fallback_mmio :: proc(ctx: rawptr, gpa: u64, write: bool, data: []u8) {
	probe := (^Whpx_Mmio_Fallback_Probe)(ctx)
	if probe.call_count < len(probe.call_gpas) {
		probe.call_gpas[probe.call_count] = gpa
		probe.call_sizes[probe.call_count] = len(data)
	}
	probe.call_count += 1
	if write {
		probe.writes += 1
		count := min(len(data), len(probe.written) - probe.written_len)
		copy(probe.written[probe.written_len:], data[:count])
		probe.written_len += count
		return
	}
	probe.reads += 1
	for &byte, i in data {byte = probe.read_data[i]}
}

@(private = "package")
whpx_test_mmio_state :: proc(
	t: ^testing.T,
	vm: ^Vm,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	gpr: [8]u64,
	ds_base: u64,
	ds_limit: u32,
	instruction: []u8,
	gpa: u64,
	write: bool,
	rflags: u64,
) -> bool {
	code := WHV_X64_SEGMENT_REGISTER {
		Limit      = 0xFFFF_FFFF,
		Selector   = 8,
		Attributes = 0xC09B,
	}
	data := WHV_X64_SEGMENT_REGISTER {
		Base       = ds_base,
		Limit      = ds_limit,
		Selector   = 16,
		Attributes = 0xC093,
	}
	flat_data := data
	flat_data.Base = 0
	names := [?]WHV_REGISTER_NAME {
		.Cs, .Ds, .Es, .Ss, .Fs, .Gs,
		.Rax, .Rcx, .Rdx, .Rbx, .Rsp, .Rbp, .Rsi, .Rdi,
		.Rip, .Rflags, .Cr0,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Segment = code
	values[1].Segment = data
	for i in 2 ..< 6 {values[i].Segment = flat_data}
	for value, i in gpr {values[6 + i].Reg64 = value}
	values[14].Reg64 = 0x7000
	values[15].Reg64 = rflags
	values[16].Reg64 = 0x11
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {return false}
	vp^ = WHV_VP_EXIT_CONTEXT {
		InstructionLengthCr8 = 0,
		Cs                   = code,
		Rip                  = 0x7000,
		Rflags               = rflags,
	}
	mmio^ = WHV_MEMORY_ACCESS_CONTEXT {
		InstructionByteCount = u8(len(instruction)),
		AccessInfo           = write ? 1 : 0,
		Gpa                  = gpa,
	}
	copy(mmio.InstructionBytes[:], instruction)
	return true
}

@(private = "file")
whpx_test_decode :: proc(
	t: ^testing.T,
	bytes: []u8,
	default_32 := true,
) -> (Whpx_Mmio_Instruction, bool) {
	decoded, ok, reason := whpx_decode_mmio_instruction(bytes, default_32)
	if !testing.expectf(t, ok, "decode failed: %s", reason) {return decoded, false}
	return decoded, true
}

@(test)
test_whpx_mmio_decoder_scalar_sib_store :: proc(t: ^testing.T) {
	decoded, ok := whpx_test_decode(t, []u8{0x89, 0x0C, 0x86})
	if !ok {return}
	testing.expect_value(t, decoded.kind, Whpx_Mmio_Kind.Scalar_Store_Register)
	testing.expect_value(t, decoded.memory_width, u8(4))
	testing.expect_value(t, decoded.register, u8(1))
	testing.expect(t, decoded.address.base_present)
	testing.expect_value(t, decoded.address.base_register, u8(6))
	testing.expect(t, decoded.address.index_present)
	testing.expect_value(t, decoded.address.index_register, u8(0))
	testing.expect_value(t, decoded.address.scale, u8(4))
	testing.expect_value(t, decoded.address.segment, WHV_REGISTER_NAME.Ds)
	testing.expect_value(t, decoded.length, u8(3))
}

@(test)
test_whpx_mmio_decoder_stops_at_the_scalar_store_inside_a_counted_loop :: proc(t: ^testing.T) {
	decoded, ok := whpx_test_decode(t, []u8{0x89, 0x0C, 0x86, 0x40, 0x39, 0xD8, 0x7C, 0xF8})
	if !ok {return}
	testing.expect_value(t, decoded.kind, Whpx_Mmio_Kind.Scalar_Store_Register)
	testing.expect_value(t, decoded.memory_width, u8(4))
	testing.expect_value(t, decoded.register, u8(1))
	testing.expect_value(t, decoded.address.base_register, u8(6))
	testing.expect_value(t, decoded.address.index_register, u8(0))
	testing.expect_value(t, decoded.address.scale, u8(4))
	testing.expect_value(t, decoded.address.segment, WHV_REGISTER_NAME.Ds)
	testing.expect_value(t, decoded.length, u8(3))

	decoded, ok, _ = whpx_decode_mmio_instruction(
		[]u8{0x89, 0x0C, 0x86, 0x40, 0x39, 0xD8, 0x7C, 0xF8},
		false,
	)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.kind, Whpx_Mmio_Kind.Scalar_Store_Register)
}

@(test)
test_whpx_mmio_decoder_prefixes_segments_and_16_bit_addressing :: proc(t: ^testing.T) {
	decoded, ok := whpx_test_decode(t, []u8{0x64, 0x66, 0x67, 0x89, 0x4A, 0xFE})
	if !ok {return}
	testing.expect_value(t, decoded.memory_width, u8(2))
	testing.expect_value(t, decoded.address.address_bits, 16)
	testing.expect_value(t, decoded.address.segment, WHV_REGISTER_NAME.Fs)
	testing.expect_value(t, decoded.address.base_register, u8(5))
	testing.expect_value(t, decoded.address.index_register, u8(6))
	testing.expect_value(t, decoded.address.displacement, u64(0xFFFE))
	testing.expect_value(t, decoded.length, u8(6))
}

@(test)
test_whpx_mmio_decoder_covers_bounded_data_movement_forms :: proc(t: ^testing.T) {
	{
		load, ok := whpx_test_decode(t, []u8{0x8A, 0x20})
		if !ok {return}
		testing.expect_value(t, load.kind, Whpx_Mmio_Kind.Scalar_Load)
		testing.expect_value(t, load.register, u8(4))
		testing.expect_value(t, load.memory_width, u8(1))
	}
	{
		immediate, ok := whpx_test_decode(t, []u8{0xC7, 0x00, 0x78, 0x56, 0x34, 0x12})
		if !ok {return}
		testing.expect_value(t, immediate.kind, Whpx_Mmio_Kind.Scalar_Store_Immediate)
		testing.expect_value(t, immediate.immediate, u32(0x1234_5678))
	}
	{
		moffs, ok := whpx_test_decode(t, []u8{0xA1, 0x00, 0x00, 0x0A, 0x00})
		if !ok {return}
		testing.expect_value(t, moffs.kind, Whpx_Mmio_Kind.Scalar_Load)
		testing.expect_value(t, moffs.address.displacement, u64(0xA0000))
	}
	{
		movzx, ok := whpx_test_decode(t, []u8{0x0F, 0xB6, 0x08})
		if !ok {return}
		testing.expect_value(t, movzx.extension, Whpx_Mmio_Extension.Zero)
		testing.expect_value(t, movzx.memory_width, u8(1))
		testing.expect_value(t, movzx.register_width, u8(4))
	}
	{
		movsx, ok := whpx_test_decode(t, []u8{0x0F, 0xBF, 0x08})
		if !ok {return}
		testing.expect_value(t, movsx.extension, Whpx_Mmio_Extension.Sign)
		testing.expect_value(t, movsx.memory_width, u8(2))
	}
	{
		movs, ok := whpx_test_decode(t, []u8{0xF3, 0xA5})
		if !ok {return}
		testing.expect_value(t, movs.kind, Whpx_Mmio_Kind.Movs)
		testing.expect(t, movs.rep)
	}
	{
		stos, ok := whpx_test_decode(t, []u8{0x66, 0xAB})
		if !ok {return}
		testing.expect_value(t, stos.kind, Whpx_Mmio_Kind.Stos)
		testing.expect_value(t, stos.memory_width, u8(2))
	}
	{
		lods, ok := whpx_test_decode(t, []u8{0xAC})
		if !ok {return}
		testing.expect_value(t, lods.kind, Whpx_Mmio_Kind.Lods)
	}
}

@(test)
test_whpx_mmio_decoder_rejects_unbounded_or_nonmemory_forms :: proc(t: ^testing.T) {
	_, ok, reason := whpx_decode_mmio_instruction([]u8{0xF0, 0x89, 0x08}, true)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "LOCK is unsupported for MMIO fallback")
	_, ok, reason = whpx_decode_mmio_instruction([]u8{0x89, 0xC8}, true)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "ModRM does not name memory")
	_, ok, reason = whpx_decode_mmio_instruction([]u8{0xFF}, true)
	testing.expect(t, !ok)
	testing.expect_value(t, reason, "unsupported MMIO opcode")
}

@(test)
test_whpx_scalar_sib_store_handles_flat_and_wrapped_ds :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}

	instruction := []u8{0x89, 0x0C, 0x86, 0x40, 0x39, 0xD8, 0x7C, 0xF8}
	ds_bases := [?]u64{0, 0xFFF0_0000}
	for ds_base, i in ds_bases {
		probe: Whpx_Mmio_Fallback_Probe
		vm.io_ctx = &probe
		vm.mmio = whpx_test_fallback_mmio
		gpr: [8]u64
		gpr[0] = 3
		gpr[1] = 0x4433_2211
		gpr[6] = i == 0 ? 0x9FFF4 : 0x19FFF4
		vp: WHV_VP_EXIT_CONTEXT
		mmio: WHV_MEMORY_ACCESS_CONTEXT
		if !whpx_test_mmio_state(
			t,
			&vm,
			&vp,
			&mmio,
			gpr,
			ds_base,
			0xFFFF_FFFF,
			instruction,
			0xA0000,
			true,
			0x2,
		) {return}
		decoded, ok := whpx_test_decode(t, mmio.InstructionBytes[:mmio.InstructionByteCount])
		if !ok {return}
		executed, detail := whpx_execute_mmio_fallback(&vm, &vp, &mmio, decoded)
		if !testing.expectf(t, executed, "%s", detail) {return}
		testing.expect_value(t, probe.writes, 1)
		testing.expect_value(t, probe.written_len, 4)
		testing.expect_value(t, probe.written[0], u8(0x11))
		testing.expect_value(t, probe.written[1], u8(0x22))
		testing.expect_value(t, probe.written[2], u8(0x33))
		testing.expect_value(t, probe.written[3], u8(0x44))
		testing.expect_value(t, get_regs(&vm).rip, u64(0x7003))
	}
}

@(test)
test_whpx_scalar_mmio_store_preserves_page_crossing_order :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	if !testing.expect(t, reserve_mmio(&vm, 0xB0000, 0x1000)) {return}
	whpx_test_write_u32(vm.ram, 0x1000, 0x2003)
	whpx_test_write_u32(vm.ram, 0x2000 + 2 * 4, 0xA0003)
	whpx_test_write_u32(vm.ram, 0x2000 + 3 * 4, 0xB0003)
	gpr: [8]u64
	gpr[1] = 0x4433_2211
	gpr[6] = 0x2FFF
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !whpx_test_mmio_state(
		t, &vm, &vp, &mmio, gpr, 0, 0xFFFF_FFFF,
		[]u8{0x89, 0x0C, 0x86}, 0xA0FFF, true, 0x2,
	) {return}
	names := [?]WHV_REGISTER_NAME{.Cr3, .Cr0}
	values: [len(names)]WHV_REGISTER_VALUE
	values[0].Reg64 = 0x1000
	values[1].Reg64 = 0x8000_0011
	if !testing.expect(
		t,
		WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) >= 0,
	) {return}
	probe: Whpx_Mmio_Fallback_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_fallback_mmio
	decoded, ok := whpx_test_decode(t, mmio.InstructionBytes[:3])
	if !ok {return}
	executed, detail := whpx_execute_mmio_fallback(&vm, &vp, &mmio, decoded)
	if !testing.expectf(t, executed, "%s", detail) {return}
	testing.expect_value(t, probe.call_count, 2)
	testing.expect_value(t, probe.call_gpas[0], u64(0xA0FFF))
	testing.expect_value(t, probe.call_sizes[0], 1)
	testing.expect_value(t, probe.call_gpas[1], u64(0xB0000))
	testing.expect_value(t, probe.call_sizes[1], 3)
	testing.expect_value(t, probe.written_len, 4)
}

@(test)
test_whpx_scalar_mmio_readback_and_extensions_commit_after_access :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	gpr: [8]u64
	gpr[0] = 0xA0000
	gpr[1] = 0xFFFF_FFFF
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !whpx_test_mmio_state(
		t, &vm, &vp, &mmio, gpr, 0, 0xFFFF_FFFF,
		[]u8{0x0F, 0xBE, 0x08}, 0xA0000, false, 0x2,
	) {return}
	probe: Whpx_Mmio_Fallback_Probe
	probe.read_data[0] = 0x80
	vm.io_ctx = &probe
	vm.mmio = whpx_test_fallback_mmio
	decoded, ok := whpx_test_decode(t, mmio.InstructionBytes[:3])
	if !ok {return}
	executed, detail := whpx_execute_mmio_fallback(&vm, &vp, &mmio, decoded)
	if !testing.expectf(t, executed, "%s", detail) {return}
	regs := get_regs(&vm)
	testing.expect_value(t, u32(regs.rcx), u32(0xFFFF_FF80))
	testing.expect_value(t, regs.rip, u64(0x7003))
	testing.expect_value(t, probe.reads, 1)
}

@(test)
test_whpx_scalar_mmio_fault_keeps_rip_and_skips_device_access :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	gpr: [8]u64
	gpr[1] = 0x4433_2211
	gpr[6] = 0xA0000
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !whpx_test_mmio_state(
		t, &vm, &vp, &mmio, gpr, 0, 0x9FFFF,
		[]u8{0x89, 0x0C, 0x86}, 0xA0000, true, 0x2,
	) {return}
	probe: Whpx_Mmio_Fallback_Probe
	vm.io_ctx = &probe
	vm.mmio = whpx_test_fallback_mmio
	decoded, ok := whpx_test_decode(t, mmio.InstructionBytes[:3])
	if !ok {return}
	executed, detail := whpx_execute_mmio_fallback(&vm, &vp, &mmio, decoded)
	testing.expect(t, executed)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.call_count, 0)
	testing.expect_value(t, get_regs(&vm).rip, u64(0x7000))
	name := WHV_REGISTER_NAME.PendingEvent
	pending: WHV_REGISTER_VALUE
	if !testing.expect(t, WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &pending) >= 0) {
		return
	}
	testing.expect_value(t, pending.Reg128[0] >> 16 & 0xFFFF, u64(13))
}

@(test)
test_whpx_rep_movs_mmio_honors_width_direction_and_progress :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)
	if !testing.expect(t, reserve_mmio(&vm, 0xA0000, 0x1000)) {return}
	copy(vm.ram[0x8000:], []u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88})

	direction_flags := [?]u64{0, 0x400}
	for direction_flag, i in direction_flags {
		gpr: [8]u64
		gpr[1] = 2
		gpr[6] = i == 0 ? 0x8000 : 0x8004
		gpr[7] = i == 0 ? 0xA0000 : 0xA0004
		vp: WHV_VP_EXIT_CONTEXT
		mmio: WHV_MEMORY_ACCESS_CONTEXT
		if !whpx_test_mmio_state(
			t, &vm, &vp, &mmio, gpr, 0, 0xFFFF_FFFF,
			[]u8{0xF3, 0xA5}, gpr[7], true, 0x2 | direction_flag,
		) {return}
		probe: Whpx_Mmio_Fallback_Probe
		vm.io_ctx = &probe
		vm.mmio = whpx_test_fallback_mmio
		decoded, ok := whpx_test_decode(t, mmio.InstructionBytes[:2])
		if !ok {return}
		executed, detail := whpx_execute_mmio_fallback(&vm, &vp, &mmio, decoded)
		if !testing.expectf(t, executed, "%s", detail) {return}
		regs := get_regs(&vm)
		testing.expect_value(t, regs.rcx, u64(0))
		testing.expect_value(t, regs.rsi, i == 0 ? u64(0x8008) : u64(0x7FFC))
		testing.expect_value(t, regs.rdi, i == 0 ? u64(0xA0008) : u64(0x9FFFC))
		testing.expect_value(t, regs.rip, u64(0x7002))
		testing.expect_value(t, probe.written_len, 8)
	}
}

// The rejection diagnostic is the only postmortem record of a guest
// instruction the host cannot execute, so it must survive formatting: a
// literal brace is a core:fmt directive and once ate the CS selector it named.
@(test)
test_whpx_mmio_diagnostic_names_cs_rip_without_brace_damage :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	if !testing.expect(t, create(&vm, 64 * 1024 * 1024)) {return}
	defer destroy(&vm)

	vp: WHV_VP_EXIT_CONTEXT
	vp.Rip = 0xFFFF
	vp.Cs.Selector = 0x9E9D
	vp.Cs.Base = 0x9E9D0
	vp.Cs.Attributes = 0x00F3
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	mmio.Gpa = 0xAE000
	bytes := [?]u8{0x66, 0xA5}

	text := whpx_mmio_diagnostic(&vm, &vp, &mmio, 0, 2, 0, bytes[:], "unsupported MMIO opcode")

	testing.expect(t, !strings.contains(text, "MISSING"))
	testing.expect(t, strings.contains(text, "cs=[sel=0x9e9d"))
	testing.expect(t, strings.contains(text, "rip=0xffff"))
	testing.expect(t, strings.contains(text, "gpa=0xae000"))
	testing.expect(t, strings.contains(text, "ins_linear=0xae9cf"))
	testing.expect(t, strings.contains(text, "reject=unsupported MMIO opcode"))
}
