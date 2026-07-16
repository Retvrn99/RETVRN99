// SPDX-License-Identifier: GPL-3.0-only
package companionio

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
companionio_test_bound_children_are_regular_and_retired_by_handle :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	root, root_error := os.make_directory_temp(base, "retvrn99-companionio-*", context.temp_allocator)
	if !testing.expect(t, root_error == nil) {return}
	defer os.remove_all(root)
	state_path, path_error := filepath.join({root, "state"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil && os.make_directory(state_path) == nil) {return}
	state, state_status := open_path(state_path, allocator = context.temp_allocator)
	if !testing.expect_value(t, state_status, Status.None) {return}
	defer close_directory(&state, context.temp_allocator)
	exists, safe, _ := probe_file(&state, "missing.bin")
	testing.expect(t, !exists && safe)
	edit, edit_status := open_child(&state, "edit", true, context.temp_allocator)
	if !testing.expect_value(t, edit_status, Status.None) {return}
	defer close_directory(&edit, context.temp_allocator)
	file, _, file_status := open_file(&edit, "data.bin", {.Read, .Write, .Create, .Sync})
	if !testing.expect_value(t, file_status, Status.None) {return}
	testing.expect(t, os.close(file) == nil)
	size: i64
	exists, safe, size = probe_file(&edit, "data.bin")
	testing.expect(t, exists && safe && size == 0)
	testing.expect(t, remove_file(&edit, "data.bin"))
	testing.expect(t, retire_directory(&state, &edit))
}
