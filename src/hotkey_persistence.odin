// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:strings"
import "host"
import "profile"

gui_hotkey_settings_store :: proc(
	settings: ^profile.Settings,
	config: host.Hotkey_Config,
	allocator := context.allocator,
) -> bool {
	if settings == nil {return false}
	values: [host.Host_Hotkey]string
	for action := host.Host_Hotkey.Release_Input;
	    action <= .Volume_Up;
	    action = host.Host_Hotkey(int(action) + 1) {
		serialized, valid := host.host_hotkey_serialize(config.bindings[action], allocator)
		if !valid {
			for value in values {delete(value, allocator)}
			return false
		}
		values[action] = serialized
	}
	delete(settings.hotkeys.release_input, allocator)
	delete(settings.hotkeys.toggle_fullscreen, allocator)
	delete(settings.hotkeys.toggle_turbo, allocator)
	delete(settings.hotkeys.volume_down, allocator)
	delete(settings.hotkeys.volume_up, allocator)
	settings.hotkeys = {
		release_input     = values[.Release_Input],
		toggle_fullscreen = values[.Toggle_Fullscreen],
		toggle_turbo      = values[.Toggle_Turbo],
		volume_down       = values[.Volume_Down],
		volume_up         = values[.Volume_Up],
	}
	return true
}

gui_release_binding_title :: proc(
	config: host.Hotkey_Config,
	allocator := context.allocator,
) -> string {
	text, valid := host.host_hotkey_serialize(config.bindings[.Release_Input], allocator)
	if valid && text != host.HOTKEY_UNASSIGNED {return text}
	delete(text, allocator)
	return strings.clone("Right Ctrl", allocator)
}
