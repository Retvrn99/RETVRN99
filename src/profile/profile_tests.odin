// SPDX-License-Identifier: GPL-3.0-only
package profile

import config "../vmconfig"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_profile_paths_from_home :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	paths, err := paths_from_home("test-home")
	testing.expect(t, err == nil)
	defer paths_destroy(&paths)

	when ODIN_OS == .Windows {
		testing.expect_value(t, paths.root, `test-home\.retvrn99`)
		testing.expect_value(t, paths.c_drive, `test-home\.retvrn99\c_drive`)
		testing.expect_value(t, paths.settings, `test-home\.retvrn99\settings.json`)
		testing.expect_value(t, paths.cmos, `test-home\.retvrn99\cmos.bin`)
		testing.expect_value(t, paths.install, `test-home\.retvrn99\install`)
		testing.expect_value(t, paths.install_state, `test-home\.retvrn99\install-state.json`)
	} else {
		testing.expect_value(t, paths.root, "test-home/.retvrn99")
		testing.expect_value(t, paths.c_drive, "test-home/.retvrn99/c_drive")
		testing.expect_value(t, paths.settings, "test-home/.retvrn99/settings.json")
		testing.expect_value(t, paths.cmos, "test-home/.retvrn99/cmos.bin")
		testing.expect_value(t, paths.install, "test-home/.retvrn99/install")
		testing.expect_value(t, paths.install_state, "test-home/.retvrn99/install-state.json")
	}
}

@(test)
test_install_state_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase            = .Launch_Pending,
		source_path      = `D:\media\WIN98SE.ISO`,
		reset_count      = 2,
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, Install_Phase.Launch_Pending)
	testing.expect_value(t, loaded.source_path, state.source_path)
	testing.expect_value(t, loaded.reset_count, u32(2))
	testing.expect(t, loaded.saved_cmos_valid)
	testing.expect_value(t, loaded.saved_cmos_38, u8(0xA5))
	testing.expect_value(t, loaded.saved_cmos_3d, u8(0x5A))
}

@(test)
test_install_state_inactive_replaces_active_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	active := Install_State {
		phase         = .Setup_Running,
		source_path   = `D:\media\WIN98SE.ISO`,
		reset_count   = 3,
		saved_cmos_38 = 0xA5,
		saved_cmos_3d = 0x5A,
	}
	testing.expect_value(t, install_state_save(path, &active), Install_State_Diagnostic.None)
	testing.expect_value(t, install_state_save_inactive(path), Install_State_Diagnostic.None)

	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, Install_Phase.None)
	testing.expect_value(t, loaded.source_path, "")
	testing.expect_value(t, loaded.reset_count, u32(0))
	testing.expect(t, !loaded.saved_cmos_valid)
	testing.expect_value(t, loaded.saved_cmos_38, u8(0))
	testing.expect_value(t, loaded.saved_cmos_3d, u8(0))
}

@(test)
test_install_state_preparing_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	state := Install_State {
		phase            = .Preparing,
		source_path      = `D:\media\WIN98SE.ISO`,
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	testing.expect_value(t, install_state_save(path, &state), Install_State_Diagnostic.None)

	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, Install_Phase.Preparing)
	testing.expect_value(t, loaded.source_path, state.source_path)
	testing.expect(t, install_state_active(&loaded))
	testing.expect(t, loaded.saved_cmos_valid)
}

@(test)
test_install_state_v1_cmos_validity_migration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})
	legacy := `{"version":1,"phase":"launch_pending","source_path":"WIN98SE.ISO","saved_cmos_38":165,"saved_cmos_3d":90}`
	testing.expect(t, os.write_entire_file(path, legacy) == nil)
	loaded, diagnostic := install_state_load(path)
	defer install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect(t, loaded.saved_cmos_valid)

	unknown := `{"version":1,"phase":"launch_pending","source_path":"WIN98SE.ISO","saved_cmos_38":0,"saved_cmos_3d":0}`
	testing.expect(t, os.write_entire_file(path, unknown) == nil)
	install_state_destroy(&loaded)
	loaded, diagnostic = install_state_load(path)
	testing.expect_value(t, diagnostic, Install_State_Diagnostic.None)
	testing.expect(t, !loaded.saved_cmos_valid)
}

@(test)
test_install_state_validation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "install-state.json"})

	_, missing := install_state_load(path)
	testing.expect_value(t, missing, Install_State_Diagnostic.Missing)
	testing.expect(t, os.write_entire_file(path, `{"version":1,"phase":"future"}`) == nil)
	_, unknown := install_state_load(path)
	testing.expect_value(t, unknown, Install_State_Diagnostic.Unknown_Phase)
	testing.expect(
		t,
		os.write_entire_file(path, `{"version":1,"phase":"setup_running","source_path":""}`) ==
		nil,
	)
	_, invalid := install_state_load(path)
	testing.expect_value(t, invalid, Install_State_Diagnostic.Invalid_State)
}

@(test)
test_settings_default_and_missing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defaults := settings_default()
	testing.expect_value(t, defaults.cpu_mode, config.Cpu_Mode.GSW_886)

	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "missing.json"})
	loaded, diagnostic := settings_load(path)
	testing.expect_value(t, diagnostic, Settings_Diagnostic.Missing)
	testing.expect_value(t, loaded.cpu_mode, config.Cpu_Mode.GSW_886)
}

@(test)
test_settings_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "nested", "settings.json"})

	diagnostic := settings_save(path, Settings{cpu_mode = .Turbo})
	testing.expect_value(t, diagnostic, Settings_Diagnostic.None)
	loaded, load_diagnostic := settings_load(path)
	testing.expect_value(t, load_diagnostic, Settings_Diagnostic.None)
	testing.expect_value(t, loaded.cpu_mode, config.Cpu_Mode.Turbo)

	data, rerr := os.read_entire_file(path, context.allocator)
	testing.expect(t, rerr == nil)
	testing.expect(t, strings.contains(string(data), `"version": 1`))
	testing.expect(t, strings.contains(string(data), `"cpu_mode": "Turbo"`))

	testing.expect_value(
		t,
		settings_save(path, Settings{cpu_mode = .GSW_886}),
		Settings_Diagnostic.None,
	)
	replaced, replace_diagnostic := settings_load(path)
	testing.expect_value(t, replace_diagnostic, Settings_Diagnostic.None)
	testing.expect_value(t, replaced.cpu_mode, config.Cpu_Mode.GSW_886)
}

@(test)
test_settings_malformed_uses_default :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "settings.json"})
	testing.expect(t, os.write_entire_file(path, `{"version":`) == nil)

	loaded, diagnostic := settings_load(path)
	testing.expect_value(t, diagnostic, Settings_Diagnostic.Malformed)
	testing.expect_value(t, loaded.cpu_mode, config.Cpu_Mode.GSW_886)
}

@(test)
test_settings_unknown_cpu_uses_default :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "settings.json"})
	testing.expect(t, os.write_entire_file(path, `{"version":1,"cpu_mode":"Pentium-III"}`) == nil)

	loaded, diagnostic := settings_load(path)
	testing.expect_value(t, diagnostic, Settings_Diagnostic.Unknown_CPU)
	testing.expect_value(t, loaded.cpu_mode, config.Cpu_Mode.GSW_886)
}

@(test)
test_settings_unknown_keys_are_ignored :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := profile_test_directory(t)
	defer os.remove_all(dir)
	path, _ := filepath.join({dir, "settings.json"})
	contents := `{"version":1,"cpu_mode":"Turbo","future":{"enabled":true}}`
	testing.expect(t, os.write_entire_file(path, contents) == nil)

	loaded, diagnostic := settings_load(path)
	testing.expect_value(t, diagnostic, Settings_Diagnostic.None)
	testing.expect_value(t, loaded.cpu_mode, config.Cpu_Mode.Turbo)
}

@(private)
profile_test_directory :: proc(t: ^testing.T) -> string {
	base, berr := os.temp_directory(context.allocator)
	testing.expect(t, berr == nil)
	dir, derr := os.make_directory_temp(base, "retvrn99_profile_*", context.allocator)
	testing.expect(t, derr == nil)
	return dir
}
