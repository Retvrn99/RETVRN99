// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_graphics_postmortem_save_enforces_bounds :: proc(t: ^testing.T) {
	checkpoint := "checkpoint"
	testing.expect_value(
		t,
		graphics_postmortem_save("", transmute([]u8)checkpoint),
		Graphics_Postmortem_Save_Diagnostic.Invalid_Path,
	)
	testing.expect_value(
		t,
		graphics_postmortem_save("checkpoint.json", nil),
		Graphics_Postmortem_Save_Diagnostic.Empty_Payload,
	)
	oversized := make([]u8, GRAPHICS_POSTMORTEM_MAX_BYTES + 1)
	defer delete(oversized)
	testing.expect_value(
		t,
		graphics_postmortem_save("checkpoint.json", oversized),
		Graphics_Postmortem_Save_Diagnostic.Payload_Too_Large,
	)
}

@(test)
test_graphics_postmortem_save_atomically_overwrites_checkpoint :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	path, path_error := filepath.join({dir, "graphics-postmortem.json"})
	if !testing.expect(t, path_error == nil) {return}
	defer {
		_ = os.remove(path)
		_ = os.remove(dir)
	}
	first_text := `{"schema":1,"revision":1}`
	second_text := `{"schema":1,"revision":2}`
	first := transmute([]u8)first_text
	second := transmute([]u8)second_text
	testing.expect_value(
		t,
		graphics_postmortem_save(path, first),
		Graphics_Postmortem_Save_Diagnostic.None,
	)
	testing.expect_value(
		t,
		graphics_postmortem_save(path, second),
		Graphics_Postmortem_Save_Diagnostic.None,
	)
	actual, read_error := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, read_error == nil) {return}
	testing.expect_value(t, string(actual), string(second))
}
