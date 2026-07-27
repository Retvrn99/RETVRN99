// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "core:strings"
import "core:time"
import "disk"
import "fat32session"
import "hv"
import "machine"
import "profile"
import "vga"
import "vmconfig"
import "win98imageprep"

RUN_SECONDS :: 60
VGA_PERIOD :: 500 * time.Millisecond
HARDWARE_DETECTION_STABLE_TIME :: 60 * time.Second
DESKTOP_GRAPHICS_STABLE_TIME :: 10 * time.Minute
DESKTOP_GRAPHICS_MIN_RGB_COVERAGE_DENOMINATOR :: 100
CONSOLE_NO_PROGRESS_TIMEOUT :: 5 * time.Minute
CONSOLE_SETUP_ARTIFACT_PERIOD :: 30 * time.Second
DESKTOP_WAITING_PRIMARY_IDE_DMA_PROGRESS_REASON :: "desktop_waiting_primary_ide_dma"
DESKTOP_ENUM_MAX_BYTES :: 4 * 1024 * 1024
DESKTOP_ENUM_RESOURCE_MAX_BYTES :: 64 * 1024
DESKTOP_ENUM_REQUIRED_AMD_IDS :: [?]string {
	"VEN_1022&DEV_7006",
	"VEN_1022&DEV_7408",
	"VEN_1022&DEV_7409",
}
DESKTOP_ENUM_REQUIRED_AMD_BDFS :: [?]string {
	"BUS_00&DEV_00&FUNC_00",
	"BUS_00&DEV_07&FUNC_00",
	"BUS_00&DEV_07&FUNC_01",
}
DESKTOP_ENUM_GSW_VGA_ID :: "VEN_FFFE&DEV_0002"
DESKTOP_ENUM_GSW_VGA_BDF :: "BUS_00&DEV_02&FUNC_00"
DESKTOP_ENUM_SYNTHETIC_CHIPSET_ID :: "VEN_FFFE&DEV_0001"
DESKTOP_ENUM_REQUIRED_IRQ :: u32(11)
DESKTOP_ENUM_MAX_MF_CHILDREN :: 8
DESKTOP_ENUM_STATUS_STARTED :: u32(0x0000_0008)
DESKTOP_ENUM_STATUS_BAD_MASK :: u32(0x8000_8400)

console_evidence_poll_due :: proc(last: ^time.Tick, now: time.Tick) -> bool {
	if last == nil || time.tick_diff(last^, now) < time.Second {return false}
	last^ = now
	return true
}

console_acceptance_profile_ready :: proc(
	accept_until: acceptance.Accept_Until,
	state: ^profile.Install_State,
	diagnostic: profile.Install_State_Diagnostic,
) -> bool {
	if accept_until == .None {return true}
	if state == nil || diagnostic != .None {return false}
	if accept_until == .Desktop {return true}
	return profile.install_state_active(state)
}

console_desktop_profile_probe_ready :: proc(state: ^profile.Install_State) -> bool {
	if state == nil {return false}
	return !profile.install_state_active(state) || state.reset_count > 0
}

console_acceptance_cpu_reset_allowed :: proc(
	accept_until: acceptance.Accept_Until,
	source: machine.Reset_Provenance,
	install_active: bool,
) -> bool {
	return accept_until == .None || install_active && source == .Dos_Extender_Warm_Resume
}

console_setup_artifact_poll_due :: proc(
	install_reset_count: u32,
	detection_pending, desktop_pending: bool,
	armed_reset_count: ^u32,
	last: ^time.Tick,
	now: time.Tick,
) -> bool {
	if last == nil || armed_reset_count == nil || (install_reset_count == 0 && !desktop_pending) {
		return false
	}
	if armed_reset_count^ != install_reset_count {
		armed_reset_count^ = install_reset_count
		last^ = now
		return false
	}
	if !(detection_pending || desktop_pending) ||
	   time.tick_diff(last^, now) < CONSOLE_SETUP_ARTIFACT_PERIOD {
		return false
	}
	last^ = now
	return true
}

Console_Progress_Snapshot :: struct {
	boot_epoch:                  u64,
	guest_requested_resets:      u64,
	irq_injections:              u64,
	dma_units:                   u64,
	modeled_io:                  u64,
	ide_io:                      u64,
	ide_commands:                u64,
	atapi_packets:               u64,
	storage_transactions:        u64,
	storage_host_calls:          u64,
	storage_bytes:               u64,
	display_activity_generation: u64,
}

Console_Progress_Watchdog :: struct {
	initialized:      bool,
	last:             Console_Progress_Snapshot,
	last_progress_at: time.Tick,
}

console_progress_snapshot :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	display_activity_generation: u64,
) -> Console_Progress_Snapshot {
	if result == nil || m == nil {return {}}
	irq_injections: u64
	for count in m.inj_count {irq_injections += count}
	dma_units: u64
	for channel in m.dma.ch {dma_units += channel.transfer_cycles}
	execution := machine.machine_execution_counters(m)
	return {
		boot_epoch = result.boot_epoch,
		guest_requested_resets = result.guest_requested_resets,
		irq_injections = irq_injections,
		dma_units = dma_units,
		modeled_io = m.bus.modeled_count,
		ide_io = m.ide_count,
		ide_commands = m.cmd_count,
		atapi_packets = m.atapi.trace_count,
		storage_transactions = execution.storage_transactions,
		storage_host_calls = execution.storage_host_calls,
		storage_bytes = execution.storage_bytes,
		display_activity_generation = display_activity_generation,
	}
}

console_progress_reason :: proc(
	previous, current: Console_Progress_Snapshot,
	desktop_idle_liveness: bool = false,
	desktop_waiting_primary_ide_dma: bool = false,
) -> string {
	if previous.boot_epoch != current.boot_epoch ||
	   previous.guest_requested_resets != current.guest_requested_resets {
		return "guest_reset"
	}
	if previous.ide_commands != current.ide_commands ||
	   previous.atapi_packets != current.atapi_packets ||
	   previous.storage_transactions != current.storage_transactions ||
	   previous.storage_host_calls != current.storage_host_calls ||
	   previous.storage_bytes != current.storage_bytes {
		return "storage_io"
	}
	if !desktop_waiting_primary_ide_dma &&
	   previous.display_activity_generation != current.display_activity_generation {
		return "display_activity"
	}
	if desktop_idle_liveness && previous.irq_injections != current.irq_injections {
		return "desktop_irq_liveness"
	}
	return ""
}

console_progress_watchdog_observe :: proc(
	watchdog: ^Console_Progress_Watchdog,
	snapshot: Console_Progress_Snapshot,
	now: time.Tick,
	timeout: time.Duration = CONSOLE_NO_PROGRESS_TIMEOUT,
	desktop_idle_liveness: bool = false,
	desktop_waiting_primary_ide_dma: bool = false,
) -> (
	reason: string,
	timed_out: bool,
) {
	if watchdog == nil {return "", false}
	if !watchdog.initialized {
		watchdog.initialized = true
		watchdog.last = snapshot
		watchdog.last_progress_at = now
		return "", false
	}
	reason = console_progress_reason(
		watchdog.last,
		snapshot,
		desktop_idle_liveness,
		desktop_waiting_primary_ide_dma,
	)
	watchdog.last = snapshot
	if reason != "" {
		watchdog.last_progress_at = now
		return reason, false
	}
	timed_out = time.tick_diff(watchdog.last_progress_at, now) >= timeout
	if timed_out && desktop_waiting_primary_ide_dma {
		return DESKTOP_WAITING_PRIMARY_IDE_DMA_PROGRESS_REASON, true
	}
	return "", timed_out
}

console_acceptance_progress_watchdog_poll :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	watchdog: ^Console_Progress_Watchdog,
	display_activity_generation: u64,
	now: time.Tick,
	desktop_idle_liveness: bool,
	desktop_waiting_primary_ide_dma: bool,
	firmware: ^Firmware_Log,
	iterations: int,
) -> bool {
	if result == nil || m == nil || watchdog == nil {return false}
	snapshot := console_progress_snapshot(result, m, display_activity_generation)
	progress_reason, no_progress := console_progress_watchdog_observe(
		watchdog,
		snapshot,
		now,
		CONSOLE_NO_PROGRESS_TIMEOUT,
		desktop_idle_liveness,
		desktop_waiting_primary_ide_dma,
	)
	if progress_reason != "" {result.last_progress_reason = progress_reason}
	if !no_progress {return false}
	firmware_log_host_flush(firmware, nil)
	fmt.printfln(
		"no meaningful guest progress for %ds after %d iterations",
		int(CONSOLE_NO_PROGRESS_TIMEOUT / time.Second),
		iterations,
	)
	machine.machine_trace_record(m, .Freeze, u64(acceptance.Stop_Reason.No_Progress))
	dump_state(m)
	print_grid(machine.machine_text_snapshot(m))
	result.stop_reason = .No_Progress
	result.exit_code = 2
	return true
}

console_prepare_windows_install :: proc(
	media_path: string,
	image_path: string,
	paths: ^profile.Paths,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
	boot_image_path: string,
	setup_diagnostics: acceptance.Setup_Diagnostics,
	desktop_probe: bool,
) -> bool {
	if media_path == "" || image_path == "" || paths == nil {return false}
	state, diagnostic := profile.install_state_load(paths.install_state)
	defer profile.install_state_destroy(&state)
	if diagnostic != .None && diagnostic != .Missing {
		fmt.eprintfln("Windows 98: existing install state is unreadable (%v)", diagnostic)
		return false
	}
	cmos_value := cmos
	flow := install_image_prepare(
		paths,
		&state,
		image_path,
		media_path,
		boot_image_path,
		cmos_value[:],
		has_cmos,
		win98imageprep.Prepare_Options {
			desktop_probe = desktop_probe,
			hardware_diagnostics = setup_diagnostics == .Hardware,
		},
	)
	defer install_image_flow_result_destroy(&flow)
	if flow.error.code == .None {
		fmt.printfln(
			"Windows 98: prepared %d files (%d bytes)",
			flow.preparation.media_info.win98_file_count,
			flow.preparation.media_info.win98_total_bytes,
		)
		return true
	}
	if flow.error.code == .Boot_Floppy_Required {
		fmt.eprintln(
			"Windows 98: --install-windows on a fresh C: also requires --floppy:<Windows 98 boot image>",
		)
	}
	fmt.eprintfln(
		"Windows 98: image preparation failed (%v): %s%s",
		flow.error.code,
		win98imageprep.error_text(&flow.error),
		flow.state_retained ? "; recovery state retained" : "",
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
		stop_reason            = .Configuration_Error,
		exit_code              = 1,
		cpu_mode               = console_cpu_mode_name(mode),
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
	case .None:
		return "none"
	case .DOS_Setup:
		return "dos_setup"
	case .First_Reboot:
		return "first_reboot"
	case .Hardware_Detection:
		return "hardware_detection"
	}
	return "unknown"
}

console_result_record_reset_request :: proc(result: ^acceptance.Result, reason: string) {
	if result == nil {return}
	result.guest_requested_resets += 1
	if result.reset_history_count >= acceptance.RESULT_MAX_RESETS {return}
	result.reset_history[result.reset_history_count] = strings.clone(reason)
	result.reset_history_count += 1
}

Console_Desktop_Graphics_Stability :: struct {
	active: bool,
	since:  time.Tick,
}

console_result_record_reset_success :: proc(
	result: ^acceptance.Result,
	desktop_graphics: ^Console_Desktop_Graphics_Stability = nil,
) {
	if result == nil {return}
	result.reset_count += 1
	result.boot_epoch += 1
	if desktop_graphics != nil {desktop_graphics^ = {}}
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
	execution := machine.machine_execution_counters(m)
	result.execution.hypervisor_runs += execution.hypervisor_runs
	result.execution.hypervisor_cancellations += execution.hypervisor_cancellations
	result.execution.timer_arms += execution.timer_arms
	result.execution.scheduler_dispatches += execution.scheduler_dispatches
	result.execution.device_advances += execution.device_advances
	result.execution.storage_transactions += execution.storage_transactions
	result.execution.storage_host_calls += execution.storage_host_calls
	result.execution.storage_bytes += execution.storage_bytes
	result.execution.primary_ide_dma_transactions += execution.primary_ide_dma_transactions
	result.execution.primary_ide_dma_bytes += execution.primary_ide_dma_bytes
	result.execution.primary_ide_kernel_dma_transactions +=
		execution.primary_ide_kernel_dma_transactions
	result.execution.primary_ide_kernel_dma_bytes += execution.primary_ide_kernel_dma_bytes
	result.execution.audio_blocks += execution.audio_blocks
	result.execution.scanout_copies += execution.scanout_copies
	result.execution.full_frame_renders += execution.full_frame_renders
	result.execution.software_rendered_pixels += execution.software_rendered_pixels
	result.execution.raster_journal_deltas += execution.raster_journal_deltas
	result.execution.raster_journal_truncations += execution.raster_journal_truncations
	observability := machine.machine_audio_observability(m)
	metrics := observability.output
	result.audio.frames_produced += metrics.frames_produced
	result.audio.frames_consumed += metrics.frames_consumed
	if first_segment {
		result.audio.queue_min_depth = metrics.queue_min_depth
	} else {
		result.audio.queue_min_depth = min(result.audio.queue_min_depth, metrics.queue_min_depth)
	}
	result.audio.queue_max_depth = max(result.audio.queue_max_depth, metrics.queue_max_depth)
	result.audio.underruns += metrics.underruns
	result.audio.underrun_events += metrics.underrun_events
	result.audio.underrun_recoveries += metrics.underrun_recoveries
	result.audio.gap_frames += metrics.gap_frames
	result.audio.ramp_down_frames += metrics.ramp_down_frames
	result.audio.overruns += metrics.overruns
	result.audio.late_callbacks += metrics.late_callbacks
	result.audio.callback_lateness_us += metrics.callback_lateness_us
	result.audio.max_callback_lateness_us = max(
		result.audio.max_callback_lateness_us,
		metrics.max_callback_lateness_us,
	)
	result.audio.clipping_frames += observability.clipping_frames
	result.audio.speaker_edges += observability.speaker_edges
	result.audio.speaker_late_edges += observability.speaker_late_edges
	result.audio.speaker_overflow_edges += observability.speaker_overflow_edges
	result.audio.scheduler_wakeups += observability.audio_scheduler_wakeups
	if first_segment {
		result.audio.pcm_fnv1a64 = observability.pcm_fnv1a64
	} else {
		result.audio.pcm_fnv1a64 =
			(result.audio.pcm_fnv1a64 ~ observability.pcm_fnv1a64) * u64(1_099_511_628_211)
	}
	result.audio.pc_speaker.frames_produced += observability.pc_speaker.frames_produced
	result.audio.pc_speaker.nonzero_frames += observability.pc_speaker.nonzero_frames
	result.audio.sb16.frames_produced += observability.sb16.frames_produced
	result.audio.sb16.nonzero_frames += observability.sb16.nonzero_frames
	result.audio.sb16.starvation_frames += observability.sb16_starvation_frames
	result.audio.sb16.irq_events += observability.sb16_irq_events
	result.audio.opl3.frames_produced += observability.opl3.frames_produced
	result.audio.opl3.nonzero_frames += observability.opl3.nonzero_frames
	result.audio.native_pcm.frames_produced += observability.native_pcm.frames_produced
	result.audio.native_pcm.nonzero_frames += observability.native_pcm.nonzero_frames
	result.audio.native_pcm.starvation_frames += observability.native_starvation_frames
	result.audio.native_pcm.irq_events += observability.native_irq_events
	result.audio.cdda.frames_produced += observability.cdda.frames_produced
	result.audio.cdda.nonzero_frames += observability.cdda.nonzero_frames
}

console_result_accumulate_machine_segment :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	segment_accumulated: ^bool,
) -> bool {
	if result == nil || m == nil {return false}
	if segment_accumulated != nil && segment_accumulated^ {return false}
	console_result_accumulate_machine(result, m)
	if segment_accumulated != nil {segment_accumulated^ = true}
	return true
}

console_primary_ide_kernel_dma_evidence :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	current_segment_accumulated: bool,
	baseline_transactions: u64 = 0,
	baseline_bytes: u64 = 0,
) -> (
	transactions, bytes: u64,
) {
	if result != nil {
		transactions = result.execution.primary_ide_kernel_dma_transactions
		bytes = result.execution.primary_ide_kernel_dma_bytes
	}
	if m != nil && !current_segment_accumulated {
		execution := machine.machine_execution_counters(m)
		transactions += execution.primary_ide_kernel_dma_transactions
		bytes += execution.primary_ide_kernel_dma_bytes
	}
	if transactions < baseline_transactions || bytes < baseline_bytes {
		return 0, 0
	}
	transactions -= baseline_transactions
	bytes -= baseline_bytes
	return
}

console_desktop_hardware_evidence_complete :: proc(
	enum_valid: bool,
	primary_dma_transactions, primary_dma_bytes: u64,
) -> bool {
	return enum_valid && primary_dma_transactions > 0 && primary_dma_bytes > 0
}

console_artifact_failed :: proc(result: ^acceptance.Result) -> bool {
	if result == nil {return true}
	if result.stop_reason == .Acceptance_Reached {return false}
	if result.exit_code != 0 {return true}
	return result.stop_reason != .Test_Exit || result.test_exit_code != 0
}

console_terminal_exit_code :: proc(
	accept_until: acceptance.Accept_Until,
	terminal_succeeded: bool,
) -> int {
	if !terminal_succeeded || accept_until != .None {return 2}
	return 0
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

console_acceptance_should_write_artifacts :: proc(
	options: ^acceptance.Options,
	result: ^acceptance.Result,
	trace_count: u64,
) -> bool {
	if options == nil || console_acceptance_artifact_directory(options, result) == "" {
		return false
	}
	return(
		options.setup_diagnostics == .Hardware ||
		trace_count > 0 ||
		console_artifact_failed(result) \
	)
}

console_acceptance_artifact_directory :: proc(
	options: ^acceptance.Options,
	result: ^acceptance.Result,
) -> string {
	if options == nil {return ""}
	if options.artifacts != "" {return options.artifacts}
	if result == nil {return ""}
	#partial switch result.stop_reason {
	case .Strict_IO_Failure, .Timeout, .Fatal_Virtualization_Failure, .No_Progress:
		return acceptance.DEFAULT_ARTIFACTS_DIRECTORY
	case:
		return ""
	}
}

console_frame_is_nonblack_graphics :: proc(frame: ^vga.Display_Frame) -> bool {
	if frame == nil ||
	   frame.kind == .Invalid ||
	   frame.kind == .Text ||
	   frame.width <= 0 ||
	   frame.height <= 0 ||
	   frame.width > max(int) / frame.height {
		return false
	}
	pixel_count := frame.width * frame.height
	if len(frame.pixels) < pixel_count {return false}
	required := pixel_count / DESKTOP_GRAPHICS_MIN_RGB_COVERAGE_DENOMINATOR
	if pixel_count % DESKTOP_GRAPHICS_MIN_RGB_COVERAGE_DENOMINATOR != 0 {required += 1}
	required = max(required, 1)
	nonblack := 0
	for pixel in frame.pixels[:pixel_count] {
		if pixel & 0x00FF_FFFF == 0 {continue}
		nonblack += 1
		if nonblack >= required {return true}
	}
	return false
}

console_desktop_graphics_observe :: proc(
	state: ^Console_Desktop_Graphics_Stability,
	frame: ^vga.Display_Frame,
	now: time.Tick,
) -> bool {
	if state == nil {return false}
	if !console_frame_is_nonblack_graphics(frame) {
		state^ = {}
		return false
	}
	if state.active {return false}
	state.active = true
	state.since = now
	return true
}

console_desktop_graphics_stable :: proc(
	state: ^Console_Desktop_Graphics_Stability,
	now: time.Tick,
) -> bool {
	return(
		state != nil &&
		state.active &&
		time.tick_diff(state.since, now) >= DESKTOP_GRAPHICS_STABLE_TIME \
	)
}

console_ascii_fold_byte :: proc(byte: u8) -> u8 {
	return byte >= 'a' && byte <= 'z' ? byte - ('a' - 'A') : byte
}

console_ascii_index_fold :: proc(text, needle: string, start: int = 0) -> int {
	if len(needle) == 0 {return clamp(start, 0, len(text))}
	if start < 0 || start > len(text) - len(needle) {return -1}
	for offset in start ..= len(text) - len(needle) {
		matched := true
		for index in 0 ..< len(needle) {
			if console_ascii_fold_byte(text[offset + index]) !=
			   console_ascii_fold_byte(needle[index]) {
				matched = false
				break
			}
		}
		if matched {return offset}
	}
	return -1
}

console_ascii_contains_fold :: proc(text, needle: string) -> bool {
	return console_ascii_index_fold(text, needle) >= 0
}

console_ascii_has_prefix_fold :: proc(text, prefix: string) -> bool {
	return len(text) >= len(prefix) && console_ascii_index_fold(text[:len(prefix)], prefix) == 0
}

console_ascii_token_boundary :: proc(byte: u8) -> bool {
	return(
		!((byte >= '0' && byte <= '9') ||
			(byte >= 'A' && byte <= 'Z') ||
			(byte >= 'a' && byte <= 'z') ||
			byte == '_') \
	)
}

console_ascii_token_contains_fold :: proc(text, token: string) -> bool {
	search := 0
	for search <= len(text) - len(token) {
		found := console_ascii_index_fold(text, token, search)
		if found < 0 {return false}
		before_ok := found == 0 || console_ascii_token_boundary(text[found - 1])
		after := found + len(token)
		after_ok := after == len(text) || console_ascii_token_boundary(text[after])
		if before_ok && after_ok {return true}
		search = found + 1
	}
	return false
}

console_registry_named_value :: proc(line, name: string) -> (string, bool) {
	trimmed := strings.trim_space(line)
	separator := strings.index_byte(trimmed, '=')
	if separator <= 0 || !strings.equal_fold(strings.trim_space(trimmed[:separator]), name) {
		return "", false
	}
	return strings.trim_space(trimmed[separator + 1:]), true
}

console_registry_line_continues :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	return len(trimmed) > 0 && trimmed[len(trimmed) - 1] == '\\'
}

console_registry_hex_nibble :: proc(byte: u8) -> (u8, bool) {
	if byte >= '0' && byte <= '9' {return byte - '0', true}
	if byte >= 'a' && byte <= 'f' {return byte - 'a' + 10, true}
	if byte >= 'A' && byte <= 'F' {return byte - 'A' + 10, true}
	return 0, false
}

console_registry_u32_value :: proc(value: string) -> (u32, bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "0" || trimmed == `"0"` {return 0, true}
	separator := strings.index_byte(trimmed, ':')
	if separator <= 0 || separator + 1 >= len(trimmed) {return 0, false}
	kind := strings.trim_space(trimmed[:separator])
	payload := strings.trim_space(trimmed[separator + 1:])
	if strings.equal_fold(kind, "dword") {
		result: u32
		digits := 0
		for byte in transmute([]u8)payload {
			if byte == ' ' || byte == '\t' {continue}
			nibble, ok := console_registry_hex_nibble(byte)
			if !ok || digits >= 8 {return 0, false}
			result = result << 4 | u32(nibble)
			digits += 1
		}
		return result, digits > 0
	}
	if !strings.equal_fold(kind, "hex") && !strings.equal_fold(kind, "hex(4)") {
		return 0, false
	}
	bytes: [4]u8
	byte_count := 0
	digits := 0
	current: u8
	for byte in transmute([]u8)payload {
		if nibble, ok := console_registry_hex_nibble(byte); ok {
			if digits == 2 {return 0, false}
			current = current << 4 | nibble
			digits += 1
			continue
		}
		if byte == ',' {
			if digits != 2 || byte_count >= len(bytes) {return 0, false}
			bytes[byte_count] = current
			byte_count += 1
			current = 0
			digits = 0
			continue
		}
		if byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\\' {
			continue
		}
		return 0, false
	}
	if digits != 2 || byte_count != len(bytes) - 1 {return 0, false}
	bytes[byte_count] = current
	result := u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
	return result, true
}

console_registry_string_value :: proc(value: string) -> (string, bool) {
	trimmed := strings.trim_space(value)
	if len(trimmed) < 2 || trimmed[0] != '"' || trimmed[len(trimmed) - 1] != '"' {
		return "", false
	}
	builder := strings.builder_make(0, len(trimmed) - 2)
	index := 1
	for index < len(trimmed) - 1 {
		byte := trimmed[index]
		if byte == '\\' && index + 1 < len(trimmed) - 1 {
			next := trimmed[index + 1]
			if next == '\\' || next == '"' {
				strings.write_byte(&builder, next)
				index += 2
				continue
			}
		}
		strings.write_byte(&builder, byte)
		index += 1
	}
	return strings.to_string(builder), true
}

console_registry_hex_bytes :: proc(value: string) -> ([dynamic]u8, bool) {
	bytes := make([dynamic]u8, context.temp_allocator)
	separator := strings.index_byte(value, ':')
	if separator <= 0 || separator + 1 >= len(value) {return bytes, false}
	kind := strings.trim_space(value[:separator])
	if !strings.equal_fold(kind, "hex") && !strings.equal_fold(kind, "hex(8)") {
		return bytes, false
	}
	digits := 0
	current: u8
	for byte in transmute([]u8)value[separator + 1:] {
		if nibble, ok := console_registry_hex_nibble(byte); ok {
			if digits == 2 {return bytes, false}
			current = current << 4 | nibble
			digits += 1
			continue
		}
		if byte == ',' {
			if digits != 2 {return bytes, false}
			if len(bytes) >= DESKTOP_ENUM_RESOURCE_MAX_BYTES {return bytes, false}
			append(&bytes, current)
			current = 0
			digits = 0
			continue
		}
		if byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n' || byte == '\\' {
			continue
		}
		return bytes, false
	}
	if digits != 2 || len(bytes) >= DESKTOP_ENUM_RESOURCE_MAX_BYTES {return bytes, false}
	append(&bytes, current)
	return bytes, len(bytes) > 0
}

console_resource_u16 :: proc(bytes: []u8, offset: int) -> (u16, bool) {
	if offset < 0 || offset + 2 > len(bytes) {return 0, false}
	return u16(bytes[offset]) | u16(bytes[offset + 1]) << 8, true
}

console_resource_u32 :: proc(bytes: []u8, offset: int) -> (u32, bool) {
	if offset < 0 || offset + 4 > len(bytes) {return 0, false}
	value :=
		u32(bytes[offset]) |
		u32(bytes[offset + 1]) << 8 |
		u32(bytes[offset + 2]) << 16 |
		u32(bytes[offset + 3]) << 24
	return value, true
}

console_resource_list_irq_evidence :: proc(
	bytes: []u8,
	expected_irq: u32,
) -> (
	irq_seen, mismatch, valid: bool,
) {
	full_count, count_ok := console_resource_u32(bytes, 0)
	if !count_ok || full_count == 0 || full_count > 64 {return false, false, false}
	offset := 4
	for _ in 0 ..< int(full_count) {
		if offset + 16 > len(bytes) {return false, false, false}
		version, version_ok := console_resource_u16(bytes, offset + 8)
		revision, revision_ok := console_resource_u16(bytes, offset + 10)
		partial_count, partial_ok := console_resource_u32(bytes, offset + 12)
		version_valid := version == 1 && revision == 1 || version == 0 && revision == 0
		if !version_ok || !revision_ok || !partial_ok || !version_valid || partial_count > 4096 {
			return false, false, false
		}
		offset += 16
		if u64(partial_count) * 16 > u64(len(bytes) - offset) {return false, false, false}
		device_specific_bytes: u32
		for index in 0 ..< int(partial_count) {
			descriptor := offset + index * 16
			type := bytes[descriptor]
			if type == 2 {
				level, level_ok := console_resource_u32(bytes, descriptor + 4)
				vector, vector_ok := console_resource_u32(bytes, descriptor + 8)
				if !level_ok || !vector_ok {return false, false, false}
				irq_seen = true
				if level != expected_irq || vector != expected_irq {mismatch = true}
			} else if type == 5 && index == int(partial_count) - 1 {
				device_specific_bytes, _ = console_resource_u32(bytes, descriptor + 4)
			}
		}
		offset += int(partial_count) * 16
		if u64(device_specific_bytes) > u64(len(bytes) - offset) {
			return false, false, false
		}
		offset += int(device_specific_bytes)
	}
	return irq_seen, mismatch, offset == len(bytes)
}

console_win98_allocation_irq_evidence :: proc(
	value: string,
	expected_irq: u32,
) -> (
	irq_seen, mismatch, valid: bool,
) {
	bytes, parsed := console_registry_hex_bytes(value)
	defer delete(bytes)
	if !parsed || len(bytes) < 12 {return false, false, false}
	header, header_ok := console_resource_u32(bytes[:], 0)
	configuration_count, count_ok := console_resource_u32(bytes[:], 4)
	trailer, trailer_ok := console_resource_u32(bytes[:], len(bytes) - 4)
	if !header_ok ||
	   !count_ok ||
	   !trailer_ok ||
	   header != 0x0000_0400 ||
	   configuration_count != 1 ||
	   trailer != 0 {
		return false, false, false
	}
	offset := 8
	limit := len(bytes) - 4
	for offset < limit {
		descriptor_bytes, length_ok := console_resource_u32(bytes[:], offset)
		type, type_ok := console_resource_u32(bytes[:], offset + 4)
		if !length_ok ||
		   !type_ok ||
		   descriptor_bytes < 8 ||
		   u64(descriptor_bytes) > u64(limit - offset) {
			return false, false, false
		}
		if type == 4 {
			if descriptor_bytes != 16 {return false, false, false}
			irq, irq_ok := console_resource_u16(bytes[:], offset + 10)
			if !irq_ok {return false, false, false}
			irq_seen = true
			if u32(irq) != expected_irq {mismatch = true}
		}
		offset += int(descriptor_bytes)
	}
	return irq_seen, mismatch, offset == limit
}

Console_Enum_Evidence :: struct {
	header_seen:                 bool,
	dynamic_header_seen:         bool,
	amd_found:                   [len(DESKTOP_ENUM_REQUIRED_AMD_IDS)]bool,
	amd_active:                  [len(DESKTOP_ENUM_REQUIRED_AMD_IDS)]bool,
	amd_health_bad:              [len(DESKTOP_ENUM_REQUIRED_AMD_IDS)]bool,
	vga_found:                   bool,
	vga_active:                  bool,
	vga_health_bad:              bool,
	vga_irq11_seen:              bool,
	vga_irq_conflict:            bool,
	synthetic_chipset_seen:      bool,
	mf_child_hashes:             [DESKTOP_ENUM_MAX_MF_CHILDREN]u64,
	mf_child_static_count:       int,
	mf_child_active:             [DESKTOP_ENUM_MAX_MF_CHILDREN]bool,
	mf_child_health_bad:         [DESKTOP_ENUM_MAX_MF_CHILDREN]bool,
	mf_child_unmatched_or_extra: bool,
}

console_ascii_fold_hash :: proc(text: string) -> u64 {
	hash := u64(0xcbf2_9ce4_8422_2325)
	for byte in transmute([]u8)text {
		hash = (hash ~ u64(console_ascii_fold_byte(byte))) * u64(0x0000_0100_0000_01b3)
	}
	return hash
}

console_mf_child_hash :: proc(text: string, static_path: bool) -> (u64, bool) {
	prefix := static_path ? `\ENUM\MF\` : `MF\`
	start := console_ascii_index_fold(text, prefix)
	if start < 0 || (!static_path && start != 0) {return 0, false}
	start += len(prefix)
	end := start
	for end < len(text) && text[end] != '\\' && text[end] != ']' {end += 1}
	if end == start {return 0, false}
	return console_ascii_fold_hash(text[start:end]), true
}

console_enum_note_static_mf_child :: proc(evidence: ^Console_Enum_Evidence, hash: u64) {
	if evidence == nil || hash == 0 {return}
	for existing in evidence.mf_child_hashes[:evidence.mf_child_static_count] {
		if existing == hash {return}
	}
	if evidence.mf_child_static_count >= len(evidence.mf_child_hashes) {
		evidence.mf_child_unmatched_or_extra = true
		return
	}
	evidence.mf_child_hashes[evidence.mf_child_static_count] = hash
	evidence.mf_child_static_count += 1
}

console_enum_static_mf_index :: proc(evidence: ^Console_Enum_Evidence, hash: u64) -> int {
	if evidence == nil || hash == 0 {return -1}
	for existing, index in evidence.mf_child_hashes[:evidence.mf_child_static_count] {
		if existing == hash {return index}
	}
	return -1
}

console_enum_note_alloc_config :: proc(
	evidence: ^Console_Enum_Evidence,
	section_is_vga: bool,
	value: string,
) {
	if evidence == nil || !section_is_vga {return}
	bytes, parsed := console_registry_hex_bytes(value)
	defer delete(bytes)
	if !parsed {
		evidence.vga_irq_conflict = true
		return
	}
	seen, mismatch, valid := console_resource_list_irq_evidence(
		bytes[:],
		DESKTOP_ENUM_REQUIRED_IRQ,
	)
	if !valid || mismatch {evidence.vga_irq_conflict = true}
	if seen {evidence.vga_irq11_seen = true}
}

console_windows98_static_enum_apply :: proc(contents: string, evidence: ^Console_Enum_Evidence) {
	if evidence == nil {return}
	amd_bdfs := DESKTOP_ENUM_REQUIRED_AMD_BDFS
	section_vga_matches := false
	alloc_config := make([dynamic]u8, context.temp_allocator)
	defer delete(alloc_config)
	alloc_pending := false
	rest := contents
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw_line)
		if line == "" {continue}
		if !evidence.header_seen {
			if !strings.equal_fold(line, "REGEDIT4") {return}
			evidence.header_seen = true
			continue
		}
		if line[0] == '[' {
			if alloc_pending {
				if section_vga_matches {evidence.vga_irq_conflict = true}
				clear(&alloc_config)
				alloc_pending = false
			}
			section_vga_matches = false
			if console_ascii_contains_fold(line, `\ENUM\PCI\`) {
				for id, index in DESKTOP_ENUM_REQUIRED_AMD_IDS {
					if console_ascii_token_contains_fold(line, id) &&
					   console_ascii_token_contains_fold(line, amd_bdfs[index]) {
						evidence.amd_found[index] = true
					}
				}
				section_vga_matches =
					console_ascii_token_contains_fold(line, DESKTOP_ENUM_GSW_VGA_ID) &&
					console_ascii_token_contains_fold(line, DESKTOP_ENUM_GSW_VGA_BDF)
				if section_vga_matches {evidence.vga_found = true}
				if console_ascii_token_contains_fold(line, DESKTOP_ENUM_SYNTHETIC_CHIPSET_ID) {
					evidence.synthetic_chipset_seen = true
				}
			} else if console_ascii_contains_fold(line, `\ENUM\MF\`) &&
			   console_ascii_token_contains_fold(line, DESKTOP_ENUM_REQUIRED_AMD_IDS[2]) &&
			   console_ascii_token_contains_fold(line, DESKTOP_ENUM_REQUIRED_AMD_BDFS[2]) {
				if hash, ok := console_mf_child_hash(line, true); ok {
					console_enum_note_static_mf_child(evidence, hash)
				}
			}
			continue
		}
		if alloc_pending {
			append(&alloc_config, line)
			if console_registry_line_continues(line) {continue}
			console_enum_note_alloc_config(evidence, section_vga_matches, string(alloc_config[:]))
			clear(&alloc_config)
			alloc_pending = false
			continue
		}
		if value, present := console_registry_named_value(line, `"AllocConfig"`); present {
			append(&alloc_config, value)
			alloc_pending = console_registry_line_continues(line)
			if !alloc_pending {
				console_enum_note_alloc_config(
					evidence,
					section_vga_matches,
					string(alloc_config[:]),
				)
				clear(&alloc_config)
			}
		}
	}
	if alloc_pending && section_vga_matches {evidence.vga_irq_conflict = true}
}

console_dynamic_device_healthy :: proc(
	problem_present: bool,
	problem: u32,
	status_present: bool,
	status: u32,
) -> bool {
	return(
		problem_present &&
		problem == 0 &&
		status_present &&
		status & DESKTOP_ENUM_STATUS_STARTED != 0 &&
		status & DESKTOP_ENUM_STATUS_BAD_MASK == 0 \
	)
}

console_enum_finish_dynamic_section :: proc(
	evidence: ^Console_Enum_Evidence,
	hardware_key: string,
	problem_present: bool,
	problem: u32,
	status_present: bool,
	status: u32,
	allocation: string,
	allocation_present, allocation_complete: bool,
) {
	if evidence == nil || hardware_key == "" {return}
	amd_bdfs := DESKTOP_ENUM_REQUIRED_AMD_BDFS
	healthy := console_dynamic_device_healthy(problem_present, problem, status_present, status)
	if console_ascii_has_prefix_fold(hardware_key, `PCI\`) {
		for id, index in DESKTOP_ENUM_REQUIRED_AMD_IDS {
			if !console_ascii_token_contains_fold(hardware_key, id) ||
			   !console_ascii_token_contains_fold(hardware_key, amd_bdfs[index]) {
				continue
			}
			evidence.amd_active[index] = true
			if !healthy {evidence.amd_health_bad[index] = true}
		}
		if console_ascii_token_contains_fold(hardware_key, DESKTOP_ENUM_GSW_VGA_ID) &&
		   console_ascii_token_contains_fold(hardware_key, DESKTOP_ENUM_GSW_VGA_BDF) {
			evidence.vga_active = true
			if !healthy {evidence.vga_health_bad = true}
			if !allocation_present {
				evidence.vga_irq_conflict = true
			} else {
				if !allocation_complete {
					evidence.vga_irq_conflict = true
				} else {
					seen, mismatch, valid := console_win98_allocation_irq_evidence(
						allocation,
						DESKTOP_ENUM_REQUIRED_IRQ,
					)
					if !valid || mismatch || !seen {evidence.vga_irq_conflict = true}
					if seen {evidence.vga_irq11_seen = true}
				}
			}
		}
		if console_ascii_token_contains_fold(hardware_key, DESKTOP_ENUM_SYNTHETIC_CHIPSET_ID) {
			evidence.synthetic_chipset_seen = true
		}
		return
	}
	if !console_ascii_has_prefix_fold(hardware_key, `MF\`) ||
	   !console_ascii_token_contains_fold(hardware_key, DESKTOP_ENUM_REQUIRED_AMD_IDS[2]) ||
	   !console_ascii_token_contains_fold(hardware_key, DESKTOP_ENUM_REQUIRED_AMD_BDFS[2]) {
		return
	}
	hash, hash_ok := console_mf_child_hash(hardware_key, false)
	index := hash_ok ? console_enum_static_mf_index(evidence, hash) : -1
	if index < 0 {
		evidence.mf_child_unmatched_or_extra = true
		return
	}
	evidence.mf_child_active[index] = true
	if !healthy {evidence.mf_child_health_bad[index] = true}
}

console_windows98_dynamic_enum_apply :: proc(contents: string, evidence: ^Console_Enum_Evidence) {
	if evidence == nil {return}
	in_section := false
	hardware_key := ""
	problem_present := false
	problem: u32
	status_present := false
	status: u32
	allocation := make([dynamic]u8, context.temp_allocator)
	allocation_present := false
	allocation_pending := false
	allocation_duplicate := false
	defer delete(allocation)
	defer delete(hardware_key)
	rest := contents
	for raw_line in strings.split_lines_iterator(&rest) {
		line := strings.trim_space(raw_line)
		if line == "" {continue}
		if !evidence.dynamic_header_seen {
			if !strings.equal_fold(line, "REGEDIT4") {return}
			evidence.dynamic_header_seen = true
			continue
		}
		if line[0] == '[' {
			if in_section {
				console_enum_finish_dynamic_section(
					evidence,
					hardware_key,
					problem_present,
					problem,
					status_present,
					status,
					string(allocation[:]),
					allocation_present,
					!allocation_pending && !allocation_duplicate,
				)
			}
			delete(hardware_key)
			hardware_key = ""
			problem_present = false
			problem = 0
			status_present = false
			status = 0
			clear(&allocation)
			allocation_present = false
			allocation_pending = false
			allocation_duplicate = false
			in_section = console_ascii_contains_fold(line, `HKEY_DYN_DATA\Config Manager\Enum\`)
			continue
		}
		if !in_section {continue}
		if allocation_pending {
			append(&allocation, line)
			allocation_pending = console_registry_line_continues(line)
			continue
		}
		if value, present := console_registry_named_value(line, `"HardWareKey"`); present {
			decoded, ok := console_registry_string_value(value)
			if ok {
				delete(hardware_key)
				hardware_key = decoded
			}
			continue
		}
		if value, present := console_registry_named_value(line, `"Problem"`); present {
			problem, problem_present = console_registry_u32_value(value)
			continue
		}
		if value, present := console_registry_named_value(line, `"Status"`); present {
			status, status_present = console_registry_u32_value(value)
			continue
		}
		if value, present := console_registry_named_value(line, `"Allocation"`); present {
			if allocation_present {allocation_duplicate = true}
			allocation_present = true
			append(&allocation, value)
			allocation_pending = console_registry_line_continues(line)
		}
	}
	if in_section {
		console_enum_finish_dynamic_section(
			evidence,
			hardware_key,
			problem_present,
			problem,
			status_present,
			status,
			string(allocation[:]),
			allocation_present,
			!allocation_pending && !allocation_duplicate,
		)
	}
}

console_windows98_enum_evidence :: proc(
	contents, dynamic_contents: string,
) -> Console_Enum_Evidence {
	evidence: Console_Enum_Evidence
	console_windows98_static_enum_apply(contents, &evidence)
	console_windows98_dynamic_enum_apply(dynamic_contents, &evidence)
	return evidence
}

console_enum_evidence_valid :: proc(evidence: Console_Enum_Evidence) -> bool {
	if !evidence.header_seen ||
	   !evidence.dynamic_header_seen ||
	   evidence.synthetic_chipset_seen ||
	   !evidence.vga_found ||
	   !evidence.vga_active ||
	   evidence.vga_health_bad ||
	   !evidence.vga_irq11_seen ||
	   evidence.vga_irq_conflict ||
	   evidence.mf_child_unmatched_or_extra ||
	   evidence.mf_child_static_count != 2 {
		return false
	}
	for present, index in evidence.amd_found {
		if !present || !evidence.amd_active[index] || evidence.amd_health_bad[index] {
			return false
		}
	}
	for index in 0 ..< evidence.mf_child_static_count {
		if !evidence.mf_child_active[index] || evidence.mf_child_health_bad[index] {
			return false
		}
	}
	return true
}

console_windows98_enum_valid :: proc(contents, dynamic_contents: string) -> bool {
	return console_enum_evidence_valid(console_windows98_enum_evidence(contents, dynamic_contents))
}

console_desktop_marker_evidence :: proc(
	session: ^fat32session.Machine_Session,
) -> (
	evidence: Console_Enum_Evidence,
	marker_seen, enum_valid: bool,
) {
	if session == nil {return {}, false, false}
	probes := [?]fat32session.Probe {
		{.Read_Range, fmt.tprintf("GSWSETUP/%s", win98imageprep.DESKTOP_MARKER_FILE), 0, 64},
		{
			.Read_Range,
			fmt.tprintf("GSWSETUP/%s", win98imageprep.DESKTOP_ENUM_FILE),
			0,
			DESKTOP_ENUM_MAX_BYTES,
		},
		{
			.Read_Range,
			fmt.tprintf("GSWSETUP/%s", win98imageprep.DESKTOP_DYNAMIC_ENUM_FILE),
			0,
			DESKTOP_ENUM_MAX_BYTES,
		},
	}
	batch, observe_error := fat32session.observe(session, probes[:], context.temp_allocator)
	defer fat32session.observation_batch_destroy(&batch, context.temp_allocator)
	if observe_error.code != .None || batch.pending || len(batch.items) != len(probes) {
		return {}, false, false
	}
	marker := &batch.items[0]
	if marker.type != .Regular ||
	   marker.size == 0 ||
	   marker.size > 64 ||
	   strings.trim_space(string(marker.data)) != "READY" {
		return {}, false, false
	}
	marker_seen = true
	enumeration := &batch.items[1]
	if enumeration.type != .Regular ||
	   enumeration.size == 0 ||
	   enumeration.size > DESKTOP_ENUM_MAX_BYTES ||
	   u64(len(enumeration.data)) != enumeration.size {
		return {}, marker_seen, false
	}
	dynamic_enumeration := &batch.items[2]
	if dynamic_enumeration.type != .Regular ||
	   dynamic_enumeration.size == 0 ||
	   dynamic_enumeration.size > DESKTOP_ENUM_MAX_BYTES ||
	   u64(len(dynamic_enumeration.data)) != dynamic_enumeration.size {
		return {}, marker_seen, false
	}
	evidence = console_windows98_enum_evidence(
		string(enumeration.data),
		string(dynamic_enumeration.data),
	)
	enum_valid = console_enum_evidence_valid(evidence)
	return
}

console_desktop_marker_exists :: proc(session: ^fat32session.Machine_Session) -> bool {
	_, marker_seen, enum_valid := console_desktop_marker_evidence(session)
	return marker_seen && enum_valid
}

console_result_refresh_desktop_evidence :: proc(
	result: ^acceptance.Result,
	session: ^fat32session.Machine_Session,
) {
	if result == nil {return}
	evidence, marker_seen, enum_valid := console_desktop_marker_evidence(session)
	result.desktop_marker_seen = marker_seen
	result.desktop_enum_valid = enum_valid
	result.desktop_vga_irq11_seen = evidence.vga_irq11_seen
}

console_acceptance_enforce_result_invariants :: proc(
	options: ^acceptance.Options,
	result: ^acceptance.Result,
	return_code: ^int,
) {
	if options == nil ||
	   result == nil ||
	   options.accept_until == .None ||
	   result.stop_reason != .Acceptance_Reached {
		return
	}
	reset_epochs_valid :=
		result.boot_epoch > 0 &&
		result.boot_epoch - 1 == result.guest_requested_resets &&
		result.reset_count == result.guest_requested_resets
	if !reset_epochs_valid {
		result.last_progress_reason = "reset_epoch_mismatch"
	} else if options.accept_until == .Desktop &&
	   (!result.desktop_marker_seen ||
			   !result.desktop_enum_valid ||
			   !result.desktop_vga_irq11_seen ||
			   result.desktop_primary_ide_dma_transactions == 0 ||
			   result.desktop_primary_ide_dma_bytes == 0) {
		result.last_progress_reason = "desktop_evidence_lost"
	} else {
		return
	}
	result.stop_reason = .Fatal_Virtualization_Failure
	result.exit_code = 2
	if return_code != nil {return_code^ = 2}
}

CONSOLE_ARTIFACT_LOG_BYTES :: 32 * 1024

console_artifact_append_log :: proc(
	builder: ^strings.Builder,
	item: ^fat32session.Observation,
	label: string,
) {
	if builder == nil || item == nil || item.type != .Regular || len(item.data) == 0 {return}
	fmt.sbprintfln(
		builder,
		"\nsetup-log %s (last %d of %d bytes):",
		label,
		len(item.data),
		item.size,
	)
	fmt.sbprintfln(builder, "%s", string(item.data))
}

console_artifact_append_setup_logs :: proc(
	builder: ^strings.Builder,
	session: ^fat32session.Machine_Session,
) {
	if builder == nil || session == nil {return}
	roots := [?]struct {
		path, label: string,
	}{{"", "C:\\"}, {"WINDOWS/", "C:\\WINDOWS\\"}}
	names := [?]string{"SETUPLOG.TXT", "DETLOG.TXT", "DETCRASH.LOG"}
	probes: [len(roots) * len(names)]fat32session.Probe
	labels: [len(probes)]string
	index := 0
	for root in roots {
		for name in names {
			probes[index] = fat32session.Probe {
				kind   = .Read_Tail,
				path   = fmt.tprintf("%s%s", root.path, name),
				length = CONSOLE_ARTIFACT_LOG_BYTES,
			}
			labels[index] = fmt.tprintf("%s%s", root.label, name)
			index += 1
		}
	}
	batch, observe_error := fat32session.observe(session, probes[:], context.temp_allocator)
	defer fat32session.observation_batch_destroy(&batch, context.temp_allocator)
	if observe_error.code != .None || batch.pending {return}
	for &item, item_index in batch.items {
		console_artifact_append_log(builder, &item, labels[item_index])
	}
}

console_artifact_append_legacy_histories :: proc(builder: ^strings.Builder, m: ^machine.Machine) {
	if builder == nil || m == nil {return}
	if m.diagnostic_tracing {
		io_count := int(min(m.io_count, u64(machine.IO_HISTORY)))
		fmt.sbprintfln(builder, "recent I/O (%d):", io_count)
		for i in 0 ..< io_count {
			index := (m.io_count - u64(io_count) + u64(i)) % machine.IO_HISTORY
			trace := m.io_hist[index]
			fmt.sbprintfln(
				builder,
				"  %s %04x size=%d value=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.val,
			)
		}
	} else {
		fmt.sbprintln(builder, "recent I/O: unavailable (diagnostic tracing disabled)")
	}
	if m.bus.diagnostic_tracing {
		fmt.sbprintfln(
			builder,
			"first kernel IDE probe accesses (%d captured of %d):",
			m.ide_kernel_probe_count,
			m.ide_kernel_probe_total,
		)
		for i in 0 ..< int(m.ide_kernel_probe_count) {
			trace := m.ide_kernel_probe_hist[i]
			fmt.sbprintfln(
				builder,
				"  %s %04x size=%d value=%08x elements=%d repeats=%d pm=%t cpl=%d cs=%04x linear=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.value,
				trace.elements,
				trace.repeats,
				trace.protected_mode,
				trace.cpl,
				trace.cs,
				trace.linear,
			)
		}
		ide_count := int(min(m.ide_count, u64(machine.IDE_HISTORY)))
		fmt.sbprintfln(builder, "recent IDE I/O (%d of %d):", ide_count, m.ide_count)
		for i in 0 ..< ide_count {
			index := (m.ide_count - u64(ide_count) + u64(i)) % machine.IDE_HISTORY
			trace := m.ide_hist[index]
			fmt.sbprintfln(
				builder,
				"  %s %04x size=%d value=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.val,
			)
		}
		command_count := int(min(m.cmd_count, u64(machine.IDE_HISTORY)))
		fmt.sbprintfln(builder, "recent IDE commands (%d of %d):", command_count, m.cmd_count)
		for i in 0 ..< command_count {
			index := (m.cmd_count - u64(command_count) + u64(i)) % machine.IDE_HISTORY
			trace := m.cmd_hist[index]
			fmt.sbprintfln(
				builder,
				"  command=%02x drive=%02x count=%d lba=%08x",
				trace.cmd,
				trace.drive,
				trace.count,
				trace.lba,
			)
		}
	}
	if m.bus.diagnostic_tracing {
		unclassified_count := int(
			min(m.bus.unclassified_count, u64(machine.BUS_UNCLASSIFIED_HISTORY)),
		)
		fmt.sbprintfln(builder, "recent unclassified I/O (%d):", unclassified_count)
		for i in 0 ..< unclassified_count {
			index :=
				(m.bus.unclassified_count - u64(unclassified_count) + u64(i)) %
				machine.BUS_UNCLASSIFIED_HISTORY
			trace := m.bus.unclassified_history[index]
			fmt.sbprintfln(
				builder,
				"  %s %04x size=%d value=%08x",
				trace.write ? "out" : "in",
				trace.port,
				trace.size,
				trace.value,
			)
		}
		mmio_count := int(
			min(m.bus.unclassified_mmio_count, u64(machine.BUS_UNCLASSIFIED_MMIO_HISTORY)),
		)
		fmt.sbprintfln(builder, "recent unclassified MMIO (%d):", mmio_count)
		for i in 0 ..< mmio_count {
			index :=
				(m.bus.unclassified_mmio_count - u64(mmio_count) + u64(i)) %
				machine.BUS_UNCLASSIFIED_MMIO_HISTORY
			trace := m.bus.unclassified_mmio_history[index]
			fmt.sbprintfln(
				builder,
				"  %s gpa=%016x size=%d",
				trace.write ? "write" : "read",
				trace.gpa,
				trace.size,
			)
		}
	} else {
		fmt.sbprintln(
			builder,
			"recent unclassified I/O: unavailable (diagnostic tracing disabled)",
		)
		fmt.sbprintln(
			builder,
			"recent unclassified MMIO: unavailable (diagnostic tracing disabled)",
		)
	}
}

console_artifact_append_uart :: proc(
	builder: ^strings.Builder,
	label: string,
	uart: ^machine.Uart_16450,
) {
	output := machine.uart_output(uart)
	fmt.sbprintfln(
		builder,
		"%s serial captured=%d dropped=%d:",
		label,
		len(output),
		machine.uart_output_dropped(uart),
	)
	for byte in output {
		switch byte {
		case '\r':
			fmt.sbprintf(builder, "\\r")
		case '\n':
			fmt.sbprintln(builder)
		case '\t':
			fmt.sbprintf(builder, "\\t")
		case '\\':
			fmt.sbprintf(builder, "\\\\")
		case:
			if byte >= 0x20 && byte < 0x7f {
				fmt.sbprintf(builder, "%c", byte)
			} else {
				fmt.sbprintf(builder, "\\x%02x", byte)
			}
		}
	}
	fmt.sbprintln(builder)
}

console_artifact_diagnostics :: proc(
	result: ^acceptance.Result,
	m: ^machine.Machine,
	firmware_text: string,
	session: ^fat32session.Machine_Session,
) -> string {
	builder := strings.builder_make()
	fmt.sbprintfln(&builder, "stop_reason=%s", acceptance.stop_reason_name(result.stop_reason))
	fmt.sbprintfln(&builder, "exit_code=%d", result.exit_code)
	fmt.sbprintfln(
		&builder,
		"master_ticks=%d wall_ms=%d",
		result.master_ticks,
		result.wall_milliseconds,
	)
	fmt.sbprintfln(
		&builder,
		"progress=%s boot_epoch=%d guest_resets=%d desktop_marker=%v enum_valid=%v vga_irq11=%v",
		result.last_progress_reason,
		result.boot_epoch,
		result.guest_requested_resets,
		result.desktop_marker_seen,
		result.desktop_enum_valid,
		result.desktop_vga_irq11_seen,
	)
	fmt.sbprintfln(
		&builder,
		"wake_guard generations=%d callbacks=%d retries=%d cancels=%d stale=%d dropped=%d",
		result.wake_guard.generations,
		result.wake_guard.callbacks,
		result.wake_guard.retry_callbacks,
		result.wake_guard.cancel_calls,
		result.wake_guard.stale_callbacks,
		result.wake_guard.evidence_dropped,
	)
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
		"primary-ide-bmide transactions=%d bytes=%d",
		result.execution.primary_ide_dma_transactions,
		result.execution.primary_ide_dma_bytes,
	)
	fmt.sbprintfln(
		&builder,
		"primary-ide-kernel-bmide transactions=%d bytes=%d; desktop-epoch transactions=%d bytes=%d",
		result.execution.primary_ide_kernel_dma_transactions,
		result.execution.primary_ide_kernel_dma_bytes,
		result.desktop_primary_ide_dma_transactions,
		result.desktop_primary_ide_dma_bytes,
	)
	fmt.sbprintfln(
		&builder,
		"audio produced=%d consumed=%d depth=%d..%d underrun_frames=%d events=%d recoveries=%d gap=%d ramp=%d overruns=%d late=%d max_late_us=%d",
		result.audio.frames_produced,
		result.audio.frames_consumed,
		result.audio.queue_min_depth,
		result.audio.queue_max_depth,
		result.audio.underruns,
		result.audio.underrun_events,
		result.audio.underrun_recoveries,
		result.audio.gap_frames,
		result.audio.ramp_down_frames,
		result.audio.overruns,
		result.audio.late_callbacks,
		result.audio.max_callback_lateness_us,
	)
	fmt.sbprintfln(
		&builder,
		"audio proof clip=%d speaker_edges=%d late_edges=%d overflow_edges=%d scheduler_wakeups=%d pcm_fnv1a64=%016x",
		result.audio.clipping_frames,
		result.audio.speaker_edges,
		result.audio.speaker_late_edges,
		result.audio.speaker_overflow_edges,
		result.audio.scheduler_wakeups,
		result.audio.pcm_fnv1a64,
	)
	fmt.sbprintfln(
		&builder,
		"audio sources speaker=%d/%d sb16=%d/%d starve=%d irq=%d opl3=%d/%d native=%d/%d starve=%d irq=%d cdda=%d/%d",
		result.audio.pc_speaker.frames_produced,
		result.audio.pc_speaker.nonzero_frames,
		result.audio.sb16.frames_produced,
		result.audio.sb16.nonzero_frames,
		result.audio.sb16.starvation_frames,
		result.audio.sb16.irq_events,
		result.audio.opl3.frames_produced,
		result.audio.opl3.nonzero_frames,
		result.audio.native_pcm.frames_produced,
		result.audio.native_pcm.nonzero_frames,
		result.audio.native_pcm.starvation_frames,
		result.audio.native_pcm.irq_events,
		result.audio.cdda.frames_produced,
		result.audio.cdda.nonzero_frames,
	)
	if m != nil {
		fmt.sbprintfln(&builder, "freeze=%s", m.bus.freeze_msg)
		registers := format_regs(hv.get_regs(&m.vm), m)
		fmt.sbprintfln(&builder, "%s", registers)
		delete(registers)
		fmt.sbprintfln(
			&builder,
			"PIC master irr=%02x isr=%02x imr=%02x asserted=%02x elcr=%02x auto_eoi=%t init=%v; slave irr=%02x isr=%02x imr=%02x asserted=%02x elcr=%02x auto_eoi=%t init=%v",
			m.pic.master.irr,
			m.pic.master.isr,
			m.pic.master.imr,
			m.pic.master.asserted,
			m.pic.master.elcr,
			m.pic.master.auto_eoi,
			m.pic.master.init,
			m.pic.slave.irr,
			m.pic.slave.isr,
			m.pic.slave.imr,
			m.pic.slave.asserted,
			m.pic.slave.elcr,
			m.pic.slave.auto_eoi,
			m.pic.slave.init,
		)
		fmt.sbprintfln(
			&builder,
			"PIC delivery queued=%t vector=%02x machine=%d/%d whpx=%d/%d pending_exits=%d",
			m.pic_offer_queued,
			m.pic_queued_offer.vector,
			m.pic_queue_count,
			m.pic_delivery_count,
			m.vm.irq_queue_count,
			m.vm.irq_delivery_count,
			m.vm.irq_pending_exit_count,
		)
		fmt.sbprintfln(
			&builder,
			"PIC queue pending_event_deferrals=%d deferred_event=%016x:%016x last_event=%016x CS=%04x:%08x linear=%08x",
			m.vm.irq_pending_event_deferrals,
			m.vm.irq_pending_event_high,
			m.vm.irq_pending_event_low,
			m.vm.irq_queue_event,
			m.vm.irq_queue_cs,
			m.vm.irq_queue_rip,
			m.vm.irq_queue_cs_base + m.vm.irq_queue_rip,
		)
		fmt.sbprintfln(
			&builder,
			"PIC last delivery reason=%d state=%04x pending=%016x CS=%04x:%08x linear=%08x RFLAGS=%08x",
			m.vm.irq_delivery_reason,
			m.vm.irq_delivery_state,
			m.vm.irq_delivery_pending,
			m.vm.irq_delivery_cs,
			m.vm.irq_delivery_rip,
			m.vm.irq_delivery_cs_base + m.vm.irq_delivery_rip,
			m.vm.irq_delivery_rflags,
		)
		fmt.sbprintf(
			&builder,
			"PIC last delivery I/O port=%04x access=%08x RAX=%08x instruction=",
			m.vm.irq_delivery_io_port,
			m.vm.irq_delivery_io_access,
			m.vm.irq_delivery_io_rax,
		)
		for index in 0 ..< int(m.vm.irq_delivery_ins_len) {
			fmt.sbprintf(&builder, "%02x", m.vm.irq_delivery_ins[index])
		}
		fmt.sbprintln(&builder)
		idtr_name := hv.WHV_REGISTER_NAME.Idtr
		idtr_value: hv.WHV_REGISTER_VALUE
		if hv.WHvGetVirtualProcessorRegisters(m.vm.part, 0, &idtr_name, 1, &idtr_value) >= 0 {
			gate: [8]u8
			gate_linear := idtr_value.Table.Base + 0x50 * 8
			if hv.linear_read(&m.vm, gate_linear, gate[:]) {
				fmt.sbprintf(
					&builder,
					"IDTR base=%08x limit=%04x vector50=",
					idtr_value.Table.Base,
					idtr_value.Table.Limit,
				)
				for byte in gate {fmt.sbprintf(&builder, "%02x", byte)}
				fmt.sbprintln(&builder)
			}
		}
		trace_stats := machine.machine_hardware_trace_stats(m)
		fmt.sbprintfln(
			&builder,
			"wake mode=%v scheduled=%v generation=%d deadline=%d trace observed=%d retained=%d suppressed=%d",
			m.wake_mode,
			m.wake_scheduled,
			m.wake_generation,
			m.wake_deadline,
			trace_stats.observed,
			trace_stats.retained,
			trace_stats.suppressed,
		)
		if m.scheduler.count > 0 {
			event := m.scheduler.heap[0]
			fmt.sbprintfln(&builder, "scheduler next=%v deadline=%d", event.device, event.deadline)
		}
		fmt.sbprintln(&builder, "PIT:")
		for channel, index in m.pit.ch {
			fmt.sbprintfln(
				&builder,
				"  ch%d mode=%d rw=%d reload=%04x active=%04x count=%05x null=%v gate=%v out=%v state=%v",
				index,
				channel.mode,
				channel.rw_mode,
				channel.reload,
				channel.active_reload,
				channel.count,
				channel.null_count,
				channel.gate,
				channel.out,
				channel.state,
			)
		}
		fmt.sbprintfln(
			&builder,
			"storage irq ide=%v atapi=%v bmide_status=%02x/%02x",
			disk.ide_interrupt_pending(&m.ide),
			disk.atapi_interrupt_pending(&m.atapi),
			m.bmide.channels[0].status,
			m.bmide.channels[1].status,
		)
		ide_pci := &m.pci.functions[machine.PCI_IDE_FUNCTION_INDEX]
		fmt.sbprintfln(
			&builder,
			"ide mode=%02x pci command=%02x%02x prog-if=%02x bar4=%02x%02x%02x%02x " +
			"cfg40=%02x cfg41=%02x timing48-4f=%02x%02x%02x%02x/%02x%02x%02x%02x " +
			"udma50-53=%02x%02x%02x%02x",
			m.ide.transfer_mode,
			ide_pci.cfg[5],
			ide_pci.cfg[4],
			ide_pci.cfg[9],
			ide_pci.cfg[0x23],
			ide_pci.cfg[0x22],
			ide_pci.cfg[0x21],
			ide_pci.cfg[0x20],
			ide_pci.cfg[0x40],
			ide_pci.cfg[0x41],
			ide_pci.cfg[0x48],
			ide_pci.cfg[0x49],
			ide_pci.cfg[0x4A],
			ide_pci.cfg[0x4B],
			ide_pci.cfg[0x4C],
			ide_pci.cfg[0x4D],
			ide_pci.cfg[0x4E],
			ide_pci.cfg[0x4F],
			ide_pci.cfg[0x50],
			ide_pci.cfg[0x51],
			ide_pci.cfg[0x52],
			ide_pci.cfg[0x53],
		)
		fmt.sbprintfln(
			&builder,
			"RTC index=%02x A=%02x B=%02x C=%02x D=%02x irq_edge=%v nmi_disabled=%v",
			m.cmos.index,
			m.cmos.ram[0x0A],
			m.cmos.ram[0x0B],
			m.cmos.ram[0x0C],
			m.cmos.ram[0x0D],
			m.cmos.irq_edge_pending,
			m.cmos.nmi_disabled,
		)
		keyboard := machine.i8042_diagnostics(&m.kbd)
		fmt.sbprintfln(
			&builder,
			"i8042 queued=%d keyboard=%d auxiliary=%d obf=%v aux=%v ibf=%v a20=%v",
			keyboard.queued,
			keyboard.keyboard_queued,
			keyboard.auxiliary_queued,
			keyboard.output_full,
			keyboard.output_aux,
			keyboard.input_busy,
			m.kbd.a20,
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
		console_artifact_append_uart(&builder, "COM1", &m.serial1)
		console_artifact_append_uart(&builder, "COM2", &m.serial2)
		console_artifact_append_legacy_histories(&builder, m)
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
		columns := vga.text_snapshot_columns(&text)
		rows := vga.text_snapshot_rows(&text)
		for row in 0 ..< rows {
			line: [vga.TEXT_SNAPSHOT_MAX_COLUMNS]u8
			for col in 0 ..< columns {
				cell := u8(text.cells[vga.text_snapshot_cell_index(&text, row, col)])
				line[col] = cell >= 0x20 && cell < 0x7F ? cell : ' '
			}
			fmt.sbprintfln(&builder, "%s", string(line[:columns]))
		}
	}
	if session != nil {console_artifact_append_setup_logs(&builder, session)}
	fmt.sbprintfln(&builder, "\nfirmware:\n%s", firmware_text)
	return strings.to_string(builder)
}

console_acceptance_finalize :: proc(
	options: ^acceptance.Options,
	run_result: ^acceptance.Result,
	m: ^machine.Machine,
	machine_live: ^bool,
	firmware: ^Firmware_Log,
	session: ^^fat32session.Machine_Session,
	paths: ^profile.Paths,
	start: time.Tick,
	return_code: ^int,
	machine_segment_accumulated: ^bool = nil,
) {
	if options == nil || run_result == nil {return}
	active_session := session != nil ? session^ : nil
	live := machine_live != nil && machine_live^
	defer if !live && m != nil {
		orphan_trace := machine.machine_hardware_trace_detach(m)
		if orphan_trace != nil {free(orphan_trace)}
	}
	if live {
		#partial switch run_result.stop_reason {
		case .Strict_IO_Failure, .Fatal_Virtualization_Failure, .No_Progress:
			machine.machine_trace_record(m, .Freeze, u64(run_result.stop_reason))
		case .Timeout:
			machine.machine_trace_record(m, .Progress, u64(run_result.stop_reason))
		}
		_ = console_result_accumulate_machine_segment(run_result, m, machine_segment_accumulated)
		frame := machine.machine_display_frame(m)
		run_result.frame_crc = acceptance.frame_crc32(frame.pixels, frame.width, frame.height)
	}
	run_result.wall_milliseconds = u64(
		max(time.Duration(0), time.tick_diff(start, time.tick_now())) / time.Millisecond,
	)
	if run_result.installation_milestone == "" {
		run_result.installation_milestone = "none"
	}
	if paths != nil {
		state, diagnostic := profile.install_state_load(paths.install_state)
		if diagnostic == .None && run_result.installation_milestone == "none" {
			run_result.installation_milestone = console_install_milestone_name(state.milestone)
		}
		profile.install_state_destroy(&state)
		if options.accept_until == .Desktop && active_session != nil {
			console_result_refresh_desktop_evidence(run_result, active_session)
		}
	}
	console_acceptance_enforce_result_invariants(options, run_result, return_code)
	trace_count := machine.machine_hardware_trace_count(m)
	run_result.hardware_trace_path = ""
	if console_acceptance_should_write_artifacts(options, run_result, trace_count) {
		artifact_directory := console_acceptance_artifact_directory(options, run_result)
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
			active_session,
		)
		defer delete(diagnostics)
		hardware_trace := machine.machine_hardware_trace_text(m)
		defer if hardware_trace != "" {delete(hardware_trace)}
		pixels: []u32
		width, height := 0, 0
		if frame != nil {pixels, width, height = frame.pixels, frame.width, frame.height}
		diagnostic := acceptance.artifact_write_bundle(
			artifact_directory,
			diagnostics,
			pixels,
			width,
			height,
			hardware_trace,
		)
		if diagnostic != .None {
			fmt.eprintfln("acceptance artifact write failed: %v", diagnostic)
			if run_result.exit_code == 0 {
				run_result.stop_reason = .Configuration_Error
				run_result.last_progress_reason = "artifact_write_failed"
				run_result.exit_code = 2
			}
			if return_code != nil && return_code^ == 0 {return_code^ = 2}
		} else if hardware_trace != "" {
			run_result.hardware_trace_path = "hardware-trace.txt"
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

console_log_total_size :: proc(session: ^fat32session.Machine_Session, names: []string) -> i64 {
	if session == nil || len(names) == 0 {return 0}
	probes := make([]fat32session.Probe, len(names) * 2, context.temp_allocator)
	index := 0
	roots := [?]string{"", "WINDOWS/"}
	for prefix in roots {
		for name in names {
			probes[index] = fat32session.Probe {
				kind = .Stat,
				path = fmt.tprintf("%s%s", prefix, name),
			}
			index += 1
		}
	}
	batch, observe_error := fat32session.observe(session, probes, context.temp_allocator)
	defer fat32session.observation_batch_destroy(&batch, context.temp_allocator)
	if observe_error.code != .None || batch.pending {return 0}
	total: i64
	for item in batch.items {
		if item.type == .Regular && item.size > 0 {total += i64(item.size)}
	}
	return total
}
