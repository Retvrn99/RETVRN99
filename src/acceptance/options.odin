// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:strings"

DEFAULT_RESULT_JSON :: "result.json"
DEFAULT_ARTIFACTS_DIRECTORY :: "artifacts"

Accept_Until :: enum {
	None,
	Hardware_Detection,
}

Options :: struct {
	test_device:         bool,
	strict_io:           bool,
	result_json:         string,
	artifacts:           string,
	install_windows:     bool,
	install_windows_path: string,
	accept_until:        Accept_Until,
	mouse_stress:        bool,
	input_script:         string,
	firmware_log_all:    bool,
}

Options_Diagnostic :: enum {
	None,
	Missing_Value,
	Invalid_Accept_Until,
	Invalid_Firmware_Log,
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
		case "--accept-until", "--firmware-log", "--input-script":
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
			case "":
				return {}, .Missing_Value
			case:
				return {}, .Invalid_Accept_Until
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
		options.mouse_stress ||
		options.input_script != "" \
	)
}
