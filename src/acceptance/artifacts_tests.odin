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
	defer os.remove_all(dir)
	long := make([]u8, ARTIFACT_TEXT_MAX_BYTES + 1024, context.temp_allocator)
	for &byte in long {byte = 'x'}
	pixels := []u32{0xFF112233, 0xFF445566}
	testing.expect_value(
		t,
		artifact_write_bundle(dir, string(long), pixels, 2, 1),
		Artifact_Diagnostic.None,
	)
	diagnostics_path, _ := filepath.join({dir, "diagnostics.txt"})
	frame_path, _ := filepath.join({dir, "final-frame.ppm"})
	diagnostics, _ := os.read_entire_file(diagnostics_path, context.temp_allocator)
	frame, _ := os.read_entire_file(frame_path, context.temp_allocator)
	testing.expect_value(t, len(diagnostics), ARTIFACT_TEXT_MAX_BYTES)
	testing.expect(t, len(frame) > 6)
	testing.expect_value(
		t,
		artifact_write_bundle(dir, "new diagnostics", nil, max(int), 2),
		Artifact_Diagnostic.None,
	)
	testing.expect(t, !os.exists(frame_path))
}
