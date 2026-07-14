// SPDX-License-Identifier: GPL-3.0-only
package machine

// Rate-phase arithmetic adapted from IzarraVM commit d930de57acccbc6a70cda8cc5a603173bf23cd1c.

MASTER_CLOCK_HZ :: u64(6_600_000_000)
NANOSECOND_HZ   :: u64(1_000_000_000)

Rate_Phase :: struct {
	remainder: u64,
}

Master_Timeline :: struct {
	now_ticks: u64,
}

Master_Source_Phase :: struct {
	remainder: u64,
}

@(private = "file")
timeline_saturating_u64 :: proc(value: u128) -> u64 {
	if value > u128(~u64(0)) {
		return ~u64(0)
	}
	return u64(value)
}

rate_phase_with_remainder :: proc(remainder: u64) -> Rate_Phase {
	assert(remainder < MASTER_CLOCK_HZ)
	return Rate_Phase{remainder = remainder}
}

rate_phase_remainder :: proc(phase: Rate_Phase) -> u64 {
	return phase.remainder
}

rate_phase_advance :: proc(phase: ^Rate_Phase, master_ticks, rate_hz: u64) -> u64 {
	total := u128(phase.remainder) + u128(master_ticks) * u128(rate_hz)
	phase.remainder = u64(total % u128(MASTER_CLOCK_HZ))
	return timeline_saturating_u64(total / u128(MASTER_CLOCK_HZ))
}

rate_phase_ticks_until :: proc(phase: Rate_Phase, events, rate_hz: u64) -> (ticks: u64, running: bool) {
	if events == 0 {
		return 0, true
	}
	if rate_hz == 0 {
		return 0, false
	}

	needed := u128(events) * u128(MASTER_CLOCK_HZ) - u128(phase.remainder)
	rate := u128(rate_hz)
	return timeline_saturating_u64((needed + rate - 1) / rate), true
}

master_source_advance_nanoseconds :: proc(phase: ^Master_Source_Phase, nanoseconds: u64) -> u64 {
	total := u128(phase.remainder) + u128(nanoseconds) * u128(MASTER_CLOCK_HZ)
	phase.remainder = u64(total % u128(NANOSECOND_HZ))
	return timeline_saturating_u64(total / u128(NANOSECOND_HZ))
}

master_ticks_to_nanoseconds :: proc(phase: ^Rate_Phase, master_ticks: u64) -> u64 {
	return rate_phase_advance(phase, master_ticks, NANOSECOND_HZ)
}

master_timeline_now :: proc(timeline: Master_Timeline) -> u64 {
	return timeline.now_ticks
}

master_timeline_advance_to :: proc(timeline: ^Master_Timeline, target_tick: u64) -> u64 {
	if target_tick <= timeline.now_ticks {
		return 0
	}
	elapsed := target_tick - timeline.now_ticks
	timeline.now_ticks = target_tick
	return elapsed
}

master_timeline_advance :: proc(timeline: ^Master_Timeline, master_ticks: u64) -> u64 {
	remaining := ~u64(0) - timeline.now_ticks
	elapsed := min(master_ticks, remaining)
	timeline.now_ticks += elapsed
	return elapsed
}
