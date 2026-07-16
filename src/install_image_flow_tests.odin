// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "fat32session"
import "profile"
import "win98imageprep"

install_gate_test_verify_exact :: proc(
	request: win98imageprep.Verify_Binding_Request,
	_: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error) {
	return {
		image_identity      = request.expected_image_identity,
		edit_transaction_id = request.preparation_transaction_id,
	}, {}
}

install_gate_test_verify_identity_mismatch :: proc(
	request: win98imageprep.Verify_Binding_Request,
	_: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error) {
	identity := request.expected_image_identity
	identity[0] = identity[0] ~ 0xFF
	return {
		image_identity      = identity,
		edit_transaction_id = request.preparation_transaction_id,
	}, {}
}

install_gate_test_verify_transaction_mismatch :: proc(
	request: win98imageprep.Verify_Binding_Request,
	_: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error) {
	return {
		image_identity      = request.expected_image_identity,
		edit_transaction_id = request.preparation_transaction_id + 1,
	}, {}
}

install_gate_test_verify_missing :: proc(
	_: win98imageprep.Verify_Binding_Request,
	_: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error) {
	return {}, win98imageprep.error_make(
		.Not_Prepared,
		"prepared transaction is missing",
	)
}

install_gate_test_verify_consumed :: proc(
	request: win98imageprep.Verify_Binding_Request,
	_: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error) {
	if !request.allow_consumed_content {
		return {}, win98imageprep.error_make(
			.Not_Prepared,
			"consumed preparation content was not allowed",
		)
	}
	return {
		image_identity      = request.expected_image_identity,
		edit_transaction_id = request.preparation_transaction_id,
	}, {}
}

install_gate_test_state :: proc(image_path: string) -> profile.Install_State {
	return {
		phase               = .Launch_Pending,
		source_path         = strings.clone("windows98.iso"),
		image_path          = strings.clone(image_path),
		image_identity      = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		edit_transaction_id = 73,
	}
}

@(test)
install_image_flow_test_candidate_is_bound_before_preparation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	image_path, _ := filepath.join({root, "c_drive.img"})
	identity := profile.Install_Image_Identity{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	cmos: profile.Cmos_Data
	cmos[0x38] = 0xA5
	cmos[0x3D] = 0x5A
	candidate := install_image_candidate(
		"windows98.iso",
		image_path,
		identity,
		42,
		cmos[:],
		true,
		nil,
	)
	defer profile.install_state_destroy(&candidate)
	testing.expect_value(t, candidate.phase, profile.Install_Phase.Preparing)
	testing.expect_value(t, candidate.source_path, "windows98.iso")
	testing.expect_value(t, candidate.image_path, image_path)
	testing.expect_value(t, candidate.image_identity, identity)
	testing.expect_value(t, candidate.edit_transaction_id, u64(42))
	testing.expect(t, candidate.saved_cmos_valid)
}

@(test)
install_image_flow_test_binding_hook_verifies_and_persists_exact_transaction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	state_path, _ := filepath.join({root, "install-state.json"})
	image_path, _ := filepath.join({root, "c_drive.img"})
	identity := profile.Install_Image_Identity{7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22}
	state := profile.Install_State {
		phase               = .Preparing,
		source_path         = strings.clone("windows98.iso"),
		image_path          = strings.clone(image_path),
		image_identity      = identity,
		edit_transaction_id = 99,
	}
	defer profile.install_state_destroy(&state)
	paths := profile.Paths{install_state = state_path}
	binding_context := Install_Image_Binding_Context {
		paths      = &paths,
		state      = &state,
		image_path = image_path,
	}
	testing.expect(
		t,
		install_image_binding_persist(
			&binding_context,
			win98imageprep.Preparation_Binding {
				image_identity      = identity,
				edit_transaction_id = 99,
			},
		),
	)
	loaded, diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.edit_transaction_id, u64(99))
	testing.expect(
		t,
		!install_image_binding_persist(
			&binding_context,
			win98imageprep.Preparation_Binding {
				image_identity      = identity,
				edit_transaction_id = 100,
			},
		),
	)
}

@(test)
install_image_flow_test_progress_cancellation_and_completion_are_coherent :: proc(t: ^testing.T) {
	shared: Shared
	defer delete(shared.install_prepare_message)
	install_prepare_status_queue(&shared)
	install_prepare_cancel_request(&shared)
	generation := install_prepare_status_begin(&shared)
	status := install_prepare_status_snapshot(&shared)
	testing.expect(t, status.running)
	testing.expect_value(t, status.generation, generation)
	testing.expect(
		t,
		install_prepare_cancel_check(&shared, .Setup_Extracted),
	)
	install_prepare_status_finish(&shared, false, "cancelled")
	status = install_prepare_status_snapshot(&shared)
	testing.expect(t, !status.running && !status.succeeded)
	testing.expect_value(t, status.generation, generation + 1)
	testing.expect_value(t, status.message, "cancelled")
	install_prepare_status_queue(&shared)
	testing.expect(t, !install_prepare_cancel_check(&shared, .Media_Inspected))
}

@(test)
guided_install_test_model_and_boot_source_labels :: proc(t: ^testing.T) {
	model: Guided_Install_Model
	defer guided_install_destroy(&model)
	testing.expect(t, guided_install_open(&model, "D:/images/c_drive.img"))
	testing.expect_value(t, model.phase, Guided_Install_Phase.Awaiting_ISO)
	iso_dialog := guided_install_iso_dialog()
	testing.expect_value(t, iso_dialog.filter_pattern, "iso")
	boot_dialog := guided_install_boot_dialog()
	testing.expect_value(t, boot_dialog.filter_pattern, "img")
	guided_install_dialog_error(&model, "The Windows file chooser could not be opened.")
	testing.expect_value(t, model.phase, Guided_Install_Phase.Awaiting_ISO)
	testing.expect_value(
		t,
		model.diagnostic,
		"The Windows file chooser could not be opened.",
	)
	model.phase = .Awaiting_Boot_Floppy
	guided_install_dialog_error(&model, "The boot-floppy chooser could not be opened.")
	testing.expect_value(t, model.phase, Guided_Install_Phase.Awaiting_Boot_Floppy)
	testing.expect_value(t, model.diagnostic, "The boot-floppy chooser could not be opened.")
	testing.expect_value(
		t,
		guided_install_boot_source_text(.Embedded),
		"Embedded 1.44 MB boot image",
	)
}

@(test)
install_image_boot_gate_test_requires_exact_path_identity_and_transaction :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	image_path, image_error := filepath.join({root, "c_drive.img"})
	other_path, other_error := filepath.join({root, "other.img"})
	if !testing.expect(t, image_error == nil && other_error == nil) {return}
	state := install_gate_test_state(image_path)
	defer profile.install_state_destroy(&state)
	exact := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_exact,
	)
	testing.expect(t, exact.allowed)
	missing_selected := install_image_boot_gate_with_verifier(
		&state,
		"",
		.In_Process,
		install_gate_test_verify_exact,
	)
	testing.expect_value(
		t,
		missing_selected.diagnostic,
		Install_Image_Boot_Diagnostic.Selected_Image_Required,
	)
	wrong_path := install_image_boot_gate_with_verifier(
		&state,
		other_path,
		.In_Process,
		install_gate_test_verify_exact,
	)
	testing.expect_value(
		t,
		wrong_path.diagnostic,
		Install_Image_Boot_Diagnostic.Image_Path_Mismatch,
	)
	wrong_identity := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_identity_mismatch,
	)
	testing.expect_value(
		t,
		wrong_identity.diagnostic,
		Install_Image_Boot_Diagnostic.Image_Identity_Mismatch,
	)
	wrong_transaction := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_transaction_mismatch,
	)
	testing.expect_value(
		t,
		wrong_transaction.diagnostic,
		Install_Image_Boot_Diagnostic.Edit_Transaction_Mismatch,
	)
	missing_preparation := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_missing,
	)
	testing.expect_value(
		t,
		missing_preparation.diagnostic,
		Install_Image_Boot_Diagnostic.Preparation_Missing,
	)
	missing_image := install_image_boot_gate(&state, image_path, .In_Process)
	testing.expect_value(
		t,
		missing_image.diagnostic,
		Install_Image_Boot_Diagnostic.Image_Unavailable,
	)
	testing.expect_value(
		t,
		missing_image.preparation_error.session_error.code,
		fat32session.Error_Code.Image_Missing,
	)
}

@(test)
install_image_boot_gate_test_setup_running_allows_consumed_bootstrap_content :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	image_path, image_error := filepath.join({root, "c_drive.img"})
	if !testing.expect(t, image_error == nil) {return}
	state := install_gate_test_state(image_path)
	defer profile.install_state_destroy(&state)
	strict := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_consumed,
	)
	testing.expect(t, !strict.allowed)
	state.phase = .Setup_Running
	consumed := install_image_boot_gate_with_verifier(
		&state,
		image_path,
		.In_Process,
		install_gate_test_verify_consumed,
	)
	testing.expect(t, consumed.allowed)
}

@(test)
install_image_boot_gate_test_clean_move_requires_state_and_selection_update :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	original, original_error := filepath.join({root, "original.img"})
	moved, moved_error := filepath.join({root, "moved.img"})
	if !testing.expect(t, original_error == nil && moved_error == nil) {return}
	state := install_gate_test_state(original)
	defer profile.install_state_destroy(&state)
	stale := install_image_boot_gate_with_verifier(
		&state,
		moved,
		.In_Process,
		install_gate_test_verify_exact,
	)
	testing.expect_value(
		t,
		stale.diagnostic,
		Install_Image_Boot_Diagnostic.Image_Path_Mismatch,
	)
	delete(state.image_path)
	state.image_path = strings.clone(moved)
	updated := install_image_boot_gate_with_verifier(
		&state,
		moved,
		.In_Process,
		install_gate_test_verify_exact,
	)
	testing.expect(t, updated.allowed)
}

@(test)
install_image_boot_gate_test_invalid_loaded_state_fails_closed :: proc(t: ^testing.T) {
	state: profile.Install_State
	result := install_image_boot_gate_loaded(
		&state,
		"",
		.Unbound_Active,
		.In_Process,
	)
	testing.expect(t, !result.allowed)
	testing.expect_value(
		t,
		result.diagnostic,
		Install_Image_Boot_Diagnostic.Install_State_Invalid,
	)
	testing.expect_value(
		t,
		result.state_diagnostic,
		profile.Install_State_Diagnostic.Unbound_Active,
	)
}

@(test)
install_image_lifecycle_test_storage_lock_distinguishes_missing_active_and_recovery :: proc(
	t: ^testing.T,
) {
	state: profile.Install_State
	testing.expect(t, !install_state_storage_locked(&state, .Missing))
	testing.expect(t, !install_state_storage_locked(&state, .None))
	testing.expect(t, install_state_storage_locked(&state, .Malformed))
	testing.expect(t, install_state_storage_locked(&state, .Unsupported_Version))
	testing.expect(t, install_state_storage_locked(&state, .Unbound_Active))

	state.phase = .Preparing
	state.source_path = strings.clone("WIN98SE.ISO")
	defer profile.install_state_destroy(&state)
	testing.expect(t, install_state_storage_locked(&state, .None))
}
