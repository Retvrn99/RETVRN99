// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_master_source_nanoseconds_split_invariant :: proc(t: ^testing.T) {
	whole_phase: Master_Source_Phase
	split_phase: Master_Source_Phase
	whole := master_source_advance_nanoseconds(&whole_phase, 1_000_003)
	split := master_source_advance_nanoseconds(&split_phase, 17) +
	         master_source_advance_nanoseconds(&split_phase, 999_986)
	testing.expect_value(t, split, whole)
	testing.expect_value(t, split_phase.remainder, whole_phase.remainder)
	ns_phase: Rate_Phase
	round_trip := master_ticks_to_nanoseconds(&ns_phase, whole)
	testing.expect(t, round_trip <= 1_000_003)
	testing.expect(t, 1_000_003 - round_trip <= 1)
}

@(private = "file")
timeline_test_random :: proc(state: ^u64) -> u64 {
	x := state^
	x = x ~ (x << 13)
	x = x ~ (x >> 7)
	x = x ~ (x << 17)
	state^ = x
	return x
}

@(test)
test_master_timeline_is_monotonic :: proc(t: ^testing.T) {
	timeline: Master_Timeline
	testing.expect_value(t, master_timeline_advance_to(&timeline, 100), u64(100))
	testing.expect_value(t, master_timeline_now(timeline), u64(100))
	testing.expect_value(t, master_timeline_advance_to(&timeline, 50), u64(0))
	testing.expect_value(t, master_timeline_now(timeline), u64(100))
	testing.expect_value(t, master_timeline_advance(&timeline, 25), u64(25))
	testing.expect_value(t, master_timeline_now(timeline), u64(125))
}

@(test)
test_master_timeline_saturates :: proc(t: ^testing.T) {
	timeline := Master_Timeline{now_ticks = ~u64(0) - 4}
	testing.expect_value(t, master_timeline_advance(&timeline, 10), u64(4))
	testing.expect_value(t, master_timeline_now(timeline), ~u64(0))
	testing.expect_value(t, master_timeline_advance(&timeline, 1), u64(0))
}

@(test)
test_rate_phase_exact_divisors :: proc(t: ^testing.T) {
	phase: Rate_Phase
	testing.expect_value(t, rate_phase_advance(&phase, MASTER_CLOCK_HZ, 1), u64(1))
	testing.expect_value(t, rate_phase_remainder(phase), u64(0))
	testing.expect_value(t, rate_phase_advance(&phase, 88_000_000, 75), u64(1))
	testing.expect_value(t, rate_phase_remainder(phase), u64(0))
	testing.expect_value(t, rate_phase_advance(&phase, 6_600, 1_000_000), u64(1))
	testing.expect_value(t, rate_phase_remainder(phase), u64(0))
}

@(test)
test_rate_phase_ticks_until_is_causal :: proc(t: ^testing.T) {
	rates := [?]u64{1, 75, 44_100, 1_193_182, MASTER_CLOCK_HZ - 1, MASTER_CLOCK_HZ, 12_000_000_000}
	event_counts := [?]u64{1, 2, 17, 65_537}
	for rate in rates {
		phase := rate_phase_with_remainder(3_141_592_653)
		for events in event_counts {
			ticks, running := rate_phase_ticks_until(phase, events, rate)
			testing.expect(t, running)
			at_deadline := phase
			testing.expect(t, rate_phase_advance(&at_deadline, ticks, rate) >= events)
			if ticks > 0 {
				before_deadline := phase
				testing.expect(t, rate_phase_advance(&before_deadline, ticks - 1, rate) < events)
			}
		}
	}

	phase: Rate_Phase
	ticks, running := rate_phase_ticks_until(phase, 0, 0)
	testing.expect_value(t, ticks, u64(0))
	testing.expect(t, running)
	_, running = rate_phase_ticks_until(phase, 1, 0)
	testing.expect(t, !running)
}

@(test)
test_rate_phase_randomized_split_invariance :: proc(t: ^testing.T) {
	rates := [?]u64{0, 1, 75, 44_100, 1_193_182, MASTER_CLOCK_HZ - 1, MASTER_CLOCK_HZ, 12_000_000_000}
	state := u64(0xA076_1D64_78BD_642F)

	for _ in 0..<512 {
		rate := rates[int(timeline_test_random(&state) % u64(len(rates)))]
		total_ticks := timeline_test_random(&state) % 1_000_000_000_000
		remainder := timeline_test_random(&state) % MASTER_CLOCK_HZ

		one_shot := rate_phase_with_remainder(remainder)
		expected_events := rate_phase_advance(&one_shot, total_ticks, rate)

		split := rate_phase_with_remainder(remainder)
		remaining := total_ticks
		actual_events: u64
		for remaining > 0 {
			chunk := 1 + timeline_test_random(&state) % min(remaining, u64(10_000_000_000))
			actual_events += rate_phase_advance(&split, chunk, rate)
			remaining -= chunk
		}

		testing.expect_value(t, actual_events, expected_events)
		testing.expect_value(t, rate_phase_remainder(split), rate_phase_remainder(one_shot))
	}
}
