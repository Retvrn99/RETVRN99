// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_pit_18hz :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x34)             // canal 0, lobyte/hibyte, modo 2
	pit_out(&pit, 0x40, 0x00); pit_out(&pit, 0x40, 0x00) // divisor 65536
	n := pit_advance(&pit, 1_000_000_000) // 1 s → ~18 ticks
	testing.expect(t, n >= 18 && n <= 19)
}

@(test)
test_pit_latch_read :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x34)
	pit_out(&pit, 0x40, 0x00); pit_out(&pit, 0x40, 0x10) // divisor 0x1000
	_ = pit_advance(&pit, 100_000)
	pit_out(&pit, 0x43, 0x00) // latch canal 0
	lo := pit_in(&pit, 0x40); hi := pit_in(&pit, 0x40)
	v := u16(hi) << 8 | u16(lo)
	testing.expect(t, v > 0 && v <= 0x1000)
}
