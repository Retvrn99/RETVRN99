// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:strings"

DEFAULT_RESULT_JSON :: "result.json"
DEFAULT_ARTIFACTS_DIRECTORY :: "artifacts"

Accept_Until :: enum {
	None,
	Hardware_Detection,
	Desktop,
}

Setup_Diagnostics :: enum {
	None,
	Hardware,
}

Legacy_Aperture_Mode :: enum {
	Auto,
	Scalar,
}

Options :: struct {
	test_device:         bool,
	strict_io:           bool,
	result_json:         string,
	artifacts:           string,
	install_windows:     bool,
	install_windows_path: string,
	accept_until:        Accept_Until,
	setup_diagnostics:  Setup_Diagnostics,
	mouse_stress:        bool,
	input_script:         string,
	firmware_log_all:    bool,
	guest_report_kind:   Guest_Report_Kind,
	guest_report_kind_set: bool,
	legacy_aperture_mode: Legacy_Aperture_Mode,
	legacy_aperture_mode_set: bool,
	shutdown_trace:      bool,
}

Options_Diagnostic :: enum {
	None,
	Missing_Value,
	Invalid_Accept_Until,
	Invalid_Setup_Diagnostics,
	Invalid_Firmware_Log,
	Invalid_Guest_Report_Kind,
	Invalid_Legacy_Aperture_Mode,
	Test_Device_Required,
	Artifacts_Required,
}

options_parse :: proc(args: []string) -> (Options, Options_Diagnostic) {
	options: Options
	for argument in args {
		switch argument {
		case "--test-device":
			options.test_device = true
		case "--strict-io":
			options.strict_io = true
		case "--result-json":
			options.result_json = DEFAULT_RESULT_JSON
		case "--artifacts":
			options.artifacts = DEFAULT_ARTIFACTS_DIRECTORY
		case "--install-windows":
			options.install_windows = true
		case "--mouse-stress":
			options.mouse_stress = true
		case "--shutdown-trace":
			options.shutdown_trace = true
		case "--accept-until", "--setup-diagnostics", "--firmware-log", "--input-script",
		     "--guest-report-kind", "--legacy-aperture-mode":
			return {}, .Missing_Value
		}
		if strings.has_prefix(argument, "--result-json:") ||
		   strings.has_prefix(argument, "--result-json=") {
			options.result_json = argument[len("--result-json:"):]
			if options.result_json == "" {return {}, .Missing_Value}
		}
		if strings.has_prefix(argument, "--artifacts:") ||
		   strings.has_prefix(argument, "--artifacts=") {
			options.artifacts = argument[len("--artifacts:"):]
			if options.artifacts == "" {return {}, .Missing_Value}
		}
		if strings.has_prefix(argument, "--install-windows:") ||
		   strings.has_prefix(argument, "--install-windows=") {
			options.install_windows = true
			options.install_windows_path = argument[len("--install-windows:"):]
			if options.install_windows_path == "" {return {}, .Missing_Value}
		}
		if strings.has_prefix(argument, "--accept-until:") ||
		   strings.has_prefix(argument, "--accept-until=") {
			value := argument[len("--accept-until:"):]
			switch value {
			case "hardware-detection":
				options.accept_until = .Hardware_Detection
			case "desktop":
				options.accept_until = .Desktop
			case "":
				return {}, .Missing_Value
			case:
				return {}, .Invalid_Accept_Until
			}
		}
		if strings.has_prefix(argument, "--setup-diagnostics:") ||
		   strings.has_prefix(argument, "--setup-diagnostics=") {
			value := argument[len("--setup-diagnostics:"):]
			switch value {
			case "hardware":
				options.setup_diagnostics = .Hardware
			case "":
				return {}, .Missing_Value
			case:
				return {}, .Invalid_Setup_Diagnostics
			}
		}
		if strings.has_prefix(argument, "--firmware-log:") ||
		   strings.has_prefix(argument, "--firmware-log=") {
			value := argument[len("--firmware-log:"):]
			if value != "all" {return {}, .Invalid_Firmware_Log}
			options.firmware_log_all = true
		}
		if strings.has_prefix(argument, "--input-script:") ||
		   strings.has_prefix(argument, "--input-script=") {
			options.input_script = argument[len("--input-script:"):]
			if options.input_script == "" {return {}, .Missing_Value}
		}
		if strings.has_prefix(argument, "--guest-report-kind:") ||
		   strings.has_prefix(argument, "--guest-report-kind=") {
			value := argument[len("--guest-report-kind:"):]
			switch value {
			case "gswgfx":
				options.guest_report_kind = .GSWGFX
			case "legacy-vga":
				options.guest_report_kind = .Legacy_VGA
			case "":
				return {}, .Missing_Value
			case:
				return {}, .Invalid_Guest_Report_Kind
			}
			options.guest_report_kind_set = true
		}
		if strings.has_prefix(argument, "--legacy-aperture-mode:") ||
		   strings.has_prefix(argument, "--legacy-aperture-mode=") {
			value := argument[len("--legacy-aperture-mode:"):]
			switch value {
			case "auto":
				options.legacy_aperture_mode = .Auto
			case "scalar":
				options.legacy_aperture_mode = .Scalar
			case "":
				return {}, .Missing_Value
			case:
				return {}, .Invalid_Legacy_Aperture_Mode
			}
			options.legacy_aperture_mode_set = true
		}
	}
	if options.setup_diagnostics == .Hardware && options.artifacts == "" {
		options.artifacts = DEFAULT_ARTIFACTS_DIRECTORY
	}
	if options.guest_report_kind_set && !options.test_device {
		return {}, .Test_Device_Required
	}
	if (options.guest_report_kind_set || options.shutdown_trace) && options.artifacts == "" {
		return {}, .Artifacts_Required
	}
	return options, .None
}

options_request_headless :: proc(options: ^Options) -> bool {
	if options == nil {return false}
	return(
		options.test_device ||
	       options.strict_io ||
	       options.result_json != "" ||
	       options.artifacts != "" ||
	       options.install_windows ||
	       options.accept_until != .None ||
	       options.setup_diagnostics != .None ||
		options.mouse_stress ||
		options.input_script != "" ||
		options.guest_report_kind_set ||
		options.legacy_aperture_mode_set ||
		options.shutdown_trace \
	)
}
