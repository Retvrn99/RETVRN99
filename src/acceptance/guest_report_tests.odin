// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:os"
import "core:path/filepath"
import "core:testing"

guest_report_test_bytes :: proc(value: string) -> []u8 {
	return transmute([]u8)value
}

guest_report_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.temp_allocator)
	if !testing.expect(t, base_error == nil) {return ""}
	directory, directory_error := os.make_directory_temp(
		base,
		"retvrn99_guest_report_*",
		context.temp_allocator,
	)
	if !testing.expect(t, directory_error == nil) {return ""}
	return directory
}

guest_report_test_read :: proc(t: ^testing.T, directory, name: string) -> []u8 {
	path, path_error := filepath.join({directory, name})
	if !testing.expect(t, path_error == nil) {return nil}
	defer delete(path)
	payload, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_error == nil) {return nil}
	return payload
}

@(test)
guest_report_test_wire_status_values_are_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, u8(Guest_Report_Status.Unprocessed), u8(0))
	testing.expect_value(t, u8(Guest_Report_Status.Ok), u8(1))
	testing.expect_value(t, u8(Guest_Report_Status.Bad_State), u8(2))
	testing.expect_value(t, u8(Guest_Report_Status.Bad_Length), u8(3))
	testing.expect_value(t, u8(Guest_Report_Status.Overflow), u8(4))
	testing.expect_value(t, u8(Guest_Report_Status.Artifacts_Disabled), u8(5))
	testing.expect_value(t, u8(Guest_Report_Status.Host_Io), u8(6))
}

@(test)
guest_report_test_commit_publishes_exact_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_append(&collector, guest_report_test_bytes("header\r\n")), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_append(&collector, guest_report_test_bytes("row\r\n")), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_commit(&collector), Guest_Report_Status.Ok)
	payload := guest_report_test_read(t, directory, GUEST_REPORT_FILE)
	testing.expect_value(t, string(payload), "header\r\nrow\r\n")
}

@(test)
guest_report_test_legacy_kind_uses_distinct_fixed_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory, .Legacy_VGA)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(
		t,
		guest_report_append(&collector, guest_report_test_bytes("legacy\r\n")),
		Guest_Report_Status.Ok,
	)
	testing.expect_value(t, guest_report_commit(&collector), Guest_Report_Status.Ok)
	payload := guest_report_test_read(t, directory, LEGACY_VGA_GUEST_REPORT_FILE)
	testing.expect_value(t, string(payload), "legacy\r\n")
	gswgfx_path, path_error := filepath.join({directory, GUEST_REPORT_FILE})
	if testing.expect(t, path_error == nil) {
		defer delete(gswgfx_path)
		testing.expect(t, !os.exists(gswgfx_path))
	}
}

@(test)
guest_report_test_legacy_partial_uses_distinct_fixed_name :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory, .Legacy_VGA)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(
		t,
		guest_report_append(&collector, guest_report_test_bytes("partial")),
		Guest_Report_Status.Ok,
	)
	testing.expect_value(t, guest_report_finalize_partial(&collector), Guest_Report_Status.Ok)
	payload := guest_report_test_read(t, directory, LEGACY_VGA_GUEST_REPORT_PARTIAL_FILE)
	testing.expect_value(t, string(payload), "partial")
}

@(test)
guest_report_test_state_length_and_artifact_errors_fail_closed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_append(&collector, {1}), Guest_Report_Status.Bad_State)
	testing.expect_value(t, guest_report_commit(&collector), Guest_Report_Status.Bad_State)
	testing.expect_value(t, guest_report_abort(&collector), Guest_Report_Status.Bad_State)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Bad_State)
	testing.expect_value(t, guest_report_append(&collector, nil), Guest_Report_Status.Bad_Length)
	too_long: [31]u8
	testing.expect_value(t, guest_report_append(&collector, too_long[:]), Guest_Report_Status.Bad_Length)
	testing.expect_value(t, guest_report_abort(&collector), Guest_Report_Status.Ok)
	disabled: Guest_Report_Collector
	guest_report_init(&disabled, "")
	defer guest_report_destroy(&disabled)
	testing.expect_value(t, guest_report_begin(&disabled), Guest_Report_Status.Artifacts_Disabled)
	testing.expect_value(t, guest_report_append(&disabled, {1}), Guest_Report_Status.Artifacts_Disabled)
	testing.expect_value(t, guest_report_commit(&disabled), Guest_Report_Status.Artifacts_Disabled)
	testing.expect_value(t, guest_report_abort(&disabled), Guest_Report_Status.Artifacts_Disabled)
}

@(test)
guest_report_test_overflow_abort_and_restart :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	resize(&collector.bytes, GUEST_REPORT_MAX_BYTES)
	testing.expect_value(t, guest_report_append(&collector, {1}), Guest_Report_Status.Overflow)
	testing.expect_value(t, guest_report_abort(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_append(&collector, guest_report_test_bytes("new")), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_commit(&collector), Guest_Report_Status.Ok)
	payload := guest_report_test_read(t, directory, GUEST_REPORT_FILE)
	testing.expect_value(t, string(payload), "new")
}

@(test)
guest_report_test_no_clobber_and_partial_evidence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := guest_report_test_directory(t)
	if directory == "" {return}
	defer acceptance_test_remove_tree(directory)
	final_path, final_error := filepath.join({directory, GUEST_REPORT_FILE})
	if !testing.expect(t, final_error == nil) {return}
	defer delete(final_path)
	testing.expect(t, os.write_entire_file(final_path, "existing") == nil)
	collector: Guest_Report_Collector
	guest_report_init(&collector, directory)
	defer guest_report_destroy(&collector)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Host_Io)
	payload := guest_report_test_read(t, directory, GUEST_REPORT_FILE)
	testing.expect_value(t, string(payload), "existing")
	_ = os.remove(final_path)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_append(&collector, guest_report_test_bytes("blocked")), Guest_Report_Status.Ok)
	testing.expect(t, os.write_entire_file(final_path, "raced") == nil)
	testing.expect_value(t, guest_report_commit(&collector), Guest_Report_Status.Host_Io)
	payload = guest_report_test_read(t, directory, GUEST_REPORT_FILE)
	testing.expect_value(t, string(payload), "raced")
	testing.expect_value(t, guest_report_abort(&collector), Guest_Report_Status.Ok)
	_ = os.remove(final_path)
	testing.expect_value(t, guest_report_begin(&collector), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_append(&collector, guest_report_test_bytes("partial")), Guest_Report_Status.Ok)
	testing.expect_value(t, guest_report_finalize_partial(&collector), Guest_Report_Status.Ok)
	partial := guest_report_test_read(t, directory, GUEST_REPORT_PARTIAL_FILE)
	testing.expect_value(t, string(partial), "partial")
	testing.expect_value(t, guest_report_finalize_partial(&collector), Guest_Report_Status.Bad_State)
}
