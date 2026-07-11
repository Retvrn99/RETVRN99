// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_cmos :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c)
	cmos_set_time(&c, 23, 59, 45) // h, m, s
	cmos_out(&c, 0x70, 0x94) // bit NMI ignorado → índice 0x14
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x2D))
	cmos_out(&c, 0x70, 0x00)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x45)) // BCD
	cmos_out(&c, 0x70, 0x04)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x23))
}
