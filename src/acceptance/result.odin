// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:unicode/utf8"

RESULT_SCHEMA_VERSION :: 2
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
	hypervisor_runs:          u64,
	hypervisor_cancellations: u64,
	timer_arms:               u64,
	scheduler_dispatches:     u64,
	device_advances:          u64,
	storage_transactions:     u64,
	storage_host_calls:       u64,
	storage_bytes:            u64,
	audio_blocks:             u64,
	scanout_copies:           u64,
	full_frame_renders:       u64,
	software_rendered_pixels: u64,
}

Result :: struct {
	stop_reason:           Stop_Reason,
	exit_code:             int,
	test_exit_code:        u8,
	master_ticks:          u64,
	wall_milliseconds:     u64,
	cpu_mode:              string,
	reset_count:           u64,
	reset_history:         [RESULT_MAX_RESETS]string,
	reset_history_count:   int,
	irq_injections:        u64,
	dma_units:             u64,
	modeled_io:            u64,
	passive_io:            u64,
	unclassified_io:       u64,
	unclassified_mmio:     u64,
	frame_crc:             u32,
	audio:                 Audio_Result,
	execution:             Execution_Result,
	installation_milestone: string,
	workload_hashes:       [RESULT_MAX_HASHES]Workload_Hash,
	workload_hash_count:   int,
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
	installation_milestone: string `json:"installation_milestone"`,
	workload_hashes:        []Workload_Hash `json:"workload_hashes"`,
}

stop_reason_name :: proc(reason: Stop_Reason) -> string {
	switch reason {
	case .None: return "none"
	case .Power_Off: return "power_off"
	case .Reset: return "reset"
	case .Test_Exit: return "test_exit"
	case .Strict_IO_Failure: return "strict_io_failure"
	case .Timeout: return "timeout"
	case .Fatal_Virtualization_Failure: return "fatal_virtualization_failure"
	case .Acceptance_Reached: return "acceptance_reached"
	case .Configuration_Error: return "configuration_error"
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
	if !utf8.valid_string(result.cpu_mode) || !utf8.valid_string(result.installation_milestone) {
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
		hashes[index] = {name = result_bound(value.name), sha256 = result_bound(value.sha256)}
	}
	disk := Disk_Result {
		version = RESULT_SCHEMA_VERSION,
		stop_reason = stop_reason_name(result.stop_reason),
		exit_code = result.exit_code,
		test_exit_code = result.test_exit_code,
		master_ticks = result.master_ticks,
		wall_milliseconds = result.wall_milliseconds,
		cpu_mode = result_bound(result.cpu_mode),
		reset_count = result.reset_count,
		reset_history = resets[:reset_count],
		irq_injections = result.irq_injections,
		dma_units = result.dma_units,
		modeled_io = result.modeled_io,
		passive_io = result.passive_io,
		unclassified_io = result.unclassified_io,
		unclassified_mmio = result.unclassified_mmio,
		frame_crc = result.frame_crc,
		audio = result.audio,
		execution = result.execution,
		installation_milestone = result_bound(result.installation_milestone),
		workload_hashes = hashes[:hash_count],
	}
	payload, err := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if err != nil {return .Encode_Failed}
	defer delete(payload)
	if len(payload) > RESULT_MAX_BYTES {return .Too_Large}
	return result_atomic_write(path, payload)
}
