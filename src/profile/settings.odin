// SPDX-License-Identifier: GPL-3.0-only
package profile

import opticaldrive "../opticaldrive"
import config "../vmconfig"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

SETTINGS_VERSION :: 3
SETTINGS_LEGACY_VERSION :: 1
SETTINGS_PREVIOUS_VERSION :: 2

HOTKEY_DEFAULT_RELEASE_INPUT :: "Super+Shift+F1"
HOTKEY_DEFAULT_FULLSCREEN :: "Super+Shift+F3"
HOTKEY_DEFAULT_TURBO :: "Super+Shift+F5"
HOTKEY_DEFAULT_VOLUME_DOWN :: "Super+Shift+F9"
HOTKEY_DEFAULT_VOLUME_UP :: "Super+Shift+F10"

Hotkey_Settings :: struct {
	release_input:     string,
	toggle_fullscreen: string,
	toggle_turbo:      string,
	volume_down:       string,
	volume_up:         string,
}

Settings :: struct {
	cpu_mode:        config.Cpu_Mode,
	hard_drive_path: string,
	floppy_path:     string,
	cdrom_path:      string,
	hotkeys:         Hotkey_Settings,
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
	Invalid_Floppy_Path,
	Invalid_Cdrom_Path,
	Create_Directory_Failed,
	Encode_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

Settings_Migration_Status :: enum {
	None,
	Version_1_To_3,
	Version_2_To_3,
}

settings_default :: proc() -> Settings {
	return Settings {
		cpu_mode = .GSW_886,
		hotkeys = {
			release_input = strings.clone(HOTKEY_DEFAULT_RELEASE_INPUT),
			toggle_fullscreen = strings.clone(HOTKEY_DEFAULT_FULLSCREEN),
			toggle_turbo = strings.clone(HOTKEY_DEFAULT_TURBO),
			volume_down = strings.clone(HOTKEY_DEFAULT_VOLUME_DOWN),
			volume_up = strings.clone(HOTKEY_DEFAULT_VOLUME_UP),
		},
	}
}

settings_clone :: proc(settings: Settings, allocator := context.allocator) -> Settings {
	result := settings
	result.hard_drive_path = strings.clone(settings.hard_drive_path, allocator)
	result.floppy_path = strings.clone(settings.floppy_path, allocator)
	result.cdrom_path = strings.clone(settings.cdrom_path, allocator)
	result.hotkeys.release_input = strings.clone(settings.hotkeys.release_input, allocator)
	result.hotkeys.toggle_fullscreen = strings.clone(settings.hotkeys.toggle_fullscreen, allocator)
	result.hotkeys.toggle_turbo = strings.clone(settings.hotkeys.toggle_turbo, allocator)
	result.hotkeys.volume_down = strings.clone(settings.hotkeys.volume_down, allocator)
	result.hotkeys.volume_up = strings.clone(settings.hotkeys.volume_up, allocator)
	return result
}

settings_destroy :: proc(settings: ^Settings, allocator := context.allocator) {
	if settings == nil {return}
	delete(settings.hard_drive_path, allocator)
	delete(settings.floppy_path, allocator)
	delete(settings.cdrom_path, allocator)
	delete(settings.hotkeys.release_input, allocator)
	delete(settings.hotkeys.toggle_fullscreen, allocator)
	delete(settings.hotkeys.toggle_turbo, allocator)
	delete(settings.hotkeys.volume_down, allocator)
	delete(settings.hotkeys.volume_up, allocator)
	settings^ = {}
}

settings_load :: proc(path: string) -> (Settings, Settings_Diagnostic, Settings_Migration_Status) {
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
	defer delete(disk.floppy_path)
	defer delete(disk.cdrom_path)
	defer delete(disk.hotkey_release_input)
	defer delete(disk.hotkey_toggle_fullscreen)
	defer delete(disk.hotkey_toggle_turbo)
	defer delete(disk.hotkey_volume_down)
	defer delete(disk.hotkey_volume_up)
	if jerr := json.unmarshal(data, &disk); jerr != nil {
		return result, .Malformed, .None
	}
	if disk.version != SETTINGS_LEGACY_VERSION &&
	   disk.version != SETTINGS_PREVIOUS_VERSION &&
	   disk.version != SETTINGS_VERSION {
		return result, .Unsupported_Version, .None
	}

	mode, known := cpu_mode_parse(disk.cpu_mode)
	if !known {
		return result, .Unknown_CPU, .None
	}
	result.cpu_mode = mode
	migration := Settings_Migration_Status.None
	if disk.version == SETTINGS_LEGACY_VERSION {
		migration = .Version_1_To_3
	} else if disk.version == SETTINGS_PREVIOUS_VERSION {
		migration = .Version_2_To_3
	}
	if disk.version != SETTINGS_LEGACY_VERSION && len(disk.hard_drive_path) > 0 {
		normalized, valid := settings_normalize_hard_drive_path(disk.hard_drive_path)
		if !valid {
			return result, .Invalid_Hard_Drive_Path, .None
		}
		result.hard_drive_path = normalized
	}
	if disk.version == SETTINGS_VERSION {
		delete(result.hotkeys.release_input)
		delete(result.hotkeys.toggle_fullscreen)
		delete(result.hotkeys.toggle_turbo)
		delete(result.hotkeys.volume_down)
		delete(result.hotkeys.volume_up)
		result.hotkeys = hotkey_settings_clone_or_default(
			{
				release_input = disk.hotkey_release_input,
				toggle_fullscreen = disk.hotkey_toggle_fullscreen,
				toggle_turbo = disk.hotkey_toggle_turbo,
				volume_down = disk.hotkey_volume_down,
				volume_up = disk.hotkey_volume_up,
			},
		)
		if len(disk.floppy_path) > 0 {
			normalized, valid := settings_normalize_media_path(disk.floppy_path)
			if !valid {return result, .Invalid_Floppy_Path, .None}
			result.floppy_path = normalized
		}
		if len(disk.cdrom_path) > 0 {
			normalized, valid := settings_normalize_media_path(disk.cdrom_path)
			if !valid {return result, .Invalid_Cdrom_Path, .None}
			result.cdrom_path = normalized
		}
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
	case .Version_1_To_3:
		migrated := settings_default()
		defer settings_destroy(&migrated)
		migrated.cpu_mode = settings.cpu_mode
		return settings_save(path, migrated)
	case .Version_2_To_3:
		return settings_save(path, settings)
	}
	return .Unsupported_Version
}

settings_save :: proc(path: string, settings: Settings) -> Settings_Diagnostic {
	name, valid := cpu_mode_serialize(settings.cpu_mode)
	if !valid {
		return .Invalid_CPU
	}
	normalized_path := ""
	defer delete(normalized_path)
	if len(settings.hard_drive_path) > 0 {
		path_valid: bool
		normalized_path, path_valid = settings_normalize_hard_drive_path(settings.hard_drive_path)
		if !path_valid {
			return .Invalid_Hard_Drive_Path
		}
	}
	normalized_floppy_path := ""
	defer delete(normalized_floppy_path)
	if len(settings.floppy_path) > 0 {
		path_valid: bool
		normalized_floppy_path, path_valid = settings_normalize_media_path(settings.floppy_path)
		if !path_valid {return .Invalid_Floppy_Path}
	}
	normalized_cdrom_path := ""
	defer delete(normalized_cdrom_path)
	if len(settings.cdrom_path) > 0 {
		path_valid: bool
		normalized_cdrom_path, path_valid = settings_normalize_media_path(settings.cdrom_path)
		if !path_valid {return .Invalid_Cdrom_Path}
	}
	hotkeys := hotkey_settings_with_defaults(settings.hotkeys)
	disk := Disk_Settings {
		version                  = SETTINGS_VERSION,
		cpu_mode                 = name,
		hard_drive_path          = normalized_path,
		floppy_path              = normalized_floppy_path,
		cdrom_path               = normalized_cdrom_path,
		hotkey_release_input     = hotkeys.release_input,
		hotkey_toggle_fullscreen = hotkeys.toggle_fullscreen,
		hotkey_toggle_turbo      = hotkeys.toggle_turbo,
		hotkey_volume_down       = hotkeys.volume_down,
		hotkey_volume_up         = hotkeys.volume_up,
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
	version:                  int `json:"version"`,
	cpu_mode:                 string `json:"cpu_mode"`,
	hard_drive_path:          string `json:"hard_drive_path"`,
	floppy_path:              string `json:"floppy_path"`,
	cdrom_path:               string `json:"cdrom_path"`,
	hotkey_release_input:     string `json:"hotkey_release_input"`,
	hotkey_toggle_fullscreen: string `json:"hotkey_toggle_fullscreen"`,
	hotkey_toggle_turbo:      string `json:"hotkey_toggle_turbo"`,
	hotkey_volume_down:       string `json:"hotkey_volume_down"`,
	hotkey_volume_up:         string `json:"hotkey_volume_up"`,
}

@(private = "file")
hotkey_settings_with_defaults :: proc(settings: Hotkey_Settings) -> Hotkey_Settings {
	return {
		release_input = settings.release_input != "" ? settings.release_input : HOTKEY_DEFAULT_RELEASE_INPUT,
		toggle_fullscreen = settings.toggle_fullscreen != "" ? settings.toggle_fullscreen : HOTKEY_DEFAULT_FULLSCREEN,
		toggle_turbo = settings.toggle_turbo != "" ? settings.toggle_turbo : HOTKEY_DEFAULT_TURBO,
		volume_down = settings.volume_down != "" ? settings.volume_down : HOTKEY_DEFAULT_VOLUME_DOWN,
		volume_up = settings.volume_up != "" ? settings.volume_up : HOTKEY_DEFAULT_VOLUME_UP,
	}
}

@(private = "file")
hotkey_settings_clone_or_default :: proc(settings: Hotkey_Settings) -> Hotkey_Settings {
	values := hotkey_settings_with_defaults(settings)
	return {
		release_input = strings.clone(values.release_input),
		toggle_fullscreen = strings.clone(values.toggle_fullscreen),
		toggle_turbo = strings.clone(values.toggle_turbo),
		volume_down = strings.clone(values.volume_down),
		volume_up = strings.clone(values.volume_up),
	}
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

settings_normalize_media_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	string,
	bool,
) {
	if opticaldrive.is_path(path) {return strings.clone(path, allocator), true}
	return settings_normalize_hard_drive_path(path, allocator)
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
