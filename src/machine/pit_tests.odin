// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(private = "file")
pit_test_program :: proc(p: ^Pit, channel, mode: u8, count: u16, bcd := false) {
	control := channel << 6 | 0x30 | mode << 1
	if bcd { control |= 1 }
	pit_out(p, 0x43, control)
	pit_out(p, 0x40 + u16(channel), u8(count))
	pit_out(p, 0x40 + u16(channel), u8(count >> 8))
}

@(private = "file")
pit_test_measure_mode3 :: proc(p: ^Pit) -> (high, low: int) {
	previous := pit_channel_out(p, 0)
	for {
		_ = pit_tick(p, 1)
		now := pit_channel_out(p, 0)
		if previous && !now { break }
		previous = now
	}
	low = 1
	for {
		_ = pit_tick(p, 1)
		if pit_channel_out(p, 0) { break }
		low += 1
	}
	high = 1
	for {
		_ = pit_tick(p, 1)
		if !pit_channel_out(p, 0) { break }
		high += 1
	}
	return
}

@(test)
test_pit_modes_zero_through_five :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 0, 4)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 3), 0)
	testing.expect_value(t, pit_tick(&pit, 1), 1)
	testing.expect_value(t, pit_tick(&pit, 32), 0)

	pit_init(&pit)
	pit_test_program(&pit, 0, 1, 4)
	_ = pit_tick(&pit, 4)
	testing.expect_value(t, pit_tick(&pit, 1), 0)
	pit_set_gate(&pit, 0, false)
	pit_set_gate(&pit, 0, true)
	testing.expect_value(t, pit_tick(&pit, 3), 0)
	testing.expect_value(t, pit_tick(&pit, 1), 1)

	pit_init(&pit)
	pit_test_program(&pit, 0, 2, 4)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 4), 1)
	testing.expect_value(t, pit_tick(&pit, 8), 2)

	pit_init(&pit)
	pit_test_program(&pit, 0, 3, 5)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 5), 1)
	testing.expect_value(t, pit_tick(&pit, 15), 3)

	pit_init(&pit)
	pit_test_program(&pit, 0, 4, 4)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 4), 0)
	testing.expect(t, !pit_channel_out(&pit, 0))
	testing.expect_value(t, pit_tick(&pit, 1), 1)
	testing.expect_value(t, pit_tick(&pit, 20), 0)

	pit_init(&pit)
	pit_test_program(&pit, 0, 5, 4)
	pit_set_gate(&pit, 0, false)
	pit_set_gate(&pit, 0, true)
	testing.expect_value(t, pit_tick(&pit, 4), 0)
	testing.expect(t, !pit_channel_out(&pit, 0))
	testing.expect_value(t, pit_tick(&pit, 1), 1)
}

@(test)
test_pit_mode3_odd_and_even_halves :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 3, 5)
	_ = pit_tick(&pit, 1)
	high, low := pit_test_measure_mode3(&pit)
	testing.expect_value(t, high, 3)
	testing.expect_value(t, low, 2)

	pit_init(&pit)
	pit_test_program(&pit, 0, 3, 6)
	_ = pit_tick(&pit, 1)
	high, low = pit_test_measure_mode3(&pit)
	testing.expect_value(t, high, 3)
	testing.expect_value(t, low, 3)
}

@(test)
test_pit_mode3_rewrite_keeps_live_phase :: proc(t: ^testing.T) {
	pit: Pit
	pit_port61_write(&pit, 0x01)
	pit_test_program(&pit, 2, 3, 16_344)
	_ = pit_tick(&pit, 1)
	transitions := 0
	previous := pit_channel_out(&pit, 2)
	for _ in 0..<60 {
		pit_out(&pit, 0x42, u8(16_344 & 0xFF))
		pit_out(&pit, 0x42, u8(16_344 >> 8))
		for _ in 0..<408 {
			_ = pit_tick(&pit, 1)
			now := pit_channel_out(&pit, 2)
			if now != previous {
				transitions += 1
				previous = now
			}
		}
	}
	testing.expect(t, transitions >= 2 && transitions <= 8)
}

@(private = "file")
pit_test_latched_count :: proc(p: ^Pit) -> u16 {
	pit_out(p, 0x43, 0)
	low := pit_in(p, 0x40)
	high := pit_in(p, 0x40)
	return u16(low) | u16(high) << 8
}

@(test)
test_pit_lsb_msb_write_commits_atomically :: proc(t: ^testing.T) {
	modes := [?]u8{0, 2, 3, 4}
	for mode in modes {
		pit: Pit
		pit_test_program(&pit, 0, mode, 20)
		_ = pit_tick(&pit, 1)
		_ = pit_tick(&pit, 2)
		before := pit.ch[0].count
		before_out := pit.ch[0].out

		pit_out(&pit, 0x40, 8)
		testing.expect_value(t, pit.ch[0].reload, u16(20))
		testing.expect_value(t, pit.ch[0].active_reload, u16(20))
		testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Counting)
		testing.expect_value(t, pit.ch[0].out, before_out)
		testing.expect(t, !pit.ch[0].null_count)
		_ = pit_tick(&pit, 2)
		testing.expect(t, pit.ch[0].count != before)

		pit_out(&pit, 0x40, 0)
		testing.expect_value(t, pit.ch[0].reload, u16(8))
		testing.expect(t, pit.ch[0].null_count)
		if mode == 2 || mode == 3 {
			testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Counting)
			testing.expect_value(t, pit.ch[0].active_reload, u16(20))
		} else {
			testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Load_Delay)
		}
	}
}

@(test)
test_pit_periodic_reload_transfers_at_cycle_boundary :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 6)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 2)
	pit_out(&pit, 0x40, 10)
	pit_out(&pit, 0x40, 0)
	testing.expect_value(t, pit.ch[0].active_reload, u16(6))
	testing.expect(t, pit.ch[0].null_count)
	_ = pit_tick(&pit, 4)
	testing.expect_value(t, pit.ch[0].active_reload, u16(10))
	testing.expect_value(t, pit.ch[0].count, u32(10))
	testing.expect(t, !pit.ch[0].null_count)

	pit_init(&pit)
	pit_test_program(&pit, 0, 3, 6)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 1)
	pit_out(&pit, 0x40, 10)
	pit_out(&pit, 0x40, 0)
	testing.expect_value(t, pit.ch[0].active_reload, u16(6))
	testing.expect(t, pit.ch[0].null_count)
	_ = pit_tick(&pit, 2)
	testing.expect_value(t, pit.ch[0].active_reload, u16(10))
	testing.expect_value(t, pit.ch[0].count, u32(10))
	testing.expect(t, !pit.ch[0].null_count)
}

@(test)
test_pit_mode4_rewrite_during_low_strobe_runs_new_count :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 4, 3)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 3)
	testing.expect(t, !pit.ch[0].out)

	pit_out(&pit, 0x40, 4)
	pit_out(&pit, 0x40, 0)
	testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Load_Delay)
	testing.expect(t, !pit.ch[0].out)
	transitions := pit_tick(&pit, 1)
	testing.expect_value(t, transitions, 1)
	testing.expect(t, pit.ch[0].out)
	testing.expect_value(t, pit.ch[0].count, u32(4))
	testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Counting)

	_ = pit_tick(&pit, 4)
	testing.expect(t, !pit.ch[0].out)
	transitions = pit_tick(&pit, 1)
	testing.expect_value(t, transitions, 1)
	testing.expect(t, pit.ch[0].out)
	testing.expect_value(t, pit.ch[0].state, Pit_Counter_State.Inactive)
}

@(test)
test_pit_mode4_low_strobe_rewrite_deadline_is_next_clock :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 4, 3)
	fall, pending := pit_next_out_edge(&pit, 0)
	if !testing.expect(t, pending) {return}
	_ = pit_advance_to(&pit, fall)
	testing.expect(t, !pit.ch[0].out)

	pit_out(&pit, 0x40, 4)
	pit_out(&pit, 0x40, 0)
	rise, rise_pending := pit_next_deadline(&pit)
	edge, edge_pending := pit_next_out_edge(&pit, 0)
	expected_delta, expected_pending := rate_phase_ticks_until(pit.clock_phase, 1, PIT_HZ)
	if !testing.expect(t, rise_pending && edge_pending && expected_pending) {return}
	testing.expect_value(t, rise, pit.now_tick + expected_delta)
	testing.expect_value(t, edge, rise)
	testing.expect_value(t, pit_advance_to(&pit, rise - 1), 0)
	testing.expect_value(t, pit_advance_to(&pit, rise), 1)
	testing.expect(t, pit.ch[0].out)
	testing.expect_value(t, pit.ch[0].count, u32(4))
}

@(test)
test_pit_bcd_counts_decimal :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 0x0100, true)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 99), 0)
	testing.expect_value(t, pit_tick(&pit, 1), 1)
	testing.expect_value(t, pit_tick(&pit, 100), 1)

	pit_init(&pit)
	pit_test_program(&pit, 0, 0, 0x0050, true)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_tick(&pit, 49), 0)
	testing.expect_value(t, pit_tick(&pit, 1), 1)
}

@(test)
test_pit_gate_pause_and_retrigger :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 10)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 4)
	remaining := pit.ch[0].count
	pit_set_gate(&pit, 0, false)
	_ = pit_tick(&pit, 100)
	testing.expect_value(t, pit.ch[0].count, remaining)
	testing.expect(t, pit_channel_out(&pit, 0))
	pit_set_gate(&pit, 0, true)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit.ch[0].count, u32(10))

	pit_init(&pit)
	pit_test_program(&pit, 0, 1, 4)
	pit_set_gate(&pit, 0, false)
	pit_set_gate(&pit, 0, true)
	_ = pit_tick(&pit, 2)
	pit_set_gate(&pit, 0, false)
	_, pending := pit_next_deadline(&pit)
	testing.expect(t, pending)
	testing.expect_value(t, pit_tick(&pit, 2), 1)

	pit_init(&pit)
	pit_test_program(&pit, 0, 1, 4)
	pit_set_gate(&pit, 0, false)
	pit_set_gate(&pit, 0, true)
	_ = pit_tick(&pit, 2)
	pit_out(&pit, 0x40, 10)
	pit_out(&pit, 0x40, 0)
	testing.expect_value(t, pit_tick(&pit, 2), 1)
	pit_set_gate(&pit, 0, false)
	pit_set_gate(&pit, 0, true)
	testing.expect_value(t, pit_tick(&pit, 9), 0)
	testing.expect_value(t, pit_tick(&pit, 1), 1)
}

@(test)
test_pit_count_and_status_latches :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 3, 100)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 4)
	pit_out(&pit, 0x43, 0x00)
	_ = pit_tick(&pit, 10)
	low := pit_in(&pit, 0x40)
	high := pit_in(&pit, 0x40)
	testing.expect_value(t, u16(low) | u16(high) << 8, u16(92))

	pit_out(&pit, 0x43, 0xE2)
	status := pit_in(&pit, 0x40)
	testing.expect_value(t, status & 0x80, u8(0x80))
	testing.expect_value(t, (status >> 4) & 3, u8(3))
	testing.expect_value(t, (status >> 1) & 7, u8(3))
	testing.expect_value(t, status & 1, u8(0))
}

@(test)
test_pit_count_latch_restarts_word_read_at_lsb :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 0)
	_ = pit_tick(&pit, 1)
	_ = pit_tick(&pit, 0x0A06)
	_ = pit_in(&pit, 0x40)

	pit_out(&pit, 0x43, 0x00)
	low := pit_in(&pit, 0x40)
	high := pit_in(&pit, 0x40)
	testing.expect_value(t, low, u8(0xFA))
	testing.expect_value(t, high, u8(0xF5))
}

@(test)
test_pit_win98_vtd_delay_accumulates_across_mode2_wraps :: proc(t: ^testing.T) {
	RELOAD :: u16(0x04A9)
	TARGET_CLOCKS :: u64(1_000_000)
	SAMPLE_CLOCKS :: u64(13)
	pit: Pit
	pit_test_program(&pit, 0, 2, RELOAD)
	_ = pit_tick(&pit, 1)
	previous := pit_test_latched_count(&pit)
	elapsed: u64
	iterations := 0
	for elapsed < TARGET_CLOCKS {
		_ = pit_tick(&pit, SAMPLE_CLOCKS)
		current := pit_test_latched_count(&pit)
		delta := u64(previous) + u64(RELOAD) - u64(current)
		if previous >= current {delta = u64(previous - current)}
		elapsed += delta
		previous = current
		iterations += 1
		if iterations > 100_000 {break}
	}
	testing.expect(t, elapsed >= TARGET_CLOCKS)
	testing.expect(t, elapsed < TARGET_CLOCKS + SAMPLE_CLOCKS)
	testing.expect(t, iterations < 100_000)
}

@(test)
test_pit_status_tracks_null_count :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 100)
	pit_out(&pit, 0x43, 0xE2)
	testing.expect_value(t, pit_in(&pit, 0x40) & 0x40, u8(0x40))
	_ = pit_tick(&pit, 1)
	pit_out(&pit, 0x43, 0xE2)
	testing.expect_value(t, pit_in(&pit, 0x40) & 0x40, u8(0))
}

@(test)
test_pit_lsb_and_msb_access_modes :: proc(t: ^testing.T) {
	pit: Pit
	pit_out(&pit, 0x43, 0x10)
	pit_out(&pit, 0x40, 0x34)
	_ = pit_tick(&pit, 1)
	testing.expect_value(t, pit_in(&pit, 0x40), u8(0x34))
	testing.expect_value(t, pit_in(&pit, 0x40), u8(0x34))

	pit_init(&pit)
	pit_out(&pit, 0x43, 0x24)
	pit_out(&pit, 0x40, 0x40)
	_ = pit_tick(&pit, 1)
	pit_out(&pit, 0x43, 0x00)
	testing.expect_value(t, pit_in(&pit, 0x40), u8(0x40))
	testing.expect(t, !pit.ch[0].count_latched)
}

@(test)
test_pit_readback_latch_nothing_is_noop :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 3, 100)
	_ = pit_tick(&pit, 5)
	pit_out(&pit, 0x43, 0xF2)
	_ = pit_tick(&pit, 4)
	pit_out(&pit, 0x43, 0x00)
	low := pit_in(&pit, 0x40)
	high := pit_in(&pit, 0x40)
	testing.expect_value(t, u16(low) | u16(high) << 8, u16(84))
}

@(test)
test_pit_master_deadline_is_causal :: proc(t: ^testing.T) {
	pit: Pit
	pit_test_program(&pit, 0, 2, 4)
	deadline, pending := pit_next_deadline(&pit)
	testing.expect(t, pending)
	testing.expect(t, deadline > 1)
	testing.expect_value(t, pit_advance_to(&pit, deadline - 1), 0)
	testing.expect_value(t, pit_advance_to(&pit, deadline), 1)
	next, next_pending := pit_next_deadline(&pit)
	testing.expect(t, next_pending)
	testing.expect(t, next > deadline)
}

@(test)
test_pit_analytic_deadlines_cover_all_modes :: proc(t: ^testing.T) {
	rise_clocks := [6]u64{5, 4, 5, 5, 6, 5}
	edge_clocks := [6]u64{5, 4, 4, 3, 5, 4}
	for mode in u8(0)..=u8(5) {
		pit: Pit
		pit_test_program(&pit, 0, mode, 4)
		if mode == 1 || mode == 5 {
			pit_set_gate(&pit, 0, false)
			pit_set_gate(&pit, 0, true)
		}
		rise, rise_pending := pit_next_deadline(&pit)
		edge, edge_pending := pit_next_out_edge(&pit, 0)
		expected_rise, _ := rate_phase_ticks_until({}, rise_clocks[mode], PIT_HZ)
		expected_edge, _ := rate_phase_ticks_until({}, edge_clocks[mode], PIT_HZ)
		testing.expect(t, rise_pending)
		testing.expect(t, edge_pending)
		testing.expect_value(t, rise, expected_rise)
		testing.expect_value(t, edge, expected_edge)
	}

	pit: Pit
	pit_test_program(&pit, 0, 2, 0x0100, true)
	deadline, pending := pit_next_deadline(&pit)
	expected, _ := rate_phase_ticks_until({}, 101, PIT_HZ)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, expected)
}

@(test)
test_pit_master_split_is_invariant :: proc(t: ^testing.T) {
	one_shot: Pit
	split: Pit
	pit_test_program(&one_shot, 0, 3, 7)
	pit_test_program(&split, 0, 3, 7)
	total := MASTER_CLOCK_HZ / 20
	one_edges := pit_advance_master(&one_shot, total)
	split_edges :=
		pit_advance_master(&split, 17_003) +
	               pit_advance_master(&split, 91_117) +
	               pit_advance_master(&split, total - 108_120)
	testing.expect_value(t, split_edges, one_edges)
	testing.expect_value(t, split.clock_phase.remainder, one_shot.clock_phase.remainder)
	testing.expect_value(t, split.ch[0].count, one_shot.ch[0].count)
	testing.expect_value(t, split.ch[0].out, one_shot.ch[0].out)
}

@(test)
test_pit_bulk_advance_finishes_live_cycle_after_smaller_reload :: proc(t: ^testing.T) {
	modes := [?]u8{2, 3}
	for mode in modes {
		pit: Pit
		pit_test_program(&pit, 0, mode, 0)
		_ = pit_advance(&pit, 1_000_000)
		before := pit.ch[0].count
		pit_out(&pit, 0x40, 0x4D)
		pit_out(&pit, 0x40, 0x17)
		testing.expect(t, before > u32(0x174D))

		fires := pit_advance(&pit, 60_000_000)
		testing.expect(t, fires > 0)
		testing.expect(t, pit.ch[0].count <= u32(0x174D))
	}
}

@(test)
test_pit_channel1_drives_refresh_bit :: proc(t: ^testing.T) {
	pit: Pit
	a := pit_port61_read(&pit)
	b := pit_port61_read(&pit)
	testing.expect_value(t, a & 0x10, b & 0x10)
	testing.expect_value(t, a & 0x10, u8(0x10))

	fall, pending := pit_next_out_edge(&pit, 1)
	testing.expect(t, pending)
	_ = pit_advance_to(&pit, fall)
	testing.expect_value(t, pit_port61_read(&pit) & 0x10, u8(0))
	rise, rise_pending := pit_next_out_edge(&pit, 1)
	testing.expect(t, rise_pending)
	_ = pit_advance_to(&pit, rise)
	testing.expect_value(t, pit_port61_read(&pit) & 0x10, u8(0x10))
}

@(test)
test_pit_channel2_transitions_have_exact_deadlines :: proc(t: ^testing.T) {
	pit: Pit
	pit_port61_write(&pit, 0x01)
	pit_test_program(&pit, 2, 3, 5)
	pit_clear_channel2_transitions(&pit)

	fall, pending := pit_next_out_edge(&pit, 2)
	testing.expect(t, pending)
	_ = pit_advance_to(&pit, fall - 1)
	testing.expect_value(t, len(pit_channel2_transition_slice(&pit)), 0)
	_ = pit_advance_to(&pit, fall)
	transitions := pit_channel2_transition_slice(&pit)
	testing.expect_value(t, len(transitions), 1)
	testing.expect_value(t, transitions[0].master_tick, fall)
	testing.expect(t, !transitions[0].level)
	testing.expect_value(t, pit_port61_read(&pit) & 0x20, u8(0))

	rise, rise_pending := pit_next_out_edge(&pit, 2)
	testing.expect(t, rise_pending)
	_ = pit_advance_to(&pit, rise)
	transitions = pit_channel2_transition_slice(&pit)
	testing.expect_value(t, len(transitions), 2)
	testing.expect_value(t, transitions[1].master_tick, rise)
	testing.expect(t, transitions[1].level)
	testing.expect_value(t, pit_port61_read(&pit) & 0x23, u8(0x21))
}
