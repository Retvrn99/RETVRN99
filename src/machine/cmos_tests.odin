// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_cmos :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	cmos_set_time(&c, 23, 59, 45) // h, m, s
	cmos_out(&c, 0x70, 0x94) // NMI bit ignored -> index 0x14
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x2D))
	cmos_out(&c, 0x70, 0x00)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x45)) // BCD
	cmos_out(&c, 0x70, 0x04)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x23))
}

@(test)
test_cmos_memory_sizes :: proc(t: ^testing.T) {
	c: Cmos
	cmos_init(&c, 64 * 1024 * 1024)
	// extended memory 1M-16M in KB, capped at 15M = 0x3C00
	cmos_out(&c, 0x70, 0x30)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x00))
	cmos_out(&c, 0x70, 0x31)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x3C))
	// memory above 16M in 64K units: 48M = 768 = 0x0300
	cmos_out(&c, 0x70, 0x34)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x00))
	cmos_out(&c, 0x70, 0x35)
	testing.expect_value(t, cmos_in(&c, 0x71), u8(0x03))
	// 16M machine: nothing above 16M
	c2: Cmos
	cmos_init(&c2, 16 * 1024 * 1024)
	cmos_out(&c2, 0x70, 0x34)
	testing.expect_value(t, cmos_in(&c2, 0x71), u8(0x00))
	cmos_out(&c2, 0x70, 0x35)
	testing.expect_value(t, cmos_in(&c2, 0x71), u8(0x00))
}
