// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:testing"

@(test)
acceptance_options_test_all_headless_flags :: proc(t: ^testing.T) {
	args := []string {
		"--test-device",
		"--strict-io",
		"--result-json:out/result.json",
		"--artifacts=out/artifacts",
		"--install-windows:WIN98SE.ISO",
		"--accept-until:hardware-detection",
		"--mouse-stress",
		"--firmware-log:all",
	}
	options, diagnostic := options_parse(args)
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect(t, options.test_device)
	testing.expect(t, options.strict_io)
	testing.expect_value(t, options.result_json, "out/result.json")
	testing.expect_value(t, options.artifacts, "out/artifacts")
	testing.expect(t, options.install_windows)
	testing.expect_value(t, options.install_windows_path, "WIN98SE.ISO")
	testing.expect_value(t, options.accept_until, Accept_Until.Hardware_Detection)
	testing.expect(t, options.mouse_stress)
	testing.expect(t, options.firmware_log_all)
	testing.expect(t, options_request_headless(&options))
}

@(test)
acceptance_options_test_bare_output_flags_have_bounded_defaults :: proc(t: ^testing.T) {
	options, diagnostic := options_parse({"--result-json", "--artifacts", "--install-windows"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect_value(t, options.result_json, DEFAULT_RESULT_JSON)
	testing.expect_value(t, options.artifacts, DEFAULT_ARTIFACTS_DIRECTORY)
	testing.expect(t, options.install_windows)
	testing.expect_value(t, options.install_windows_path, "")
}

@(test)
acceptance_options_test_rejects_invalid_values :: proc(t: ^testing.T) {
	_, diagnostic := options_parse({"--accept-until:desktop"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Accept_Until)
	_, diagnostic = options_parse({"--result-json:"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--firmware-log:verbose"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Firmware_Log)
	_, diagnostic = options_parse({"--accept-until"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--firmware-log"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
}

@(test)
acceptance_options_test_unrelated_arguments_are_ignored :: proc(t: ^testing.T) {
	options, diagnostic := options_parse({"--console", "--seconds:3", "--cdrom:disc.iso"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect(t, !options_request_headless(&options))
}
