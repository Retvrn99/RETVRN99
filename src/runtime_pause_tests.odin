// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "core:sync"
import "host"
import sdl3 "vendor:sdl3"

@(test)
runtime_lifecycle_pause_waits_for_did_enter_foreground :: proc(t: ^testing.T) {
	events := [?]sdl3.EventType {
		sdl3.EventType.WILL_ENTER_BACKGROUND,
		sdl3.EventType.DID_ENTER_BACKGROUND,
		sdl3.EventType.WILL_ENTER_FOREGROUND,
	}
	for event_type in events {
		active, handled := lifecycle_pause_update(event_type)
		testing.expect(t, handled)
		testing.expect(t, active)
	}
	active, handled := lifecycle_pause_update(.DID_ENTER_FOREGROUND)
	testing.expect(t, handled)
	testing.expect(t, !active)
	_, handled = lifecycle_pause_update(.WINDOW_FOCUS_LOST)
	testing.expect(t, !handled)
}

@(test)
runtime_lifecycle_watch_enqueues_thread_safe_pause_commands :: proc(t: ^testing.T) {
	shared: Shared
	shared.running = true
	watch := Lifecycle_Watch{shared = &shared}
	defer command_queue_destroy(&shared)

	background := sdl3.Event{type = .WILL_ENTER_BACKGROUND}
	foreground := sdl3.Event{type = .DID_ENTER_FOREGROUND}
	testing.expect(t, lifecycle_event_watch(&watch, &background))
	testing.expect(t, lifecycle_event_watch(&watch, &foreground))

	sync.lock(&shared.mu)
	defer sync.unlock(&shared.mu)
	testing.expect_value(t, len(shared.cmds), 2)
	testing.expect_value(t, shared.cmds[0].kind, Command_Kind.Set_Pause)
	testing.expect_value(t, shared.cmds[0].pause_reason, host.Pause_Reason.Host_Background)
	testing.expect(t, shared.cmds[0].pause_active)
	testing.expect(t, !shared.cmds[1].pause_active)
}
