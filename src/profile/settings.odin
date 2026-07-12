// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:encoding/json"
import "core:os"
import config "../vmconfig"

SETTINGS_VERSION :: 1

Settings :: struct {
	cpu_mode: config.Cpu_Mode,
}

Settings_Diagnostic :: enum {
	None,
	Missing,
	Read_Failed,
	Malformed,
	Unsupported_Version,
	Unknown_CPU,
	Invalid_CPU,
	Create_Directory_Failed,
	Encode_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

settings_default :: proc() -> Settings {
	return Settings{cpu_mode = .GSW_886}
}

settings_load :: proc(path: string) -> (Settings, Settings_Diagnostic) {
	result := settings_default()
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		if rerr == os.General_Error.Not_Exist {
			return result, .Missing
		}
		return result, .Read_Failed
	}
	defer delete(data)

	disk: Disk_Settings
	defer delete(disk.cpu_mode)
	if jerr := json.unmarshal(data, &disk); jerr != nil {
		return result, .Malformed
	}
	if disk.version != SETTINGS_VERSION {
		return result, .Unsupported_Version
	}

	mode, known := cpu_mode_parse(disk.cpu_mode)
	if !known {
		return result, .Unknown_CPU
	}
	result.cpu_mode = mode
	return result, .None
}

settings_save :: proc(path: string, settings: Settings) -> Settings_Diagnostic {
	name, valid := cpu_mode_serialize(settings.cpu_mode)
	if !valid {
		return .Invalid_CPU
	}
	disk := Disk_Settings{version = SETTINGS_VERSION, cpu_mode = name}
	data, jerr := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if jerr != nil {
		return .Encode_Failed
	}
	defer delete(data)

	switch atomic_replace(path, data, "settings") {
	case .None: return .None
	case .Create_Directory_Failed: return .Create_Directory_Failed
	case .Temporary_Path_Failed: return .Temporary_Path_Failed
	case .Write_Failed: return .Write_Failed
	case .Replace_Failed: return .Replace_Failed
	}
	return .Write_Failed
}

@(private)
Disk_Settings :: struct {
	version:  int    `json:"version"`,
	cpu_mode: string `json:"cpu_mode"`,
}

@(private = "file")
cpu_mode_parse :: proc(name: string) -> (config.Cpu_Mode, bool) {
	switch name {
	case "GSW-886":
		return .GSW_886, true
	case "Turbo":
		return .Turbo, true
	}
	return .GSW_886, false
}

@(private = "file")
cpu_mode_serialize :: proc(mode: config.Cpu_Mode) -> (string, bool) {
	switch mode {
	case .GSW_886:
		return config.cpu_mode_name(mode), true
	case .Turbo:
		return config.cpu_mode_name(mode), true
	}
	return "", false
}
