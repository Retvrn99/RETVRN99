// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:sort"
import "core:strconv"
import "core:strings"

PRESENTATION_RATE_HZ :: u64(60)
PRESENTATION_MINIMUM_FPS_MILLI :: u64(55_000)
PRESENTATION_NANOSECONDS_PER_SECOND :: u64(1_000_000_000)
PRESENTATION_1024X768_PIPELINE_P95_LIMIT_NS :: u64(4_000_000)
PRESENTATION_1920X1080_PIPELINE_P95_LIMIT_NS :: u64(8_000_000)
PRESENTATION_SAMPLE_CAPACITY :: 4096
PRESENTATION_MINIMUM_WIDTH :: 64
PRESENTATION_MAXIMUM_WIDTH :: 4096
PRESENTATION_MINIMUM_HEIGHT :: 64
PRESENTATION_MAXIMUM_HEIGHT :: 4096
PRESENTATION_MINIMUM_WARMUP_SECONDS :: 1
PRESENTATION_MAXIMUM_WARMUP_SECONDS :: 10
PRESENTATION_MINIMUM_STABLE_SECONDS :: 5
PRESENTATION_MAXIMUM_STABLE_SECONDS :: 60

#assert(
	PRESENTATION_MAXIMUM_STABLE_SECONDS * int(PRESENTATION_RATE_HZ) <=
	PRESENTATION_SAMPLE_CAPACITY,
)
#assert(PRESENTATION_DIRTY_SIZE <= PRESENTATION_MINIMUM_WIDTH)

Presentation_Options :: struct {
	width:          int,
	height:         int,
	warmup_seconds: int,
	stable_seconds: int,
}

Presentation_Options_Diagnostic :: enum u8 {
	None,
	Missing_Option,
	Duplicate_Option,
	Unknown_Option,
	Invalid_Value,
	Unsafe_Extent,
}

Presentation_Cadence_Decision :: struct {
	valid:         bool,
	slot:          u64,
	skipped_slots: u64,
	due_ns:        u64,
	wait_ns:       u64,
}

Presentation_Sample :: struct {
	index:               u64 `json:"index"`,
	slot:                u64 `json:"slot"`,
	skipped_before:      u64 `json:"skipped_before"`,
	scheduled_offset_ns: u64 `json:"scheduled_offset_ns"`,
	started_offset_ns:   u64 `json:"started_offset_ns"`,
	completed_offset_ns: u64 `json:"completed_offset_ns"`,
	pipeline_ns:         u64 `json:"pipeline_ns"`,
	present_ns:          u64 `json:"present_ns"`,
}

Presentation_Sample_Recorder :: struct {
	values:   [PRESENTATION_SAMPLE_CAPACITY]Presentation_Sample,
	count:    int,
	overflow: bool,
}

Presentation_Timing_Summary :: struct {
	p50_ns: u64 `json:"p50_ns"`,
	p95_ns: u64 `json:"p95_ns"`,
	p99_ns: u64 `json:"p99_ns"`,
	max_ns: u64 `json:"max_ns"`,
}

presentation_pipeline_p95_limit_ns :: proc(width, height: int) -> (u64, bool) {
	if width == 1024 && height == 768 {
		return PRESENTATION_1024X768_PIPELINE_P95_LIMIT_NS, true
	}
	if width == 1920 && height == 1080 {
		return PRESENTATION_1920X1080_PIPELINE_P95_LIMIT_NS, true
	}
	return 0, false
}

presentation_options_diagnostic_text :: proc(
	diagnostic: Presentation_Options_Diagnostic,
) -> string {
	switch diagnostic {
	case .None:
		return "none"
	case .Missing_Option:
		return "all four options are required"
	case .Duplicate_Option:
		return "an option was repeated"
	case .Unknown_Option:
		return "an option was not recognized"
	case .Invalid_Value:
		return "an option value is invalid or outside its fixed range"
	case .Unsafe_Extent:
		return "the requested surface extent is unsafe"
	}
	return "unknown option diagnostic"
}

presentation_parse_int :: proc(text: string, minimum, maximum: int) -> (int, bool) {
	if text == "" {return 0, false}
	value, ok := strconv.parse_int(text, 10)
	if !ok || value < minimum || value > maximum {return 0, false}
	return value, true
}

presentation_options_parse :: proc(
	args: []string,
) -> (
	Presentation_Options,
	Presentation_Options_Diagnostic,
) {
	options: Presentation_Options
	seen_width, seen_height := false, false
	seen_warmup, seen_stable := false, false

	for argument in args {
		switch {
		case strings.has_prefix(argument, "--width:"):
			if seen_width {return {}, .Duplicate_Option}
			value, ok := presentation_parse_int(
				argument[len("--width:"):],
				PRESENTATION_MINIMUM_WIDTH,
				PRESENTATION_MAXIMUM_WIDTH,
			)
			if !ok {return {}, .Invalid_Value}
			options.width = value
			seen_width = true
		case strings.has_prefix(argument, "--height:"):
			if seen_height {return {}, .Duplicate_Option}
			value, ok := presentation_parse_int(
				argument[len("--height:"):],
				PRESENTATION_MINIMUM_HEIGHT,
				PRESENTATION_MAXIMUM_HEIGHT,
			)
			if !ok {return {}, .Invalid_Value}
			options.height = value
			seen_height = true
		case strings.has_prefix(argument, "--warmup-seconds:"):
			if seen_warmup {return {}, .Duplicate_Option}
			value, ok := presentation_parse_int(
				argument[len("--warmup-seconds:"):],
				PRESENTATION_MINIMUM_WARMUP_SECONDS,
				PRESENTATION_MAXIMUM_WARMUP_SECONDS,
			)
			if !ok {return {}, .Invalid_Value}
			options.warmup_seconds = value
			seen_warmup = true
		case strings.has_prefix(argument, "--stable-seconds:"):
			if seen_stable {return {}, .Duplicate_Option}
			value, ok := presentation_parse_int(
				argument[len("--stable-seconds:"):],
				PRESENTATION_MINIMUM_STABLE_SECONDS,
				PRESENTATION_MAXIMUM_STABLE_SECONDS,
			)
			if !ok {return {}, .Invalid_Value}
			options.stable_seconds = value
			seen_stable = true
		case:
			return {}, .Unknown_Option
		}
	}

	if !seen_width || !seen_height || !seen_warmup || !seen_stable {
		return {}, .Missing_Option
	}
	pixels := u64(options.width) * u64(options.height)
	if pixels == 0 || pixels > u64(PRESENTATION_MAXIMUM_WIDTH * PRESENTATION_MAXIMUM_HEIGHT) {
		return {}, .Unsafe_Extent
	}
	_, supported := presentation_pipeline_p95_limit_ns(options.width, options.height)
	if !supported {return {}, .Unsafe_Extent}
	return options, .None
}

presentation_cadence_slot_at_ns :: proc(now_ns: u64) -> (u64, bool) {
	seconds := now_ns / PRESENTATION_NANOSECONDS_PER_SECOND
	remainder := now_ns % PRESENTATION_NANOSECONDS_PER_SECOND
	if seconds > max(u64) / PRESENTATION_RATE_HZ {return 0, false}
	slots := seconds * PRESENTATION_RATE_HZ
	fractional := remainder * PRESENTATION_RATE_HZ / PRESENTATION_NANOSECONDS_PER_SECOND
	if fractional > max(u64) - slots {return 0, false}
	return slots + fractional, true
}

presentation_cadence_due_ns :: proc(slot: u64) -> (u64, bool) {
	seconds := slot / PRESENTATION_RATE_HZ
	remainder := slot % PRESENTATION_RATE_HZ
	if seconds > max(u64) / PRESENTATION_NANOSECONDS_PER_SECOND {return 0, false}
	due := seconds * PRESENTATION_NANOSECONDS_PER_SECOND
	fractional := remainder * PRESENTATION_NANOSECONDS_PER_SECOND / PRESENTATION_RATE_HZ
	if fractional > max(u64) - due {return 0, false}
	return due + fractional, true
}

presentation_cadence_decide :: proc(now_ns, next_slot: u64) -> Presentation_Cadence_Decision {
	current_slot, current_ok := presentation_cadence_slot_at_ns(now_ns)
	if !current_ok {return {}}
	selected := max(current_slot, next_slot)
	due_ns, due_ok := presentation_cadence_due_ns(selected)
	if !due_ok {return {}}
	skipped: u64
	if selected > next_slot {skipped = selected - next_slot}
	wait_ns: u64
	if due_ns > now_ns {wait_ns = due_ns - now_ns}
	return {
		valid = true,
		slot = selected,
		skipped_slots = skipped,
		due_ns = due_ns,
		wait_ns = wait_ns,
	}
}

presentation_sample_record :: proc(
	recorder: ^Presentation_Sample_Recorder,
	sample: Presentation_Sample,
) -> bool {
	if recorder == nil {return false}
	if recorder.count < 0 || recorder.count >= len(recorder.values) {
		recorder.overflow = true
		return false
	}
	recorder.values[recorder.count] = sample
	recorder.count += 1
	return true
}

presentation_fps_milli :: proc(presented, elapsed_ns: u64) -> (u64, bool) {
	if elapsed_ns == 0 {return 0, false}
	value := u128(presented) * u128(1_000_000_000_000) / u128(elapsed_ns)
	if value > u128(max(u64)) {return 0, false}
	return u64(value), true
}

presentation_rate_gate_pass :: proc(presented, elapsed_ns: u64, sample_overflow: bool) -> bool {
	if sample_overflow {return false}
	fps_milli, valid := presentation_fps_milli(presented, elapsed_ns)
	return valid && fps_milli >= PRESENTATION_MINIMUM_FPS_MILLI
}

presentation_cadence_trailing_skips :: proc(next_slot, total_slots: u64) -> u64 {
	if next_slot >= total_slots {return 0}
	return total_slots - next_slot
}

presentation_pipeline_p95_gate_pass :: proc(
	width, height: int,
	summary: Presentation_Timing_Summary,
) -> bool {
	limit_ns, supported := presentation_pipeline_p95_limit_ns(width, height)
	return supported && summary.p95_ns < limit_ns
}

presentation_nearest_rank_index :: proc(count, percentile: int) -> (int, bool) {
	if count <= 0 || percentile <= 0 || percentile > 100 {return 0, false}
	rank := (count * percentile + 99) / 100
	return rank - 1, true
}

presentation_timing_summary :: proc(values: []u64) -> Presentation_Timing_Summary {
	if len(values) == 0 {return {}}
	ordered := make([]u64, len(values))
	defer delete(ordered)
	copy(ordered, values)
	sort.sort(sort.slice_interface(&ordered))
	p50, _ := presentation_nearest_rank_index(len(ordered), 50)
	p95, _ := presentation_nearest_rank_index(len(ordered), 95)
	p99, _ := presentation_nearest_rank_index(len(ordered), 99)
	return {
		p50_ns = ordered[p50],
		p95_ns = ordered[p95],
		p99_ns = ordered[p99],
		max_ns = ordered[len(ordered) - 1],
	}
}
