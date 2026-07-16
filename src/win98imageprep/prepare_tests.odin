// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import cabinetextract "../cabinetextract"
import fat32image "../fat32image"
import fat32session "../fat32session"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Prep_Test_Binding_Capture :: struct {
	called:  bool,
	binding: Preparation_Binding,
	accept:  bool,
}

prep_test_binding_persist :: proc(ctx: rawptr, binding: Preparation_Binding) -> bool {
	capture := (^Prep_Test_Binding_Capture)(ctx)
	if capture == nil {return false}
	capture.called = true
	capture.binding = binding
	return capture.accept
}

prep_test_prepare_request :: proc(
	environment: ^Prep_Test_Environment,
	boot_floppy_path := "",
) -> Prepare_Request {
	return {
		image_path = environment.image_path,
		iso_path = environment.iso_path,
		boot_floppy_path = boot_floppy_path,
		scratch_parent = environment.scratch,
		edit_session_id = "win98-preparation-test",
		options = {setup_source_overlay = prep_test_setup_source_overlay()},
	}
}

prep_test_setup_source_overlay :: proc() -> Setup_Source_Overlay {
	return {extract = prep_test_setup_source_extract}
}

prep_test_setup_source_extract :: proc(
	_: rawptr,
	_, first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	if first_cabinet == TLB_VMM32_FIRST_CABINET {
		if len(requests) != 1 || requests[0].source_name != TLB_VMM32_NAME {
			return {code = .Invalid_Argument, request_index = -1}
		}
		data := tlb_test_variant_source(.Updated_V1, false)
		if u64(len(data)) > requests[0].max_output_bytes ||
		   os.write_entire_file(requests[0].destination, data) != nil {
			return {code = .Output_Write_Failed, request_index = 0}
		}
		return {extracted_count = 1, request_index = -1}
	}
	if first_cabinet != STOCK_DMA_FIRST_CABINET {
		return {code = .Invalid_Argument, request_index = -1}
	}
	for request, index in requests {
		data := ""
		if request.source_name == "MSHDC.INF" {
			data = "; localized MSHDC fixture\r\n" + "[ESDI_AddReg]\r\nHKR,,Existing,0,1\r\n"
		} else if request.source_name == "DISKDRV.INF" {
			data = "; localized DISKDRV fixture\r\n" + "[DiskReg]\r\nHKR,,Existing,0,1\r\n"
		} else {
			return {code = .Target_Missing, request_index = i32(index)}
		}
		if u64(len(data)) > request.max_output_bytes ||
		   os.write_entire_file(request.destination, data) != nil {
			return {code = .Output_Write_Failed, request_index = i32(index)}
		}
	}
	return {extracted_count = u16(len(requests)), request_index = -1}
}

prep_test_scratch_empty :: proc(t: ^testing.T, path: string) {
	if !os.exists(path) {return}
	entries, read_error := os.read_all_directory_by_path(path, context.temp_allocator)
	if !testing.expect_value(t, read_error, os.Error(nil)) {return}
	defer for entry in entries {os.file_info_delete(entry, context.temp_allocator)}
	testing.expect_value(t, len(entries), 0)
}

prep_test_stat :: proc(
	t: ^testing.T,
	session: ^fat32session.Edit_Session,
	path: string,
) -> fat32session.Edit_Stat {
	stat, stat_error := fat32session.edit_stat(session, path)
	testing.expect_value(t, stat_error.code, fat32session.Error_Code.None)
	return stat
}

prep_test_read :: proc(t: ^testing.T, session: ^fat32session.Edit_Session, path: string) -> []u8 {
	stat := prep_test_stat(t, session, path)
	if !stat.exists || stat.is_directory {return nil}
	result, read_error := fat32session.edit_read(session, path, 0, stat.size)
	if !testing.expect_value(t, read_error.code, fat32session.Error_Code.None) {return nil}
	return result.data
}

prep_test_import_bytes :: proc(
	t: ^testing.T,
	environment: ^Prep_Test_Environment,
	session: ^fat32session.Edit_Session,
	guest_path, data: string,
) -> bool {
	host_path, path_error := filepath.join(
		{environment.root, fmt.tprintf("import-%s", guest_path)},
		context.temp_allocator,
	)
	if !testing.expect(t, path_error == nil) {return false}
	if !testing.expect_value(
		t,
		os.make_directory_all(filepath.dir(host_path)),
		os.Error(nil),
	) {return false}
	if !testing.expect_value(
		t,
		os.write_entire_file(host_path, data),
		os.Error(nil),
	) {return false}
	begin_error := fat32session.edit_begin_import_file(session, host_path, guest_path)
	if !testing.expect_value(t, begin_error.code, fat32session.Error_Code.None) {return false}
	for {
		progress, step_error := fat32session.edit_job_step(session)
		if !testing.expect_value(t, step_error.code, fat32session.Error_Code.None) {return false}
		if progress.state == .Complete {return true}
		if !testing.expect(
			t,
			progress.state == .Pending || progress.state == .Running,
		) {return false}
	}
}

prep_test_seed_dos :: proc(
	t: ^testing.T,
	environment: ^Prep_Test_Environment,
	file_count: int,
) -> bool {
	session, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-preexisting-dos",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return false}
	defer if session != nil {_ = fat32session.edit_close_retain(session)}
	names := BOOTSTRAP_SYSTEM_NAMES
	contents := [?]string{"existing io.sys", "[Options]\r\nBootGUI=0\r\n", "existing command.com"}
	for index in 0 ..< file_count {
		if !prep_test_import_bytes(t, environment, session, names[index], contents[index]) {
			return false
		}
	}
	apply_error := fat32session.edit_finish(session, true)
	session = nil
	return testing.expect_value(t, apply_error.code, fat32session.Error_Code.None)
}

@(test)
prepare_test_embedded_media_stages_one_durable_edit :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	capture := Prep_Test_Binding_Capture {
		accept = true,
	}
	request := prep_test_prepare_request(&environment)
	request.options = {
		desktop_probe = true,
		hardware_diagnostics = true,
		setup_source_overlay = prep_test_setup_source_overlay(),
		host_locale = {language = "es", country = "ES"},
	}
	request.binding_hook = {
		ctx     = &capture,
		persist = prep_test_binding_persist,
	}
	result, prep_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect(t, capture.called)
	testing.expect_value(t, result.boot_source, Boot_Source.Embedded)
	testing.expect(t, result.edit_transaction_id != 0)
	testing.expect(t, result.boot_target.first_cluster >= 2)
	testing.expect(t, result.boot_target.lba > 0)
	testing.expect_value(t, capture.binding.image_identity, result.image_identity)
	testing.expect_value(t, capture.binding.edit_transaction_id, result.edit_transaction_id)
	testing.expect_value(t, capture.binding.boot_target, result.boot_target)
	prep_test_scratch_empty(t, environment.scratch)
	validated, validation_error := fat32image.validate(environment.image_path)
	if testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {
		testing.expect(t, !validated.dirty)
		fat32image.info_destroy(&validated)
	}
	verify, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-preparation-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	defer if verify != nil {_ = fat32session.edit_close_retain(verify)}
	paths := [?]string {
		"IO.SYS",
		"MSDOS.SYS",
		"COMMAND.COM",
		PAYLOAD_PATH,
		PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME,
		LAUNCHER_PATH,
		AUTOEXEC_PATH,
		OWNER_FILE_NAME,
	}
	for path in paths {
		testing.expect(t, prep_test_stat(t, verify, path).exists)
	}
	owner, owner_exists, owner_error := owner_read(verify)
	if testing.expect_value(t, owner_error.code, Error_Code.None) &&
	   testing.expect(t, owner_exists) {
		testing.expect_value(t, owner.transaction_id, result.edit_transaction_id)
		testing.expect_value(t, owner.boot_target, result.boot_target)
	}
	launcher := prep_test_read(t, verify, LAUNCHER_PATH)
	testing.expect(t, len(launcher) > len(LAUNCHER_MARKER))
	delete(launcher)
	msbatch := prep_test_read(t, verify, PAYLOAD_PATH + "/MSBATCH.INF")
	testing.expect(t, strings.contains(string(msbatch), "Locale=L0C0A\r\n"))
	testing.expect(t, strings.contains(string(msbatch), "SelectedKeyboard=KEYBOARD_0000040A\r\n"))
	delete(msbatch)
	finish_error := fat32session.edit_finish(verify, false)
	verify = nil
	testing.expect_value(t, finish_error.code, fat32session.Error_Code.None)
}

@(test)
prepare_test_retail_requires_then_accepts_matching_floppy :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = false, setup_name = "SETUP"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	request := prep_test_prepare_request(&environment)
	inspection, inspect_error := inspect(
		{
			image_path = request.image_path,
			iso_path = request.iso_path,
			edit_session_id = request.edit_session_id,
		},
		.In_Process,
	)
	inspection_destroy(&inspection)
	testing.expect_value(t, inspect_error.code, Error_Code.Boot_Floppy_Required)
	request.boot_floppy_path = environment.floppy_path
	result, prep_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect_value(t, result.boot_source, Boot_Source.Provided)
	prep_test_scratch_empty(t, environment.scratch)
}

@(test)
prepare_test_invalid_embedded_fat12_is_rejected_during_inspection :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	file, open_error := os.open(environment.iso_path, {.Read, .Write})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	invalid_signature := [1]u8{0}
	written, write_error := os.write_at(
		file,
		invalid_signature[:],
		i64(61 * PREP_TEST_ISO_BLOCK_BYTES + 510),
	)
	close_error := os.close(file)
	if !testing.expect_value(t, written, 1) ||
	   !testing.expect_value(t, write_error, os.Error(nil)) ||
	   !testing.expect_value(t, close_error, os.Error(nil)) {
		return
	}
	inspection, inspect_error := inspect(
		{
			image_path = environment.image_path,
			iso_path = environment.iso_path,
			edit_session_id = "invalid-embedded-fat12",
		},
		.In_Process,
	)
	defer inspection_destroy(&inspection)
	testing.expect_value(t, inspect_error.code, Error_Code.Boot_Floppy_Invalid)
	testing.expect_value(t, inspect_error.boot_diagnostic, Bootstrap_Diagnostic.Boot_Image_Invalid)
	testing.expect(t, !os.exists(environment.scratch))
}

@(test)
prepare_test_existing_dos_does_not_require_retail_floppy :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = false, setup_name = "SETUP"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	if !prep_test_seed_dos(t, &environment, 3) {return}
	request := prep_test_prepare_request(&environment)
	result, prep_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect_value(t, result.boot_source, Boot_Source.Existing_DOS)
	testing.expect(t, result.used_existing_dos)
	verify, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-existing-dos-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	io := prep_test_read(t, verify, "IO.SYS")
	testing.expect_value(t, string(io), "existing io.sys")
	delete(io)
	testing.expect_value(
		t,
		fat32session.edit_finish(verify, false).code,
		fat32session.Error_Code.None,
	)
}

@(test)
prepare_test_rejects_partial_dos_and_existing_windows :: proc(t: ^testing.T) {
	partial, partial_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !partial_ok {return}
	defer prep_test_environment_destroy(&partial)
	if !prep_test_seed_dos(t, &partial, 1) {return}
	partial_request := prep_test_prepare_request(&partial)
	partial_inspection, partial_error := inspect(
		{
			image_path = partial_request.image_path,
			iso_path = partial_request.iso_path,
			edit_session_id = partial_request.edit_session_id,
		},
		.In_Process,
	)
	inspection_destroy(&partial_inspection)
	testing.expect_value(t, partial_error.code, Error_Code.Partial_DOS)
	windows, windows_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !windows_ok {return}
	defer prep_test_environment_destroy(&windows)
	session, open_error := fat32session.open_edit(
		windows.image_path,
		"win98-existing-windows",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32session.edit_mkdir(session, "WINDOWS").code,
		fat32session.Error_Code.None,
	) {
		_ = fat32session.edit_close_retain(session)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.edit_finish(session, true).code,
		fat32session.Error_Code.None,
	) {return}
	windows_request := prep_test_prepare_request(&windows)
	windows_inspection, windows_error := inspect(
		{
			image_path = windows_request.image_path,
			iso_path = windows_request.iso_path,
			edit_session_id = windows_request.edit_session_id,
		},
		.In_Process,
	)
	inspection_destroy(&windows_inspection)
	testing.expect_value(t, windows_error.code, Error_Code.Existing_Windows)
}

@(test)
prepare_test_korean_host_path_and_localized_setup :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "SETUPKOR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	korean_directory, directory_error := filepath.join(
		{environment.root, "한국어 설치 미디어"},
		context.allocator,
	)
	if !testing.expect(t, directory_error == nil) {return}
	defer delete(korean_directory)
	if !testing.expect_value(t, os.make_directory(korean_directory), os.Error(nil)) {return}
	korean_iso, path_error := filepath.join(
		{korean_directory, "윈도우 98.iso"},
		context.allocator,
	)
	if !testing.expect(t, path_error == nil) {return}
	if !testing.expect_value(t, os.rename(environment.iso_path, korean_iso), os.Error(nil)) {
		delete(korean_iso)
		return
	}
	delete(environment.iso_path)
	environment.iso_path = korean_iso
	result, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	defer prepare_result_destroy(&result)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {return}
	testing.expect_value(t, result.media_info.setup_executable, "SETUPKOR.EXE")
}
