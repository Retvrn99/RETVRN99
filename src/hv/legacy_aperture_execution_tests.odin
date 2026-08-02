// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:log"
import "core:testing"

@(private = "file")
legacy_aperture_execution_test_layout :: proc(_: rawptr) -> Legacy_Aperture_Layout {
	return {
		kind = .Indexed_Unchained,
		width = 360,
		height = 240,
		pitch_bytes = 90,
		aperture_base = 0xA0000,
		aperture_size = 0x10000,
	}
}

@(test)
legacy_aperture_execution_test_auto_and_scalar_forward_the_same_physical_exits :: proc(
	t: ^testing.T,
) {
	modes := [?]Legacy_Aperture_Execution_Mode{.Auto, .Scalar}
	gpas := [?]u64{0x9FFFF, 0xA0000, 0xBFFFF, 0xC0000}
	for mode in modes {
		vm: Vm
		legacy_aperture_execution_set_mode(&vm, mode)
		vp: WHV_VP_EXIT_CONTEXT
		mmio: WHV_MEMORY_ACCESS_CONTEXT
		for gpa in gpas {
			mmio.Gpa = gpa
			action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
			testing.expect_value(t, action, Legacy_Aperture_Execution_Action.Forward)
			testing.expect_value(t, detail, "")
		}

		snapshot := legacy_aperture_execution_observability(&vm)
		testing.expect_value(t, snapshot.mode, mode)
		testing.expect_value(t, snapshot.memory_access_exits, u64(2))
		testing.expect_value(t, snapshot.forwarded_exits, u64(2))
	}
}

@(test)
legacy_aperture_execution_test_histogram_retains_exact_keys_and_accounting :: proc(t: ^testing.T) {
	vm: Vm
	legacy_aperture_execution_set_mode(&vm, .Scalar)
	legacy_aperture_execution_set_layout_adapter(
		&vm,
		Legacy_Aperture_Layout_Adapter{snapshot = legacy_aperture_execution_test_layout},
	)
	if !testing.expect(t, legacy_aperture_execution_set_histogram_enabled(&vm, true)) {return}
	defer legacy_aperture_execution_destroy(&vm)

	vp := WHV_VP_EXIT_CONTEXT {
		Rip = 0x1234,
	}
	vp.Cs.Selector = 0xA7
	mmio := WHV_MEMORY_ACCESS_CONTEXT {
		InstructionByteCount = 8,
		Gpa                  = 0xA0004,
	}
	instruction := [?]u8{0x89, 0x0C, 0x86, 0x40, 0x39, 0xD8, 0x7C, 0xF8}
	copy(mmio.InstructionBytes[:], instruction[:])
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	mmio.Gpa = 0xA0000
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)

	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect(t, snapshot.histogram_enabled)
	testing.expect_value(t, snapshot.histogram_rows, u64(2))
	testing.expect_value(t, snapshot.histogram_exits, u64(3))
	testing.expect_value(t, snapshot.histogram_retained_exits, u64(3))
	testing.expect_value(t, snapshot.histogram_dropped_exits, u64(0))

	report := legacy_aperture_execution_histogram_text(&vm)
	defer delete(report)
	testing.expect_value(
		t,
		report,
		"schema\tlegacy-aperture-histogram-v1\n" +
		"mode\tscalar\n" +
		"capacity\t65536\n" +
		"rows\t2\n" +
		"exits\t3\n" +
		"retained\t3\n" +
		"dropped\t0\n" +
		"instruction\toperation\tcs\trip\tgpa\tlayout\twidth\theight\tpitch\taperture_base\taperture_size\texits\n" +
		"890c864039d87cf8\tScalar_Store_Register\t00a7\t0000000000001234\t00000000000a0000\tIndexed_Unchained\t360\t240\t90\t00000000000a0000\t65536\t1\n" +
		"890c864039d87cf8\tScalar_Store_Register\t00a7\t0000000000001234\t00000000000a0004\tIndexed_Unchained\t360\t240\t90\t00000000000a0000\t65536\t2\n",
	)
}

@(test)
legacy_aperture_execution_test_whpx_destroy_releases_histogram_state :: proc(t: ^testing.T) {
	vm: Vm
	if !testing.expect(t, legacy_aperture_execution_set_histogram_enabled(&vm, true)) {return}
	whpx_destroy(&vm)
	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect(t, !snapshot.histogram_enabled)
	testing.expect_value(t, snapshot.histogram_rows, u64(0))
}

@(test)
legacy_aperture_execution_test_histogram_overflow_is_exactly_accounted :: proc(t: ^testing.T) {
	vm: Vm
	if !testing.expect(t, legacy_aperture_execution_set_histogram_enabled(&vm, true)) {return}
	defer legacy_aperture_execution_destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	mmio := WHV_MEMORY_ACCESS_CONTEXT {
		InstructionByteCount = 1,
	}
	mmio.InstructionBytes[0] = 0xAA
	for index in 0 ..< LEGACY_APERTURE_HISTOGRAM_CAPACITY + 1 {
		mmio.Gpa = LEGACY_APERTURE_EXECUTION_BASE + u64(index)
		_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	}

	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect_value(t, snapshot.histogram_rows, u64(LEGACY_APERTURE_HISTOGRAM_CAPACITY))
	testing.expect_value(t, snapshot.histogram_exits, u64(LEGACY_APERTURE_HISTOGRAM_CAPACITY + 1))
	testing.expect_value(
		t,
		snapshot.histogram_retained_exits,
		u64(LEGACY_APERTURE_HISTOGRAM_CAPACITY),
	)
	testing.expect_value(t, snapshot.histogram_dropped_exits, u64(1))
	testing.expect_value(
		t,
		snapshot.histogram_exits,
		snapshot.histogram_retained_exits + snapshot.histogram_dropped_exits,
	)
}

@(test)
legacy_aperture_execution_test_histogram_window_resets_and_pauses_collection :: proc(
	t: ^testing.T,
) {
	vm: Vm
	if !testing.expect(t, legacy_aperture_execution_set_histogram_enabled(&vm, true)) {return}
	defer legacy_aperture_execution_destroy(&vm)
	vp: WHV_VP_EXIT_CONTEXT
	mmio := WHV_MEMORY_ACCESS_CONTEXT {
		InstructionByteCount = 1,
		Gpa                  = 0xA0000,
	}
	mmio.InstructionBytes[0] = 0xAA

	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	testing.expect(t, legacy_aperture_execution_histogram_end(&vm))
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect(t, !snapshot.histogram_collecting)
	testing.expect_value(t, snapshot.histogram_exits, u64(1))

	testing.expect(t, legacy_aperture_execution_histogram_begin(&vm))
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	_, _ = legacy_aperture_execution_step(&vm, &vp, &mmio)
	testing.expect(t, legacy_aperture_execution_histogram_end(&vm))
	snapshot = legacy_aperture_execution_observability(&vm)
	testing.expect(t, !snapshot.histogram_collecting)
	testing.expect_value(t, snapshot.histogram_rows, u64(1))
	testing.expect_value(t, snapshot.histogram_exits, u64(2))
	testing.expect_value(t, snapshot.histogram_retained_exits, u64(2))
	testing.expect_value(t, snapshot.histogram_dropped_exits, u64(0))
	testing.expect_value(t, snapshot.memory_access_exits, u64(4))
}

@(private = "file")
legacy_aperture_execution_test_counted_store_instruction :: proc() -> [15]u8 {
	return {
		0x89,
		0x1F,
		0x83,
		0xC6,
		0x10,
		0x83,
		0xC7,
		0x04,
		0x49,
		0x75,
		0xE7,
		0x03,
		0x3D,
		0xE8,
		0xDB,
	}
}

@(private = "file")
legacy_aperture_execution_test_counted_store_head :: proc() -> [14]u8 {
	return {0x8A, 0x7E, 0x0C, 0x8A, 0x5E, 0x08, 0xC1, 0xE3, 0x10, 0x8A, 0x7E, 0x04, 0x8A, 0x1E}
}

@(private = "file")
legacy_aperture_execution_test_prepare_counted_store :: proc(
	t: ^testing.T,
	vm: ^Vm,
	probe: ^Whpx_Mmio_Fallback_Probe,
	vp: ^WHV_VP_EXIT_CONTEXT,
	mmio: ^WHV_MEMORY_ACCESS_CONTEXT,
	count: u64,
	budget: u64,
	rflags := u64(0x203),
	source := u64(0x8000),
) -> bool {
	if !testing.expect(t, create(vm, 64 * 1024 * 1024)) {return false}
	if !testing.expect(t, reserve_mmio(vm, 0xA0000, 0x10000)) {return false}
	probe.budget = budget
	vm.io_ctx = probe
	vm.mmio = whpx_test_fallback_mmio
	vm.io_string_budget = whpx_test_fallback_budget
	vm.io_string_begin = whpx_test_fallback_begin
	vm.io_string_end = whpx_test_fallback_end
	legacy_aperture_execution_set_mode(vm, .Auto)
	legacy_aperture_execution_set_layout_adapter(
		vm,
		Legacy_Aperture_Layout_Adapter{snapshot = legacy_aperture_execution_test_layout},
	)
	gpr: [8]u64
	gpr[1] = count
	gpr[3] = 0x4433_2211
	gpr[6] = source
	gpr[7] = 0xA0000
	instruction := legacy_aperture_execution_test_counted_store_instruction()
	if !whpx_test_mmio_state(
		t,
		vm,
		vp,
		mmio,
		gpr,
		0,
		0xFFFF_FFFF,
		instruction[:],
		0xA0000,
		true,
		rflags,
	) {
		return false
	}
	head := legacy_aperture_execution_test_counted_store_head()
	copy(vm.ram[0x7000 - len(head):], head[:])
	vm.ram[0x8010] = 0x55
	vm.ram[0x8014] = 0x66
	vm.ram[0x8018] = 0x77
	vm.ram[0x801C] = 0x88
	vm.ram[0x8020] = 0x99
	vm.ram[0x8024] = 0xAA
	vm.ram[0x8028] = 0xBB
	vm.ram[0x802C] = 0xCC
	return true
}

@(test)
legacy_aperture_execution_test_counted_store_matches_scalar_bytes_and_final_state :: proc(
	t: ^testing.T,
) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	probe: Whpx_Mmio_Fallback_Probe
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !legacy_aperture_execution_test_prepare_counted_store(
		t,
		&vm,
		&probe,
		&vp,
		&mmio,
		3,
		WHPX_IO_STRING_BUDGET,
	) {return}
	defer destroy(&vm)

	action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
	if !testing.expectf(t, action == .Handled, "%s", detail) {return}
	testing.expect_value(t, probe.call_count, 3)
	testing.expect_value(t, probe.writes, 3)
	testing.expect_value(t, probe.written_len, 12)
	expected := [?]u8{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC}
	for byte, index in expected {
		testing.expect_value(t, probe.written[index], byte)
	}
	for index in 0 ..< 3 {
		testing.expect_value(t, probe.call_gpas[index], u64(0xA0000 + index * 4))
		testing.expect_value(t, probe.call_sizes[index], 4)
	}
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rcx, u64(0))
	testing.expect_value(t, regs.rbx, u64(0xCCBB_AA99))
	testing.expect_value(t, regs.rsi, u64(0x8030))
	testing.expect_value(t, regs.rdi, u64(0xA000C))
	testing.expect_value(t, regs.rip, u64(0x700B))
	testing.expect_value(t, regs.rflags, u64(0x246))
	testing.expect_value(t, probe.begin_count, 1)
	testing.expect_value(t, probe.end_count, 1)
	testing.expect_value(t, probe.budget_begin_count, 1)
	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect_value(t, snapshot.memory_access_exits, u64(1))
	testing.expect_value(t, snapshot.forwarded_exits, u64(0))
	testing.expect_value(t, snapshot.handled_exits, u64(1))
	testing.expect_value(t, snapshot.executed_elements, u64(3))
}

@(test)
legacy_aperture_execution_test_counted_store_budget_yields_at_loop_head :: proc(t: ^testing.T) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	probe: Whpx_Mmio_Fallback_Probe
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !legacy_aperture_execution_test_prepare_counted_store(t, &vm, &probe, &vp, &mmio, 3, 2) {
		return
	}
	defer destroy(&vm)

	action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
	if !testing.expectf(t, action == .Handled, "%s", detail) {return}
	regs := get_regs(&vm)
	testing.expect_value(t, probe.call_count, 2)
	testing.expect_value(t, regs.rcx, u64(1))
	testing.expect_value(t, regs.rbx, u64(0x8877_6655))
	testing.expect_value(t, regs.rsi, u64(0x8020))
	testing.expect_value(t, regs.rdi, u64(0xA0008))
	testing.expect_value(
		t,
		regs.rip,
		u64(0x7000 - len(legacy_aperture_execution_test_counted_store_head())),
	)
	testing.expect_value(t, regs.rflags, u64(0x202))
}

@(test)
legacy_aperture_execution_test_counted_store_rejects_trap_flag_without_side_effects :: proc(
	t: ^testing.T,
) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	probe: Whpx_Mmio_Fallback_Probe
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !legacy_aperture_execution_test_prepare_counted_store(
		t,
		&vm,
		&probe,
		&vp,
		&mmio,
		3,
		WHPX_IO_STRING_BUDGET,
		0x303,
	) {return}
	defer destroy(&vm)

	action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
	testing.expect_value(t, action, Legacy_Aperture_Execution_Action.Forward)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.call_count, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rcx, u64(3))
	testing.expect_value(t, regs.rip, u64(0x7000))
	snapshot := legacy_aperture_execution_observability(&vm)
	testing.expect_value(t, snapshot.forwarded_exits, u64(1))
	testing.expect_value(t, snapshot.handled_exits, u64(0))
}

@(test)
legacy_aperture_execution_test_scalar_mode_keeps_exact_template_on_native_path :: proc(
	t: ^testing.T,
) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	probe: Whpx_Mmio_Fallback_Probe
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !legacy_aperture_execution_test_prepare_counted_store(
		t,
		&vm,
		&probe,
		&vp,
		&mmio,
		3,
		WHPX_IO_STRING_BUDGET,
	) {return}
	defer destroy(&vm)
	legacy_aperture_execution_set_mode(&vm, .Scalar)

	action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
	testing.expect_value(t, action, Legacy_Aperture_Execution_Action.Forward)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.call_count, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rcx, u64(3))
	testing.expect_value(t, regs.rip, u64(0x7000))
}

@(test)
legacy_aperture_execution_test_counted_store_preflights_future_source_before_writes :: proc(
	t: ^testing.T,
) {
	if !available() {log.warn("WHPX not available"); return}
	vm: Vm
	probe: Whpx_Mmio_Fallback_Probe
	vp: WHV_VP_EXIT_CONTEXT
	mmio: WHV_MEMORY_ACCESS_CONTEXT
	if !legacy_aperture_execution_test_prepare_counted_store(
		t,
		&vm,
		&probe,
		&vp,
		&mmio,
		2,
		WHPX_IO_STRING_BUDGET,
		0x203,
		64 * 1024 * 1024 - 16,
	) {return}
	defer destroy(&vm)

	action, detail := legacy_aperture_execution_step(&vm, &vp, &mmio)
	testing.expect_value(t, action, Legacy_Aperture_Execution_Action.Forward)
	testing.expect_value(t, detail, "")
	testing.expect_value(t, probe.call_count, 0)
	regs := get_regs(&vm)
	testing.expect_value(t, regs.rcx, u64(2))
	testing.expect_value(t, regs.rip, u64(0x7000))
}

@(test)
legacy_aperture_execution_test_counted_store_dec_flags_match_x86 :: proc(t: ^testing.T) {
	test_cases := [?]struct {
		flags:     u64,
		before:    u32,
		result:    u32,
		add_carry: bool,
		expected:  u64,
	} {
		{0x203, 1, 0, false, 0x246},
		{0x202, 0, 0xFFFF_FFFF, true, 0x297},
		{0x203, 0x8000_0000, 0x7FFF_FFFF, false, 0xA16},
		{0x203, 2, 1, false, 0x202},
	}
	for test_case in test_cases {
		testing.expect_value(
			t,
			legacy_aperture_dec32_flags(
				test_case.flags,
				test_case.before,
				test_case.result,
				test_case.add_carry,
			),
			test_case.expected,
		)
	}
}
