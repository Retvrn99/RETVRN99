// SPDX-License-Identifier: GPL-3.0-only
package opticaldrive

import "core:testing"

@(test)
opticaldrive_test_persistent_path_round_trip :: proc(t: ^testing.T) {
	value := path('d')
	testing.expect_value(t, value, "hostcd://D:")
	letter, ok := path_letter(value)
	testing.expect(t, ok)
	testing.expect_value(t, letter, u8('D'))
	testing.expect(t, is_path("HOSTCD://d:"))
	_, malformed := path_letter(`\\.\D:`)
	testing.expect(t, !malformed)
}

@(test)
opticaldrive_test_enumeration_is_bounded :: proc(t: ^testing.T) {
	drives := enumerate()
	testing.expect_value(t, len(drives), 26)
}
