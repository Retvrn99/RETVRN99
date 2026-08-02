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
		"--setup-diagnostics=hardware",
		"--mouse-stress",
		"--input-script:setup.input",
		"--firmware-log:all",
		"--guest-report-kind:legacy-vga",
		"--legacy-aperture-mode:scalar",
		"--shutdown-trace",
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
	testing.expect_value(t, options.setup_diagnostics, Setup_Diagnostics.Hardware)
	testing.expect(t, options.mouse_stress)
	testing.expect_value(t, options.input_script, "setup.input")
	testing.expect(t, options.firmware_log_all)
	testing.expect_value(t, options.guest_report_kind, Guest_Report_Kind.Legacy_VGA)
	testing.expect(t, options.guest_report_kind_set)
	testing.expect_value(t, options.legacy_aperture_mode, Legacy_Aperture_Mode.Scalar)
	testing.expect(t, options.legacy_aperture_mode_set)
	testing.expect(t, options.shutdown_trace)
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
	testing.expect_value(t, options.guest_report_kind, Guest_Report_Kind.GSWGFX)
	testing.expect_value(t, options.legacy_aperture_mode, Legacy_Aperture_Mode.Auto)
}

@(test)
acceptance_options_test_rejects_invalid_values :: proc(t: ^testing.T) {
	options, diagnostic := options_parse({"--accept-until:desktop"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect_value(t, options.accept_until, Accept_Until.Desktop)
	_, diagnostic = options_parse({"--result-json:"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--firmware-log:verbose"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Firmware_Log)
	_, diagnostic = options_parse({"--setup-diagnostics:verbose"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Setup_Diagnostics)
	_, diagnostic = options_parse({"--accept-until"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--firmware-log"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--setup-diagnostics"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--input-script:"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--guest-report-kind:vbe"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Guest_Report_Kind)
	_, diagnostic = options_parse({"--legacy-aperture-mode:native"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Invalid_Legacy_Aperture_Mode)
	_, diagnostic = options_parse({"--guest-report-kind"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
	_, diagnostic = options_parse({"--legacy-aperture-mode="})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Missing_Value)
}

@(test)
acceptance_options_test_report_and_shutdown_controls_fail_closed :: proc(t: ^testing.T) {
	_, diagnostic := options_parse({"--guest-report-kind:legacy-vga"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Test_Device_Required)
	_, diagnostic = options_parse({"--test-device", "--guest-report-kind:legacy-vga"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Artifacts_Required)
	_, diagnostic = options_parse({"--shutdown-trace"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Artifacts_Required)
	options: Options
	options, diagnostic = options_parse({"--shutdown-trace", "--artifacts:out"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect(t, options.shutdown_trace)
	options, diagnostic = options_parse({
		"--test-device",
		"--artifacts:out",
		"--guest-report-kind:gswgfx",
		"--shutdown-trace",
	})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect_value(t, options.guest_report_kind, Guest_Report_Kind.GSWGFX)
	testing.expect(t, options.shutdown_trace)
}

@(test)
acceptance_options_test_aperture_mode_requests_headless :: proc(t: ^testing.T) {
	_, diagnostic := options_parse({"--legacy-aperture-mode:auto"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.Artifacts_Required)
	options: Options
	options, diagnostic = options_parse({
		"--legacy-aperture-mode:auto",
		"--artifacts:out",
	})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect_value(t, options.legacy_aperture_mode, Legacy_Aperture_Mode.Auto)
	testing.expect(t, options.legacy_aperture_mode_set)
	testing.expect(t, options_request_headless(&options))
}

@(test)
acceptance_options_test_hardware_diagnostics_default_artifacts :: proc(t: ^testing.T) {
	options, diagnostic := options_parse({"--setup-diagnostics=hardware"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect_value(t, options.setup_diagnostics, Setup_Diagnostics.Hardware)
	testing.expect_value(t, options.artifacts, DEFAULT_ARTIFACTS_DIRECTORY)
}

@(test)
acceptance_options_test_unrelated_arguments_are_ignored :: proc(t: ^testing.T) {
	options, diagnostic := options_parse({"--console", "--seconds:3", "--cdrom:disc.iso"})
	testing.expect_value(t, diagnostic, Options_Diagnostic.None)
	testing.expect(t, !options_request_headless(&options))
}
