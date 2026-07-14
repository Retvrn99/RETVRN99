// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:testing"

@(test)
acceptance_workload_manifest_test_tracked_gate_is_valid :: proc(t: ^testing.T) {
	manifest, diagnostic := workload_manifest_parse(WORKLOAD_MANIFEST_DATA[:])
	defer workload_manifest_destroy(&manifest)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.None)
	testing.expect_value(t, len(manifest.workloads), 2)
	testing.expect_value(t, manifest.workloads[0].expected, u64(2134))
	testing.expect_value(t, manifest.workloads[1].expected, u64(969))
}

@(test)
acceptance_workload_manifest_test_rejects_unsafe_names_duplicates_and_oversize_input :: proc(t: ^testing.T) {
	unsafe_names := [?]string{".", "..", "NUL", "COM1.exe", "doom.exe."}
	for executable in unsafe_names {
		workload := Workload {
			id = "gate", executable = executable, metric = "frames",
			expected = 1, repetitions = 1, semantic_exit = "test_device",
		}
		testing.expect(t, !workload_valid(&workload))
	}
	duplicate := `{"version":1,"workloads":[{"id":"same","executable":"doom.exe","arguments":[],"metric":"gametics","expected":1,"repetitions":1,"semantic_exit":"test_device"},{"id":"same","executable":"quake.exe","arguments":[],"metric":"frames","expected":1,"repetitions":1,"semantic_exit":"test_device"}]}`
	_, diagnostic := workload_manifest_parse(transmute([]u8)duplicate)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.Invalid_Entry)
	oversize := make([]u8, WORKLOAD_MANIFEST_MAX_BYTES + 1, context.temp_allocator)
	_, diagnostic = workload_manifest_parse(oversize)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.Malformed)
	partial := `{"version":1,"workloads":[{"id":"allocated","executable":"doom.exe"`
	_, diagnostic = workload_manifest_parse(transmute([]u8)partial)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.Malformed)
}

@(test)
acceptance_workload_manifest_test_rejects_paths_and_unknown_metrics :: proc(t: ^testing.T) {
	path_text := `{"version":1,"workloads":[{"id":"doom","executable":"C:/games/doom.exe","arguments":[],"metric":"gametics","expected":1,"repetitions":3,"semantic_exit":"test_device"}]}`
	_, diagnostic := workload_manifest_parse(transmute([]u8)path_text)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.Invalid_Entry)
	metric_text := `{"version":1,"workloads":[{"id":"doom","executable":"doom.exe","arguments":[],"metric":"seconds","expected":1,"repetitions":3,"semantic_exit":"test_device"}]}`
	_, diagnostic = workload_manifest_parse(transmute([]u8)metric_text)
	testing.expect_value(t, diagnostic, Workload_Manifest_Diagnostic.Invalid_Entry)
}
