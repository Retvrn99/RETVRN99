// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "host"
import "profile"

@(test)
hotkey_persistence_test_store_uses_stable_action_fields :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	settings := profile.settings_default()
	defer profile.settings_destroy(&settings)
	config := host.host_hotkey_defaults()
	config.bindings[.Release_Input] = {}
	config.bindings[.Volume_Up] = {{.Control, .Alt}, .F12, true}
	testing.expect(t, gui_hotkey_settings_store(&settings, config))
	testing.expect_value(t, settings.hotkeys.release_input, host.HOTKEY_UNASSIGNED)
	testing.expect_value(t, settings.hotkeys.volume_up, "Ctrl+Alt+F12")
	testing.expect_value(t, gui_release_binding_title(config), "Right Ctrl")
}
