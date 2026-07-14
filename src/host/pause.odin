// SPDX-License-Identifier: GPL-3.0-only
package host

Pause_Reason :: enum {
	User,
	Host_Background,
}

Pause_Transition :: enum {
	Unchanged,
	Paused,
	Resumed,
}

Pause_State :: struct {
	reasons: [Pause_Reason]bool,
}

pause_active :: proc(state: ^Pause_State) -> bool {
	if state == nil {return false}
	for active in state.reasons {
		if active {return true}
	}
	return false
}

pause_reason_active :: proc(state: ^Pause_State, reason: Pause_Reason) -> bool {
	return state != nil && state.reasons[reason]
}

pause_set :: proc(state: ^Pause_State, reason: Pause_Reason, active: bool) -> Pause_Transition {
	if state == nil || state.reasons[reason] == active {return .Unchanged}
	was_paused := pause_active(state)
	state.reasons[reason] = active
	is_paused := pause_active(state)
	if was_paused == is_paused {return .Unchanged}
	return is_paused ? .Paused : .Resumed
}
