// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
acceptance_artifacts_test_bundle_is_fixed_name_and_bounded :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_artifacts_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	long := make([]u8, ARTIFACT_TEXT_MAX_BYTES + 1024, context.temp_allocator)
	for &byte in long {byte = 'x'}
	pixels := []u32{0xFF112233, 0xFF445566}
	testing.expect_value(
		t,
		artifact_write_bundle(dir, string(long), pixels, 2, 1, "tick=1 pit\n"),
		Artifact_Diagnostic.None,
	)
	diagnostics_path, _ := filepath.join({dir, "diagnostics.txt"})
	frame_path, _ := filepath.join({dir, "final-frame.ppm"})
	trace_path, _ := filepath.join({dir, "hardware-trace.txt"})
	diagnostics, _ := os.read_entire_file(diagnostics_path, context.temp_allocator)
	frame, _ := os.read_entire_file(frame_path, context.temp_allocator)
	testing.expect_value(t, len(diagnostics), ARTIFACT_TEXT_MAX_BYTES)
	testing.expect(t, len(frame) > 6)
	trace, _ := os.read_entire_file(trace_path, context.temp_allocator)
	testing.expect_value(t, string(trace), "tick=1 pit\n")
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "new diagnostics", nil, max(int), 2),
		Artifact_Diagnostic.None,
	)
	testing.expect(t, !os.exists(frame_path))
	testing.expect(t, !os.exists(trace_path))
}

@(test)
acceptance_artifacts_test_trace_keeps_bounded_complete_tail :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_trace_artifact_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	long := make([]u8, ARTIFACT_HARDWARE_TRACE_MAX_BYTES + 257, context.temp_allocator)
	for _, index in long {
		long[index] = 'x'
		if index % 64 == 63 {long[index] = '\n'}
	}
	copy(long[len(long) - 5:], "tail\n")
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "diagnostics", nil, 0, 0, string(long)),
		Artifact_Diagnostic.None,
	)
	trace_path, _ := filepath.join({dir, "hardware-trace.txt"})
	trace, read_error := os.read_entire_file(trace_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect(t, len(trace) <= ARTIFACT_HARDWARE_TRACE_MAX_BYTES)
	testing.expect(t, len(trace) >= ARTIFACT_HARDWARE_TRACE_MAX_BYTES - 64)
	testing.expect(t, len(trace) >= 5 && string(trace[len(trace) - 5:]) == "tail\n")
}

@(test)
acceptance_artifacts_test_reports_stale_trace_removal_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_trace_remove_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	trace_path, _ := filepath.join({dir, "hardware-trace.txt"})
	testing.expect(t, os.make_directory(trace_path) == nil)
	child, _ := filepath.join({trace_path, "retained"})
	testing.expect(t, os.write_entire_file(child, "retained") == nil)
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "diagnostics"),
		Artifact_Diagnostic.Write_Failed,
	)
}

@(test)
acceptance_artifacts_test_reports_stale_frame_removal_failure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_frame_remove_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	frame_path, _ := filepath.join({dir, "final-frame.ppm"})
	testing.expect(t, os.make_directory(frame_path) == nil)
	child, _ := filepath.join({frame_path, "retained"})
	testing.expect(t, os.write_entire_file(child, "retained") == nil)
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "diagnostics", nil, 0, 0, "trace\n"),
		Artifact_Diagnostic.Write_Failed,
	)
}

// A guest snapshot writes a frame and touches nothing else. Routing it through
// the bundle used to rewrite the diagnostics text and delete the hardware trace
// on every capture, so the run lost its own evidence to its own snapshots.
@(test)
acceptance_artifacts_test_snapshot_leaves_the_bundle_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_snapshot_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	pixels := []u32{0xFF112233, 0xFF445566}
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "run diagnostics", pixels, 2, 1, "tick=1 pit\n"),
		Artifact_Diagnostic.None,
	)
	testing.expect_value(
		t,
		artifact_write_snapshot(dir, 0, pixels, 2, 1),
		Artifact_Diagnostic.None,
	)

	diagnostics_path, _ := filepath.join({dir, "diagnostics.txt"})
	trace_path, _ := filepath.join({dir, "hardware-trace.txt"})
	final_path, _ := filepath.join({dir, "final-frame.ppm"})
	diagnostics, _ := os.read_entire_file(diagnostics_path, context.temp_allocator)
	trace, _ := os.read_entire_file(trace_path, context.temp_allocator)
	testing.expect_value(t, string(diagnostics), "run diagnostics")
	testing.expect_value(t, string(trace), "tick=1 pit\n")
	testing.expect(t, os.exists(final_path))
}

// Every label is its own file, so a guest test that captures at several moments
// keeps all of them.
@(test)
acceptance_artifacts_test_snapshot_labels_do_not_collide :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_snapshot_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	first := []u32{0xFF112233, 0xFF445566}
	second := []u32{0xFF778899, 0xFFAABBCC, 0xFFDDEEFF, 0xFF010203}
	testing.expect_value(t, artifact_write_snapshot(dir, 0, first, 2, 1), Artifact_Diagnostic.None)
	testing.expect_value(
		t,
		artifact_write_snapshot(dir, 7, second, 2, 2),
		Artifact_Diagnostic.None,
	)
	testing.expect_value(
		t,
		artifact_write_snapshot(dir, 255, first, 2, 1),
		Artifact_Diagnostic.None,
	)

	zero_path, _ := filepath.join({dir, "snapshot-0.ppm"})
	seven_path, _ := filepath.join({dir, "snapshot-7.ppm"})
	last_path, _ := filepath.join({dir, "snapshot-255.ppm"})
	zero, _ := os.read_entire_file(zero_path, context.temp_allocator)
	seven, _ := os.read_entire_file(seven_path, context.temp_allocator)
	testing.expect(t, os.exists(last_path))
	// The 2x2 capture is larger than the 2x1 one, so the labels really did keep
	// their own images rather than one overwriting the other.
	testing.expect(t, len(seven) > len(zero))
	testing.expect_value(t, string(zero[:2]), "P6")
}

// A label that names an unwritable geometry clears its own file and reports no
// failure, matching how the bundle already treats an absent frame.
@(test)
acceptance_artifacts_test_snapshot_clears_a_stale_label :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(base, "retvrn99_snapshot_*", context.temp_allocator)
	defer acceptance_test_remove_tree(dir)
	pixels := []u32{0xFF112233, 0xFF445566}
	testing.expect_value(
		t,
		artifact_write_snapshot(dir, 3, pixels, 2, 1),
		Artifact_Diagnostic.None,
	)
	path, _ := filepath.join({dir, "snapshot-3.ppm"})
	testing.expect(t, os.exists(path))
	testing.expect_value(t, artifact_write_snapshot(dir, 3, nil, 0, 0), Artifact_Diagnostic.None)
	testing.expect(t, !os.exists(path))
}
