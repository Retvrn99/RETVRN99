// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import config "../vmconfig"

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
	} else {
		testing.expect_value(t, paths.root, "test-home/.retvrn99")
		testing.expect_value(t, paths.c_drive, "test-home/.retvrn99/c_drive")
		testing.expect_value(t, paths.settings, "test-home/.retvrn99/settings.json")
		testing.expect_value(t, paths.cmos, "test-home/.retvrn99/cmos.bin")
		testing.expect_value(t, paths.install, "test-home/.retvrn99/install")
	}
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
