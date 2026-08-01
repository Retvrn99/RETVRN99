// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "fat32session"
import "hv"
import "machine"
import "profile"
import "vga"

@(test)
console_acceptance_test_reset_history_owns_bounded_reasons :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	result := acceptance.Result {
		boot_epoch = 1,
	}
	reason := strings.clone("guest reset")
	console_result_record_reset_request(&result, reason)
	bytes := transmute([]u8)reason
	bytes[0] = 'X'
	testing.expect_value(t, result.reset_history[0], "guest reset")
	for _ in 0 ..< acceptance.RESULT_MAX_RESETS + 4 {
		console_result_record_reset_request(&result, "more")
	}
	testing.expect_value(t, result.reset_count, u64(0))
	testing.expect_value(t, result.guest_requested_resets, u64(acceptance.RESULT_MAX_RESETS + 5))
	testing.expect_value(t, result.boot_epoch, u64(1))
	testing.expect_value(t, result.reset_history_count, acceptance.RESULT_MAX_RESETS)
	console_result_record_reset_success(&result)
	testing.expect_value(t, result.reset_count, u64(1))
	testing.expect_value(t, result.boot_epoch, u64(2))
	delete(reason)
	console_result_destroy(&result)
}

@(test)
console_acceptance_test_success_requires_one_boot_epoch_per_guest_reset :: proc(t: ^testing.T) {
	options := acceptance.Options {
		accept_until = .Desktop,
	}
	result := acceptance.Result {
		stop_reason                          = .Acceptance_Reached,
		exit_code                            = 0,
		reset_count                          = 1,
		boot_epoch                           = 2,
		guest_requested_resets               = 1,
		desktop_marker_seen                  = true,
		desktop_enum_valid                   = true,
		desktop_vga_irq11_seen               = true,
		desktop_primary_ide_dma_transactions = 1,
		desktop_primary_ide_dma_bytes        = 512,
	}
	result.execution.primary_ide_dma_transactions = 1
	result.execution.primary_ide_dma_bytes = 512
	return_code := 0
	console_acceptance_enforce_result_invariants(&options, &result, &return_code)
	testing.expect_value(t, result.stop_reason, acceptance.Stop_Reason.Acceptance_Reached)
	testing.expect_value(t, return_code, 0)

	desktop_lost := result
	desktop_lost.desktop_marker_seen = false
	desktop_lost_return_code := 0
	console_acceptance_enforce_result_invariants(
		&options,
		&desktop_lost,
		&desktop_lost_return_code,
	)
	testing.expect_value(
		t,
		desktop_lost.stop_reason,
		acceptance.Stop_Reason.Fatal_Virtualization_Failure,
	)
	testing.expect_value(t, desktop_lost.last_progress_reason, "desktop_evidence_lost")
	testing.expect_value(t, desktop_lost_return_code, 2)

	firmware_only := result
	firmware_only.desktop_primary_ide_dma_transactions = 0
	firmware_only.desktop_primary_ide_dma_bytes = 0
	firmware_only_return_code := 0
	console_acceptance_enforce_result_invariants(
		&options,
		&firmware_only,
		&firmware_only_return_code,
	)
	testing.expect_value(
		t,
		firmware_only.stop_reason,
		acceptance.Stop_Reason.Fatal_Virtualization_Failure,
	)
	testing.expect_value(t, firmware_only.last_progress_reason, "desktop_evidence_lost")
	testing.expect_value(t, firmware_only_return_code, 2)

	result.guest_requested_resets = 2
	console_acceptance_enforce_result_invariants(&options, &result, &return_code)
	testing.expect_value(
		t,
		result.stop_reason,
		acceptance.Stop_Reason.Fatal_Virtualization_Failure,
	)
	testing.expect_value(t, result.last_progress_reason, "reset_epoch_mismatch")
	testing.expect_value(t, result.exit_code, 2)
	testing.expect_value(t, return_code, 2)
}

@(test)
console_acceptance_test_failed_reset_does_not_accumulate_live_segment_twice :: proc(
	t: ^testing.T,
) {
	result: acceptance.Result
	m := new(machine.Machine)
	defer free(m)
	m.inj_count[8] = 3
	m.platform.bus.modeled_count = 7
	m.platform.bus.unclassified_count = 2
	segment_accumulated := false
	testing.expect(t, console_result_accumulate_machine_segment(&result, m, &segment_accumulated))
	testing.expect(t, segment_accumulated)
	testing.expect(t, !console_result_accumulate_machine_segment(&result, m, &segment_accumulated))
	testing.expect_value(t, result.irq_injections, u64(3))
	testing.expect_value(t, result.modeled_io, u64(7))
	testing.expect_value(t, result.unclassified_io, u64(2))

	segment_accumulated = false
	m^ = {}
	m.inj_count[8] = 5
	testing.expect(t, console_result_accumulate_machine_segment(&result, m, &segment_accumulated))
	testing.expect_value(t, result.irq_injections, u64(8))
}

@(test)
console_acceptance_test_successful_boot_epoch_restarts_desktop_stability :: proc(t: ^testing.T) {
	now := time.tick_now()
	pixels := []u32{0xFF010203}
	frame := vga.Display_Frame {
		kind   = .Xrgb_8888,
		pixels = pixels,
		width  = 1,
		height = 1,
	}
	state: Console_Desktop_Graphics_Stability
	testing.expect(t, console_desktop_graphics_observe(&state, &frame, now))
	testing.expect(
		t,
		console_desktop_graphics_stable(&state, time.tick_add(now, DESKTOP_GRAPHICS_STABLE_TIME)),
	)
	result := acceptance.Result {
		boot_epoch = 1,
	}
	console_result_record_reset_success(&result, &state)
	testing.expect_value(t, result.boot_epoch, u64(2))
	testing.expect(t, !state.active)
	new_epoch := time.tick_add(now, DESKTOP_GRAPHICS_STABLE_TIME + time.Second)
	testing.expect(t, console_desktop_graphics_observe(&state, &frame, new_epoch))
	testing.expect(
		t,
		!console_desktop_graphics_stable(
			&state,
			time.tick_add(new_epoch, DESKTOP_GRAPHICS_STABLE_TIME - time.Nanosecond),
		),
	)
}

@(test)
console_acceptance_test_evidence_polls_have_independent_deadlines :: proc(t: ^testing.T) {
	now := time.tick_now()
	detection := time.tick_add(now, -2 * time.Second)
	desktop := detection
	testing.expect(t, console_evidence_poll_due(&detection, now))
	testing.expect(t, console_evidence_poll_due(&desktop, now))
	testing.expect(t, !console_evidence_poll_due(&detection, now))
	testing.expect(t, !console_evidence_poll_due(&desktop, now))
}

@(test)
console_acceptance_test_setup_artifact_poll_is_shared_and_throttled :: proc(t: ^testing.T) {
	start := time.tick_now()
	last := start
	armed_reset_count: u32
	for second in 1 ..= 60 {
		testing.expect(
			t,
			!console_setup_artifact_poll_due(
				0,
				true,
				false,
				&armed_reset_count,
				&last,
				time.tick_add(start, time.Duration(second) * time.Second),
			),
		)
	}
	testing.expect_value(t, last, start)
	desktop_last := start
	desktop_armed_reset_count: u32
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			0,
			false,
			true,
			&desktop_armed_reset_count,
			&desktop_last,
			time.tick_add(start, CONSOLE_SETUP_ARTIFACT_PERIOD - time.Nanosecond),
		),
	)
	desktop_period := time.tick_add(start, CONSOLE_SETUP_ARTIFACT_PERIOD)
	testing.expect(
		t,
		console_setup_artifact_poll_due(
			0,
			false,
			true,
			&desktop_armed_reset_count,
			&desktop_last,
			desktop_period,
		),
	)
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			0,
			false,
			true,
			&desktop_armed_reset_count,
			&desktop_last,
			desktop_period,
		),
	)
	testing.expect(
		t,
		console_setup_artifact_poll_due(
			0,
			false,
			true,
			&desktop_armed_reset_count,
			&desktop_last,
			time.tick_add(desktop_period, CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
	first_phase_two := time.tick_add(start, 60 * time.Second)
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			1,
			true,
			false,
			&armed_reset_count,
			&last,
			first_phase_two,
		),
	)
	testing.expect_value(t, last, first_phase_two)
	testing.expect_value(t, armed_reset_count, u32(1))
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			1,
			true,
			false,
			&armed_reset_count,
			&last,
			time.tick_add(first_phase_two, CONSOLE_SETUP_ARTIFACT_PERIOD - time.Nanosecond),
		),
	)
	testing.expect(
		t,
		console_setup_artifact_poll_due(
			1,
			true,
			true,
			&armed_reset_count,
			&last,
			time.tick_add(first_phase_two, CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
	// Both observers share one cadence, so the second branch cannot flush again.
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			1,
			true,
			true,
			&armed_reset_count,
			&last,
			time.tick_add(first_phase_two, CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
	testing.expect(
		t,
		console_setup_artifact_poll_due(
			1,
			false,
			true,
			&armed_reset_count,
			&last,
			time.tick_add(first_phase_two, 2 * CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			1,
			false,
			false,
			&armed_reset_count,
			&last,
			time.tick_add(first_phase_two, 3 * CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
	second_reset := time.tick_add(first_phase_two, 3 * CONSOLE_SETUP_ARTIFACT_PERIOD)
	testing.expect(
		t,
		!console_setup_artifact_poll_due(2, true, true, &armed_reset_count, &last, second_reset),
	)
	testing.expect_value(t, last, second_reset)
	testing.expect_value(t, armed_reset_count, u32(2))
	testing.expect(
		t,
		!console_setup_artifact_poll_due(
			2,
			true,
			true,
			&armed_reset_count,
			&last,
			time.tick_add(second_reset, CONSOLE_SETUP_ARTIFACT_PERIOD - time.Nanosecond),
		),
	)
	testing.expect(
		t,
		console_setup_artifact_poll_due(
			2,
			true,
			true,
			&armed_reset_count,
			&last,
			time.tick_add(second_reset, CONSOLE_SETUP_ARTIFACT_PERIOD),
		),
	)
}

@(test)
console_acceptance_test_artifact_setup_logs_are_bounded_and_path_free :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_console_artifact_*", context.temp_allocator)
	defer os.remove_all(dir)
	payload := make([]u8, CONSOLE_ARTIFACT_LOG_BYTES + 4096, context.temp_allocator)
	for &byte in payload {byte = 'x'}
	image_path := test_image_create(t, dir, "artifact.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"WINDOWS"},
		[]Test_Image_File {
			{path = "WINDOWS/SETUPLOG.TXT", data = string(payload)},
			{path = "IO.SYS", data = "boot"},
		},
	) {return}
	session, session_error := fat32session.open_in_process(image_path, "artifact-test")
	if !testing.expect(t, session_error.code == .None && session != nil) {return}
	defer if session != nil {_ = fat32session.close(session, .Commit)}
	result := acceptance.Result {
		stop_reason            = .Strict_IO_Failure,
		exit_code              = 2,
		unclassified_io        = 3,
		unclassified_mmio      = 4,
		last_progress_reason   = "hardware_detection",
		boot_epoch             = 2,
		guest_requested_resets = 1,
	}
	result.wake_guard = {
		generations      = 7,
		callbacks        = 6,
		retry_callbacks  = 2,
		cancel_calls     = 5,
		stale_callbacks  = 1,
		evidence_dropped = 3,
	}
	diagnostics := console_artifact_diagnostics(&result, nil, "firmware-tail", session)
	defer delete(diagnostics)
	testing.expect(t, strings.contains(diagnostics, "unclassified=3 mmio=4"))
	testing.expect(t, strings.contains(diagnostics, "setup-log C:\\WINDOWS\\SETUPLOG.TXT"))
	testing.expect(t, strings.contains(diagnostics, "last 32768 of 36864 bytes"))
	testing.expect(t, strings.contains(diagnostics, "firmware-tail"))
	testing.expect(
		t,
		strings.contains(diagnostics, "progress=hardware_detection boot_epoch=2 guest_resets=1"),
	)
	testing.expect(
		t,
		strings.contains(
			diagnostics,
			"wake_guard generations=7 callbacks=6 retries=2 cancels=5 stale=1 dropped=3",
		),
	)
	testing.expect(t, !strings.contains(diagnostics, dir))
	testing.expect(t, len(diagnostics) < CONSOLE_ARTIFACT_LOG_BYTES + 2048)
}

@(test)
console_acceptance_test_uart_artifact_is_bounded_and_readable :: proc(t: ^testing.T) {
	uart: machine.Uart_16450
	machine.uart_init_com1(&uart)
	fixture := [?]u8{'A', '\r', '\n', '\t', '\\', 0, 0xff}
	for byte in fixture {
		_ = machine.uart_out(&uart, machine.UART_COM1_BASE, byte)
		machine.uart_advance(&uart, machine.uart_ticks_until_idle(&uart))
	}
	builder := strings.builder_make()
	console_artifact_append_uart(&builder, "COM1", &uart)
	diagnostics := strings.to_string(builder)
	defer delete(diagnostics)
	testing.expect(t, strings.contains(diagnostics, "COM1 serial captured=7 dropped=0:"))
	testing.expect(t, strings.contains(diagnostics, "A\\r\n\\t\\\\\\x00\\xff"))
}

@(test)
console_acceptance_test_configuration_failure_writes_requested_outputs :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_console_config_*", context.temp_allocator)
	defer os.remove_all(dir)
	result_path, _ := filepath.join({dir, "result.json"}, context.temp_allocator)
	artifacts, _ := filepath.join({dir, "artifacts"}, context.temp_allocator)
	options := acceptance.Options {
		result_json = result_path,
		artifacts   = artifacts,
	}
	testing.expect_value(
		t,
		console_acceptance_configuration_error(&options, nil, .GSW_886, "isolated failure"),
		1,
	)
	result_data, result_error := os.read_entire_file(result_path, context.temp_allocator)
	testing.expect(t, result_error == nil)
	testing.expect(
		t,
		strings.contains(string(result_data), `"stop_reason": "configuration_error"`),
	)
	diagnostics_path, _ := filepath.join({artifacts, "diagnostics.txt"}, context.temp_allocator)
	diagnostics, diagnostics_error := os.read_entire_file(diagnostics_path, context.temp_allocator)
	testing.expect(t, diagnostics_error == nil)
	testing.expect(t, strings.contains(string(diagnostics), "configuration=isolated failure"))
}

@(test)
console_acceptance_test_periodic_frame_change_is_not_guest_activity :: proc(t: ^testing.T) {
	previous: u64
	frame := vga.Display_Frame {
		content_generation        = 10,
		guest_activity_generation = 4,
	}
	testing.expect(t, !console_acceptance_observe_display_activity(&previous, &frame))
	testing.expect_value(t, previous, u64(4))
	frame.content_generation += 1
	testing.expect(t, !console_acceptance_observe_display_activity(&previous, &frame))
	frame.guest_activity_generation += 1
	testing.expect(t, console_acceptance_observe_display_activity(&previous, &frame))
}

@(test)
console_acceptance_test_hardware_diagnostics_always_requests_artifacts :: proc(t: ^testing.T) {
	result := acceptance.Result {
		stop_reason = .Acceptance_Reached,
	}
	options := acceptance.Options {
		artifacts         = "artifacts",
		setup_diagnostics = .Hardware,
	}
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 0))
	options.setup_diagnostics = .None
	testing.expect(t, !console_acceptance_should_write_artifacts(&options, &result, 0))
	options.shutdown_trace = true
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 0))
	options.shutdown_trace = false
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 1))
	result.stop_reason = .Timeout
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 0))
	options.artifacts = ""
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 0))
	testing.expect_value(
		t,
		console_acceptance_artifact_directory(&options, &result),
		acceptance.DEFAULT_ARTIFACTS_DIRECTORY,
	)
	result.stop_reason = .Fatal_Virtualization_Failure
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 1))
	testing.expect_value(
		t,
		console_acceptance_artifact_directory(&options, &result),
		acceptance.DEFAULT_ARTIFACTS_DIRECTORY,
	)
	result.stop_reason = .No_Progress
	testing.expect(t, console_acceptance_should_write_artifacts(&options, &result, 1))
}

@(test)
console_acceptance_test_shutdown_trace_text_is_marker_armed_tsv :: proc(t: ^testing.T) {
	m := new(machine.Machine)
	defer free(m)
	hv.shutdown_trace_set_enabled(&m.vm, true)
	defer hv.shutdown_trace_set_enabled(&m.vm, false)
	hv.shutdown_trace_record(&m.vm, {kind = .Mmio, address = 0xA0000})
	hv.shutdown_trace_note_marker(&m.vm, 0xD1)
	hv.shutdown_trace_note_marker(&m.vm, 0xD5)
	hv.shutdown_trace_record(
		&m.vm,
		{kind = .Irq_Deferred, value = 9, cs = 0x28, flags = 3, rip = 0x1234},
	)
	trace := console_shutdown_trace_text(m)
	defer delete(trace)
	testing.expect(
		t,
		strings.contains(
			trace,
			"recorded\tdropped_unarmed\tdropped_markers\toverwritten",
		),
	)
	testing.expect(
		t,
		strings.contains(
			trace,
			"true\ttrue\t65536\t3\t3\t1\t0\t0\nsequence\tkind\tvalue\tcs\tflags\trip\taddress\tdetail",
		),
	)
	testing.expect(t, strings.contains(trace, "1\tmarker\td1\t0000"))
	testing.expect(t, strings.contains(trace, "2\tmarker\td5\t0000"))
	testing.expect(t, strings.contains(trace, "3\tirq-deferred\t09\t0028\t00000003"))
	testing.expect(t, len(trace) <= acceptance.ARTIFACT_SHUTDOWN_TRACE_MAX_BYTES)
}

@(test)
console_acceptance_test_shutdown_trace_text_reports_marker_archive_overflow :: proc(t: ^testing.T) {
	m := new(machine.Machine)
	defer free(m)
	hv.shutdown_trace_set_enabled(&m.vm, true)
	defer hv.shutdown_trace_set_enabled(&m.vm, false)
	hv.shutdown_trace_note_marker(&m.vm, 0xD5)
	for index in 0 ..< hv.SHUTDOWN_TRACE_MARKER_CAPACITY + 1 {
		hv.shutdown_trace_note_marker(&m.vm, u8(0xE0 + index % 16))
	}

	trace := console_shutdown_trace_text(m)
	defer delete(trace)
	testing.expect(
		t,
		strings.contains(trace, "true\ttrue\t65536\t514\t514\t0\t2\t0\n"),
	)
}

@(test)
console_acceptance_test_progress_watchdog_uses_meaningful_guest_activity :: proc(t: ^testing.T) {
	start := time.tick_now()
	watchdog: Console_Progress_Watchdog
	base := Console_Progress_Snapshot {
		modeled_io = 10,
	}
	reason, timed_out := console_progress_watchdog_observe(&watchdog, base, start, 5 * time.Second)
	testing.expect_value(t, reason, "")
	testing.expect(t, !timed_out)

	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		base,
		time.tick_add(start, 5 * time.Second),
		5 * time.Second,
	)
	testing.expect_value(t, reason, "")
	testing.expect(t, timed_out)

	storage := base
	storage.ide_commands = 1
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		storage,
		time.tick_add(start, 6 * time.Second),
		5 * time.Second,
	)
	testing.expect_value(t, reason, "storage_io")
	testing.expect(t, !timed_out)
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		storage,
		time.tick_add(start, 10 * time.Second),
		5 * time.Second,
	)
	testing.expect(t, !timed_out)
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		storage,
		time.tick_add(start, 11 * time.Second),
		5 * time.Second,
	)
	testing.expect(t, timed_out)
}

@(test)
console_acceptance_test_progress_reason_ignores_periodic_and_polled_activity :: proc(
	t: ^testing.T,
) {
	base: Console_Progress_Snapshot
	current := base
	current.irq_injections = 1
	current.dma_units = 1
	current.modeled_io = 1
	current.ide_io = 1
	testing.expect_value(t, console_progress_reason(base, current), "")
	current = base
	current.display_activity_generation = 1
	testing.expect_value(t, console_progress_reason(base, current), "display_activity")
	current = base
	current.ide_commands = 1
	testing.expect_value(t, console_progress_reason(base, current), "storage_io")
	current = base
	current.boot_epoch = 2
	testing.expect_value(t, console_progress_reason(base, current), "guest_reset")
}

@(test)
console_acceptance_test_desktop_dma_wait_ignores_animated_display_until_timeout :: proc(
	t: ^testing.T,
) {
	start := time.tick_now()
	watchdog: Console_Progress_Watchdog
	snapshot := Console_Progress_Snapshot {
		display_activity_generation = 1,
	}
	reason, timed_out := console_progress_watchdog_observe(
		&watchdog,
		snapshot,
		start,
		5 * time.Second,
		false,
		true,
	)
	testing.expect_value(t, reason, "")
	testing.expect(t, !timed_out)

	snapshot.display_activity_generation = 2
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		snapshot,
		time.tick_add(start, 4 * time.Second),
		5 * time.Second,
		false,
		true,
	)
	testing.expect_value(t, reason, "")
	testing.expect(t, !timed_out)

	snapshot.display_activity_generation = 3
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		snapshot,
		time.tick_add(start, 5 * time.Second),
		5 * time.Second,
		false,
		true,
	)
	testing.expect_value(t, reason, DESKTOP_WAITING_PRIMARY_IDE_DMA_PROGRESS_REASON)
	testing.expect(t, timed_out)

	result := acceptance.Result {
		last_progress_reason = "display_activity",
	}
	if reason != "" {result.last_progress_reason = reason}
	testing.expect_value(
		t,
		result.last_progress_reason,
		DESKTOP_WAITING_PRIMARY_IDE_DMA_PROGRESS_REASON,
	)
}

@(test)
console_acceptance_test_periodic_irq_and_status_polling_do_not_reset_watchdog :: proc(
	t: ^testing.T,
) {
	start := time.tick_now()
	watchdog: Console_Progress_Watchdog
	base: Console_Progress_Snapshot
	_, timed_out := console_progress_watchdog_observe(&watchdog, base, start, 5 * time.Second)
	testing.expect(t, !timed_out)

	periodic := base
	periodic.irq_injections = 100
	periodic.dma_units = 10
	periodic.modeled_io = 1000
	periodic.ide_io = 500
	reason: string
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		periodic,
		time.tick_add(start, 4 * time.Second),
		5 * time.Second,
	)
	testing.expect_value(t, reason, "")
	testing.expect(t, !timed_out)

	periodic.irq_injections += 100
	periodic.dma_units += 10
	periodic.modeled_io += 1000
	periodic.ide_io += 500
	reason, timed_out = console_progress_watchdog_observe(
		&watchdog,
		periodic,
		time.tick_add(start, 5 * time.Second),
		5 * time.Second,
	)
	testing.expect_value(t, reason, "")
	testing.expect(t, timed_out)
}

@(test)
console_acceptance_test_static_desktop_irq_liveness_outlasts_stability_window :: proc(
	t: ^testing.T,
) {
	start := time.tick_now()
	watchdog: Console_Progress_Watchdog
	snapshot: Console_Progress_Snapshot
	_, timed_out := console_progress_watchdog_observe(
		&watchdog,
		snapshot,
		start,
		CONSOLE_NO_PROGRESS_TIMEOUT,
		true,
	)
	testing.expect(t, !timed_out)

	for elapsed := time.Second; elapsed <= DESKTOP_GRAPHICS_STABLE_TIME; elapsed += time.Second {
		snapshot.irq_injections += 1
		reason, desktop_timed_out := console_progress_watchdog_observe(
			&watchdog,
			snapshot,
			time.tick_add(start, elapsed),
			CONSOLE_NO_PROGRESS_TIMEOUT,
			true,
		)
		testing.expect_value(t, reason, "desktop_irq_liveness")
		if !testing.expect(t, !desktop_timed_out) {return}
	}

	frame := vga.Display_Frame {
		kind   = .Xrgb_8888,
		pixels = []u32{0xFF010203},
		width  = 1,
		height = 1,
	}
	graphics: Console_Desktop_Graphics_Stability
	testing.expect(t, console_desktop_graphics_observe(&graphics, &frame, start))
	testing.expect(
		t,
		console_desktop_graphics_stable(
			&graphics,
			time.tick_add(start, DESKTOP_GRAPHICS_STABLE_TIME),
		),
	)
}

@(test)
console_acceptance_test_reports_unavailable_legacy_histories_when_not_traced :: proc(
	t: ^testing.T,
) {
	m := new(machine.Machine)
	defer free(m)
	m.io_count = 8
	m.platform.bus.unclassified_count = 3
	m.platform.bus.unclassified_mmio_count = 2
	builder := strings.builder_make()
	console_artifact_append_legacy_histories(&builder, m)
	diagnostics := strings.to_string(builder)
	defer delete(diagnostics)
	testing.expect(t, strings.contains(diagnostics, "recent I/O: unavailable"))
	testing.expect(t, strings.contains(diagnostics, "recent unclassified I/O: unavailable"))
	testing.expect(t, !strings.contains(diagnostics, "recent I/O (8):"))
}

@(test)
console_acceptance_test_nonlive_machine_trace_is_written_and_released :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_orphan_trace_*", context.temp_allocator)
	defer os.remove_all(dir)
	artifacts, _ := filepath.join({dir, "artifacts"})
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	machine.machine_trace_record(m, .Reset_Request, 0xCF9, 0x06)
	live := false
	options := acceptance.Options {
		artifacts = artifacts,
	}
	result := acceptance.Result {
		stop_reason = .Fatal_Virtualization_Failure,
		exit_code   = 2,
	}
	firmware: Firmware_Log
	return_code := 2
	console_acceptance_finalize(
		&options,
		&result,
		m,
		&live,
		&firmware,
		nil,
		nil,
		time.tick_now(),
		&return_code,
	)
	trace_path, _ := filepath.join({artifacts, "hardware-trace.txt"})
	trace, trace_error := os.read_entire_file(trace_path, context.temp_allocator)
	testing.expect(t, trace_error == nil)
	testing.expect(t, strings.contains(string(trace), "reset"))
	testing.expect_value(t, result.hardware_trace_path, "hardware-trace.txt")
	testing.expect_value(t, machine.machine_hardware_trace_count(m), u64(0))
}

@(test)
console_acceptance_test_requested_artifact_failure_is_nonzero :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_artifact_failure_*", context.temp_allocator)
	defer os.remove_all(dir)
	artifacts, _ := filepath.join({dir, "artifacts"})
	trace_path, _ := filepath.join({artifacts, "hardware-trace.txt"})
	retained_path, _ := filepath.join({trace_path, "retained"})
	testing.expect(t, os.make_directory_all(trace_path) == nil)
	testing.expect(t, os.write_entire_file(retained_path, "retained") == nil)
	result_path, _ := filepath.join({dir, "result.json"})
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	machine.machine_trace_record(m, .Reset_Request, 0xCF9, 0x06)
	live := false
	options := acceptance.Options {
		artifacts         = artifacts,
		result_json       = result_path,
		setup_diagnostics = .Hardware,
	}
	result := acceptance.Result {
		stop_reason = .Acceptance_Reached,
		exit_code   = 0,
	}
	firmware: Firmware_Log
	return_code := 0
	console_acceptance_finalize(
		&options,
		&result,
		m,
		&live,
		&firmware,
		nil,
		nil,
		time.tick_now(),
		&return_code,
	)
	testing.expect_value(t, return_code, 2)
	testing.expect_value(t, result.exit_code, 2)
	testing.expect_value(t, result.stop_reason, acceptance.Stop_Reason.Configuration_Error)
	testing.expect_value(t, result.last_progress_reason, "artifact_write_failed")
	serialized, read_error := os.read_entire_file(result_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect(t, strings.contains(string(serialized), `"stop_reason": "configuration_error"`))
	testing.expect(t, strings.contains(string(serialized), `"exit_code": 2`))
}

console_acceptance_test_stopped_write :: proc(
	t: ^testing.T,
	session: ^^fat32session.Machine_Session,
	image_path: string,
	files: []Test_Image_File,
) -> bool {
	if session == nil || session^ == nil {return false}
	if close_error := fat32session.close(session^, .Commit); close_error.code != .None {
		return false
	}
	session^ = nil
	if !test_image_write_files(t, image_path, nil, files) {return false}
	reopened, open_error := fat32session.open_in_process(image_path, "desktop-marker-test")
	if open_error.code != .None || reopened == nil {return false}
	session^ = reopened
	return true
}

console_acceptance_test_stopped_write_one :: proc(
	t: ^testing.T,
	session: ^^fat32session.Machine_Session,
	image_path, guest_path, data: string,
) -> bool {
	return console_acceptance_test_stopped_write(
		t,
		session,
		image_path,
		[]Test_Image_File{{path = guest_path, data = data}},
	)
}

@(test)
console_acceptance_test_desktop_proof_requires_marker_and_nonblack_graphics :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_desktop_marker_*", context.temp_allocator)
	defer os.remove_all(dir)
	image_path := test_image_create(t, dir, "desktop.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"GSWSETUP"},
		[]Test_Image_File{{path = "IO.SYS", data = "boot"}},
	) {return}
	session, session_error := fat32session.open_in_process(image_path, "desktop-marker-test")
	if !testing.expect(t, session_error.code == .None && session != nil) {return}
	defer if session != nil {_ = fat32session.close(session, .Commit)}
	testing.expect(t, !console_desktop_marker_exists(session))
	testing.expect(
		t,
		console_acceptance_test_stopped_write(
			t,
			&session,
			image_path,
			[]Test_Image_File{{path = "GSWSETUP/DESKTOP.OK", data = "READY\r\n"}},
		),
	)
	marker_batch, marker_error := fat32session.observe(
		session,
		[]fat32session.Probe{{kind = .Read_Range, path = "GSWSETUP/DESKTOP.OK", length = 64}},
		context.temp_allocator,
	)
	if testing.expect_value(t, marker_error.code, fat32session.Error_Code.None) {
		defer fat32session.observation_batch_destroy(&marker_batch, context.temp_allocator)
		testing.expect_value(t, len(marker_batch.items), 1)
		if len(marker_batch.items) == 1 {
			testing.expect_value(t, marker_batch.items[0].type, fat32session.Observed_Type.Regular)
			testing.expect_value(t, string(marker_batch.items[0].data), "READY\r\n")
		}
	}
	_, marker_seen, enum_valid := console_desktop_marker_evidence(session)
	testing.expect(t, marker_seen)
	testing.expect(t, !enum_valid)
	result: acceptance.Result
	console_result_refresh_desktop_evidence(&result, session)
	testing.expect(t, result.desktop_marker_seen)
	testing.expect(t, !result.desktop_enum_valid)
	testing.expect(t, !result.desktop_vga_irq11_seen)
	testing.expect(t, !console_desktop_marker_exists(session))
	testing.expect(
		t,
		console_acceptance_test_stopped_write(
			t,
			&session,
			image_path,
			[]Test_Image_File{{path = "GSWSETUP/ENUM.REG", data = "REGEDIT4\r\n"}},
		),
	)
	testing.expect(t, !console_desktop_marker_exists(session))
	valid_enumeration :=
		"REGEDIT4\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_1022&DEV_7006&REV_25\\BUS_00&DEV_00&FUNC_00]\r\n" +
		"\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_1022&DEV_7408&REV_01\\BUS_00&DEV_07&FUNC_00]\r\n" +
		"\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_1022&DEV_7409&REV_07\\BUS_00&DEV_07&FUNC_01]\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\MF\\GOODPRIMARY\\PCI&VEN_1022&DEV_7409&REV_07&BUS_00&DEV_07&FUNC_01]\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\MF\\GOODSECONDARY\\PCI&VEN_1022&DEV_7409&REV_07&BUS_00&DEV_07&FUNC_01]\r\n\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_FFFE&DEV_0002&REV_01\\BUS_00&DEV_02&FUNC_00]\r\n" +
		"\r\n" +
		"[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_FFFE&DEV_0002&REV_01\\BUS_00&DEV_02&FUNC_00\\LogConfig]\r\n" +
		`"0000"=hex:00,04,00,00,00,30,00,00,10,00,00,00,04,00,00,00,03,00,0b,00,00,08,00,00,00,00,00,00` +
		"\r\n"
	valid_dynamic_enumeration :=
		"REGEDIT4\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000001]\r\n" +
		`"HardWareKey"="PCI\\VEN_1022&DEV_7006&REV_25\\BUS_00&DEV_00&FUNC_00"` +
		"\r\n" +
		`"Problem"=hex:00,00,00,00` +
		"\r\n" +
		`"Status"=hex:4a,00,00,00` +
		"\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000002]\r\n" +
		`"HardWareKey"="PCI\\VEN_1022&DEV_7408&REV_01\\BUS_00&DEV_07&FUNC_00"` +
		"\r\n" +
		`"Problem"=dword:00000000` +
		"\r\n" +
		`"Status"=dword:0000004a` +
		"\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000003]\r\n" +
		`"HardWareKey"="PCI\\VEN_1022&DEV_7409&REV_07\\BUS_00&DEV_07&FUNC_01"` +
		"\r\n" +
		`"Problem"=hex:00,00,00,00` +
		"\r\n" +
		`"Status"=hex:4a,00,00,00` +
		"\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000004]\r\n" +
		`"HardWareKey"="PCI\\VEN_FFFE&DEV_0002&REV_01\\BUS_00&DEV_02&FUNC_00"` +
		"\r\n" +
		`"Problem"=hex:00,00,00,00` +
		"\r\n" +
		`"Status"=hex:4a,00,00,00` +
		"\r\n" +
		`"Allocation"=hex:00,04,00,00,01,00,00,00,10,00,00,00,04,00,00,00,\` +
		"\r\n" +
		"  03,00,0b,00,00,08,00,00,00,00,00,00\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000005]\r\n" +
		`"HardWareKey"="MF\\GOODPRIMARY\\PCI&VEN_1022&DEV_7409&REV_07&BUS_00&DEV_07&FUNC_01"` +
		"\r\n" +
		`"Problem"=hex:00,00,00,00` +
		"\r\n" +
		`"Status"=hex:4a,00,02,00` +
		"\r\n\r\n" +
		"[HKEY_DYN_DATA\\Config Manager\\Enum\\C0000006]\r\n" +
		`"HardWareKey"="MF\\GOODSECONDARY\\PCI&VEN_1022&DEV_7409&REV_07&BUS_00&DEV_07&FUNC_01"` +
		"\r\n" +
		`"Problem"=hex:00,00,00,00` +
		"\r\n" +
		`"Status"=hex:4a,00,02,00` +
		"\r\n"
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/ENUM.REG",
			valid_enumeration,
		),
	)
	testing.expect(t, !console_desktop_marker_exists(session))
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/DYNENUM.REG",
			valid_dynamic_enumeration,
		),
	)
	testing.expect(t, console_desktop_marker_exists(session))
	testing.expect(t, console_windows98_enum_valid(valid_enumeration, valid_dynamic_enumeration))
	console_result_refresh_desktop_evidence(&result, session)
	testing.expect(t, result.desktop_marker_seen)
	testing.expect(t, result.desktop_enum_valid)
	testing.expect(t, result.desktop_vga_irq11_seen)
	no_dynamic_irq, no_dynamic_irq_allocated := strings.replace_all(
		valid_dynamic_enumeration,
		"10,00,00,00,04,00,00,00,\\",
		"10,00,00,00,01,00,00,00,\\",
	)
	testing.expect(t, no_dynamic_irq_allocated)
	testing.expect(t, !console_windows98_enum_valid(valid_enumeration, no_dynamic_irq))
	if no_dynamic_irq_allocated {delete(no_dynamic_irq)}
	missing_allocation, missing_allocation_allocated := strings.replace_all(
		valid_dynamic_enumeration,
		`"Allocation"=hex:00,04,00,00,01,00,00,00,10,00,00,00,04,00,00,00,\` +
		"\r\n" +
		"  03,00,0b,00,00,08,00,00,00,00,00,00\r\n",
		"",
	)
	testing.expect(t, missing_allocation_allocated)
	testing.expect(t, !console_windows98_enum_valid(valid_enumeration, missing_allocation))
	if missing_allocation_allocated {delete(missing_allocation)}
	bad_wrapper, bad_wrapper_allocated := strings.replace_all(
		valid_dynamic_enumeration,
		`"Allocation"=hex:00,04,00,00`,
		`"Allocation"=hex:01,04,00,00`,
	)
	testing.expect(t, !console_windows98_enum_valid(valid_enumeration, bad_wrapper))
	if bad_wrapper_allocated {delete(bad_wrapper)}
	bad_irq, bad_irq_allocated := strings.replace_all(
		valid_dynamic_enumeration,
		"03,00,0b,00,00,08,00,00",
		"03,00,0a,00,00,08,00,00",
	)
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/DYNENUM.REG",
			bad_irq,
		),
	)
	if bad_irq_allocated {delete(bad_irq)}
	testing.expect(t, !console_desktop_marker_exists(session))
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/DYNENUM.REG",
			valid_dynamic_enumeration,
		),
	)
	mixed_irq, mixed_irq_error := strings.concatenate(
		{
			valid_enumeration,
			"\r\n[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_FFFE&DEV_0002&REV_01\\BUS_00&DEV_02&FUNC_00\\LogConfig\\ALT]\r\n",
			`"AllocConfig"=hex(8):01,00,00,00,05,00,00,00,00,00,00,00,01,00,01,00,01,00,00,00,02,03,00,00,0a,00,00,00,0a,00,00,00,ff,ff,ff,ff` +
			"\r\n",
		},
	)
	testing.expect(t, mixed_irq_error == nil)
	if mixed_irq_error == nil {
		testing.expect(t, !console_windows98_enum_valid(mixed_irq, valid_dynamic_enumeration))
		delete(mixed_irq)
	}
	near_match, near_match_allocated := strings.replace_all(
		valid_enumeration,
		"VEN_1022&DEV_7006",
		"VEN_1022&DEV_70060",
	)
	testing.expect(t, !console_windows98_enum_valid(near_match, valid_dynamic_enumeration))
	if near_match_allocated {delete(near_match)}
	one_child, one_child_allocated := strings.replace_all(
		valid_enumeration,
		"[HKEY_LOCAL_MACHINE\\Enum\\MF\\GOODSECONDARY\\PCI&VEN_1022&DEV_7409&REV_07&BUS_00&DEV_07&FUNC_01]\r\n\r\n",
		"",
	)
	testing.expect(t, !console_windows98_enum_valid(one_child, valid_dynamic_enumeration))
	if one_child_allocated {delete(one_child)}

	dynamic_invalid_replacements := [?][2]string {
		{`"Problem"=hex:00,00,00,00`, ""},
		{`"Problem"=hex:00,00,00,00`, `"Problem"=hex:16,00,00,00`},
		{`"Status"=hex:4a,00,00,00`, ""},
		{`"Status"=hex:4a,00,00,00`, `"Status"=hex:42,00,00,00`},
		{`"Status"=hex:4a,00,00,00`, `"Status"=hex:4a,04,00,00`},
		{`"Status"=hex:4a,00,00,00`, `"Status"=hex:4a,80,00,00`},
		{`"Status"=hex:4a,00,00,00`, `"Status"=hex:4a,00,00,80`},
	}
	for replacement in dynamic_invalid_replacements {
		invalid, allocated := strings.replace_all(
			valid_dynamic_enumeration,
			replacement[0],
			replacement[1],
		)
		testing.expect(t, !console_windows98_enum_valid(valid_enumeration, invalid))
		if allocated {delete(invalid)}
	}
	bad_child, bad_child_allocated := strings.replace_all(
		valid_dynamic_enumeration,
		`"Status"=hex:4a,00,02,00`,
		`"Status"=hex:4a,04,02,00`,
	)
	testing.expect(t, !console_windows98_enum_valid(valid_enumeration, bad_child))
	if bad_child_allocated {delete(bad_child)}
	synthetic, synthetic_error := strings.concatenate(
		{
			valid_enumeration,
			"\r\n[HKEY_LOCAL_MACHINE\\Enum\\PCI\\VEN_FFFE&DEV_0001\\BUS_00&DEV_03&FUNC_00]\r\n",
		},
	)
	if !testing.expect(t, synthetic_error == nil) {return}
	defer delete(synthetic)
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/ENUM.REG",
			synthetic,
		),
	)
	testing.expect(t, !console_desktop_marker_exists(session))
	harmless_text, harmless_text_error := strings.concatenate(
		{
			valid_enumeration,
			"\r\n[HKEY_LOCAL_MACHINE\\Enum\\Root\\LEGACY]\r\n",
			`"Comment"="VEN_FFFE&DEV_0001"`,
		},
	)
	testing.expect(t, harmless_text_error == nil)
	if harmless_text_error == nil {
		testing.expect(t, console_windows98_enum_valid(harmless_text, valid_dynamic_enumeration))
		delete(harmless_text)
	}
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/ENUM.REG",
			valid_enumeration,
		),
	)
	testing.expect(t, console_desktop_marker_exists(session))
	testing.expect(
		t,
		console_acceptance_test_stopped_write_one(
			t,
			&session,
			image_path,
			"GSWSETUP/DESKTOP.OK",
			"STALE\r\n",
		),
	)
	testing.expect(t, !console_desktop_marker_exists(session))

	pixels := []u32{0xFF000000, 0xFF000000}
	frame := vga.Display_Frame {
		kind   = .Xrgb_8888,
		pixels = pixels,
		width  = 2,
		height = 1,
	}
	testing.expect(t, !console_frame_is_nonblack_graphics(&frame))
	pixels[1] = 0xFF010203
	testing.expect(t, console_frame_is_nonblack_graphics(&frame))
	frame.kind = .Text
	testing.expect(t, !console_frame_is_nonblack_graphics(&frame))
}

@(test)
console_acceptance_test_profile_readiness_preserves_install_gates :: proc(t: ^testing.T) {
	inactive: profile.Install_State
	active_pre_reset := profile.Install_State {
		phase = .Setup_Running,
	}
	active_post_reset := profile.Install_State {
		phase       = .Setup_Running,
		reset_count = 1,
	}
	testing.expect(t, console_acceptance_profile_ready(.None, nil, .Missing))
	testing.expect(t, !console_acceptance_profile_ready(.Desktop, nil, .None))
	testing.expect(t, !console_acceptance_profile_ready(.Desktop, &inactive, .Missing))
	testing.expect(t, console_acceptance_profile_ready(.Desktop, &inactive, .None))
	testing.expect(t, !console_acceptance_profile_ready(.Hardware_Detection, &inactive, .None))
	testing.expect(
		t,
		console_acceptance_profile_ready(.Hardware_Detection, &active_pre_reset, .None),
	)
	testing.expect(t, console_desktop_profile_probe_ready(&inactive))
	testing.expect(t, !console_desktop_profile_probe_ready(&active_pre_reset))
	testing.expect(t, console_desktop_profile_probe_ready(&active_post_reset))
}

@(test)
console_acceptance_test_only_dos_extender_cpu_resets_are_allowed_during_gates :: proc(
	t: ^testing.T,
) {
	testing.expect(t, console_acceptance_cpu_reset_allowed(.None, .Triple_Fault, false))
	testing.expect(
		t,
		console_acceptance_cpu_reset_allowed(.Desktop, .Dos_Extender_Warm_Resume, true),
	)
	testing.expect(
		t,
		!console_acceptance_cpu_reset_allowed(.Desktop, .Dos_Extender_Warm_Resume, false),
	)
	testing.expect(t, !console_acceptance_cpu_reset_allowed(.Desktop, .Triple_Fault, true))
	testing.expect(t, !console_acceptance_cpu_reset_allowed(.Hardware_Detection, .None, true))
}

@(test)
console_acceptance_test_win98_dynamic_allocation_irq_is_strict :: proc(t: ^testing.T) {
	real_irq11 :=
		"hex:00,04,00,00,01,00,00,00,30,00,00,00,01,00,00,00,01,00,14,00," +
		"00,00,0a,00,ff,ff,0a,00,01,00,00,00,ff,ff,ff,ff,00,00,01,00,00,00," +
		"0a,00,ff,ff,0a,00,01,00,00,00,ff,00,00,00,30,00,00,00,01,00,00,00," +
		"01,00,14,00,00,00,0b,00,ff,ff,0b,00,01,00,00,00,ff,ff,ff,ff,00,00," +
		"01,00,00,00,0b,00,ff,ff,0b,00,01,00,00,00,ff,00,00,00,24,00,00,00," +
		"02,00,00,00,01,00,0c,00,b0,03,bb,03,00,00,04,03,ff,ff,0c,00,b0,03," +
		"bb,03,00,00,04,03,ff,00,00,00,24,00,00,00,02,00,00,00,01,00,0c,00," +
		"c0,03,df,03,00,00,04,03,ff,ff,20,00,c0,03,df,03,00,00,04,03,ff,00," +
		"00,00,10,00,00,00,04,00,00,00,03,00,0b,00,00,08,00,00,30,00,00,00," +
		"01,00,00,00,01,00,14,00,00,00,00,fe,ff,0f,00,fe,01,00,00,00,00,f0," +
		"ff,ff,00,10,00,00,00,00,00,00,ff,ff,ff,ff,01,00,00,00,10,00,00,00," +
		"30,00,00,00,01,00,00,00,01,00,14,00,00,00,00,fc,ff,ff,ff,fd,01,00," +
		"00,00,00,00,00,fe,00,00,00,02,00,00,00,00,ff,ff,ff,ff,01,00,00,00,14," +
		"00,00,00,00,00,00,00"
	seen, mismatch, valid := console_win98_allocation_irq_evidence(real_irq11, 11)
	testing.expect(t, seen)
	testing.expect(t, !mismatch)
	testing.expect(t, valid)

	real_irq10, real_irq10_allocated := strings.replace_all(
		real_irq11,
		"03,00,0b,00,00,08,00,00",
		"03,00,0a,00,00,08,00,00",
	)
	defer if real_irq10_allocated {delete(real_irq10)}
	seen, mismatch, valid = console_win98_allocation_irq_evidence(real_irq10, 11)
	testing.expect(t, seen)
	testing.expect(t, mismatch)
	testing.expect(t, valid)

	malformed :=
		"hex:00,04,00,00,01,00,00,00," +
		"11,00,00,00,04,00,00,00,03,00,0b,00,00,08,00,00," +
		"00,00,00,00"
	_, _, valid = console_win98_allocation_irq_evidence(malformed, 11)
	testing.expect(t, !valid)
}

@(test)
console_acceptance_test_desktop_graphics_requires_one_percent_visible_rgb :: proc(t: ^testing.T) {
	width, height := 640, 480
	pixels := make([]u32, width * height)
	defer delete(pixels)
	for &pixel in pixels {pixel = 0xFF000000}
	frame := vga.Display_Frame {
		kind   = .Xrgb_8888,
		pixels = pixels,
		width  = width,
		height = height,
	}

	pixels[0] = 0x00000000
	testing.expect(t, !console_frame_is_nonblack_graphics(&frame))
	for y in 0 ..< 32 {
		for x in 0 ..< 32 {
			pixels[(height / 2 - 16 + y) * width + width / 2 - 16 + x] = 0xFFFFFFFF
		}
	}
	testing.expect(t, !console_frame_is_nonblack_graphics(&frame))

	for &pixel in pixels {pixel = 0xFF000000}
	required := len(pixels) / DESKTOP_GRAPHICS_MIN_RGB_COVERAGE_DENOMINATOR
	for index in 0 ..< required - 1 {pixels[index] = 0xFFFFFFFF}
	testing.expect(t, !console_frame_is_nonblack_graphics(&frame))
	pixels[required - 1] = 0xFFFFFFFF
	testing.expect(t, console_frame_is_nonblack_graphics(&frame))

	for &pixel in pixels {pixel = 0xFF008080}
	start := time.tick_now()
	stability: Console_Desktop_Graphics_Stability
	testing.expect(t, console_desktop_graphics_observe(&stability, &frame, start))
	testing.expect(
		t,
		console_desktop_graphics_stable(
			&stability,
			time.tick_add(start, DESKTOP_GRAPHICS_STABLE_TIME),
		),
	)
}

@(test)
console_acceptance_test_primary_ide_dma_evidence_combines_completed_segments :: proc(
	t: ^testing.T,
) {
	result := acceptance.Result {
		execution = {
			primary_ide_dma_transactions = 200,
			primary_ide_dma_bytes = 100 * 1024,
			primary_ide_kernel_dma_transactions = 2,
			primary_ide_kernel_dma_bytes = 1024,
		},
	}
	m := new(machine.Machine)
	defer free(m)
	m.bmide.channel_transactions[0] = 300
	m.bmide.channel_bytes_moved[0] = 150 * 1024
	m.bmide.channel_transactions[1] = 7
	m.bmide.channel_bytes_moved[1] = 14 * 1024
	m.primary_ide_kernel_dma_transactions = 3
	m.primary_ide_kernel_dma_bytes = 1536

	transactions, bytes := console_primary_ide_kernel_dma_evidence(&result, m, false)
	testing.expect_value(t, transactions, u64(5))
	testing.expect_value(t, bytes, u64(2560))
	transactions, bytes = console_primary_ide_kernel_dma_evidence(&result, m, false, 2, 1024)
	testing.expect_value(t, transactions, u64(3))
	testing.expect_value(t, bytes, u64(1536))
	transactions, bytes = console_primary_ide_kernel_dma_evidence(&result, m, false, 5, 2560)
	testing.expect_value(t, transactions, u64(0))
	testing.expect_value(t, bytes, u64(0))
	transactions, bytes = console_primary_ide_kernel_dma_evidence(&result, m, false, 6, 2561)
	testing.expect_value(t, transactions, u64(0))
	testing.expect_value(t, bytes, u64(0))
	transactions, bytes = console_primary_ide_kernel_dma_evidence(&result, m, true)
	testing.expect_value(t, transactions, u64(2))
	testing.expect_value(t, bytes, u64(1024))
	testing.expect(t, console_desktop_hardware_evidence_complete(true, transactions, bytes))
	testing.expect(t, !console_desktop_hardware_evidence_complete(false, transactions, bytes))
	testing.expect(t, !console_desktop_hardware_evidence_complete(true, 0, bytes))
	testing.expect(t, !console_desktop_hardware_evidence_complete(true, transactions, 0))
}

@(test)
console_acceptance_test_pending_target_rejects_early_terminal_exit :: proc(t: ^testing.T) {
	testing.expect_value(t, console_terminal_exit_code(.None, true), 0)
	testing.expect_value(t, console_terminal_exit_code(.None, false), 2)
	result := acceptance.Result {
		stop_reason = .Test_Exit,
	}
	testing.expect(t, !console_artifact_failed(&result))
	result.exit_code = 2
	testing.expect(t, console_artifact_failed(&result))
	targets := [?]acceptance.Accept_Until {
		acceptance.Accept_Until.Hardware_Detection,
		acceptance.Accept_Until.Desktop,
	}
	for target in targets {
		testing.expect_value(t, console_terminal_exit_code(target, true), 2)
		testing.expect_value(t, console_terminal_exit_code(target, false), 2)
	}
}
