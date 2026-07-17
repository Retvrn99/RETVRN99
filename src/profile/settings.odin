// SPDX-License-Identifier: GPL-3.0-only
package profile

import config "../vmconfig"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"

SETTINGS_VERSION :: 2
SETTINGS_LEGACY_VERSION :: 1

Settings :: struct {
	cpu_mode:        config.Cpu_Mode,
	hard_drive_path: string,
}

Settings_Diagnostic :: enum {
	None,
	Missing,
	Read_Failed,
	Malformed,
	Unsupported_Version,
	Unknown_CPU,
	Invalid_CPU,
	Invalid_Hard_Drive_Path,
	Create_Directory_Failed,
	Encode_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

Settings_Migration_Status :: enum {
	None,
	Version_1_To_2,
}

settings_default :: proc() -> Settings {
	return Settings{cpu_mode = .GSW_886}
}

settings_destroy :: proc(settings: ^Settings, allocator := context.allocator) {
	if settings == nil {return}
	delete(settings.hard_drive_path, allocator)
	settings^ = {}
}

settings_load :: proc(path: string) -> (
	Settings,
	Settings_Diagnostic,
	Settings_Migration_Status,
) {
	result := settings_default()
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		if rerr == os.General_Error.Not_Exist {
			return result, .Missing, .None
		}
		return result, .Read_Failed, .None
	}
	defer delete(data)

	disk: Disk_Settings
	defer delete(disk.cpu_mode)
	defer delete(disk.hard_drive_path)
	if jerr := json.unmarshal(data, &disk); jerr != nil {
		return result, .Malformed, .None
	}
	if disk.version != SETTINGS_LEGACY_VERSION && disk.version != SETTINGS_VERSION {
		return result, .Unsupported_Version, .None
	}

	mode, known := cpu_mode_parse(disk.cpu_mode)
	if !known {
		return result, .Unknown_CPU, .None
	}
	result.cpu_mode = mode
	migration := Settings_Migration_Status.None
	if disk.version == SETTINGS_LEGACY_VERSION {
		migration = .Version_1_To_2
	}
	if disk.version == SETTINGS_VERSION && len(disk.hard_drive_path) > 0 {
		normalized, valid := settings_normalize_hard_drive_path(disk.hard_drive_path)
		if !valid {
			return settings_default(), .Invalid_Hard_Drive_Path, .None
		}
		result.hard_drive_path = normalized
	}
	return result, .None, migration
}

settings_migrate :: proc(
	path: string,
	settings: Settings,
	status: Settings_Migration_Status,
) -> Settings_Diagnostic {
	switch status {
	case .None:
		return .None
	case .Version_1_To_2:
		return settings_save(path, Settings{cpu_mode = settings.cpu_mode})
	}
	return .Unsupported_Version
}

settings_save :: proc(path: string, settings: Settings) -> Settings_Diagnostic {
	name, valid := cpu_mode_serialize(settings.cpu_mode)
	if !valid {
		return .Invalid_CPU
	}
	normalized_path := ""
	if len(settings.hard_drive_path) > 0 {
		path_valid: bool
		normalized_path, path_valid = settings_normalize_hard_drive_path(settings.hard_drive_path)
		if !path_valid {
			return .Invalid_Hard_Drive_Path
		}
		defer delete(normalized_path)
	}
	disk := Disk_Settings {
		version         = SETTINGS_VERSION,
		cpu_mode        = name,
		hard_drive_path = normalized_path,
	}
	data, jerr := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if jerr != nil {
		return .Encode_Failed
	}
	defer delete(data)

	switch atomic_replace(path, data, "settings") {
	case .None:
		return .None
	case .Create_Directory_Failed:
		return .Create_Directory_Failed
	case .Temporary_Path_Failed:
		return .Temporary_Path_Failed
	case .Write_Failed:
		return .Write_Failed
	case .Replace_Failed:
		return .Replace_Failed
	}
	return .Write_Failed
}

@(private)
Disk_Settings :: struct {
	version:         int `json:"version"`,
	cpu_mode:        string `json:"cpu_mode"`,
	hard_drive_path: string `json:"hard_drive_path"`,
}

settings_normalize_hard_drive_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if len(path) == 0 {return "", true}
	absolute, absolute_error := filepath.abs(path, allocator)
	if absolute_error != nil {return "", false}
	defer delete(absolute, allocator)
	normalized, clean_error := filepath.clean(absolute, allocator)
	if clean_error != nil {return "", false}
	return normalized, true
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
