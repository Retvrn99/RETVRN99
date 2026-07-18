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

@(test)
host_test_device_sounds_defaults_and_cancel_semantics :: proc(t: ^testing.T) {
	state: Device_Sounds_Dialog_State
	device_sounds_dialog_open(&state, true, true)
	testing.expect(t, state.visible)
	testing.expect(t, !device_sounds_dialog_changed(&state))
	state.draft_hard_drive_clicking = false
	testing.expect(t, device_sounds_dialog_changed(&state))
	result := device_sounds_dialog_apply_event(&state, .Cancel)
	testing.expect_value(t, result.action, Device_Sounds_Dialog_Action.Cancel)
	testing.expect(t, result.hard_drive_clicking)
	testing.expect(t, result.floppy_noise)
	testing.expect(t, !state.visible)
}

@(test)
host_test_device_sounds_apply_then_cancel_keeps_applied_values :: proc(t: ^testing.T) {
	state: Device_Sounds_Dialog_State
	device_sounds_dialog_open(&state, true, true)
	state.draft_hard_drive_clicking = false
	apply := device_sounds_dialog_apply_event(&state, .Apply)
	testing.expect_value(t, apply.action, Device_Sounds_Dialog_Action.Apply)
	testing.expect(t, !apply.hard_drive_clicking)
	testing.expect(t, !device_sounds_dialog_changed(&state))
	state.draft_floppy_noise = false
	cancel := device_sounds_dialog_apply_event(&state, .Cancel)
	testing.expect_value(t, cancel.action, Device_Sounds_Dialog_Action.Cancel)
	testing.expect(t, !cancel.hard_drive_clicking)
	testing.expect(t, cancel.floppy_noise)
}

@(test)
host_test_device_sounds_ok_and_tests_return_draft_values :: proc(t: ^testing.T) {
	state: Device_Sounds_Dialog_State
	device_sounds_dialog_open(&state, true, true)
	state.draft_floppy_noise = false
	test_result := device_sounds_dialog_apply_event(&state, .Test_Floppy)
	testing.expect_value(t, test_result.action, Device_Sounds_Dialog_Action.Test_Floppy)
	testing.expect(t, !test_result.floppy_noise)
	testing.expect(t, state.visible)
	ok := device_sounds_dialog_apply_event(&state, .Ok)
	testing.expect_value(t, ok.action, Device_Sounds_Dialog_Action.Ok)
	testing.expect(t, ok.hard_drive_clicking)
	testing.expect(t, !ok.floppy_noise)
	testing.expect(t, !state.visible)
}
