// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:strings"
import sdl3 "vendor:sdl3"

Host_Hotkey :: enum u8 {
	None,
	Release_Input,
	Toggle_Fullscreen,
	Toggle_Turbo,
	Volume_Down,
	Volume_Up,
}

Hotkey_Modifier :: enum u8 {
	Control,
	Alt,
	Shift,
	Super,
}

Hotkey_Modifiers :: bit_set[Hotkey_Modifier; u8]

Hotkey_Binding :: struct {
	modifiers: Hotkey_Modifiers,
	scancode:  sdl3.Scancode,
	assigned:  bool,
}

Hotkey_Config :: struct {
	bindings: [Host_Hotkey]Hotkey_Binding,
}

HOST_VOLUME_STEP :: f32(0.1)
HOTKEY_UNASSIGNED :: "None"

host_hotkey_action_id :: proc(action: Host_Hotkey) -> string {
	switch action {
	case .Release_Input:     return "release_input"
	case .Toggle_Fullscreen: return "toggle_fullscreen"
	case .Toggle_Turbo:      return "toggle_turbo"
	case .Volume_Down:       return "volume_down"
	case .Volume_Up:         return "volume_up"
	case .None:              return ""
	}
	return ""
}

host_hotkey_action_name :: proc(action: Host_Hotkey) -> string {
	switch action {
	case .Release_Input:     return "Release Input"
	case .Toggle_Fullscreen: return "Toggle Fullscreen"
	case .Toggle_Turbo:      return "Toggle Turbo"
	case .Volume_Down:       return "Volume Down"
	case .Volume_Up:         return "Volume Up"
	case .None:              return ""
	}
	return ""
}

host_hotkey_defaults :: proc() -> Hotkey_Config {
	config: Hotkey_Config
	modifiers := Hotkey_Modifiers{.Super, .Shift}
	config.bindings[.Release_Input] = {modifiers, .F1, true}
	config.bindings[.Toggle_Fullscreen] = {modifiers, .F3, true}
	config.bindings[.Toggle_Turbo] = {modifiers, .F5, true}
	config.bindings[.Volume_Down] = {modifiers, .F9, true}
	config.bindings[.Volume_Up] = {modifiers, .F10, true}
	return config
}

host_hotkey_binding_default :: proc(action: Host_Hotkey) -> Hotkey_Binding {
	return host_hotkey_defaults().bindings[action]
}

host_hotkey_parse :: proc(text: string) -> (binding: Hotkey_Binding, valid: bool) {
	trimmed := strings.trim_space(text)
	if strings.equal_fold(trimmed, HOTKEY_UNASSIGNED) {return {}, true}
	if trimmed == "" {return {}, false}
	parts := strings.split(trimmed, "+", context.temp_allocator)
	if len(parts) == 0 {return {}, false}
	key_seen := false
	for raw_part in parts {
		part := strings.trim_space(raw_part)
		if part == "" {return {}, false}
		if strings.equal_fold(part, "Ctrl") || strings.equal_fold(part, "Control") {
			if .Control in binding.modifiers || key_seen {return {}, false}
			binding.modifiers += {.Control}
			continue
		}
		if strings.equal_fold(part, "Alt") {
			if .Alt in binding.modifiers || key_seen {return {}, false}
			binding.modifiers += {.Alt}
			continue
		}
		if strings.equal_fold(part, "Shift") {
			if .Shift in binding.modifiers || key_seen {return {}, false}
			binding.modifiers += {.Shift}
			continue
		}
		if strings.equal_fold(part, "Super") ||
		   strings.equal_fold(part, "Win") ||
		   strings.equal_fold(part, "Windows") {
			if .Super in binding.modifiers || key_seen {return {}, false}
			binding.modifiers += {.Super}
			continue
		}
		if key_seen {return {}, false}
		name := strings.clone_to_cstring(part, context.temp_allocator)
		binding.scancode = sdl3.GetScancodeFromName(name)
		if binding.scancode == .UNKNOWN || host_hotkey_modifier_scancode(binding.scancode) {
			return {}, false
		}
		binding.assigned = true
		key_seen = true
	}
	return binding, key_seen
}

host_hotkey_serialize :: proc(
	binding: Hotkey_Binding,
	allocator := context.allocator,
) -> (string, bool) {
	if !binding.assigned {return strings.clone(HOTKEY_UNASSIGNED, allocator), true}
	if binding.scancode == .UNKNOWN || host_hotkey_modifier_scancode(binding.scancode) {
		return "", false
	}
	name_value := sdl3.GetScancodeName(binding.scancode)
	if name_value == nil || string(name_value) == "" {return "", false}
	builder := strings.builder_make(0, 48, allocator)
	if .Super in binding.modifiers {strings.write_string(&builder, "Super+")}
	if .Control in binding.modifiers {strings.write_string(&builder, "Ctrl+")}
	if .Alt in binding.modifiers {strings.write_string(&builder, "Alt+")}
	if .Shift in binding.modifiers {strings.write_string(&builder, "Shift+")}
	strings.write_string(&builder, string(name_value))
	return strings.to_string(builder), true
}

host_hotkey_config_set_text :: proc(
	config: ^Hotkey_Config,
	action: Host_Hotkey,
	text: string,
) -> bool {
	if config == nil || action == .None {return false}
	binding, valid := host_hotkey_parse(text)
	if !valid {return false}
	config.bindings[action] = binding
	return true
}

host_hotkey_conflict :: proc(
	config: ^Hotkey_Config,
	action: Host_Hotkey,
	binding: Hotkey_Binding,
) -> Host_Hotkey {
	if config == nil || action == .None || !binding.assigned {return .None}
	for candidate := Host_Hotkey.Release_Input; candidate <= .Volume_Up; candidate = Host_Hotkey(int(candidate) + 1) {
		if candidate == action {continue}
		if host_hotkey_binding_equal(config.bindings[candidate], binding) {return candidate}
	}
	return .None
}

host_hotkey_binding_equal :: proc(left, right: Hotkey_Binding) -> bool {
	if left.assigned != right.assigned {return false}
	if !left.assigned {return true}
	return left.scancode == right.scancode && left.modifiers == right.modifiers
}

host_hotkey_config_equal :: proc(left, right: Hotkey_Config) -> bool {
	for action := Host_Hotkey.Release_Input; action <= .Volume_Up; action = Host_Hotkey(int(action) + 1) {
		if !host_hotkey_binding_equal(left.bindings[action], right.bindings[action]) {return false}
	}
	return true
}

host_hotkey_from_key :: proc(
	scancode: sdl3.Scancode,
	modifiers: sdl3.Keymod,
	down, repeat: bool,
	config: ^Hotkey_Config = nil,
) -> Host_Hotkey {
	if !down || repeat {return .None}
	active_config := config
	defaults: Hotkey_Config
	if active_config == nil {
		defaults = host_hotkey_defaults()
		active_config = &defaults
	}
	normalized := host_hotkey_modifiers_from_sdl(modifiers)
	for action := Host_Hotkey.Release_Input; action <= .Volume_Up; action = Host_Hotkey(int(action) + 1) {
		binding := active_config.bindings[action]
		if binding.assigned && binding.scancode == scancode && binding.modifiers == normalized {
			return action
		}
	}
	return .None
}

host_hotkey_modifiers_from_sdl :: proc(modifiers: sdl3.Keymod) -> Hotkey_Modifiers {
	result: Hotkey_Modifiers
	if .LCTRL in modifiers || .RCTRL in modifiers {result += {.Control}}
	if .LALT in modifiers || .RALT in modifiers {result += {.Alt}}
	if .LSHIFT in modifiers || .RSHIFT in modifiers {result += {.Shift}}
	if .LGUI in modifiers || .RGUI in modifiers {result += {.Super}}
	return result
}

host_hotkey_modifier_scancode :: proc(scancode: sdl3.Scancode) -> bool {
	#partial switch scancode {
	case .LCTRL, .RCTRL, .LALT, .RALT, .LSHIFT, .RSHIFT, .LGUI, .RGUI:
		return true
	}
	return false
}

host_volume_adjust :: proc(gain: f32, hotkey: Host_Hotkey) -> f32 {
	#partial switch hotkey {
	case .Volume_Down:
		return max(0, gain - HOST_VOLUME_STEP)
	case .Volume_Up:
		return min(1, gain + HOST_VOLUME_STEP)
	}
	return gain
}
