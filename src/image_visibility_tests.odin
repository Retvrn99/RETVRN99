// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:testing"
import "fat32fs"
import "fat32session"

@(test)
image_visibility_test_host_import_reaches_guest_and_guest_write_reaches_browser :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	adapters := [?]fat32session.Adapter_Kind {
		fat32session.Adapter_Kind.In_Process,
		fat32session.Adapter_Kind.Process,
	}
	for adapter in adapters {
		image_visibility_test_adapter(t, root, adapter)
	}
}

@(private = "file")
image_visibility_test_adapter :: proc(
	t: ^testing.T,
	root: string,
	adapter: fat32session.Adapter_Kind,
) {
	process := adapter == .Process
	image_name := process ? "visibility-process.img" : "visibility-in-process.img"
	session_name := process ? "visibility-process" : "visibility-in-process"
	image_path := test_image_create(t, root, image_name, adapter)
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		nil,
		[]Test_Image_File{{path = "HOST.TXT", data = "host to guest"}},
		adapter,
	) {
		return
	}

	machine_session, open_error := fat32session.open_machine(image_path, session_name, adapter)
	if !testing.expect(t, open_error.code == .None && machine_session != nil) {return}
	host_batch, observe_error := fat32session.observe(
		machine_session,
		[]fat32session.Probe{{kind = .Read_Range, path = "HOST.TXT", length = 64}},
		context.temp_allocator,
	)
	if testing.expect(t, observe_error.code == .None && !host_batch.pending) &&
	   testing.expect_value(t, len(host_batch.items), 1) {
		testing.expect_value(t, string(host_batch.items[0].data), "host to guest")
	}
	fat32session.observation_batch_destroy(&host_batch, context.temp_allocator)

	volume, volume_error := fat32fs.open(fat32session.block_device(machine_session))
	if !testing.expect_value(t, volume_error.code, fat32fs.Error_Code.None) {
		_ = fat32session.close(machine_session, .Retain)
		return
	}
	guest_text := "guest to browser"
	guest_data := transmute([]u8)guest_text
	writer, begin_error := fat32fs.file_begin(&volume, "GUEST.TXT", u64(len(guest_data)))
	if !testing.expect_value(t, begin_error.code, fat32fs.Error_Code.None) {
		_ = fat32session.close(machine_session, .Retain)
		return
	}
	if write_error := fat32fs.file_write(&writer, guest_data);
	   !testing.expect_value(t, write_error.code, fat32fs.Error_Code.None) {
		_ = fat32fs.file_cancel(&writer)
		_ = fat32session.close(machine_session, .Retain)
		return
	}
	if finish_error := fat32fs.file_finish(&writer);
	   !testing.expect_value(t, finish_error.code, fat32fs.Error_Code.None) {
		_ = fat32session.close(machine_session, .Retain)
		return
	}
	barrier, barrier_error := fat32session.barrier(machine_session, .Reset)
	testing.expect_value(t, barrier_error.code, fat32session.Error_Code.None)
	testing.expect_value(t, barrier.materialization, fat32session.Materialization.Materialized)
	if !testing.expect_value(
		t,
		fat32session.close(machine_session, .Commit).code,
		fat32session.Error_Code.None,
	) {
		return
	}

	edit, edit_error := fat32session.open_edit(image_path, session_name, 0, adapter)
	if !testing.expect(t, edit_error.code == .None && edit != nil) {return}
	guest_read, guest_error := fat32session.edit_read(
		edit,
		"GUEST.TXT",
		0,
		64,
		context.temp_allocator,
	)
	if testing.expect_value(t, guest_error.code, fat32session.Error_Code.None) {
		testing.expect_value(t, string(guest_read.data), "guest to browser")
	}
	fat32fs.read_result_destroy(&guest_read, context.temp_allocator)
	testing.expect_value(
		t,
		fat32session.edit_finish(edit, false).code,
		fat32session.Error_Code.None,
	)
}
