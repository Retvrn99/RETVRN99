// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_test_win98_dialog_primary_button_models :: proc(t: ^testing.T) {
	state := Win98_Dialog_State {
		buttons = .Ok,
	}
	testing.expect_value(t, win98_dialog_primary_label(&state), "OK")
	state.buttons = .Action_Cancel
	testing.expect_value(t, win98_dialog_primary_label(&state), "Continue")
	state.action_label = "Retry"
	testing.expect_value(t, win98_dialog_primary_label(&state), "Retry")
	testing.expect_value(t, win98_dialog_icon_role(.Error), Ui_Icon_Role.Error_32)
	testing.expect_value(t, win98_dialog_icon_role(.Warning), Ui_Icon_Role.Warning_32)
}
