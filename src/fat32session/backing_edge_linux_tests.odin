#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
fat32session_test_linux_live_path_replacement_freezes_before_block_io :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-live-replacement-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "active.img")
	if !created {return}
	replacement_path, replacement_created := session_test_image(t, root, "replacement.img")
	if !replacement_created {return}
	held_path, path_error := filepath.join({root, "held.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}

	session, open_error := open_in_process(path, "live-replacement")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, os.rename(path, held_path), os.Error(nil)) ||
	   !testing.expect_value(t, os.rename(replacement_path, path), os.Error(nil)) {
		return
	}

	device := block_device(session)
	sector: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, !device.read(device.ctx, 0, sector[:]))
	terminal, frozen := session_terminal_error(session)
	testing.expect(t, frozen)
	testing.expect_value(t, terminal.code, Error_Code.State_Mismatch)
	testing.expect_value(t, terminal.outcome, Operation_Outcome.Retained)
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
}
