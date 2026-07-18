// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
install_state_test_v5_legacy_milestones_and_binding_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase            = .Setup_Running,
		milestone        = .Hardware_Detection,
		source_path      = "WIN98SE.ISO",
		reset_count      = 2,
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	image_path, _ := filepath.join({dir, "c_drive.img"})
	identity := install_state_test_bind(t, &state, image_path, 41)
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), `"version": 5`))
	testing.expect(t, strings.contains(string(data), `"backend": "legacy_setup"`))
	testing.expect(t, strings.contains(string(data), `"milestone": "hardware_detection"`))
	testing.expect(t, strings.contains(string(data), `"edit_transaction_id": 41`))
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, Install_Phase.Setup_Running)
	testing.expect_value(t, loaded.milestone, Install_Milestone.Hardware_Detection)
	testing.expect_value(t, loaded.reset_count, u32(2))
	testing.expect_value(t, loaded.image_path, state.image_path)
	testing.expect_value(t, loaded.image_identity, identity)
	testing.expect_value(t, loaded.edit_transaction_id, u64(41))
	testing.expect_value(
		t,
		install_state_verify_binding(&loaded, state.image_path, identity, 41),
		Install_Binding_Diagnostic.None,
	)
}

@(test)
install_state_test_v4_active_install_continues_as_legacy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	image_path, _ := filepath.join({dir, "c_drive.img"})
	state := Install_State {
		phase       = .Setup_Running,
		milestone   = .First_Reboot,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
	_ = install_state_test_bind(t, &state, image_path, 410)
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if !testing.expect(t, err == nil) {return}
	v4, _ := strings.replace(string(data), `"version": 5`, `"version": 4`, 1)
	testing.expect(t, os.write_entire_file(path, v4) == nil)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.backend, Install_Backend.Legacy_Setup)
	testing.expect_value(t, loaded.phase, Install_Phase.Setup_Running)
	testing.expect_value(t, loaded.milestone, Install_Milestone.First_Reboot)
}

@(test)
install_state_test_v5_local_pack_metadata_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	image_path, _ := filepath.join({dir, "c_drive.img"})
	fingerprint := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	pack_hash := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
	state := Install_State {
		backend            = .Local_Pack,
		phase              = .Importing,
		source_path        = "WIN98SE.ISO",
		builder_version    = "0.1.0",
		builder_protocol   = 1,
		install_profile    = "minimal",
		source_fingerprint = fingerprint,
		pack_hash          = pack_hash,
		update_recipe_set  = "phase0",
	}
	_ = install_state_test_bind(t, &state, image_path, 411)
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.backend, Install_Backend.Local_Pack)
	testing.expect_value(t, loaded.phase, Install_Phase.Importing)
	testing.expect_value(t, loaded.builder_version, "0.1.0")
	testing.expect_value(t, loaded.builder_protocol, u32(1))
	testing.expect_value(t, loaded.install_profile, "minimal")
	testing.expect_value(t, loaded.source_fingerprint, fingerprint)
	testing.expect_value(t, loaded.pack_hash, pack_hash)
	testing.expect_value(t, loaded.update_recipe_set, "phase0")

	state.pack_hash = "NOT-A-SHA256"
	testing.expect_value(
		t,
		install_state_save(path, &state),
		Install_State_Diagnostic.Invalid_State,
	)
}

@(test)
install_state_test_each_explicit_milestone_round_trips :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	cases := [?]struct {
		milestone:   Install_Milestone,
		reset_count: u32,
	}{{.DOS_Setup, 0}, {.First_Reboot, 1}, {.Hardware_Detection, 1}}
	for candidate in cases {
		state := Install_State {
			phase       = .Setup_Running,
			milestone   = candidate.milestone,
			source_path = "WIN98SE.ISO",
			reset_count = candidate.reset_count,
		}
		image_path, _ := filepath.join({dir, "c_drive.img"})
		_ = install_state_test_bind(t, &state, image_path, 42)
		testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
		loaded, diagnostic := install_state_load(path)
		testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
		testing.expect_value(t, loaded.milestone, candidate.milestone)
		install_state_destroy(&loaded)
	}
}

@(test)
install_state_test_v1_and_v2_migrate_milestones :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	v1 := `{"version":1,"phase":"setup_running","source_path":"WIN98SE.ISO","reset_count":0}`
	testing.expect(t, os.write_entire_file(path, v1) == nil)
	loaded, diagnostic := install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Unbound_Active)
	testing.expect_value(t, loaded.phase, Install_Phase.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.None)
	install_state_destroy(&loaded)

	v2 := `{"version":2,"phase":"setup_running","source_path":"WIN98SE.ISO","reset_count":2,"saved_cmos_valid":true}`
	testing.expect(t, os.write_entire_file(path, v2) == nil)
	loaded, diagnostic = install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Unbound_Active)
	testing.expect_value(t, loaded.phase, Install_Phase.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.None)
	testing.expect(t, !loaded.saved_cmos_valid)
	testing.expect_value(t, install_state_save(path, &loaded), Install_State_Diagnostic.None)
}

@(test)
install_state_test_legacy_non_setup_phases_have_no_milestone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	legacy := `{"version":2,"phase":"launch_pending","source_path":"WIN98SE.ISO","reset_count":4}`
	testing.expect(t, os.write_entire_file(path, legacy) == nil)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Unbound_Active)
	testing.expect_value(t, loaded.phase, Install_Phase.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.None)
}

@(test)
install_state_test_save_normalizes_existing_setup_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase       = .Setup_Running,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
	image_path, _ := filepath.join({dir, "c_drive.img"})
	_ = install_state_test_bind(t, &state, image_path, 43)
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.First_Reboot)
	install_state_destroy(&loaded)
	state.milestone = .DOS_Setup
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	loaded, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.First_Reboot)
}

@(test)
install_state_test_binding_rejects_wrong_image_path_identity_and_transaction :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	image_path, _ := filepath.join({dir, "c_drive.img"})
	other_path, _ := filepath.join({dir, "moved.img"})
	state: Install_State
	identity := install_state_test_bind(t, &state, image_path, 100)
	state.phase = .Preparing
	state.source_path = "WIN98SE.ISO"

	testing.expect_value(
		t,
		install_state_verify_binding(&state, image_path, identity, 100),
		Install_Binding_Diagnostic.None,
	)
	testing.expect_value(
		t,
		install_state_verify_binding(&state, other_path, identity, 100),
		Install_Binding_Diagnostic.Image_Path_Mismatch,
	)
	wrong_identity := identity
	wrong_identity[15] = wrong_identity[15] ~ 0xFF
	testing.expect_value(
		t,
		install_state_verify_binding(&state, image_path, wrong_identity, 100),
		Install_Binding_Diagnostic.Image_Identity_Mismatch,
	)
	testing.expect_value(
		t,
		install_state_verify_binding(&state, image_path, identity, 101),
		Install_Binding_Diagnostic.Stale_Edit_Transaction,
	)
}

@(test)
install_state_test_active_move_rejected_but_inactive_move_can_rebind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	first, _ := filepath.join({dir, "first.img"})
	second, _ := filepath.join({dir, "second.img"})
	state: Install_State
	identity := install_state_test_bind(t, &state, first, 200)
	state.phase = .Launch_Pending
	state.source_path = "WIN98SE.ISO"
	testing.expect_value(
		t,
		install_state_clear_binding(&state),
		Install_Binding_Diagnostic.Active_Rebind_Rejected,
	)
	testing.expect_value(
		t,
		install_state_bind(&state, second, identity, 200),
		Install_Binding_Diagnostic.Active_Rebind_Rejected,
	)
	testing.expect_value(t, state.image_path, first)

	state.phase = .None
	state.source_path = ""
	state.reset_count = 0
	state.milestone = .None
	testing.expect_value(
		t,
		install_state_bind(&state, second, identity, 201),
		Install_Binding_Diagnostic.None,
	)
	testing.expect_value(t, state.image_path, second)
	testing.expect_value(t, state.edit_transaction_id, u64(201))
	testing.expect_value(t, install_state_clear_binding(&state), Install_Binding_Diagnostic.None)
	testing.expect(t, !install_state_bound(&state))
}

@(test)
install_state_test_legacy_inactive_state_remains_usable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	legacy := `{"version":3,"phase":"none","milestone":"none","source_path":"","reset_count":0}`
	testing.expect(t, os.write_entire_file(path, legacy) == nil)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect(t, !install_state_active(&loaded))
	testing.expect(t, !install_state_bound(&loaded))
	testing.expect_value(
		t,
		install_state_verify_binding(&loaded, "", {}, 0),
		Install_Binding_Diagnostic.Inactive_Unbound,
	)
}

@(test)
install_state_test_v4_rejects_malformed_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	image_path, _ := filepath.join({dir, "c_drive.img"})
	state: Install_State
	_ = install_state_test_bind(t, &state, image_path, 300)
	state.phase = .Preparing
	state.source_path = "WIN98SE.ISO"
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	valid_identity := "0102030405060708090a0b0c0d0e0f10"

	short_text, _ := strings.replace_all(
		string(data),
		valid_identity,
		"0102",
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(path, short_text) == nil)
	_, diagnostic := install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Malformed_Image_Identity)

	upper, _ := strings.replace_all(
		string(data),
		valid_identity,
		"0102030405060708090A0B0C0D0E0F10",
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(path, upper) == nil)
	_, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Malformed_Image_Identity)

	zero, _ := strings.replace_all(
		string(data),
		valid_identity,
		"00000000000000000000000000000000",
		context.temp_allocator,
	)
	testing.expect(t, os.write_entire_file(path, zero) == nil)
	_, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Malformed_Image_Identity)
}

install_state_test_bind :: proc(
	t: ^testing.T,
	state: ^Install_State,
	image_path: string,
	transaction_id: u64,
) -> Install_Image_Identity {
	identity := Install_Image_Identity{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	phase := state.phase
	state.phase = .None
	testing.expect_value(
		t,
		install_state_bind(state, image_path, identity, transaction_id),
		Install_Binding_Diagnostic.None,
	)
	state.phase = phase
	return identity
}

@(test)
install_state_test_v3_validation_rejects_incoherent_milestones :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	unknown := `{"version":3,"phase":"setup_running","milestone":"future","source_path":"WIN98SE.ISO","reset_count":1}`
	testing.expect(t, os.write_entire_file(path, unknown) == nil)
	_, diagnostic := install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Unknown_Milestone)

	missing := `{"version":3,"phase":"setup_running","milestone":"none","source_path":"WIN98SE.ISO","reset_count":1}`
	testing.expect(t, os.write_entire_file(path, missing) == nil)
	_, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Invalid_State)

	impossible := `{"version":3,"phase":"setup_running","milestone":"first_reboot","source_path":"WIN98SE.ISO","reset_count":0}`
	testing.expect(t, os.write_entire_file(path, impossible) == nil)
	_, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Invalid_State)

	stale := `{"version":3,"phase":"setup_running","milestone":"dos_setup","source_path":"WIN98SE.ISO","reset_count":1}`
	testing.expect(t, os.write_entire_file(path, stale) == nil)
	_, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.Invalid_State)

	wrong_phase := Install_State {
		phase       = .Launch_Pending,
		milestone   = .Hardware_Detection,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
	testing.expect_value(
		t,
		install_state_save(path, &wrong_phase),
		Install_State_Diagnostic.Invalid_State,
	)
}

@(test)
install_state_test_invalid_abandon_preserves_exact_evidence_before_clearing :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	cases := [?]struct {
		name:       string,
		payload:    string,
		diagnostic: Install_State_Diagnostic,
	} {
		{"malformed", `{"version":`, .Malformed},
		{"unsupported", `{"version":99,"phase":"none"}`, .Unsupported_Version},
		{
			"unbound",
			`{"version":1,"phase":"launch_pending","source_path":"WIN98SE.ISO"}`,
			.Unbound_Active,
		},
	}
	for item in cases {
		path, path_error := filepath.join(
			{dir, fmt.tprintf("%s-install-state.json", item.name)},
			context.temp_allocator,
		)
		if !testing.expect(t, path_error == nil) {continue}
		if !testing.expect_value(t, os.write_entire_file(path, item.payload), os.Error(nil)) {
			continue
		}
		loaded, load_diagnostic := install_state_load(path)
		install_state_destroy(&loaded)
		if !testing.expect_value(t, load_diagnostic, item.diagnostic) {continue}
		testing.expect(t, install_state_recovery_required(load_diagnostic))

		evidence_path, recovery_diagnostic := install_state_abandon_invalid(
			path,
			load_diagnostic,
			context.temp_allocator,
		)
		if !testing.expect_value(
			t,
			recovery_diagnostic,
			Install_State_Recovery_Diagnostic.None,
		) {
			continue
		}
		testing.expect(t, evidence_path != "" && evidence_path != path)
		retained, retained_error := os.read_entire_file(evidence_path, context.temp_allocator)
		testing.expect(t, retained_error == nil)
		testing.expect_value(t, string(retained), item.payload)
		current, current_error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, current_error == nil)
		testing.expect(t, strings.contains(string(current), `"version": 5`))
		testing.expect(t, strings.contains(string(current), `"phase": "none"`))

		cleared, clear_diagnostic := install_state_load(path)
		testing.expect_value(t, clear_diagnostic, Install_State_Diagnostic.None)
		testing.expect(t, !install_state_active(&cleared))
		testing.expect(t, !install_state_bound(&cleared))
		install_state_destroy(&cleared)
	}
}

@(test)
install_state_test_missing_and_valid_state_do_not_request_invalid_recovery :: proc(
	t: ^testing.T,
) {
	testing.expect(t, !install_state_recovery_required(.None))
	testing.expect(t, !install_state_recovery_required(.Missing))
	testing.expect(t, install_state_recovery_required(.Malformed))
	testing.expect(t, install_state_recovery_required(.Unsupported_Version))
	testing.expect(t, install_state_recovery_required(.Unbound_Active))

	evidence, diagnostic := install_state_abandon_invalid("missing", .Missing)
	defer delete(evidence)
	testing.expect_value(t, evidence, "")
	testing.expect_value(t, diagnostic, Install_State_Recovery_Diagnostic.Not_Required)
}

@(test)
install_state_test_milestones_advance_monotonically :: proc(t: ^testing.T) {
	state := Install_State {
		phase       = .Setup_Running,
		source_path = "WIN98SE.ISO",
	}
	testing.expect(t, install_state_advance_milestone(&state, .DOS_Setup))
	testing.expect(t, install_state_milestone_reached(&state, .DOS_Setup))
	testing.expect(t, !install_state_advance_milestone(&state, .First_Reboot))
	state.reset_count = 1
	testing.expect(t, install_state_milestone_reached(&state, .First_Reboot))
	testing.expect(t, install_state_advance_milestone(&state, .First_Reboot))
	testing.expect(t, install_state_advance_milestone(&state, .Hardware_Detection))
	testing.expect(t, install_state_milestone_reached(&state, .First_Reboot))
	testing.expect(t, !install_state_advance_milestone(&state, .DOS_Setup))
}
