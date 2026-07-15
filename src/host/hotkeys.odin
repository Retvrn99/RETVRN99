// SPDX-License-Identifier: GPL-3.0-only
package host

import sdl3 "vendor:sdl3"

Host_Hotkey :: enum u8 {
	None,
	Release_Input,
	Toggle_Fullscreen,
	Toggle_Turbo,
	Volume_Down,
	Volume_Up,
}

HOST_VOLUME_STEP :: f32(0.1)

host_hotkey_from_key :: proc(
	scancode: sdl3.Scancode,
	modifiers: sdl3.Keymod,
	down, repeat: bool,
) -> Host_Hotkey {
	gui_down := .LGUI in modifiers || .RGUI in modifiers
	shift_down := .LSHIFT in modifiers || .RSHIFT in modifiers
	if !down || repeat || !gui_down || !shift_down {return .None}
	#partial switch scancode {
	case .F1:
		return .Release_Input
	case .F3:
		return .Toggle_Fullscreen
	case .F5:
		return .Toggle_Turbo
	case .F9:
		return .Volume_Down
	case .F10:
		return .Volume_Up
	}
	return .None
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
