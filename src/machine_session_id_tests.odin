// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:strings"
import "core:testing"
import "core:time"

@(test)
machine_session_id_test_formats_exact_gui_and_console_shapes :: proc(t: ^testing.T) {
	gui := machine_session_id_text(.Gui, 1234, 567890)
	console := machine_session_id_text(.Console, 4321, 987654)

	testing.expect_value(t, gui, "gui-1234-567890")
	testing.expect_value(t, console, "console-4321-987654")
	testing.expect(t, !strings.contains(gui, "%!"))
	testing.expect(t, !strings.contains(console, "%!"))
}

@(test)
machine_session_id_test_derives_numeric_monotonic_nonce :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		machine_session_nonce_ns(time.Tick{123_456_789}),
		u64(123_456_789),
	)
}
