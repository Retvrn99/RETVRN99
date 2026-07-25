// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:fmt"
import "core:os"
import "core:path/filepath"

GUEST_REPORT_MAX_BYTES :: 256 * 1024
GUEST_REPORT_FILE :: "gswgfx-result.tsv"
GUEST_REPORT_PARTIAL_FILE :: "gswgfx-result.partial.tsv"

Guest_Report_Status :: enum u8 {
	Unprocessed       = 0,
	Ok                = 1,
	Bad_State         = 2,
	Bad_Length        = 3,
	Overflow          = 4,
	Artifacts_Disabled = 5,
	Host_Io           = 6,
}

Guest_Report_Collector :: struct {
	artifacts: string,
	bytes:     [dynamic]u8,
	active:    bool,
	committed: bool,
}

guest_report_init :: proc(collector: ^Guest_Report_Collector, artifacts: string) {
	if collector == nil {return}
	collector^ = {}
	collector.artifacts = artifacts
}

guest_report_destroy :: proc(collector: ^Guest_Report_Collector) {
	if collector == nil {return}
	delete(collector.bytes)
	collector^ = {}
}

@(private = "file")
guest_report_path :: proc(collector: ^Guest_Report_Collector, name: string) -> (string, bool) {
	if collector == nil || collector.artifacts == "" {return "", false}
	path, path_error := filepath.join({collector.artifacts, name})
	return path, path_error == nil
}

@(private = "file")
guest_report_write_exact :: proc(file: ^os.File, payload: []u8) -> bool {
	written := 0
	for written < len(payload) {
		count, write_error := os.write(file, payload[written:])
		if write_error != nil || count <= 0 {return false}
		written += count
	}
	return true
}

@(private = "file")
guest_report_publish :: proc(
	collector: ^Guest_Report_Collector,
	name: string,
	payload: []u8,
) -> bool {
	path, path_ok := guest_report_path(collector, name)
	if !path_ok {return false}
	defer delete(path)
	if os.make_directory_all(collector.artifacts) != nil {return false}
	temporary_name := fmt.tprintf(".gswgfx-report.%d.tmp", os.get_pid())
	temporary, temporary_error := filepath.join({collector.artifacts, temporary_name})
	if temporary_error != nil {return false}
	defer delete(temporary)
	file, open_error := os.open(temporary, {.Write, .Create, .Excl, .Sync})
	if open_error != nil {return false}
	ok := guest_report_write_exact(file, payload) && os.sync(file) == nil
	if os.close(file) != nil {ok = false}
	if !ok {
		_ = os.remove(temporary)
		return false
	}
	if os.link(temporary, path) != nil {
		_ = os.remove(temporary)
		return false
	}
	_ = os.remove(temporary)
	return true
}

guest_report_begin :: proc(collector: ^Guest_Report_Collector) -> Guest_Report_Status {
	if collector == nil || collector.artifacts == "" {return .Artifacts_Disabled}
	if collector.active || collector.committed {return .Bad_State}
	final_path, path_ok := guest_report_path(collector, GUEST_REPORT_FILE)
	if !path_ok {return .Host_Io}
	defer delete(final_path)
	if os.make_directory_all(collector.artifacts) != nil || os.exists(final_path) {
		return .Host_Io
	}
	clear(&collector.bytes)
	collector.active = true
	return .Ok
}

guest_report_append :: proc(
	collector: ^Guest_Report_Collector,
	payload: []u8,
) -> Guest_Report_Status {
	if collector == nil || collector.artifacts == "" {return .Artifacts_Disabled}
	if !collector.active || collector.committed {return .Bad_State}
	if len(payload) < 1 || len(payload) > 30 {return .Bad_Length}
	if len(collector.bytes) > GUEST_REPORT_MAX_BYTES - len(payload) {return .Overflow}
	append(&collector.bytes, ..payload)
	return .Ok
}

guest_report_commit :: proc(collector: ^Guest_Report_Collector) -> Guest_Report_Status {
	if collector == nil || collector.artifacts == "" {return .Artifacts_Disabled}
	if !collector.active || collector.committed || len(collector.bytes) == 0 {
		return .Bad_State
	}
	if !guest_report_publish(collector, GUEST_REPORT_FILE, collector.bytes[:]) {
		return .Host_Io
	}
	collector.active = false
	collector.committed = true
	clear(&collector.bytes)
	return .Ok
}

guest_report_abort :: proc(collector: ^Guest_Report_Collector) -> Guest_Report_Status {
	if collector == nil || collector.artifacts == "" {return .Artifacts_Disabled}
	if !collector.active || collector.committed {return .Bad_State}
	collector.active = false
	clear(&collector.bytes)
	return .Ok
}

guest_report_finalize_partial :: proc(collector: ^Guest_Report_Collector) -> Guest_Report_Status {
	if collector == nil || collector.artifacts == "" {return .Artifacts_Disabled}
	if !collector.active || collector.committed || len(collector.bytes) == 0 {
		return .Bad_State
	}
	status := Guest_Report_Status.Ok
	if !guest_report_publish(collector, GUEST_REPORT_PARTIAL_FILE, collector.bytes[:]) {
		status = .Host_Io
	}
	collector.active = false
	clear(&collector.bytes)
	return status
}
