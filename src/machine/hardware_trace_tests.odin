// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:strings"
import "core:testing"

@(test)
hardware_trace_test_is_disabled_by_default_and_wraps :: proc(t: ^testing.T) {
	trace: Hardware_Trace
	hardware_trace_record(&trace, 1, .Progress, 0x43, 0x36)
	testing.expect_value(t, trace.retained_count, u64(0))
	hardware_trace_enable(&trace, true)
	for index in 0 ..< HARDWARE_TRACE_CAPACITY + 3 {
		hardware_trace_record(&trace, u64(index), .Progress, u64(index))
	}
	testing.expect_value(t, trace.retained_count, u64(HARDWARE_TRACE_CAPACITY + 3))
	text := hardware_trace_text(&trace)
	defer delete(text)
	lines := 0
	for byte in transmute([]u8)text {
		if byte == '\n' {lines += 1}
	}
	testing.expect_value(t, lines, HARDWARE_TRACE_CAPACITY)
	testing.expect(t, len(text) <= HARDWARE_TRACE_TEXT_MAX_BYTES)
	testing.expect(t, strings.contains(text, "00000003"))
	testing.expect(t, strings.contains(text, "progress"))
	testing.expect(t, !strings.contains(text, "00000002 tick="))
}

@(test)
hardware_trace_test_noisy_kinds_are_sampled_independently :: proc(t: ^testing.T) {
	trace: Hardware_Trace
	hardware_trace_enable(&trace, true)
	noisy := [?]Hardware_Event_Kind {
		.Wake_Arm,
		.Wake_Fire,
		.Wake_Disarm,
		.Hv_Exit,
		.Pit_Access,
		.Mmio_Access,
		.Vga_Access,
		.Ide_Access,
	}
	for kind in noisy {
		for index in 0 ..< HARDWARE_TRACE_NOISY_WINDOW {
			hardware_trace_record(&trace, u64(index), kind, u64(hv.Exit_Kind.Canceled))
		}
	}
	stats := hardware_trace_stats(&trace)
	expected_observed := u64(len(noisy) * HARDWARE_TRACE_NOISY_WINDOW)
	expected_per_kind := HARDWARE_TRACE_NOISY_INITIAL_RETAIN
	expected_retained := u64(len(noisy) * expected_per_kind)
	testing.expect_value(t, stats.observed, expected_observed)
	testing.expect_value(t, stats.retained, expected_retained)
	testing.expect_value(t, stats.suppressed, expected_observed - expected_retained)
}

@(test)
hardware_trace_test_post_reset_churn_preserves_reset_and_device_evidence :: proc(t: ^testing.T) {
	trace: Hardware_Trace
	hardware_trace_enable(&trace, true)
	hardware_trace_record(&trace, 1, .Reset_Request, 0xCF9, 0x06)
	hardware_trace_record(&trace, 2, .Pci_Config, 0xCF8, 4, 0x8000_3800)
	hardware_trace_record(&trace, 3, .Ide_Access, 0x1F7, 1, 0x20)

	// The failed install produced about 3,570 noisy events per second. This
	// models slightly more than the roughly 30 seconds after its first reset.
	POST_RESET_NOISY_PER_KIND :: 27_000
	for index in 0 ..< POST_RESET_NOISY_PER_KIND {
		tick := u64(index + 4)
		hardware_trace_record(&trace, tick, .Wake_Arm, 2, u64(index), tick)
		hardware_trace_record(&trace, tick, .Wake_Fire, u64(index), u64(index), tick)
		hardware_trace_record(&trace, tick, .Wake_Disarm, 2, u64(index))
		hardware_trace_record(&trace, tick, .Hv_Exit, u64(hv.Exit_Kind.Canceled), u64(index))
		hardware_trace_record(&trace, tick, .Pit_Access, 0x43, 1, 0)
		hardware_trace_record(&trace, tick, .Mmio_Access, u64(index), 4, 0)
		hardware_trace_record(&trace, tick, .Vga_Access, 0x3DA, 1, 0)
		hardware_trace_record(&trace, tick, .Ide_Access, 0x1F7, 1, 0x40)
	}

	stats := hardware_trace_stats(&trace)
	full_windows := POST_RESET_NOISY_PER_KIND / HARDWARE_TRACE_NOISY_WINDOW
	remainder := POST_RESET_NOISY_PER_KIND % HARDWARE_TRACE_NOISY_WINDOW
	retained_per_kind := HARDWARE_TRACE_NOISY_INITIAL_RETAIN
	if full_windows > 0 {
		retained_per_kind +=
			(full_windows - 1) * HARDWARE_TRACE_NOISY_RETAIN +
			min(remainder, HARDWARE_TRACE_NOISY_RETAIN)
	}
	expected_observed := u64(3 + POST_RESET_NOISY_PER_KIND * HARDWARE_TRACE_NOISY_KINDS)
	expected_retained := u64(2 + retained_per_kind * HARDWARE_TRACE_NOISY_KINDS)
	testing.expect_value(t, stats.observed, expected_observed)
	testing.expect_value(t, stats.retained, expected_retained)
	testing.expect(t, stats.retained < HARDWARE_TRACE_CAPACITY)
	testing.expect_value(t, stats.observed, stats.retained + stats.suppressed)
	text := hardware_trace_text(&trace)
	defer delete(text)
	testing.expect(t, strings.contains(text, "reset"))
	testing.expect(t, strings.contains(text, "pci-config"))
	testing.expect(t, strings.contains(text, "ide"))
	testing.expect(t, len(text) <= HARDWARE_TRACE_TEXT_MAX_BYTES)
}

@(test)
hardware_trace_test_exceptional_hv_exits_bypass_sampling :: proc(t: ^testing.T) {
	trace: Hardware_Trace
	hardware_trace_enable(&trace, true)
	for index in 0 ..< HARDWARE_TRACE_NOISY_INITIAL_RETAIN + 1 {
		hardware_trace_record(&trace, u64(index), .Hv_Exit, u64(hv.Exit_Kind.Canceled), u64(index))
	}
	hardware_trace_record(&trace, 20, .Hv_Exit, u64(hv.Exit_Kind.Reset), 20)
	hardware_trace_record(&trace, 21, .Hv_Exit, u64(hv.Exit_Kind.Failed), 21)
	stats := hardware_trace_stats(&trace)
	testing.expect_value(t, stats.observed, u64(HARDWARE_TRACE_NOISY_INITIAL_RETAIN + 3))
	testing.expect_value(t, stats.retained, u64(HARDWARE_TRACE_NOISY_INITIAL_RETAIN + 2))
	testing.expect_value(t, stats.suppressed, u64(1))
	reset := trace.events[HARDWARE_TRACE_NOISY_INITIAL_RETAIN]
	failed := trace.events[HARDWARE_TRACE_NOISY_INITIAL_RETAIN + 1]
	testing.expect_value(t, reset.a, u64(hv.Exit_Kind.Reset))
	testing.expect_value(t, failed.a, u64(hv.Exit_Kind.Failed))
}

@(test)
hardware_trace_test_classifies_transition_ports_without_data_flooding :: proc(t: ^testing.T) {
	testing.expect_value(t, hardware_trace_io_kind(0x43, true), Hardware_Event_Kind.Pit_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x43, true, nil, 0x36), Hardware_Event_Kind.Pit_Program)
	testing.expect_value(t, hardware_trace_io_kind(0x43, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x40, false), Hardware_Event_Kind.Pit_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x42, false), Hardware_Event_Kind.Pit_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x40, true), Hardware_Event_Kind.Pit_Program)
	testing.expect_value(t, hardware_trace_io_kind(0x61, true), Hardware_Event_Kind.Pit_Program)
	testing.expect_value(t, hardware_trace_io_kind(0xCF9, true), Hardware_Event_Kind.Reset_Request)
	testing.expect_value(t, hardware_trace_io_kind(0xCF9, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0xCF8, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x1F7, true), Hardware_Event_Kind.Ide_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x1F7, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x1F6, true), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x1F0, true), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x3F5, false), Hardware_Event_Kind.Fdc_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x279, true), Hardware_Event_Kind.Isa_Pnp_Access)
	testing.expect_value(t, hardware_trace_io_kind(0xA79, true), Hardware_Event_Kind.Isa_Pnp_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x279, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x20B, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x20B, true), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x20C, false), Hardware_Event_Kind.None)
	pnp: Isa_Pnp
	isa_pnp_init(&pnp)
	isa_pnp_test_enter_configuration(&pnp)
	_ = isa_pnp_out(&pnp, ISA_PNP_ADDRESS_PORT, ISA_PNP_SET_READ_DATA)
	_ = isa_pnp_out(&pnp, ISA_PNP_WRITE_DATA_PORT, 0x82)
	testing.expect_value(
		t,
		hardware_trace_io_kind(0x20B, false, &pnp),
		Hardware_Event_Kind.Isa_Pnp_Access,
	)
	testing.expect_value(t, hardware_trace_io_kind(0x203, false, &pnp), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x3FF, false, &pnp), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x80, true), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x81, true), Hardware_Event_Kind.Dma_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x64, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x60, false), Hardware_Event_Kind.I8042_Access)
	testing.expect_value(t, hardware_trace_io_kind(0x3C0, false), Hardware_Event_Kind.None)
	testing.expect_value(t, hardware_trace_io_kind(0x3DA, false), Hardware_Event_Kind.Vga_Access)
}

@(test)
hardware_trace_test_records_only_interrupt_acknowledging_ide_status_reads :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	if !testing.expect(t, machine_set_hardware_trace(m, true)) {return}
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3940)
	pci_out(&m.pci, 0xCFC, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE))
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3904)
	pci_out(&m.pci, 0xCFC, 2, 0x0001)
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	machine_attach_disk(m, machine_test_bd(&backing))
	if !testing.expect(t, !m.bus.frozen) {return}

	m.ide.irq_pending = true
	m.ide.irq_signaled = true
	m.ide.reg_status = 0x40
	value, ok := m.vm.io_read(m.vm.io_ctx, 0x01F7, 1)
	testing.expect(t, ok)
	testing.expect_value(t, value, u32(0x40))
	testing.expect(t, !m.ide.irq_pending)
	_, _ = m.vm.io_read(m.vm.io_ctx, 0x01F7, 1)

	ide_events := 0
	for sequence in 0 ..< m.hardware_trace.retained_count {
		event := m.hardware_trace.events[sequence % HARDWARE_TRACE_CAPACITY]
		if event.kind == .Ide_Access {ide_events += 1}
	}
	testing.expect_value(t, ide_events, 1)
}

@(test)
hardware_trace_test_does_not_enable_diagnostic_string_io_path :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	testing.expect(t, machine_set_hardware_trace(m, true))
	testing.expect(t, m.hardware_trace != nil && m.hardware_trace.enabled)
	testing.expect(t, !m.diagnostic_tracing)
	testing.expect(t, !m.bus.diagnostic_tracing)
	trace := machine_hardware_trace_detach(m)
	if trace != nil {free(trace)}
}

@(test)
hardware_trace_test_bus_diagnostics_preserve_string_io_acceleration :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	machine_set_bus_diagnostic_tracing(m, true)
	testing.expect(t, m.bus.diagnostic_tracing)
	testing.expect(t, !m.diagnostic_tracing)
	machine_set_bus_diagnostic_tracing(m, false)
	testing.expect(t, !m.bus.diagnostic_tracing)
}

@(test)
hardware_trace_test_bus_only_diagnostics_record_bounded_ide_histories :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)

	// Enable the AMD-756 primary compatibility channel without enabling the
	// full scalar-I/O trace, which is what disables the accelerated REP path.
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3940)
	pci_out(&m.pci, 0xCFC, 1, u32(AMD756_IDE_PRIMARY_CHANNEL_ENABLE))
	pci_out(&m.pci, 0xCF8, 4, 0x8000_3904)
	pci_out(&m.pci, 0xCFC, 2, 0x0001)
	backing := make([]u8, 1024 * 1024)
	defer delete(backing)
	machine_attach_disk(m, machine_test_bd(&backing))
	machine_set_bus_diagnostic_tracing(m, true)
	testing.expect(t, m.bus.diagnostic_tracing)
	testing.expect(t, !m.diagnostic_tracing)

	stream_data := []u8{0x11, 0x22, 0x33, 0x44}
	completed, handled, ok := m.vm.io_stream_write(m.vm.io_ctx, 0x1F0, 2, stream_data)
	testing.expect_value(t, completed, 2)
	testing.expect(t, handled)
	testing.expect(t, ok)

	scalar_count := IDE_HISTORY + 5
	for index in 0 ..< scalar_count {
		if !testing.expect(t, m.vm.io_write(m.vm.io_ctx, 0x1F2, 1, u32(u8(index)))) {
			return
		}
	}
	testing.expect_value(t, m.ide_count, u64(scalar_count))
	oldest_scalar_sequence := scalar_count - IDE_HISTORY
	oldest_scalar := m.ide_hist[oldest_scalar_sequence % IDE_HISTORY]
	latest_scalar := m.ide_hist[(scalar_count - 1) % IDE_HISTORY]
	testing.expect_value(t, oldest_scalar.port, u16(0x1F2))
	testing.expect_value(t, oldest_scalar.val, u32(u8(oldest_scalar_sequence)))
	testing.expect_value(t, latest_scalar.port, u16(0x1F2))
	testing.expect_value(t, latest_scalar.val, u32(u8(scalar_count - 1)))

	m.ide.reg_drive = 0xE2
	m.ide.reg_seccount = 7
	m.ide.reg_lba_lo = 0x34
	m.ide.reg_lba_mid = 0x12
	m.ide.reg_lba_hi = 0x56
	command_count := IDE_HISTORY + 3
	for index in 0 ..< command_count {
		command := u32(0xF0 | index & 0x0F)
		if !testing.expect(t, m.vm.io_write(m.vm.io_ctx, 0x1F7, 1, command)) {return}
	}
	testing.expect_value(t, m.cmd_count, u64(command_count))
	oldest_command_sequence := command_count - IDE_HISTORY
	oldest_command := m.cmd_hist[oldest_command_sequence % IDE_HISTORY]
	latest_command := m.cmd_hist[(command_count - 1) % IDE_HISTORY]
	testing.expect_value(t, oldest_command.cmd, u8(0xF0 | oldest_command_sequence & 0x0F))
	testing.expect_value(t, latest_command.cmd, u8(0xF0 | (command_count - 1) & 0x0F))
	testing.expect_value(t, latest_command.drive, u8(0xE2))
	testing.expect_value(t, latest_command.count, u8(7))
	testing.expect_value(t, latest_command.lba, u32(0x0256_1234))

	// Bus-only evidence retains its two fixed-size rings and leaves the broad
	// scalar history untouched, even after each IDE ring has wrapped.
	testing.expect_value(t, len(m.ide_hist), IDE_HISTORY)
	testing.expect_value(t, len(m.cmd_hist), IDE_HISTORY)
	for entry in m.io_hist {
		testing.expect_value(t, entry, Io_Trace{})
	}
	testing.expect(t, m.bus.diagnostic_tracing)
	testing.expect(t, !m.diagnostic_tracing)
}

@(test)
hardware_trace_test_detach_attach_preserves_reset_history :: proc(t: ^testing.T) {
	before := new(Machine)
	after := new(Machine)
	defer free(before)
	defer free(after)
	if !testing.expect(t, machine_set_hardware_trace(before, true)) {return}
	hardware_trace_record(before.hardware_trace, 11, .Reset_Request, 0xCF9, 0x06)
	trace := machine_hardware_trace_detach(before)
	if !testing.expect(t, trace != nil) {return}
	owned := true
	defer if owned {free(trace)}
	testing.expect(t, machine_hardware_trace_attach(after, trace))
	owned = false
	testing.expect_value(t, machine_hardware_trace_count(after), u64(1))
	testing.expect(t, after.hardware_trace.enabled)
	testing.expect(t, !machine_hardware_trace_attach(after, trace))
	trace = machine_hardware_trace_detach(after)
	if trace != nil {free(trace)}
}

@(test)
hardware_trace_test_canceled_exit_is_not_inferred_to_be_a_wake_callback :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	machine_trace_hv_exit(m, .Canceled, 41)
	if !testing.expect_value(t, machine_hardware_trace_count(m), u64(1)) {return}
	event := m.hardware_trace.events[0]
	testing.expect_value(t, event.kind, Hardware_Event_Kind.Hv_Exit)
	testing.expect_value(t, event.a, u64(hv.Exit_Kind.Canceled))
	testing.expect_value(t, event.b, u64(41))
}
