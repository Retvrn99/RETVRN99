// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:os"
import "core:testing"

@(test)
fat32session_test_live_size_change_freezes_before_block_io :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-live-size-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "live-size.img")
	if !created {return}
	session, open_error := open_in_process(path, "live-size")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^In_Process_Implementation)(session.ctx)
	logical_size, size_error := os.file_size(impl.image.file)
	if !testing.expect_value(t, size_error, os.Error(nil)) {return}
	if !testing.expect_value(
		t,
		os.truncate(impl.image.file, logical_size - fat32image.SECTOR_BYTES),
		os.Error(nil),
	) {return}

	device := block_device(session)
	sector: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, !device.read(device.ctx, device.sector_count - 1, sector[:]))
	terminal, frozen := session_terminal_error(session)
	testing.expect(t, frozen)
	testing.expect_value(t, terminal.code, Error_Code.State_Mismatch)
	testing.expect_value(t, terminal.outcome, Operation_Outcome.Retained)
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
}

@(test)
fat32session_test_live_extension_freezes_before_block_io :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-session-live-extension-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "live-extension.img")
	if !created {return}
	session, open_error := open_in_process(path, "live-extension")
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	impl := (^In_Process_Implementation)(session.ctx)
	logical_size, size_error := os.file_size(impl.image.file)
	if !testing.expect_value(t, size_error, os.Error(nil)) {return}
	if !testing.expect_value(
		t,
		os.truncate(impl.image.file, logical_size + fat32image.SECTOR_BYTES),
		os.Error(nil),
	) {return}

	device := block_device(session)
	sector: [fat32image.SECTOR_BYTES]u8
	testing.expect(t, !device.read(device.ctx, 0, sector[:]))
	terminal, frozen := session_terminal_error(session)
	testing.expect(t, frozen)
	testing.expect_value(t, terminal.code, Error_Code.State_Mismatch)
	testing.expect_value(t, terminal.outcome, Operation_Outcome.Retained)
	testing.expect_value(t, close(session, .Retain).code, Error_Code.None)
}
