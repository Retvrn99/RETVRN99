// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
install_state_test_v3_milestones_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase = .Setup_Running,
		milestone = .Hardware_Detection,
		source_path = "WIN98SE.ISO",
		reset_count = 2,
		saved_cmos_valid = true,
		saved_cmos_38 = 0xA5,
		saved_cmos_3d = 0x5A,
	}
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), `"version": 3`))
	testing.expect(t, strings.contains(string(data), `"milestone": "hardware_detection"`))
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, Install_Phase.Setup_Running)
	testing.expect_value(t, loaded.milestone, Install_Milestone.Hardware_Detection)
	testing.expect_value(t, loaded.reset_count, u32(2))
}

@(test)
install_state_test_each_explicit_milestone_round_trips :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	cases := [?]struct {
		milestone: Install_Milestone,
		reset_count: u32,
	}{
		{.DOS_Setup, 0},
		{.First_Reboot, 1},
		{.Hardware_Detection, 1},
	}
	for candidate in cases {
		state := Install_State {
			phase = .Setup_Running,
			milestone = candidate.milestone,
			source_path = "WIN98SE.ISO",
			reset_count = candidate.reset_count,
		}
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
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.DOS_Setup)
	install_state_destroy(&loaded)

	v2 := `{"version":2,"phase":"setup_running","source_path":"WIN98SE.ISO","reset_count":2,"saved_cmos_valid":true}`
	testing.expect(t, os.write_entire_file(path, v2) == nil)
	loaded, diagnostic = install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.First_Reboot)
	testing.expect(t, loaded.saved_cmos_valid)
	testing.expect_value(t, install_state_save(path, &loaded), Install_State_Diagnostic.None)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), `"version": 3`))
	testing.expect(t, strings.contains(string(data), `"milestone": "first_reboot"`))
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
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.milestone, Install_Milestone.None)
}

@(test)
install_state_test_save_normalizes_existing_setup_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase = .Setup_Running,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
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
		phase = .Launch_Pending,
		milestone = .Hardware_Detection,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
	testing.expect_value(t, install_state_save(path, &wrong_phase), Install_State_Diagnostic.Invalid_State)
}

@(test)
install_state_test_milestones_advance_monotonically :: proc(t: ^testing.T) {
	state := Install_State {
		phase = .Setup_Running,
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
