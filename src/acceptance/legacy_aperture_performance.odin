// SPDX-License-Identifier: GPL-3.0-only
package acceptance

LEGACY_APERTURE_PERFORMANCE_WARMUP_NS :: u64(2_000_000_000)
LEGACY_APERTURE_PERFORMANCE_MEASURE_NS :: u64(10_000_000_000)
LEGACY_APERTURE_PERFORMANCE_SAMPLE_NS :: u64(1_000_000_000 / 60)

Legacy_Aperture_Performance_Phase :: enum u8 {
	Waiting,
	Warmup,
	Measuring,
	Complete,
}

Legacy_Aperture_Performance_Identity :: struct {
	width, height:      u32,
	owner_generation:   u64,
	mode_generation:    u64,
	surface_generation: u64,
}

Legacy_Aperture_Performance_Sample :: struct {
	wall_ns:            u64,
	active_mode_x:      bool,
	width, height:      u32,
	content_generation: u64,
	owner_generation:   u64,
	mode_generation:    u64,
	surface_generation: u64,
	aperture_exits:     u64,
}

Legacy_Aperture_Performance_Result :: struct {
	valid:              bool,
	width, height:      u32,
	owner_generation:   u64,
	mode_generation:    u64,
	surface_generation: u64,
	elapsed_ns:         u64,
	sample_count:       u64,
	presented_frames:   u64,
	presented_hz_milli: u64,
	aperture_exits:     u64,
}

Legacy_Aperture_Performance :: struct {
	phase:                   Legacy_Aperture_Performance_Phase,
	identity:                Legacy_Aperture_Performance_Identity,
	phase_started_ns:        u64,
	last_wall_ns:            u64,
	last_content_generation: u64,
	baseline_aperture_exits: u64,
	last_aperture_exits:     u64,
	sample_count:            u64,
	presented_frames:        u64,
	counter_regressions:     u64,
	result:                  Legacy_Aperture_Performance_Result,
}

@(private = "file")
legacy_aperture_performance_identity :: proc(
	sample: Legacy_Aperture_Performance_Sample,
) -> Legacy_Aperture_Performance_Identity {
	return {
		width = sample.width,
		height = sample.height,
		owner_generation = sample.owner_generation,
		mode_generation = sample.mode_generation,
		surface_generation = sample.surface_generation,
	}
}

@(private = "file")
legacy_aperture_performance_sample_valid :: proc(
	sample: Legacy_Aperture_Performance_Sample,
) -> bool {
	return(
		sample.active_mode_x &&
		sample.width != 0 &&
		sample.height != 0 &&
		sample.content_generation != 0 &&
		sample.owner_generation != 0 &&
		sample.mode_generation != 0 &&
		sample.surface_generation != 0 \
	)
}

@(private = "file")
legacy_aperture_performance_identity_equal :: proc(
	left, right: Legacy_Aperture_Performance_Identity,
) -> bool {
	return(
		left.width == right.width &&
		left.height == right.height &&
		left.owner_generation == right.owner_generation &&
		left.mode_generation == right.mode_generation &&
		left.surface_generation == right.surface_generation \
	)
}

@(private = "file")
legacy_aperture_performance_wait :: proc(state: ^Legacy_Aperture_Performance) {
	if state == nil {return}
	regressions := state.counter_regressions
	state^ = {}
	state.counter_regressions = regressions
}

@(private = "file")
legacy_aperture_performance_begin_warmup :: proc(
	state: ^Legacy_Aperture_Performance,
	sample: Legacy_Aperture_Performance_Sample,
) {
	regressions := state.counter_regressions
	state^ = {
		phase                   = .Warmup,
		identity                = legacy_aperture_performance_identity(sample),
		phase_started_ns        = sample.wall_ns,
		last_wall_ns            = sample.wall_ns,
		last_content_generation = sample.content_generation,
		last_aperture_exits     = sample.aperture_exits,
		counter_regressions     = regressions,
	}
}

@(private = "file")
legacy_aperture_performance_begin_measurement :: proc(
	state: ^Legacy_Aperture_Performance,
	sample: Legacy_Aperture_Performance_Sample,
) {
	state.phase = .Measuring
	state.phase_started_ns = sample.wall_ns
	state.last_wall_ns = sample.wall_ns
	state.last_content_generation = sample.content_generation
	state.baseline_aperture_exits = sample.aperture_exits
	state.last_aperture_exits = sample.aperture_exits
	state.sample_count = 0
	state.presented_frames = 0
	state.result = {}
}

@(private = "file")
legacy_aperture_performance_rate_milli :: proc(frames, elapsed_ns: u64) -> u64 {
	if frames == 0 || elapsed_ns == 0 {return 0}
	rate := u128(frames) * 1_000_000_000_000 / u128(elapsed_ns)
	if rate > u128(max(u64)) {return max(u64)}
	return u64(rate)
}

legacy_aperture_performance_step :: proc(
	state: ^Legacy_Aperture_Performance,
	sample: Legacy_Aperture_Performance_Sample,
) {
	if state == nil {return}
	if state.phase == .Complete {return}
	if !legacy_aperture_performance_sample_valid(sample) {
		legacy_aperture_performance_wait(state)
		return
	}

	identity := legacy_aperture_performance_identity(sample)
	if state.phase == .Waiting {
		legacy_aperture_performance_begin_warmup(state, sample)
		return
	}
	if sample.wall_ns < state.last_wall_ns ||
	   !legacy_aperture_performance_identity_equal(state.identity, identity) {
		legacy_aperture_performance_begin_warmup(state, sample)
		return
	}
	if sample.aperture_exits < state.last_aperture_exits {
		if state.counter_regressions < max(u64) {state.counter_regressions += 1}
		legacy_aperture_performance_begin_warmup(state, sample)
		return
	}

	state.last_wall_ns = sample.wall_ns
	if state.phase == .Warmup {
		state.last_content_generation = sample.content_generation
		state.last_aperture_exits = sample.aperture_exits
		if sample.wall_ns - state.phase_started_ns >= LEGACY_APERTURE_PERFORMANCE_WARMUP_NS {
			legacy_aperture_performance_begin_measurement(state, sample)
		}
		return
	}

	if state.sample_count < max(u64) {state.sample_count += 1}
	if sample.content_generation != state.last_content_generation &&
	   state.presented_frames < max(u64) {
		state.presented_frames += 1
	}
	state.last_content_generation = sample.content_generation
	state.last_aperture_exits = sample.aperture_exits
	elapsed := sample.wall_ns - state.phase_started_ns
	if elapsed < LEGACY_APERTURE_PERFORMANCE_MEASURE_NS {return}

	state.result = {
		valid              = true,
		width              = state.identity.width,
		height             = state.identity.height,
		owner_generation   = state.identity.owner_generation,
		mode_generation    = state.identity.mode_generation,
		surface_generation = state.identity.surface_generation,
		elapsed_ns         = elapsed,
		sample_count       = state.sample_count,
		presented_frames   = state.presented_frames,
		presented_hz_milli = legacy_aperture_performance_rate_milli(
			state.presented_frames,
			elapsed,
		),
		aperture_exits     = sample.aperture_exits - state.baseline_aperture_exits,
	}
	state.phase = .Complete
}
