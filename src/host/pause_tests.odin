// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_pause_reasons_resume_only_after_all_clear :: proc(t: ^testing.T) {
	state: Pause_State
	testing.expect(t, !pause_active(&state))
	testing.expect_value(t, pause_set(&state, .User, true), Pause_Transition.Paused)
	testing.expect_value(t, pause_set(&state, .Host_Background, true), Pause_Transition.Unchanged)
	testing.expect(t, pause_reason_active(&state, .User))
	testing.expect(t, pause_reason_active(&state, .Host_Background))
	testing.expect_value(t, pause_set(&state, .User, false), Pause_Transition.Unchanged)
	testing.expect(t, pause_active(&state))
	testing.expect_value(t, pause_set(&state, .Host_Background, false), Pause_Transition.Resumed)
	testing.expect(t, !pause_active(&state))
}

@(test)
host_pause_reason_updates_are_idempotent :: proc(t: ^testing.T) {
	state: Pause_State
	testing.expect_value(t, pause_set(&state, .Host_Background, false), Pause_Transition.Unchanged)
	testing.expect_value(t, pause_set(&state, .Host_Background, true), Pause_Transition.Paused)
	testing.expect_value(t, pause_set(&state, .Host_Background, true), Pause_Transition.Unchanged)
	testing.expect_value(t, pause_set(&state, .Host_Background, false), Pause_Transition.Resumed)
	testing.expect_value(t, pause_set(&state, .Host_Background, false), Pause_Transition.Unchanged)
}
