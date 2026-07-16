// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32image "../fat32image"
import fat32session "../fat32session"
import "core:testing"

Prep_Test_Cancellation_State :: struct {
	point: Cancel_Point,
}

prep_test_cancel_at_point :: proc(ctx: rawptr, point: Cancel_Point) -> bool {
	state := (^Prep_Test_Cancellation_State)(ctx)
	return state != nil && state.point == point
}

prep_test_expect_unprepared :: proc(t: ^testing.T, environment: ^Prep_Test_Environment) {
	validated, validation_error := fat32image.validate(environment.image_path)
	if testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {
		testing.expect(t, !validated.dirty)
		fat32image.info_destroy(&validated)
	}
	verify, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-cancellation-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	paths := [?]string {
		"IO.SYS",
		"MSDOS.SYS",
		"COMMAND.COM",
		PAYLOAD_PATH,
		LAUNCHER_PATH,
		AUTOEXEC_PATH,
		OWNER_FILE_NAME,
	}
	for path in paths {testing.expect(t, !prep_test_stat(t, verify, path).exists)}
	testing.expect_value(
		t,
		fat32session.edit_finish(verify, false).code,
		fat32session.Error_Code.None,
	)
}

@(test)
prepare_test_cancellation_discards_every_phase_and_cleans_scratch :: proc(t: ^testing.T) {
	points := [?]Cancel_Point {
		.Media_Inspected,
		.Edit_Opened,
		.Boot_Seed_Staged,
		.Setup_Extracted,
		.DOS_Imported,
		.Payload_Imported,
		.Launcher_Imported,
		.Boot_Loader_Staged,
		.Before_Apply,
	}
	for point in points {
		environment, environment_ok := prep_test_environment(
			t,
			{embedded_boot = true, setup_name = "INSTALAR"},
		)
		if !environment_ok {return}
		state := Prep_Test_Cancellation_State {
			point = point,
		}
		request := prep_test_prepare_request(&environment)
		request.cancellation = {
			ctx   = &state,
			check = prep_test_cancel_at_point,
		}
		result, prep_error := prepare(request, .In_Process)
		prepare_result_destroy(&result)
		testing.expect_value(t, prep_error.code, Error_Code.Cancelled)
		prep_test_scratch_empty(t, environment.scratch)
		prep_test_expect_unprepared(t, &environment)
		prep_test_environment_destroy(&environment)
	}
}

@(test)
prepare_test_binding_failure_discards_preparation :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	capture := Prep_Test_Binding_Capture {
		accept = false,
	}
	request := prep_test_prepare_request(&environment)
	request.binding_hook = {
		ctx     = &capture,
		persist = prep_test_binding_persist,
	}
	result, prep_error := prepare(request, .In_Process)
	prepare_result_destroy(&result)
	testing.expect_value(t, prep_error.code, Error_Code.Binding_Failed)
	testing.expect(t, capture.called)
	prep_test_scratch_empty(t, environment.scratch)
	prep_test_expect_unprepared(t, &environment)
}

@(test)
prepare_test_recovers_dirty_overlay_then_recognizes_applied_owner :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	interrupted, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-interrupted-preparation",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	if !prep_test_import_bytes(
		t,
		&environment,
		interrupted,
		"INTERRUPT.TMP",
		"uncertain staging",
	) {
		_ = fat32session.edit_close_retain(interrupted)
		return
	}
	transaction_id := fat32session.edit_transaction_id(interrupted)
	if !testing.expect(t, transaction_id != 0) {return}
	if !testing.expect_value(
		t,
		fat32session.edit_close_retain(interrupted).code,
		fat32session.Error_Code.None,
	) {return}
	request := prep_test_prepare_request(&environment)
	request.edit_session_id = "win98-interrupted-preparation"
	request.requested_transaction_id = transaction_id
	first, first_error := prepare(request, .In_Process)
	if !testing.expect_value(t, first_error.code, Error_Code.None) {
		prepare_result_destroy(&first)
		return
	}
	testing.expect_value(t, first.edit_transaction_id, transaction_id)
	testing.expect(t, !first.recovered)
	verify, verify_error := fat32session.open_edit(
		environment.image_path,
		"win98-recovery-verify",
		0,
		.In_Process,
	)
	if testing.expect_value(t, verify_error.code, fat32session.Error_Code.None) {
		testing.expect(t, !prep_test_stat(t, verify, "INTERRUPT.TMP").exists)
		testing.expect(t, prep_test_stat(t, verify, OWNER_FILE_NAME).exists)
		testing.expect_value(
			t,
			fat32session.edit_finish(verify, false).code,
			fat32session.Error_Code.None,
		)
	}
	prepare_result_destroy(&first)
	request.requested_transaction_id = 0
	request.edit_session_id = "win98-applied-recovery"
	second, second_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&second)
	if !testing.expect_value(t, second_error.code, Error_Code.None) {return}
	testing.expect(t, second.recovered)
	testing.expect_value(t, second.edit_transaction_id, transaction_id)
}

@(test)
abandon_test_discards_unowned_interrupted_transaction :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	interrupted, open_error := fat32session.open_edit(
		environment.image_path,
		"win98-abandon-interrupted",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	if !prep_test_import_bytes(t, &environment, interrupted, "INTERRUPT.TMP", "temporary") {
		_ = fat32session.edit_close_retain(interrupted)
		return
	}
	transaction_id := fat32session.edit_transaction_id(interrupted)
	if !testing.expect_value(
		t,
		fat32session.edit_close_retain(interrupted).code,
		fat32session.Error_Code.None,
	) {return}
	_, abandon_error := abandon(
		{
			image_path = environment.image_path,
			edit_session_id = "win98-abandon-interrupted",
			preparation_transaction_id = transaction_id,
		},
		.In_Process,
	)
	if !testing.expect_value(t, abandon_error.code, Error_Code.None) {return}
	prep_test_expect_unprepared(t, &environment)
}

prep_test_read_vbr :: proc(
	t: ^testing.T,
	image_path: string,
) -> (
	sector: [fat32image.SECTOR_BYTES]u8,
	ok: bool,
) {
	image, open_error := fat32image.open(image_path, .Read_Only)
	if !testing.expect_value(t, open_error.code, fat32image.Error_Code.None) {return {}, false}
	read_error := fat32image.block_read(image, u64(image.info.partition_lba), sector[:])
	close_error := fat32image.close(image, .Clean)
	return sector,
		testing.expect_value(t, read_error.code, fat32image.Error_Code.None) &&
		testing.expect_value(t, close_error.code, fat32image.Error_Code.None)
}

@(test)
abandon_test_removes_owned_preparation_and_restores_boot_stub :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	initial_vbr, initial_ok := prep_test_read_vbr(t, environment.image_path)
	if !initial_ok {return}
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	_, abandon_error := abandon(
		{
			image_path = environment.image_path,
			edit_session_id = "win98-owned-abandon",
			preparation_transaction_id = transaction_id,
		},
		.In_Process,
	)
	if !testing.expect_value(t, abandon_error.code, Error_Code.None) {return}
	prep_test_expect_unprepared(t, &environment)
	restored_vbr, restored_ok := prep_test_read_vbr(t, environment.image_path)
	if restored_ok {testing.expect_value(t, restored_vbr, initial_vbr)}
}

@(test)
abandon_test_restores_preexisting_autoexec_and_preserves_existing_dos :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = false, setup_name = "SETUP"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	if !prep_test_seed_dos(t, &environment, 3) {return}
	seed, seed_error := fat32session.open_edit(
		environment.image_path,
		"win98-existing-autoexec",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, seed_error.code, fat32session.Error_Code.None) {return}
	if !prep_test_import_bytes(t, &environment, seed, AUTOEXEC_PATH, "@ECHO ORIGINAL\r\n") {
		_ = fat32session.edit_close_retain(seed)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.edit_finish(seed, true).code,
		fat32session.Error_Code.None,
	) {return}
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	_, abandon_error := abandon(
		{
			image_path = environment.image_path,
			edit_session_id = "win98-existing-dos-abandon",
			preparation_transaction_id = transaction_id,
		},
		.In_Process,
	)
	if !testing.expect_value(t, abandon_error.code, Error_Code.None) {return}
	verify, verify_error := fat32session.open_edit(
		environment.image_path,
		"win98-existing-dos-abandon-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, verify_error.code, fat32session.Error_Code.None) {return}
	for name in BOOTSTRAP_SYSTEM_NAMES {
		testing.expect(t, prep_test_stat(t, verify, name).exists)
	}
	autoexec := prep_test_read(t, verify, AUTOEXEC_PATH)
	testing.expect_value(t, string(autoexec), "@ECHO ORIGINAL\r\n")
	delete(autoexec)
	testing.expect(t, !prep_test_stat(t, verify, AUTOEXEC_BACKUP_PATH).exists)
	testing.expect(t, !prep_test_stat(t, verify, OWNER_FILE_NAME).exists)
	testing.expect_value(
		t,
		fat32session.edit_finish(verify, false).code,
		fat32session.Error_Code.None,
	)
}

@(test)
abandon_test_refuses_modified_owned_content_without_deleting_evidence :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	modify, modify_error := fat32session.open_edit(
		environment.image_path,
		"win98-external-modification",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, modify_error.code, fat32session.Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32session.edit_remove_recursive(modify, LAUNCHER_PATH).code,
		fat32session.Error_Code.None,
	) {
		_ = fat32session.edit_close_retain(modify)
		return
	}
	if !prep_test_import_bytes(t, &environment, modify, LAUNCHER_PATH, "@ECHO USER FILE\r\n") {
		_ = fat32session.edit_close_retain(modify)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.edit_finish(modify, true).code,
		fat32session.Error_Code.None,
	) {return}
	_, abandon_error := abandon(
		{
			image_path = environment.image_path,
			edit_session_id = "win98-modified-abandon",
			preparation_transaction_id = transaction_id,
		},
		.In_Process,
	)
	testing.expect_value(t, abandon_error.code, Error_Code.Ownership_Mismatch)
	verify, verify_error := fat32session.open_edit(
		environment.image_path,
		"win98-modified-abandon-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, verify_error.code, fat32session.Error_Code.None) {return}
	testing.expect(t, prep_test_stat(t, verify, OWNER_FILE_NAME).exists)
	testing.expect(t, prep_test_stat(t, verify, PAYLOAD_PATH).exists)
	launcher := prep_test_read(t, verify, LAUNCHER_PATH)
	testing.expect_value(t, string(launcher), "@ECHO USER FILE\r\n")
	delete(launcher)
	testing.expect_value(
		t,
		fat32session.edit_finish(verify, false).code,
		fat32session.Error_Code.None,
	)
}

@(test)
abandon_test_setup_running_removes_only_content_still_owned_by_retvrn99 :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prep_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	if !testing.expect_value(t, prep_error.code, Error_Code.None) {
		prepare_result_destroy(&prepared)
		return
	}
	transaction_id := prepared.edit_transaction_id
	prepare_result_destroy(&prepared)
	modify, modify_error := fat32session.open_edit(
		environment.image_path,
		"win98-consumed-modification",
		transaction_id,
		.In_Process,
	)
	if !testing.expect_value(t, modify_error.code, fat32session.Error_Code.None) {return}
	modified_paths := []string{LAUNCHER_PATH, AUTOEXEC_PATH}
	for path in modified_paths {
		if !testing.expect_value(
			t,
			fat32session.edit_remove_recursive(modify, path).code,
			fat32session.Error_Code.None,
		) {
			_ = fat32session.edit_close_retain(modify)
			return
		}
	}
	if !prep_test_import_bytes(
		t,
		&environment,
		modify,
		LAUNCHER_PATH,
		"@ECHO USER REPLACED LAUNCHER\r\n",
	) ||
	   !prep_test_import_bytes(
		   t,
		   &environment,
		   modify,
		   AUTOEXEC_PATH,
		   "@ECHO WINDOWS SETUP AUTOEXEC\r\n",
	   ) ||
	   !prep_test_import_bytes(
		   t,
		   &environment,
		   modify,
		   PAYLOAD_PATH + "/USERKEEP.TXT",
		   "unowned Setup output\r\n",
	   ) {
		_ = fat32session.edit_close_retain(modify)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.edit_finish(modify, true).code,
		fat32session.Error_Code.None,
	) {return}

	_, abandon_error := abandon(
		{
			image_path                 = environment.image_path,
			edit_session_id            = "win98-consumed-abandon",
			preparation_transaction_id = transaction_id,
			allow_consumed_content     = true,
		},
		.In_Process,
	)
	if !testing.expect_value(t, abandon_error.code, Error_Code.None) {return}
	verify, verify_error := fat32session.open_edit(
		environment.image_path,
		"win98-consumed-abandon-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, verify_error.code, fat32session.Error_Code.None) {return}
	testing.expect(t, !prep_test_stat(t, verify, OWNER_FILE_NAME).exists)
	testing.expect(t, prep_test_stat(t, verify, PAYLOAD_PATH).is_directory)
	testing.expect(t, !prep_test_stat(
		t,
		verify,
		PAYLOAD_PATH + "/" + PAYLOAD_MARKER_NAME,
	).exists)
	user_output := prep_test_read(t, verify, PAYLOAD_PATH + "/USERKEEP.TXT")
	testing.expect_value(t, string(user_output), "unowned Setup output\r\n")
	delete(user_output)
	launcher := prep_test_read(t, verify, LAUNCHER_PATH)
	testing.expect_value(t, string(launcher), "@ECHO USER REPLACED LAUNCHER\r\n")
	delete(launcher)
	autoexec := prep_test_read(t, verify, AUTOEXEC_PATH)
	testing.expect_value(t, string(autoexec), "@ECHO WINDOWS SETUP AUTOEXEC\r\n")
	delete(autoexec)
	for path in BOOTSTRAP_SYSTEM_NAMES {
		testing.expect(t, !prep_test_stat(t, verify, path).exists)
	}
	testing.expect_value(
		t,
		fat32session.edit_finish(verify, false).code,
		fat32session.Error_Code.None,
	)
}
