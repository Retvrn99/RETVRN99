// SPDX-License-Identifier: GPL-3.0-only
package main

import "base:runtime"
import "host"
import sdl3 "vendor:sdl3"

Lifecycle_Watch :: struct {
	shared: ^Shared,
}

lifecycle_pause_update :: proc(event_type: sdl3.EventType) -> (active, handled: bool) {
	#partial switch event_type {
	case .WILL_ENTER_BACKGROUND, .DID_ENTER_BACKGROUND, .WILL_ENTER_FOREGROUND:
		return true, true
	case .DID_ENTER_FOREGROUND:
		return false, true
	}
	return false, false
}

lifecycle_event_watch :: proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
	context = runtime.default_context()
	watch := (^Lifecycle_Watch)(userdata)
	if watch == nil || watch.shared == nil || event == nil {return true}
	active, handled := lifecycle_pause_update(event.type)
	if handled {
		_ = push_cmd(watch.shared, Command {
			kind         = .Set_Pause,
			pause_reason = host.Pause_Reason.Host_Background,
			pause_active = active,
		})
	}
	return true
}
