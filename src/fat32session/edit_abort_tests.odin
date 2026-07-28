// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32image "../fat32image"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(private = "file")
edit_abort_test_image_crc :: proc(path: string) -> (u32, bool) {
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return 0, false}
	defer os.close(file)
	buffer := make([]u8, 1 << 20)
	defer delete(buffer)
	checksum: u32
	for {
		count, read_error := os.read(file, buffer)
		if count > 0 {checksum = hash.crc32(buffer[:count], checksum)}
		if read_error != nil {
			if read_error == .EOF {break}
			return 0, false
		}
		if count == 0 {break}
	}
	return checksum, true
}

@(private = "file")
edit_abort_test_expect_recovered :: proc(t: ^testing.T, path, machine_id: string) -> bool {
	validated, validation_error := validate_image(path, .In_Process)
	if !testing.expect_value(t, validation_error.code, Error_Code.None) {return false}
	dirty := validated.dirty
	image_info_destroy(&validated)
	if !testing.expect(t, !dirty) {return false}
	state_root, root_ok := companion_path(path, context.temp_allocator)
	if !testing.expect(t, root_ok && !os.exists(state_root)) {return false}
	machine, open_error := open_machine(path, machine_id, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return false}
	return testing.expect_value(t, close(machine, .Commit).code, Error_Code.None)
}

@(test)
edit_abort_test_failed_import_begin_discard_recovers_machine :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-abort-begin-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "abort-begin.img")
	if !created {return}
	source, source_error := filepath.join({root, "payload.bin"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {return}
	payload := make([]u8, 4096)
	defer delete(payload)
	for &value, index in payload {value = u8(index)}
	if !testing.expect_value(t, os.write_entire_file(source, payload), os.Error(nil)) {return}
	before, before_ok := edit_abort_test_image_crc(path)
	if !testing.expect(t, before_ok) {return}
	session, open_error := open_edit(path, "abort-begin", 0, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	begin_error := edit_begin_import_file(session, source, "MISSING/TARGET.BIN", false)
	testing.expect(t, begin_error.code != .None)
	if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
	after, after_ok := edit_abort_test_image_crc(path)
	if !testing.expect(t, after_ok) {return}
	testing.expect_value(t, after, before)
	edit_abort_test_expect_recovered(t, path, "abort-begin-machine")
}

@(test)
edit_abort_test_failed_import_job_discard_restores_byte_identical_image :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-abort-job-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	adapters := [2]Adapter_Kind{.In_Process, .Process}
	for adapter, index in adapters {
		path, created := session_test_image(t, root, fmt.tprintf("abort-job-%d.img", index))
		if !created {return}
		source, source_error := filepath.join(
			{root, fmt.tprintf("payload-%d.bin", index)},
			context.temp_allocator,
		)
		if !testing.expect(t, source_error == nil) {return}
		payload := make([]u8, 4096)
		for &value, value_index in payload {value = u8(value_index)}
		write_error := os.write_entire_file(source, payload)
		if !testing.expect_value(t, write_error, os.Error(nil)) {delete(payload); return}
		before, before_ok := edit_abort_test_image_crc(path)
		if !testing.expect(t, before_ok) {delete(payload); return}
		session, open_error := open_edit(
			path,
			fmt.tprintf("abort-job-%d", index),
			0,
			adapter,
		)
		if !testing.expect_value(t, open_error.code, Error_Code.None) {delete(payload); return}
		begin_error := edit_begin_import_file(session, source, "TARGET.BIN", false)
		if !testing.expect_value(t, begin_error.code, Error_Code.None) {
			delete(payload)
			_ = edit_close_retain(session)
			return
		}
		// Growing the verified source between begin and step makes the
		// import job fail deterministically inside the running job.
		grown := make([]u8, 8192)
		mutate_error := os.write_entire_file(source, grown)
		delete(grown)
		delete(payload)
		if !testing.expect_value(t, mutate_error, os.Error(nil)) {
			_ = edit_close_retain(session)
			return
		}
		_, step_error := edit_job_step(session)
		testing.expect(t, step_error.code != .None)
		if !testing.expect_value(t, edit_finish(session, false).code, Error_Code.None) {return}
		after, after_ok := edit_abort_test_image_crc(path)
		if !testing.expect(t, after_ok) {return}
		testing.expect_value(t, after, before)
		if !edit_abort_test_expect_recovered(
			t,
			path,
			fmt.tprintf("abort-job-machine-%d", index),
		) {
			return
		}
	}
}

@(test)
edit_abort_test_retained_failed_job_reopen_discard_recovers :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-edit-abort-retain-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	path, created := session_test_image(t, root, "abort-retain.img")
	if !created {return}
	source, source_error := filepath.join({root, "payload.bin"}, context.temp_allocator)
	if !testing.expect(t, source_error == nil) {return}
	payload := make([]u8, 4096)
	defer delete(payload)
	if !testing.expect_value(t, os.write_entire_file(source, payload), os.Error(nil)) {return}
	session, open_error := open_edit(path, "abort-retain", 0, .In_Process)
	if !testing.expect_value(t, open_error.code, Error_Code.None) {return}
	begin_error := edit_begin_import_file(session, source, "MISSING/TARGET.BIN", false)
	testing.expect(t, begin_error.code != .None)
	// A consumer that gives up with close-retain leaves the image dirty;
	// the next Edit open must recover it far enough to discard cleanly.
	if !testing.expect_value(t, edit_close_retain(session).code, Error_Code.None) {return}
	validated, validation_error := fat32image.validate(path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	dirty := validated.dirty
	fat32image.info_destroy(&validated)
	if !testing.expect(t, dirty) {return}
	reopened, reopen_error := open_edit(path, "abort-retain-recover", 0, .In_Process)
	if !testing.expect_value(t, reopen_error.code, Error_Code.None) {return}
	if !testing.expect_value(t, edit_finish(reopened, false).code, Error_Code.None) {return}
	edit_abort_test_expect_recovered(t, path, "abort-retain-machine")
}
