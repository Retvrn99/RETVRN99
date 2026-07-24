// SPDX-License-Identifier: GPL-3.0-only
package main

import host "../../src/host"
import contract "../../src/presentation"
import "core:testing"

@(test)
presentation_options_parse_test :: proc(t: ^testing.T) {
	options, diagnostic := presentation_options_parse(
		{"--stable-seconds:10", "--width:1024", "--warmup-seconds:2", "--height:768"},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.None)
	testing.expect_value(t, options.width, 1024)
	testing.expect_value(t, options.height, 768)
	testing.expect_value(t, options.warmup_seconds, 2)
	testing.expect_value(t, options.stable_seconds, 10)

	_, diagnostic = presentation_options_parse(
		{
			"--width:1024",
			"--width:1024",
			"--height:768",
			"--warmup-seconds:2",
			"--stable-seconds:10",
		},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.Duplicate_Option)

	_, diagnostic = presentation_options_parse(
		{"--width:1024", "--height:768", "--warmup-seconds:2"},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.Missing_Option)

	_, diagnostic = presentation_options_parse(
		{"--width:1024", "--height:768", "--warmup-seconds:2", "--stable-seconds:4"},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.Invalid_Value)

	_, diagnostic = presentation_options_parse(
		{
			"--width:1024",
			"--height:768",
			"--warmup-seconds:2",
			"--stable-seconds:10",
			"--minimum-fps:1",
		},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.Unknown_Option)

	_, diagnostic = presentation_options_parse(
		{"--width:800", "--height:600", "--warmup-seconds:2", "--stable-seconds:10"},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.Unsafe_Extent)

	options, diagnostic = presentation_options_parse(
		{"--width:1920", "--height:1080", "--warmup-seconds:2", "--stable-seconds:10"},
	)
	testing.expect_value(t, diagnostic, Presentation_Options_Diagnostic.None)
	testing.expect_value(t, options.width, 1920)
	testing.expect_value(t, options.height, 1080)
}

@(test)
presentation_cadence_skips_missed_slots_without_catch_up_test :: proc(t: ^testing.T) {
	first := presentation_cadence_decide(0, 0)
	testing.expect(t, first.valid)
	testing.expect_value(t, first.slot, u64(0))
	testing.expect_value(t, first.wait_ns, u64(0))

	waiting := presentation_cadence_decide(8_000_000, 1)
	testing.expect(t, waiting.valid)
	testing.expect_value(t, waiting.slot, u64(1))
	testing.expect_value(t, waiting.due_ns, u64(16_666_666))
	testing.expect_value(t, waiting.wait_ns, u64(8_666_666))

	late := presentation_cadence_decide(50_000_000, 1)
	testing.expect(t, late.valid)
	testing.expect_value(t, late.slot, u64(3))
	testing.expect_value(t, late.skipped_slots, u64(2))
	testing.expect_value(t, late.due_ns, u64(50_000_000))
	testing.expect_value(t, late.wait_ns, u64(0))
	testing.expect_value(t, presentation_cadence_trailing_skips(551, 600), u64(49))
	testing.expect_value(t, presentation_cadence_trailing_skips(600, 600), u64(0))
	testing.expect_value(t, presentation_cadence_trailing_skips(700, 600), u64(0))

	_, valid := presentation_cadence_due_ns(max(u64))
	testing.expect(t, !valid)
	_, valid = presentation_cadence_slot_at_ns(max(u64))
	testing.expect(t, valid)
}

@(test)
presentation_rate_threshold_and_overflow_test :: proc(t: ^testing.T) {
	fps_milli, valid := presentation_fps_milli(550, 10_000_000_000)
	testing.expect(t, valid)
	testing.expect_value(t, fps_milli, u64(55_000))
	testing.expect(t, presentation_rate_gate_pass(550, 10_000_000_000, false))
	testing.expect(t, !presentation_rate_gate_pass(549, 10_000_000_000, false))
	testing.expect(t, !presentation_rate_gate_pass(550, 10_000_000_000, true))
	_, valid = presentation_fps_milli(1, 0)
	testing.expect(t, !valid)
	_, valid = presentation_fps_milli(max(u64), 1)
	testing.expect(t, !valid)
}

@(test)
presentation_sample_capacity_fails_closed_test :: proc(t: ^testing.T) {
	recorder := new(Presentation_Sample_Recorder)
	defer free(recorder)
	recorder.count = PRESENTATION_SAMPLE_CAPACITY
	testing.expect(t, !presentation_sample_record(recorder, {index = 1}))
	testing.expect(t, recorder.overflow)
	testing.expect_value(t, recorder.count, PRESENTATION_SAMPLE_CAPACITY)
}

@(test)
presentation_timing_nearest_rank_test :: proc(t: ^testing.T) {
	values := []u64{100, 10, 70, 20, 60, 30, 50, 40, 90, 80}
	summary := presentation_timing_summary(values)
	testing.expect_value(t, summary.p50_ns, u64(50))
	testing.expect_value(t, summary.p95_ns, u64(100))
	testing.expect_value(t, summary.p99_ns, u64(100))
	testing.expect_value(t, summary.max_ns, u64(100))
}

@(test)
presentation_pipeline_p95_threshold_is_strict_test :: proc(t: ^testing.T) {
	limit, valid := presentation_pipeline_p95_limit_ns(1024, 768)
	testing.expect(t, valid)
	testing.expect_value(t, limit, u64(4_000_000))
	testing.expect(t, presentation_pipeline_p95_gate_pass(1024, 768, {p95_ns = 3_999_999}))
	testing.expect(t, !presentation_pipeline_p95_gate_pass(1024, 768, {p95_ns = 4_000_000}))

	limit, valid = presentation_pipeline_p95_limit_ns(1920, 1080)
	testing.expect(t, valid)
	testing.expect_value(t, limit, u64(8_000_000))
	testing.expect(t, presentation_pipeline_p95_gate_pass(1920, 1080, {p95_ns = 7_999_999}))
	testing.expect(t, !presentation_pipeline_p95_gate_pass(1920, 1080, {p95_ns = 8_000_000}))
	testing.expect(t, !presentation_pipeline_p95_gate_pass(800, 600, {p95_ns = 1}))
}

@(test)
presentation_1024x768_synthetic_contract_admits_without_sdl_test :: proc(t: ^testing.T) {
	width, height := 1024, 768
	pixels := make([]u32, width * height)
	defer delete(pixels)
	present, frame, reason, built := presentation_synthetic_frame(pixels, width, height, 1, true)
	testing.expect(t, built)
	testing.expect_value(t, reason, contract.Damage_Full_Reason.Initial_Surface)

	h: host.Host
	testing.expect(t, host.host_presentation_start(&h, 1))
	admission := host.host_presentation_admit_gsw(
		&h,
		present,
		u64(width * height * size_of(u32)),
		reason,
	)
	testing.expect(t, admission.valid)
	testing.expect_value(t, admission.kind, host.Host_Presentation_Kind.Gsw_Snapshot)
	plan := host.host_presentation_upload_plan(&frame, admission.gsw.header)
	testing.expect(t, plan.valid)
	testing.expect(t, plan.full)
	testing.expect_value(t, plan.bytes, u64(width * height * size_of(u32)))

	partial, partial_frame, partial_reason, partial_built := presentation_synthetic_frame(
		pixels,
		width,
		height,
		2,
		false,
	)
	testing.expect(t, partial_built)
	testing.expect_value(t, partial_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, partial.header.dirty.count, u32(1))
	partial_plan := host.host_presentation_upload_plan(&partial_frame, partial.header)
	testing.expect(t, partial_plan.valid)
	testing.expect(t, !partial_plan.full)
	testing.expect_value(
		t,
		partial_plan.bytes,
		u64(PRESENTATION_DIRTY_SIZE * PRESENTATION_DIRTY_SIZE * size_of(u32)),
	)
}

@(test)
presentation_stable_metric_invariants_test :: proc(t: ^testing.T) {
	presented := u64(275)
	metrics := Presentation_Metrics_Evidence {
		gsw_snapshot_partial_updates = presented,
		upload_bytes = presented * u64(PRESENTATION_DIRTY_SIZE * PRESENTATION_DIRTY_SIZE * size_of(u32)),
		upload_regions = presented,
		resource_reuses = presented,
	}
	testing.expect(t, presentation_metrics_valid(metrics, presented))
	metrics.resource_recreations = 1
	testing.expect(t, !presentation_metrics_valid(metrics, presented))
	metrics.resource_recreations = 0
	metrics.copy_bytes = 1
	testing.expect(t, !presentation_metrics_valid(metrics, presented))
}

@(test)
presentation_sample_accounting_includes_trailing_slots_test :: proc(t: ^testing.T) {
	recorder := new(Presentation_Sample_Recorder)
	defer free(recorder)
	testing.expect(t, presentation_sample_record(recorder, {
		index = 0,
		slot = 0,
		completed_offset_ns = 1,
		pipeline_ns = 1,
	}))
	testing.expect(t, presentation_sample_record(recorder, {
		index = 1,
		slot = 1,
		scheduled_offset_ns = 16_666_666,
		started_offset_ns = 16_666_666,
		completed_offset_ns = 16_666_667,
		pipeline_ns = 1,
	}))
	phase := Presentation_Phase_Result {
		attempted = 2,
		presented = 2,
		skipped = 3,
		elapsed_ns = 83_333_333,
	}
	testing.expect(t, presentation_samples_valid(recorder, phase, 5))
	phase.skipped = 2
	testing.expect(t, !presentation_samples_valid(recorder, phase, 5))
}
