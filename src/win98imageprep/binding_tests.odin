// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32session "../fat32session"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
verify_binding_test_checks_identity_transaction_and_clean_image_move :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prepare_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	defer prepare_result_destroy(&prepared)
	if !testing.expect_value(t, prepare_error.code, Error_Code.None) {return}
	request := Verify_Binding_Request {
		image_path                 = environment.image_path,
		edit_session_id            = "binding-correct",
		expected_image_identity    = prepared.image_identity,
		preparation_transaction_id = prepared.edit_transaction_id,
	}
	binding, binding_error := verify_preparation_binding(request, .In_Process)
	if !testing.expect_value(t, binding_error.code, Error_Code.None) {return}
	testing.expect_value(t, binding.image_identity, prepared.image_identity)
	testing.expect_value(t, binding.edit_transaction_id, prepared.edit_transaction_id)
	request.edit_session_id = "binding-wrong-transaction"
	request.preparation_transaction_id += 1
	_, transaction_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, transaction_error.code, Error_Code.Transaction_Mismatch)
	request.preparation_transaction_id = prepared.edit_transaction_id
	request.edit_session_id = "binding-wrong-identity"
	request.expected_image_identity[0] = request.expected_image_identity[0] ~ 0xFF
	_, identity_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, identity_error.code, Error_Code.Image_Identity_Mismatch)
	request.expected_image_identity = prepared.image_identity
	moved_path, moved_error := filepath.join(
		{environment.root, "moved-c_drive.img"},
		context.temp_allocator,
	)
	if !testing.expect(t, moved_error == nil) {return}
	if !testing.expect_value(
		t,
		os.rename(environment.image_path, moved_path),
		os.Error(nil),
	) {return}
	request.image_path = moved_path
	request.edit_session_id = "binding-clean-move"
	moved_binding, moved_binding_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, moved_binding_error.code, Error_Code.None)
	testing.expect_value(t, moved_binding.image_identity, prepared.image_identity)
	validated, validation_error := fat32session.validate_image(moved_path, .In_Process)
	if testing.expect_value(t, validation_error.code, fat32session.Error_Code.None) {
		testing.expect(t, !validated.dirty)
		fat32session.image_info_destroy(&validated)
	}
}

@(test)
verify_binding_test_setup_running_accepts_consumed_bootstrap_with_bound_owner :: proc(
	t: ^testing.T,
) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	prepared, prepare_error := prepare(prep_test_prepare_request(&environment), .In_Process)
	defer prepare_result_destroy(&prepared)
	if !testing.expect_value(t, prepare_error.code, Error_Code.None) {return}

	modify, open_error := fat32session.open_edit(
		environment.image_path,
		"binding-consume",
		prepared.edit_transaction_id,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	if !testing.expect_value(
		t,
		fat32session.edit_remove_recursive(modify, AUTOEXEC_PATH).code,
		fat32session.Error_Code.None,
	) {
		_ = fat32session.edit_close_retain(modify)
		return
	}
	if !prep_test_import_bytes(
		t,
		&environment,
		modify,
		AUTOEXEC_PATH,
		"@ECHO WINDOWS SETUP CONSUMED THE BOOTSTRAP\r\n",
	) {
		_ = fat32session.edit_close_retain(modify)
		return
	}
	if !testing.expect_value(
		t,
		fat32session.edit_finish(modify, true).code,
		fat32session.Error_Code.None,
	) {return}

	request := Verify_Binding_Request {
		image_path                 = environment.image_path,
		edit_session_id            = "binding-consumed-strict",
		expected_image_identity    = prepared.image_identity,
		preparation_transaction_id = prepared.edit_transaction_id,
	}
	_, strict_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, strict_error.code, Error_Code.Ownership_Mismatch)
	request.edit_session_id = "binding-consumed-active"
	request.allow_consumed_content = true
	binding, consumed_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, consumed_error.code, Error_Code.None)
	testing.expect_value(t, binding.image_identity, prepared.image_identity)
	testing.expect_value(t, binding.edit_transaction_id, prepared.edit_transaction_id)
	request.edit_session_id = "binding-consumed-wrong-transaction"
	request.preparation_transaction_id += 1
	_, transaction_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, transaction_error.code, Error_Code.Transaction_Mismatch)
	request.preparation_transaction_id = prepared.edit_transaction_id
	request.edit_session_id = "binding-consumed-wrong-identity"
	request.expected_image_identity[0] = request.expected_image_identity[0] ~ 0xFF
	_, identity_error := verify_preparation_binding(request, .In_Process)
	testing.expect_value(t, identity_error.code, Error_Code.Image_Identity_Mismatch)
}
