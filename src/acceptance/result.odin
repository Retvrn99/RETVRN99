// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:unicode/utf8"

RESULT_SCHEMA_VERSION :: 3
RESULT_MAX_BYTES :: 64 * 1024
RESULT_MAX_HASHES :: 32
RESULT_MAX_RESETS :: 16
RESULT_MAX_LABEL_BYTES :: 96

Stop_Reason :: enum {
	None,
	Power_Off,
	Reset,
	Test_Exit,
	Strict_IO_Failure,
	Timeout,
	No_Progress,
	Fatal_Virtualization_Failure,
	Acceptance_Reached,
	Configuration_Error,
}

Workload_Hash :: struct {
	name:   string,
	sha256: string,
}

Audio_Result :: struct {
	frames_produced:          u64,
	frames_consumed:          u64,
	queue_min_depth:          u64,
	queue_max_depth:          u64,
	underruns:                u64,
	overruns:                 u64,
	late_callbacks:           u64,
	max_callback_lateness_us: u64,
}

Execution_Result :: struct {
	hypervisor_runs:              u64,
	hypervisor_cancellations:     u64,
	timer_arms:                   u64,
	scheduler_dispatches:         u64,
	device_advances:              u64,
	storage_transactions:         u64,
	storage_host_calls:           u64,
	storage_bytes:                u64,
	primary_ide_dma_transactions: u64,
	primary_ide_dma_bytes:        u64,
	audio_blocks:                 u64,
	scanout_copies:               u64,
	full_frame_renders:           u64,
	software_rendered_pixels:     u64,
}

Wake_Guard_Result :: struct {
	generations:      u64,
	callbacks:        u64,
	retry_callbacks:  u64,
	cancel_calls:     u64,
	stale_callbacks:  u64,
	evidence_dropped: u64,
}

Result :: struct {
	stop_reason:            Stop_Reason,
	exit_code:              int,
	test_exit_code:         u8,
	master_ticks:           u64,
	wall_milliseconds:      u64,
	cpu_mode:               string,
	reset_count:            u64,
	boot_epoch:             u64,
	guest_requested_resets: u64,
	reset_history:          [RESULT_MAX_RESETS]string,
	reset_history_count:    int,
	irq_injections:         u64,
	dma_units:              u64,
	modeled_io:             u64,
	passive_io:             u64,
	unclassified_io:        u64,
	unclassified_mmio:      u64,
	frame_crc:              u32,
	audio:                  Audio_Result,
	execution:              Execution_Result,
	wake_guard:             Wake_Guard_Result,
	installation_milestone: string,
	desktop_marker_seen:    bool,
	desktop_enum_valid:     bool,
	desktop_vga_irq11_seen: bool,
	last_progress_reason:   string,
	hardware_trace_path:    string,
	workload_hashes:        [RESULT_MAX_HASHES]Workload_Hash,
	workload_hash_count:    int,
}

Result_Diagnostic :: enum {
	None,
	Invalid_Path,
	Invalid_Data,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Encode_Failed,
	Too_Large,
	Write_Failed,
	Replace_Failed,
}

@(private = "file")
Disk_Result :: struct {
	version:                int `json:"version"`,
	stop_reason:            string `json:"stop_reason"`,
	exit_code:              int `json:"exit_code"`,
	test_exit_code:         u8 `json:"test_exit_code"`,
	master_ticks:           u64 `json:"master_ticks"`,
	wall_milliseconds:      u64 `json:"wall_milliseconds"`,
	cpu_mode:               string `json:"cpu_mode"`,
	reset_count:            u64 `json:"reset_count"`,
	boot_epoch:             u64 `json:"boot_epoch"`,
	guest_requested_resets: u64 `json:"guest_requested_resets"`,
	reset_history:          []string `json:"reset_history"`,
	irq_injections:         u64 `json:"irq_injections"`,
	dma_units:              u64 `json:"dma_units"`,
	modeled_io:             u64 `json:"modeled_io"`,
	passive_io:             u64 `json:"passive_io"`,
	unclassified_io:        u64 `json:"unclassified_io"`,
	unclassified_mmio:      u64 `json:"unclassified_mmio"`,
	frame_crc:              u32 `json:"frame_crc"`,
	audio:                  Audio_Result `json:"audio"`,
	execution:              Execution_Result `json:"execution"`,
	wake_guard:             Wake_Guard_Result `json:"wake_guard"`,
	installation_milestone: string `json:"installation_milestone"`,
	desktop_marker_seen:    bool `json:"desktop_marker_seen"`,
	desktop_enum_valid:     bool `json:"desktop_enum_valid"`,
	desktop_vga_irq11_seen: bool `json:"desktop_vga_irq11_seen"`,
	last_progress_reason:   string `json:"last_progress_reason"`,
	hardware_trace_path:    string `json:"hardware_trace_path"`,
	workload_hashes:        []Workload_Hash `json:"workload_hashes"`,
}

stop_reason_name :: proc(reason: Stop_Reason) -> string {
	switch reason {
	case .None:
		return "none"
	case .Power_Off:
		return "power_off"
	case .Reset:
		return "reset"
	case .Test_Exit:
		return "test_exit"
	case .Strict_IO_Failure:
		return "strict_io_failure"
	case .Timeout:
		return "timeout"
	case .No_Progress:
		return "no_progress"
	case .Fatal_Virtualization_Failure:
		return "fatal_virtualization_failure"
	case .Acceptance_Reached:
		return "acceptance_reached"
	case .Configuration_Error:
		return "configuration_error"
	}
	return "unknown"
}

@(private = "file")
result_bound :: proc(value: string) -> string {
	if len(value) <= RESULT_MAX_LABEL_BYTES {return value}
	end := 0
	for end < len(value) {
		_, width := utf8.decode_rune_in_string(value[end:])
		if width <= 0 || end + width > RESULT_MAX_LABEL_BYTES {break}
		end += width
	}
	return value[:end]
}

@(private = "file")
result_hash_valid :: proc(value: string) -> bool {
	if len(value) != 64 {return false}
	for byte in transmute([]u8)value {
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')) {return false}
	}
	return true
}

@(private = "file")
result_hardware_trace_path_valid :: proc(value: string) -> bool {
	return value == "" || value == "hardware-trace.txt"
}

@(private = "file")
result_atomic_write :: proc(path: string, payload: []u8) -> Result_Diagnostic {
	directory := filepath.dir(path)
	if os.make_directory_all(directory) != nil {return .Create_Directory_Failed}
	temporary_name := fmt.tprintf(".acceptance-result.%d.tmp", os.get_pid())
	temporary, err := filepath.join({directory, temporary_name})
	if err != nil {return .Temporary_Path_Failed}
	defer delete(temporary)
	defer _ = os.remove(temporary)
	if os.write_entire_file(temporary, payload) != nil {return .Write_Failed}
	if os.rename(temporary, path) != nil {return .Replace_Failed}
	return .None
}

result_save :: proc(path: string, result: ^Result) -> Result_Diagnostic {
	if path == "" || result == nil {return .Invalid_Path}
	if !utf8.valid_string(result.cpu_mode) ||
	   !utf8.valid_string(result.installation_milestone) ||
	   !utf8.valid_string(result.last_progress_reason) ||
	   !utf8.valid_string(result.hardware_trace_path) ||
	   !result_hardware_trace_path_valid(result.hardware_trace_path) {
		return .Invalid_Data
	}
	reset_count := clamp(result.reset_history_count, 0, RESULT_MAX_RESETS)
	hash_count := clamp(result.workload_hash_count, 0, RESULT_MAX_HASHES)
	resets: [RESULT_MAX_RESETS]string
	for value, index in result.reset_history[:reset_count] {
		if !utf8.valid_string(value) {return .Invalid_Data}
		resets[index] = result_bound(value)
	}
	hashes: [RESULT_MAX_HASHES]Workload_Hash
	for value, index in result.workload_hashes[:hash_count] {
		if value.name == "" || !utf8.valid_string(value.name) || !result_hash_valid(value.sha256) {
			return .Invalid_Data
		}
		hashes[index] = {
			name   = result_bound(value.name),
			sha256 = result_bound(value.sha256),
		}
	}
	disk := Disk_Result {
		version                = RESULT_SCHEMA_VERSION,
		stop_reason            = stop_reason_name(result.stop_reason),
		exit_code              = result.exit_code,
		test_exit_code         = result.test_exit_code,
		master_ticks           = result.master_ticks,
		wall_milliseconds      = result.wall_milliseconds,
		cpu_mode               = result_bound(result.cpu_mode),
		reset_count            = result.reset_count,
		boot_epoch             = result.boot_epoch,
		guest_requested_resets = result.guest_requested_resets,
		reset_history          = resets[:reset_count],
		irq_injections         = result.irq_injections,
		dma_units              = result.dma_units,
		modeled_io             = result.modeled_io,
		passive_io             = result.passive_io,
		unclassified_io        = result.unclassified_io,
		unclassified_mmio      = result.unclassified_mmio,
		frame_crc              = result.frame_crc,
		audio                  = result.audio,
		execution              = result.execution,
		wake_guard             = result.wake_guard,
		installation_milestone = result_bound(result.installation_milestone),
		desktop_marker_seen    = result.desktop_marker_seen,
		desktop_enum_valid     = result.desktop_enum_valid,
		desktop_vga_irq11_seen = result.desktop_vga_irq11_seen,
		last_progress_reason   = result_bound(result.last_progress_reason),
		hardware_trace_path    = result_bound(result.hardware_trace_path),
		workload_hashes        = hashes[:hash_count],
	}
	payload, err := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {return .Encode_Failed}
	defer delete(payload)
	if len(payload) > RESULT_MAX_BYTES {return .Too_Large}
	return result_atomic_write(path, payload)
}
