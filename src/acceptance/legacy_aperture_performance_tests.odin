// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:testing"

legacy_aperture_performance_test_sample :: proc(
	wall_ns, content_generation, aperture_exits: u64,
	width: u32 = 360,
	height: u32 = 240,
	owner_generation: u64 = 7,
	mode_generation: u64 = 11,
	surface_generation: u64 = 13,
) -> Legacy_Aperture_Performance_Sample {
	return {
		wall_ns = wall_ns,
		active_mode_x = true,
		width = width,
		height = height,
		content_generation = content_generation,
		owner_generation = owner_generation,
		mode_generation = mode_generation,
		surface_generation = surface_generation,
		aperture_exits = aperture_exits,
	}
}

@(test)
legacy_aperture_performance_test_stable_sixty_hz_window_completes :: proc(t: ^testing.T) {
	state: Legacy_Aperture_Performance
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(1_000, 1, 500),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(
			1_000 + LEGACY_APERTURE_PERFORMANCE_WARMUP_NS,
			2,
			700,
		),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Measuring)
	for i in 1 ..= 600 {
		elapsed := u64(i) * LEGACY_APERTURE_PERFORMANCE_MEASURE_NS / 600
		legacy_aperture_performance_step(
			&state,
			legacy_aperture_performance_test_sample(
				1_000 + LEGACY_APERTURE_PERFORMANCE_WARMUP_NS + elapsed,
				u64(2 + i),
				u64(700 + i * 10),
			),
		)
	}
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Complete)
	testing.expect(t, state.result.valid)
	testing.expect_value(t, state.result.width, u32(360))
	testing.expect_value(t, state.result.height, u32(240))
	testing.expect_value(t, state.result.elapsed_ns, LEGACY_APERTURE_PERFORMANCE_MEASURE_NS)
	testing.expect_value(t, state.result.sample_count, u64(600))
	testing.expect_value(t, state.result.presented_frames, u64(600))
	testing.expect_value(t, state.result.presented_hz_milli, u64(60_000))
	testing.expect_value(t, state.result.aperture_exits, u64(6_000))
	exited := legacy_aperture_performance_test_sample(
		1_000 + LEGACY_APERTURE_PERFORMANCE_WARMUP_NS + LEGACY_APERTURE_PERFORMANCE_MEASURE_NS + 1,
		700,
		7000,
	)
	exited.active_mode_x = false
	legacy_aperture_performance_step(&state, exited)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Complete)
	testing.expect(t, state.result.valid)
	testing.expect_value(t, state.result.presented_frames, u64(600))
}

@(test)
legacy_aperture_performance_test_identity_change_restarts_warmup :: proc(t: ^testing.T) {
	state: Legacy_Aperture_Performance
	legacy_aperture_performance_step(&state, legacy_aperture_performance_test_sample(0, 1, 10))
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(1_000_000_000, 2, 20, 320, 200),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
	testing.expect_value(t, state.phase_started_ns, u64(1_000_000_000))
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(2_000_000_000, 3, 30, 320, 200),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(3_000_000_000, 4, 40, 320, 200),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Measuring)
	testing.expect_value(t, state.identity.width, u32(320))
}

@(test)
legacy_aperture_performance_test_stale_content_is_not_presented :: proc(t: ^testing.T) {
	state: Legacy_Aperture_Performance
	legacy_aperture_performance_step(&state, legacy_aperture_performance_test_sample(0, 9, 10))
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(LEGACY_APERTURE_PERFORMANCE_WARMUP_NS, 9, 20),
	)
	for i in 1 ..= 500 {
		legacy_aperture_performance_step(
			&state,
			legacy_aperture_performance_test_sample(
				LEGACY_APERTURE_PERFORMANCE_WARMUP_NS + u64(i) * 20_000_000,
				9,
				u64(20 + i),
			),
		)
	}
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Complete)
	testing.expect_value(t, state.result.presented_frames, u64(0))
	testing.expect_value(t, state.result.presented_hz_milli, u64(0))
}

@(test)
legacy_aperture_performance_test_counter_regression_restarts_fail_closed :: proc(t: ^testing.T) {
	state: Legacy_Aperture_Performance
	legacy_aperture_performance_step(&state, legacy_aperture_performance_test_sample(0, 1, 100))
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(LEGACY_APERTURE_PERFORMANCE_WARMUP_NS, 2, 200),
	)
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(3_000_000_000, 3, 199),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
	testing.expect_value(t, state.phase_started_ns, u64(3_000_000_000))
	testing.expect(t, !state.result.valid)
	testing.expect_value(t, state.counter_regressions, u64(1))
}

@(test)
legacy_aperture_performance_test_warmup_counter_regression_restarts_fail_closed :: proc(
	t: ^testing.T,
) {
	state: Legacy_Aperture_Performance
	legacy_aperture_performance_step(&state, legacy_aperture_performance_test_sample(0, 1, 100))
	legacy_aperture_performance_step(
		&state,
		legacy_aperture_performance_test_sample(1_000_000_000, 2, 99),
	)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
	testing.expect_value(t, state.phase_started_ns, u64(1_000_000_000))
	testing.expect_value(t, state.last_aperture_exits, u64(99))
	testing.expect_value(t, state.counter_regressions, u64(1))
}

@(test)
legacy_aperture_performance_test_invalid_mode_waits_for_new_baseline :: proc(t: ^testing.T) {
	state: Legacy_Aperture_Performance
	sample := legacy_aperture_performance_test_sample(1, 1, 1)
	sample.active_mode_x = false
	legacy_aperture_performance_step(&state, sample)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Waiting)
	sample = legacy_aperture_performance_test_sample(2, 2, 2)
	legacy_aperture_performance_step(&state, sample)
	testing.expect_value(t, state.phase, Legacy_Aperture_Performance_Phase.Warmup)
}
