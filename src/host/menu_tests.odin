// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_test_cdrom_menu_action_availability :: proc(t: ^testing.T) {
	st: Menu_State
	testing.expect(t, menu_action_enabled(&st, .Mount_Cdrom))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Install_Windows_98))
	testing.expect(t, !menu_action_enabled(&st, .Finish_Windows_98_Installation))

	st.cdrom_mounted = true
	testing.expect(t, menu_action_enabled(&st, .Eject_Cdrom))

	st.installing_windows_98 = true
	testing.expect(t, !menu_action_enabled(&st, .Mount_Cdrom))
	testing.expect(t, !menu_action_enabled(&st, .Eject_Cdrom))
	testing.expect(t, menu_action_enabled(&st, .Install_Windows_98))
	testing.expect(t, menu_action_enabled(&st, .Finish_Windows_98_Installation))
}

@(test)
host_test_existing_menu_actions_remain_enabled :: proc(t: ^testing.T) {
	st := Menu_State {
		installing_windows_98 = true,
	}
	actions := []Menu_Action {
		Menu_Action.Reset,
		Menu_Action.Power_Off,
		Menu_Action.Mount_Floppy,
		Menu_Action.Eject_Floppy,
		Menu_Action.Set_Cpu_Mode,
	}
	for action in actions {
		testing.expect(t, menu_action_enabled(&st, action))
	}
}
