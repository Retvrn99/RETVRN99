// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_pit_18hz :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x34)             // channel 0, lobyte/hibyte, mode 2
	pit_out(&pit, 0x40, 0x00); pit_out(&pit, 0x40, 0x00) // divisor 65536
	n := pit_advance(&pit, 1_000_000_000) // 1 s -> ~18 ticks
	testing.expect(t, n >= 18 && n <= 19)
}

@(test)
test_pit_latch_read :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x34)
	pit_out(&pit, 0x40, 0x00); pit_out(&pit, 0x40, 0x10) // divisor 0x1000
	_ = pit_advance(&pit, 100_000)
	pit_out(&pit, 0x43, 0x00) // latch channel 0
	lo := pit_in(&pit, 0x40); hi := pit_in(&pit, 0x40)
	v := u16(hi) << 8 | u16(lo)
	testing.expect(t, v > 0 && v <= 0x1000)
}

// SeaBIOS tsctimer_setup: gate on via 0x61, ch2 mode 0, count LSB/MSB, poll bit5
@(test)
test_pit_ch2_mode0_tsctimer :: proc(t: ^testing.T) {
	pit: Pit
	pit_port61_write(&pit, 0x01)  // gate high, speaker off
	pit_out(&pit, 0x43, 0xB0)     // ch2, lobyte/hibyte, mode 0, binary
	pit_out(&pit, 0x42, 0x00); pit_out(&pit, 0x42, 0x80) // count 0x8000
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0))
	_ = pit_advance(&pit, 1_000_000) // 1 ms ~ 1193 ticks, below 0x8000
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0))
	_ = pit_advance(&pit, 30_000_000) // ~37k ticks total, past 0x8000
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0x20))
	// gate/speaker bits read back as written
	testing.expect_value(t, pit_port61_read(&pit) & 0x03, u8(0x01))
}

@(test)
test_pit_ch2_gate_low_holds :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0xB0)
	pit_out(&pit, 0x42, 0x10); pit_out(&pit, 0x42, 0x00) // count 16
	_ = pit_advance(&pit, 1_000_000_000) // gate low: ch2 must not count
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0))
	pit_port61_write(&pit, 0x01) // 0->1 restarts the mode-0 count
	_ = pit_advance(&pit, 1_000_000)
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0x20))
}

@(test)
test_pit_port61_refresh_toggle :: proc(t: ^testing.T) {
	pit: Pit
	a := pit_port61_read(&pit) & 0x10
	b := pit_port61_read(&pit) & 0x10
	testing.expect(t, a != b) // bit4 flips on every read
}

// MSB-only mode: the single-byte read completes the sequence, releasing
// the latch so later reads return the live count
@(test)
test_pit_msb_only_unlatches :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x24) // ch0, MSB only, mode 2
	pit_out(&pit, 0x40, 0x40) // reload 0x4000
	_ = pit_advance(&pit, 1_000_000) // move the count off the reload value
	pit_out(&pit, 0x43, 0x00) // latch ch0
	first := pit_in(&pit, 0x40)
	testing.expect(t, !pit.ch[0].latched)
	_ = pit_advance(&pit, 20_000_000)
	second := pit_in(&pit, 0x40)
	testing.expect(t, first != second) // live count, not the stale latch
}

@(test)
test_pit_lsb_only_read :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x12) // ch0, LSB only, mode 1
	pit_out(&pit, 0x40, 0x34)
	testing.expect_value(t, pit_in(&pit, 0x40), u8(0x34))
	testing.expect_value(t, pit_in(&pit, 0x40), u8(0x34)) // never alternates to MSB
}

@(test)
test_pit_advance_huge_delta :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x34)
	pit_out(&pit, 0x40, 0x00); pit_out(&pit, 0x40, 0x00) // divisor 65536
	// 6 h in one call: without the clamp the tick multiply overflows u64
	n := pit_advance(&pit, 6 * 3_600_000_000_000)
	testing.expect(t, n >= 65000 && n <= 66000) // clamped to 1 h worth of ticks
}
