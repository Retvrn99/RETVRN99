// SPDX-License-Identifier: GPL-3.0-only
package hv

// Coarse duty-cycle governor, default off. The real GSW-886 governor
// (consistent PIII-1GHz envelope) is an M3 concern.
Throttle :: struct {
	enabled:    bool,
	budget_pct: int, // guest run budget per window, 1..99
	ran_ns:     u64, // accumulated run time in the current window
}

// Pure math: feed elapsed guest-run nanoseconds, get back how long the
// caller must sleep to honor the budget (0 while the window has room).
throttle_deficit :: proc(t: ^Throttle, ran_ns, window_ns: u64) -> u64 {
	if !t.enabled || t.budget_pct <= 0 || t.budget_pct >= 100 {
		return 0
	}
	t.ran_ns += ran_ns
	budget := window_ns * u64(t.budget_pct) / 100
	if t.ran_ns < budget {
		return 0
	}
	t.ran_ns = 0
	return window_ns - budget
}
