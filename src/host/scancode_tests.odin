// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_test_set1_plain_make_break :: proc(t: ^testing.T) {
	s, ok := scancode_to_set1(.A)
	testing.expect(t, ok)
	buf, n := set1_bytes(s, true)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, buf[0], u8(0x1E))
	buf, n = set1_bytes(s, false)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, buf[0], u8(0x9E))
}

@(test)
host_test_set1_extended_arrows :: proc(t: ^testing.T) {
	up, ok := scancode_to_set1(.UP)
	testing.expect(t, ok)
	buf, n := set1_bytes(up, true)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, buf[0], u8(0xE0))
	testing.expect_value(t, buf[1], u8(0x48))
	buf, n = set1_bytes(up, false)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, buf[0], u8(0xE0))
	testing.expect_value(t, buf[1], u8(0xC8))
	left, _ := scancode_to_set1(.LEFT)
	buf, _ = set1_bytes(left, true)
	testing.expect_value(t, buf[1], u8(0x4B))
}

@(test)
host_test_set1_ctrl_pair :: proc(t: ^testing.T) {
	// LCtrl and RCtrl share a code; only RCtrl carries E0
	l, _ := scancode_to_set1(.LCTRL)
	r, _ := scancode_to_set1(.RCTRL)
	testing.expect_value(t, l.code, u8(0x1D))
	testing.expect_value(t, r.code, u8(0x1D))
	testing.expect(t, !l.ext)
	testing.expect(t, r.ext)
}

@(test)
host_test_set1_keypad_vs_nav :: proc(t: ^testing.T) {
	// Delete in the navigation block is E0 53; KP_PERIOD is 53 without prefix
	del, _ := scancode_to_set1(.DELETE)
	kp, _ := scancode_to_set1(.KP_PERIOD)
	testing.expect(t, del.ext)
	testing.expect(t, !kp.ext)
	testing.expect_value(t, del.code, kp.code)
	// Keypad Enter: E0 1C
	kpe, _ := scancode_to_set1(.KP_ENTER)
	testing.expect(t, kpe.ext)
	testing.expect_value(t, kpe.code, u8(0x1C))
}

@(test)
host_test_set1_unmapped :: proc(t: ^testing.T) {
	_, ok := scancode_to_set1(.PRINTSCREEN)
	testing.expect(t, !ok)
	_, ok = scancode_to_set1(.UNKNOWN)
	testing.expect(t, !ok)
}
