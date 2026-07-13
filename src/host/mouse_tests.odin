// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
mouse_test_button_mapping :: proc(t: ^testing.T) {
	buttons: u8
	buttons = mouse_set_button(buttons, sdl3.BUTTON_LEFT, true)
	buttons = mouse_set_button(buttons, sdl3.BUTTON_RIGHT, true)
	testing.expect_value(t, buttons, MOUSE_LEFT | MOUSE_RIGHT)
	buttons = mouse_set_button(buttons, sdl3.BUTTON_LEFT, false)
	buttons = mouse_set_button(buttons, sdl3.BUTTON_MIDDLE, true)
	testing.expect_value(t, buttons, MOUSE_RIGHT | MOUSE_MIDDLE)
}

@(test)
mouse_test_sdl_flags :: proc(t: ^testing.T) {
	flags := sdl3.MouseButtonFlags{.LEFT, .MIDDLE}
	testing.expect_value(t, mouse_buttons_from_sdl(flags), MOUSE_LEFT | MOUSE_MIDDLE)
}

@(test)
mouse_test_guest_view_hit :: proc(t: ^testing.T) {
	h := Host {
		has_frame     = true,
		aspect_width  = 4,
		aspect_height = 3,
	}
	r := guest_view_rect(4, 3)
	testing.expect(t, mouse_inside_guest(&h, r.x + r.w * 0.5, r.y + r.h * 0.5))
	testing.expect(t, !mouse_inside_guest(&h, r.x - 1, r.y))
	testing.expect(t, !mouse_inside_guest(&h, r.x, r.y + r.h))
	h.has_frame = false
	testing.expect(t, !mouse_inside_guest(&h, r.x + 1, r.y + 1))
}
