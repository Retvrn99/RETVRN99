// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "disk"
import "hv"
import "machine"
import "profile"
import "vga"
import "vmconfig"
import "win98prep"

RUN_SECONDS :: 60
VGA_PERIOD :: 500 * time.Millisecond
HARDWARE_DETECTION_STABLE_TIME :: 60 * time.Second

console_prepare_windows_install :: proc(
	media_path: string,
	paths: ^profile.Paths,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
	boot_image_path: string,
) -> bool {
	if media_path == "" || paths == nil {return false}
	previous, diagnostic := profile.install_state_load(paths.install_state)
	defer profile.install_state_destroy(&previous)
	if diagnostic != .None && diagnostic != .Missing {
		fmt.eprintfln("Windows 98: existing install state is unreadable (%v)", diagnostic)
		return false
	}
	cmos_value := cmos
	candidate := install_state_candidate(media_path, cmos_value[:], has_cmos, &previous)
	defer profile.install_state_destroy(&candidate)
	if profile.install_state_save(paths.install_state, &candidate) != .None {
		fmt.eprintln("Windows 98: cannot record media preparation")
		return false
	}
	report := win98prep.prepare(media_path, paths.install, paths.c_drive, boot_image_path)
	defer win98prep.report_destroy(&report)
	if report.diagnostic == .None {
		candidate.phase = .Launch_Pending
		if profile.install_state_save(paths.install_state, &candidate) == .None {
			if !win98prep.prepare_finish(&report) {
				fmt.eprintln("Windows 98: setup is ready; obsolete preparation backups remain")
			}
			fmt.printfln(
				"Windows 98: prepared %d files (%d bytes)",
				report.media_info.win98_file_count,
				report.media_info.win98_total_bytes,
			)
			return true
		}
		candidate.phase = .Preparing
		if !win98prep.prepare_rollback(&report) {
			fmt.eprintln("Windows 98: preparation state save and rollback both failed")
			return false
		}
	}
	if report.transaction.state != .Inactive && report.transaction.state != .Rolled_Back {
		fmt.eprintfln("Windows 98: preparation failed and rollback is incomplete (%v)", report.diagnostic)
		return false
	}
	if profile.install_state_save(paths.install_state, &previous) != .None {
		fmt.eprintln("Windows 98: preparation failed and the previous install state could not be restored")
		return false
	}
	if report.bootstrap_diagnostic == .Boot_Image_Required {
		fmt.eprintln("Windows 98: --install-windows on a fresh C: also requires --floppy:<Windows 98 boot image>")
	}
	fmt.eprintfln(
		"Windows 98: preparation failed (%v, media %v, bootstrap %v, cleanup %v)",
		report.diagnostic,
		report.media_diagnostic,
		report.bootstrap_diagnostic,
		report.retry_cleanup.diagnostic,
	)
	return false
}

console_acceptance_configuration_error :: proc(
	options: ^acceptance.Options,
	paths: ^profile.Paths,
	mode: vmconfig.Cpu_Mode,
	message: string,
) -> int {
	if options == nil {return 1}
	result := acceptance.Result {
		stop_reason = .Configuration_Error,
		exit_code = 1,
		cpu_mode = console_cpu_mode_name(mode),
		installation_milestone = "none",
	}
	if paths != nil {
		state, diagnostic := profile.install_state_load(paths.install_state)
		if diagnostic == .None {
			result.installation_milestone = console_install_milestone_name(state.milestone)
		}
		profile.install_state_destroy(&state)
	}
	if options.artifacts != "" {
		diagnostics := fmt.tprintf(
			"stop_reason=%s\nexit_code=1\nconfiguration=%s\n",
			acceptance.stop_reason_name(result.stop_reason),
			message,
		)
		defer delete(diagnostics)
		if diagnostic := acceptance.artifact_write_bundle(options.artifacts, diagnostics);
		   diagnostic != .None {
			fmt.eprintfln("acceptance artifact write failed: %v", diagnostic)
		}
	}
	if options.result_json != "" {
		if diagnostic := acceptance.result_save(options.result_json, &result);
		   diagnostic != .None {
			fmt.eprintfln("acceptance result write failed: %v", diagnostic)
		}
	}
	return 1
}

console_cpu_mode_name :: proc(mode: vmconfig.Cpu_Mode) -> string {
	return mode == .Turbo ? "Turbo" : "GSW-886"
}

console_install_milestone_name :: proc(milestone: profile.Install_Milestone) -> string {
	switch milestone {
	case .None: return "none"
	case .DOS_Setup: return "dos_setup"
	case .First_Reboot: return "first_reboot"
	case .Hardware_Detection: return "hardware_detection"
	}
	return "unknown"
}

console_result_record_reset :: proc(result: ^acceptance.Result, reason: string) {
	if result == nil {return}
	result.reset_count += 1
	if result.reset_history_count >= acceptance.RESULT_MAX_RESETS {return}
	result.reset_history[result.reset_history_count] = strings.clone(reason)
	result.reset_history_count += 1
}

console_result_destroy :: proc(result: ^acceptance.Result) {
	if result == nil {return}
	for reason in result.reset_history[:clamp(result.reset_history_count, 0, acceptance.RESULT_MAX_RESETS)] {
		delete(reason)
	}
	for hash in result.workload_hashes[:clamp(result.workload_hash_count, 0, acceptance.RESULT_MAX_HASHES)] {
		delete(hash.name)
		delete(hash.sha256)
	}
	result^ = {}
}

console_result_accumulate_machine :: proc(result: ^acceptance.Result, m: ^machine.Machine) {
	if result == nil || m == nil {return}
	first_segment := result.master_ticks == 0
	result.master_ticks += machine.master_timeline_now(m.timeline)
	for count in m.inj_count {result.irq_injections += count}
	for channel in m.dma.ch {result.dma_units += channel.transfer_cycles}
	result.modeled_io += m.bus.modeled_count
	result.passive_io += m.bus.passive_count
	result.unclassified_io += m.bus.unclassified_count
	result.unclassified_mmio += m.bus.unclassified_mmio_count
	metrics := machine.machine_audio_metrics(m)
	result.audio.frames_produced += metrics.frames_produced
	result.audio.frames_consumed += metrics.frames_consumed
	if first_segment {
		result.audio.queue_min_depth = metrics.queue_min_depth
	} else {
		result.audio.queue_min_depth = min(result.audio.queue_min_depth, metrics.queue_min_depth)
	}
	result.audio.queue_max_depth = max(result.audio.queue_max_depth, metrics.queue_max_depth)
	result.audio.underruns += metrics.underruns
	result.audio.overruns += metrics.overruns
	result.audio.late_callbacks += metrics.late_callbacks
	result.audio.max_callback_lateness_us = max(
		result.audio.max_callback_lateness_us,
		metrics.max_callback_lateness_us,
	)
}

console_artifact_failed :: proc(result: ^acceptance.Result) -> bool {
	if result == nil {return true}
	if result.stop_reason == .Acceptance_Reached {return false}
	return result.stop_reason != .Test_Exit || result.test_exit_code != 0
}

console_acceptance_observe_display_activity :: proc(
	previous: ^u64,
	frame: ^vga.Display_Frame,
) -> bool {
	if previous == nil || frame == nil {return false}
	current := frame.guest_activity_generation
	changed := previous^ != 0 && previous^ != current
	previous^ = current
	return changed
}

CONSOLE_ARTIFACT_LOG_BYTES :: 32 * 1024

console_artifact_append_log :: proc(
	builder: ^strings.Builder,
	path, label: string,
) {
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return}
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size <= 0 {return}
	start := max(i64(0), size - CONSOLE_ARTIFACT_LOG_BYTES)
	wanted := int(min(i64(CONSOLE_ARTIFACT_LOG_BYTES), size))
	buffer: [CONSOLE_ARTIFACT_LOG_BYTES]u8
	total := 0
	for total < wanted {
		count, read_error := os.read_at(file, buffer[total:wanted], start + i64(total))
		if count <= 0 {break}
		total += count
		if read_error != nil {break}
	}
	if total == 0 {return}
	fmt.sbprintfln(builder, "\nsetup-log %s (last %d of %d bytes):", label, total, size)
	fmt.sbprintfln(builder, "%s", string(buffer[:total]))
}

console_artifact_append_setup_logs :: proc(builder: ^strings.Builder, c_drive: string) {
	if builder == nil || c_drive == "" {return}
	windows, windows_error := filepath.join({c_drive, "WINDOWS"}, context.temp_allocator)
	if windows_error != nil {return}
	roots := [?]struct {
		path: string,
		label: string,
	}{
		{c_drive, "C:\\"},
		{windows, "C:\\WINDOWS\\"},
	}
	names := [?]string{"SETUPLOG.TXT", "DETLOG.TXT", "DETCRASH.LOG"}
	for root in roots {
		for name in names {
			path, path_error := filepath.join({root.path, name}, context.temp_allocator)
			if path_error != nil {continue}
			label := fmt.tprintf("%s%s", root.label, name)
			console_artifact_append_log(builder, path, label)
		}
	}
}

console_artifact_diagnostics :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	firmware_text: string,
	paths: ^profile.Paths,
) -> string {
	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "stop_reason=%s", acceptance.stop_reason_name(result.stop_reason))
	fmt.sbprintfln(&builder, "exit_code=%d", result.exit_code)
	fmt.sbprintfln(&builder, "master_ticks=%d wall_ms=%d", result.master_ticks, result.wall_milliseconds)
	fmt.sbprintfln(
		&builder,
		"io modeled=%d passive=%d unclassified=%d mmio=%d",
		result.modeled_io,
		result.passive_io,
		result.unclassified_io,
		result.unclassified_mmio,
	)
	fmt.sbprintfln(
		&builder,
		"audio produced=%d consumed=%d depth=%d..%d underruns=%d overruns=%d late=%d max_late_us=%d",
		result.audio.frames_produced,
		result.audio.frames_consumed,
		result.audio.queue_min_depth,
		result.audio.queue_max_depth,
		result.audio.underruns,
		result.audio.overruns,
		result.audio.late_callbacks,
		result.audio.max_callback_lateness_us,
	)
	if m != nil {
		fmt.sbprintfln(&builder, "freeze=%s", m.bus.freeze_msg)
		registers := format_regs(hv.get_regs(&m.vm), m)
		fmt.sbprintfln(&builder, "%s", registers)
		delete(registers)
		fmt.sbprintfln(
			&builder,
			"PIC master irr=%02x isr=%02x imr=%02x asserted=%02x elcr=%02x; slave irr=%02x isr=%02x imr=%02x asserted=%02x elcr=%02x",
			m.pic.master.irr,
			m.pic.master.isr,
			m.pic.master.imr,
			m.pic.master.asserted,
			m.pic.master.elcr,
			m.pic.slave.irr,
			m.pic.slave.isr,
			m.pic.slave.imr,
			m.pic.slave.asserted,
			m.pic.slave.elcr,
		)
		fmt.sbprintln(&builder, "DMA:")
		for channel, index in m.dma.ch {
			fmt.sbprintfln(
				&builder,
				"  ch%d addr=%02x:%04x count=%04x mode=%02x masked=%v dreq=%v active=%v tc=%v units=%d",
				index,
				channel.page,
				channel.addr,
				channel.count,
				channel.mode,
				channel.masked,
				channel.dreq,
				channel.active,
				channel.tc,
				channel.transfer_cycles,
			)
		}
		fmt.sbprintf(&builder, "IRQ injections:")
		for count, vector in m.inj_count {
			if count > 0 {fmt.sbprintf(&builder, " %02x=%d", vector, count)}
		}
		fmt.sbprintln(&builder)
		reset_count := machine.machine_reset_record_count(m)
		fmt.sbprintfln(&builder, "reset records (%d):", reset_count)
		for index in 0 ..< reset_count {
			if record, ok := machine.machine_reset_record(m, index); ok {
				fmt.sbprintfln(
					&builder,
					"  %v tick=%d cmos_0f=%02x",
					record.source,
					record.master_tick,
					record.cmos_shutdown,
				)
			}
		}
		io_count := int(min(m.io_count, u64(machine.IO_HISTORY)))
		fmt.sbprintfln(&builder, "recent I/O (%d):", io_count)
		for i in 0 ..< io_count {
			index := (m.io_count - u64(io_count) + u64(i)) % machine.IO_HISTORY
			trace := m.io_hist[index]
			fmt.sbprintfln(
				&builder,
				"  %s %04x size=%d value=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.val,
			)
		}
		unclassified_count := int(min(m.bus.unclassified_count, u64(machine.BUS_UNCLASSIFIED_HISTORY)))
		fmt.sbprintfln(&builder, "recent unclassified I/O (%d):", unclassified_count)
		for i in 0 ..< unclassified_count {
			index := (m.bus.unclassified_count - u64(unclassified_count) + u64(i)) % machine.BUS_UNCLASSIFIED_HISTORY
			trace := m.bus.unclassified_history[index]
			fmt.sbprintfln(
				&builder,
				"  %s %04x size=%d value=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.value,
			)
		}
		mmio_count := int(min(m.bus.unclassified_mmio_count, u64(machine.BUS_UNCLASSIFIED_MMIO_HISTORY)))
		fmt.sbprintfln(&builder, "recent unclassified MMIO (%d):", mmio_count)
		for i in 0 ..< mmio_count {
			index := (m.bus.unclassified_mmio_count - u64(mmio_count) + u64(i)) % machine.BUS_UNCLASSIFIED_MMIO_HISTORY
			trace := m.bus.unclassified_mmio_history[index]
			fmt.sbprintfln(
				&builder,
				"  %s gpa=%016x size=%d",
				trace.write ? "write" : "read",
				trace.gpa,
				trace.size,
			)
		}
		atapi_count := int(min(m.atapi.trace_count, u64(disk.ATAPI_TRACE_HISTORY)))
		fmt.sbprintfln(&builder, "recent ATAPI packets (%d):", atapi_count)
		for i in 0 ..< atapi_count {
			index := (m.atapi.trace_count - u64(atapi_count) + u64(i)) % disk.ATAPI_TRACE_HISTORY
			trace := m.atapi.trace_hist[index]
			fmt.sbprintf(&builder, "  packet")
			for byte in trace.packet {fmt.sbprintf(&builder, " %02x", byte)}
			fmt.sbprintfln(
				&builder,
				" limit=%d status=%02x error=%02x sense=%02x/%02x/%02x",
				trace.phase_limit,
				trace.dispatch_status,
				trace.dispatch_error,
				trace.dispatch_key,
				trace.dispatch_asc,
				trace.dispatch_ascq,
			)
		}
		text := machine.machine_text_snapshot(m)
		fmt.sbprintln(&builder, "decoded text:")
		for row in 0 ..< 25 {
			line: [80]u8
			for col in 0 ..< 80 {
				cell := u8(text.cells[row * 80 + col])
				line[col] = cell >= 0x20 && cell < 0x7F ? cell : ' '
			}
			fmt.sbprintfln(&builder, "%s", string(line[:]))
		}
	}
	if paths != nil {console_artifact_append_setup_logs(&builder, paths.c_drive)}
	fmt.sbprintfln(&builder, "\nfirmware:\n%s", firmware_text)
	return strings.to_string(builder)
}

console_acceptance_finalize :: proc(
	options: ^acceptance.Options,
	run_result: ^acceptance.Result,
	m: ^machine.Machine,
	machine_live: ^bool,
	firmware: ^Firmware_Log,
	paths: ^profile.Paths,
	start: time.Tick,
	return_code: ^int,
) {
	if options == nil || run_result == nil {return}
	live := machine_live != nil && machine_live^
	if live {
		console_result_accumulate_machine(run_result, m)
		frame := machine.machine_display_frame(m)
		run_result.frame_crc = acceptance.frame_crc32(frame.pixels, frame.width, frame.height)
	}
	run_result.wall_milliseconds = u64(
		max(time.Duration(0), time.tick_diff(start, time.tick_now())) / time.Millisecond,
	)
	run_result.installation_milestone = "none"
	if paths != nil {
		state, diagnostic := profile.install_state_load(paths.install_state)
		if diagnostic == .None {
			run_result.installation_milestone = console_install_milestone_name(state.milestone)
		}
		profile.install_state_destroy(&state)
	}
	if options.artifacts != "" && console_artifact_failed(run_result) {
		firmware_text := firmware_log_recent(firmware)
		defer delete(firmware_text)
		frame: ^vga.Display_Frame
		if live {
			frame = machine.machine_display_frame(m)
		}
		diagnostics := console_artifact_diagnostics(
			run_result,
			live ? m : nil,
			firmware_text,
			paths,
		)
		defer delete(diagnostics)
		pixels: []u32
		width, height := 0, 0
		if frame != nil {pixels, width, height = frame.pixels, frame.width, frame.height}
		if diagnostic := acceptance.artifact_write_bundle(
			options.artifacts,
			diagnostics,
			pixels,
			width,
			height,
		); diagnostic != .None {
			fmt.eprintfln("acceptance artifact write failed: %v", diagnostic)
		}
	}
	if options.result_json != "" {
		if diagnostic := acceptance.result_save(options.result_json, run_result);
		   diagnostic != .None {
			fmt.eprintfln("acceptance result write failed: %v", diagnostic)
			if return_code != nil && return_code^ == 0 {return_code^ = 2}
		}
	}
}

console_log_total_size :: proc(c_drive: string, names: []string) -> i64 {
	total: i64
	windows, _ := filepath.join({c_drive, "WINDOWS"}, context.temp_allocator)
	roots := [?]string{c_drive, windows}
	for root in roots {
		for name in names {
			path, err := filepath.join({root, name}, context.temp_allocator)
			if err != nil {continue}
			info, stat_error := os.stat(path, context.temp_allocator)
			if stat_error == nil {
				if info.type == .Regular && info.size > 0 {total += info.size}
				os.file_info_delete(info, context.temp_allocator)
			}
		}
	}
	return total
}
