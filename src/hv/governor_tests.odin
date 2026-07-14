// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:testing"
import config "../vmconfig"

@(test)
test_governor_turbo_is_unrestricted :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.Turbo,
		host_hz = 4_000_000_000,
	}
	testing.expect_value(t, governor_charge(&g, 1_000_000, 1_000_000), i64(0))
	testing.expect_value(t, g.balance_ns, i64(0))
}

@(test)
test_governor_gsw_886_tracks_wait_overshoot :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.GSW_886,
		host_hz = 4_000_000_000,
	}
	testing.expect_value(t, governor_charge(&g, 250_000, 250_000), i64(1_178_571))
	governor_record_wait(&g, 900_000)
	testing.expect_value(t, g.balance_ns, i64(278_571))
	testing.expect_value(t, governor_charge(&g, 250_000, 250_000), i64(1_457_142))
}

@(test)
test_governor_gsw_886_does_not_bank_idle_time :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.GSW_886,
		host_hz = 4_000_000_000,
	}
	testing.expect_value(t, governor_charge(&g, 0, 20_000_000), i64(0))
	testing.expect_value(t, g.balance_ns, -GOVERNOR_MAX_CREDIT_NS)
	testing.expect_value(t, governor_charge(&g, 500_000, 500_000), i64(1_357_142))
}

@(test)
test_governor_host_at_target_needs_no_wait :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.GSW_886,
		host_hz = GSW_886_THROUGHPUT_HZ,
	}
	testing.expect_value(t, governor_charge(&g, 1_000_000, 1_000_000), i64(0))
}

@(test)
test_governor_carries_large_debt_across_waits :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.GSW_886,
		host_hz = 4_000_000_000,
	}
	testing.expect_value(t, governor_charge(&g, 50_000_000, 50_000_000), GOVERNOR_MAX_SLEEP_NS)
	testing.expect_value(t, g.balance_ns, i64(235_714_285))
	governor_record_wait(&g, GOVERNOR_MAX_SLEEP_NS)
	testing.expect_value(t, governor_charge(&g, 0, 0), GOVERNOR_MAX_SLEEP_NS)
}

@(test)
test_governor_uses_full_wall_interval :: proc(t: ^testing.T) {
	g := Governor {
		mode    = config.Cpu_Mode.GSW_886,
		host_hz = 4_000_000_000,
	}
	testing.expect_value(t, governor_charge(&g, 35_000_000, 180_000_000), i64(20_000_000))
}
