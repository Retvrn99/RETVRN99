// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:testing"

@(test)
test_throttle_deficit :: proc(t: ^testing.T) {
	th: Throttle
	// disabled: never sleeps
	testing.expect_value(t, throttle_deficit(&th, 10_000_000, 10_000_000), 0)
	// 50% budget over a 10ms window: second 5ms chunk exhausts it
	th.enabled = true
	th.budget_pct = 50
	testing.expect_value(t, throttle_deficit(&th, 4_000_000, 10_000_000), 0)
	testing.expect_value(t, throttle_deficit(&th, 1_500_000, 10_000_000), 5_000_000)
	// window reset after the sleep
	testing.expect_value(t, th.ran_ns, 0)
	testing.expect_value(t, throttle_deficit(&th, 1_000_000, 10_000_000), 0)
}
