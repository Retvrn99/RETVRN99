// SPDX-License-Identifier: GPL-3.0-only
package main

import host "../../src/host"
import contract "../../src/presentation"
import vga "../../src/vga"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:time"
import sdl3 "vendor:sdl3"

PRESENTATION_RESULT_PREFIX :: "PRESENTATION_60HZ_RESULT "
PRESENTATION_EVIDENCE_SCHEMA :: u32(1)
PRESENTATION_DIRTY_SIZE :: 64
PRESENTATION_SURFACE_ID :: u64(0x5052_4553_3630)

Presentation_Run_Diagnostic :: enum u8 {
	None,
	Host_Initialization_Failed,
	Vsync_Unavailable,
	Window_Target_Failed,
	Output_Target_Mismatch,
	Quit_Requested,
	Cadence_Overflow,
	Sequence_Overflow,
	Admission_Failed,
	Upload_Failed,
	Commit_Failed,
	Composition_Failed,
	Present_Failed,
	Sample_Overflow,
	Metric_Counter_Reversed,
	Metric_Invariant_Failed,
	Rate_Threshold_Failed,
	Pipeline_P95_Threshold_Failed,
}

Presentation_Frame_Result :: struct {
	diagnostic:   Presentation_Run_Diagnostic,
	started_at:   time.Tick,
	completed_at: time.Tick,
	pipeline_ns:  u64,
	present_ns:   u64,
}

Presentation_Phase_Result :: struct {
	diagnostic: Presentation_Run_Diagnostic,
	attempted:  u64,
	presented:  u64,
	skipped:    u64,
	elapsed_ns: u64,
}

Presentation_Metrics_Evidence :: struct {
	legacy_full_updates:          u64 `json:"legacy_full_updates"`,
	legacy_partial_updates:       u64 `json:"legacy_partial_updates"`,
	gsw_snapshot_full_updates:    u64 `json:"gsw_snapshot_full_updates"`,
	gsw_snapshot_partial_updates: u64 `json:"gsw_snapshot_partial_updates"`,
	copy_bytes:                   u64 `json:"copy_bytes"`,
	conversion_pixels:            u64 `json:"conversion_pixels"`,
	upload_bytes:                 u64 `json:"upload_bytes"`,
	upload_regions:               u64 `json:"upload_regions"`,
	stale_generation_drops:       u64 `json:"stale_generation_drops"`,
	stale_finalization_drops:     u64 `json:"stale_finalization_drops"`,
	invalid_rejections:           u64 `json:"invalid_rejections"`,
	closed_rejections:            u64 `json:"closed_rejections"`,
	resident_presents:            u64 `json:"resident_presents"`,
	readback_requests:            u64 `json:"readback_requests"`,
	readback_bytes:               u64 `json:"readback_bytes"`,
	last_good_restorations:       u64 `json:"last_good_restorations"`,
	resource_reuses:              u64 `json:"resource_reuses"`,
	resource_recreations:         u64 `json:"resource_recreations"`,
	resource_retirements:         u64 `json:"resource_retirements"`,
	full_fallback_uploads:        u64 `json:"full_fallback_uploads"`,
	overlay_invalidated_regions:  u64 `json:"overlay_invalidated_regions"`,
	overlay_full_invalidations:   u64 `json:"overlay_full_invalidations"`,
	source_full_initial:          u64 `json:"source_full_initial"`,
	source_full_mode:             u64 `json:"source_full_mode"`,
	source_full_ambiguous:        u64 `json:"source_full_ambiguous"`,
	source_full_capacity:         u64 `json:"source_full_capacity"`,
	source_full_external:         u64 `json:"source_full_external"`,
}

Presentation_Run_Result :: struct {
	diagnostic:            Presentation_Run_Diagnostic,
	output_width:          int,
	output_height:         int,
	vsync:                 bool,
	warmup_presented:      u64,
	stable:                Presentation_Phase_Result,
	fps_milli:             u64,
	metrics:               Presentation_Metrics_Evidence,
	metrics_valid:         bool,
	pipeline_timing:       Presentation_Timing_Summary,
	present_timing:        Presentation_Timing_Summary,
	gate_pass:             bool,
	pipeline_p95_limit_ns: u64,
}

Presentation_Evidence :: struct {
	schema:                         u32 `json:"schema"`,
	tool:                           string `json:"tool"`,
	proof_scope:                    string `json:"proof_scope"`,
	synthetic_source:               string `json:"synthetic_source"`,
	presentation_path:              string `json:"presentation_path"`,
	target_hz:                      u64 `json:"target_hz"`,
	minimum_fps_milli:              u64 `json:"minimum_fps_milli"`,
	host_presentation_metric:       string `json:"host_presentation_metric"`,
	host_presentation_p95_limit_ns: u64 `json:"host_presentation_p95_limit_ns"`,
	width:                          int `json:"width"`,
	height:                         int `json:"height"`,
	warmup_seconds:                 int `json:"warmup_seconds"`,
	stable_seconds:                 int `json:"stable_seconds"`,
	output_width:                   int `json:"output_width"`,
	output_height:                  int `json:"output_height"`,
	vsync:                          bool `json:"vsync"`,
	warmup_presented:               u64 `json:"warmup_presented"`,
	stable_attempted:               u64 `json:"stable_attempted"`,
	stable_presented:               u64 `json:"stable_presented"`,
	stable_skipped_slots:           u64 `json:"stable_skipped_slots"`,
	stable_elapsed_ns:              u64 `json:"stable_elapsed_ns"`,
	presented_fps_milli:            u64 `json:"presented_fps_milli"`,
	sample_count:                   int `json:"sample_count"`,
	sample_capacity:                int `json:"sample_capacity"`,
	sample_overflow:                bool `json:"sample_overflow"`,
	pipeline_timing:                Presentation_Timing_Summary `json:"pipeline_timing"`,
	present_timing:                 Presentation_Timing_Summary `json:"present_timing"`,
	metrics:                        Presentation_Metrics_Evidence `json:"stable_host_metrics"`,
	metrics_valid:                  bool `json:"stable_host_metrics_valid"`,
	gate_pass:                      bool `json:"gate_pass"`,
	failure:                        string `json:"failure"`,
	samples:                        []Presentation_Sample `json:"samples"`,
}

presentation_run_diagnostic_text :: proc(diagnostic: Presentation_Run_Diagnostic) -> string {
	switch diagnostic {
	case .None:
		return "none"
	case .Host_Initialization_Failed:
		return "host initialization failed"
	case .Vsync_Unavailable:
		return "renderer vsync is unavailable"
	case .Window_Target_Failed:
		return "the requested window target could not be applied"
	case .Output_Target_Mismatch:
		return "the renderer output does not match the requested target"
	case .Quit_Requested:
		return "the proof window was closed"
	case .Cadence_Overflow:
		return "cadence arithmetic overflowed"
	case .Sequence_Overflow:
		return "synthetic frame sequence overflowed"
	case .Admission_Failed:
		return "host presentation admission failed"
	case .Upload_Failed:
		return "host texture staging or upload failed"
	case .Commit_Failed:
		return "host presentation commit failed"
	case .Composition_Failed:
		return "host guest composition failed"
	case .Present_Failed:
		return "SDL RenderPresent failed"
	case .Sample_Overflow:
		return "the fixed evidence sample buffer overflowed"
	case .Metric_Counter_Reversed:
		return "a host presentation metric moved backwards"
	case .Metric_Invariant_Failed:
		return "stable host presentation metrics violated the proof invariants"
	case .Rate_Threshold_Failed:
		return "presented rate was below 55 FPS"
	case .Pipeline_P95_Threshold_Failed:
		return "host presentation pipeline p95 did not meet the reference-host threshold"
	}
	return "unknown run diagnostic"
}

presentation_tick_elapsed_ns :: proc(started, completed: time.Tick) -> u64 {
	elapsed := time.tick_diff(started, completed)
	if elapsed <= 0 {return 0}
	return u64(elapsed)
}

presentation_synthetic_update :: proc(
	pixels: []u32,
	width, height: int,
	sequence: u64,
	full: bool,
) -> contract.Rect {
	if full {
		for y in 0 ..< height {
			for x in 0 ..< width {
				red := u32(x * 255 / max(1, width - 1))
				green := u32(y * 255 / max(1, height - 1))
				blue := u32((x + y) & 0xFF)
				pixels[y * width + x] = 0xFF00_0000 | red << 16 | green << 8 | blue
			}
		}
		return {width = u32(width), height = u32(height)}
	}

	span := min(PRESENTATION_DIRTY_SIZE, min(width, height))
	x_range := max(1, width - span + 1)
	y_range := max(1, height - span + 1)
	x := int(sequence * 37 % u64(x_range))
	y := int(sequence * 53 % u64(y_range))
	color := u32(0xFF00_0000) | u32(sequence * 29 & 0x00FF_FFFF)
	for row in y ..< y + span {
		for column in x ..< x + span {
			variation := u32((row - y) << 8) | u32(column - x)
			pixels[row * width + column] = color ~ variation
		}
	}
	return {x = u32(x), y = u32(y), width = u32(span), height = u32(span)}
}

presentation_synthetic_frame :: proc(
	pixels: []u32,
	width, height: int,
	sequence: u64,
	full: bool,
) -> (
	contract.Gsw_Present,
	vga.Display_Frame,
	contract.Damage_Full_Reason,
	bool,
) {
	dirty_rect := presentation_synthetic_update(pixels, width, height, sequence, full)
	dirty: contract.Rect_Set
	if !contract.rect_set_append(&dirty, dirty_rect) {return {}, {}, .None, false}
	extent := contract.Extent{u32(width), u32(height)}
	full_rect := contract.Rect {
		width  = u32(width),
		height = u32(height),
	}
	mode_key := contract.Mode_Key {
		format         = .Bgrx_8888,
		display_aspect = contract.aspect_ratio_make(extent.width, extent.height),
		surface_extent = extent,
		canvas_extent  = extent,
		source         = full_rect,
		destination    = full_rect,
	}
	present := contract.Gsw_Present {
		clip_mode = .Fullscreen,
		source_pitch = u32(width * size_of(u32)),
		header = {
			sequence = sequence,
			lifecycle_generation = 1,
			mode_generation = 1,
			mode_key = mode_key,
			identity_namespace = .Gsw2d,
			device_generation = 1,
			surface = {PRESENTATION_SURFACE_ID, 1},
			format = .Bgrx_8888,
			display_aspect = mode_key.display_aspect,
			surface_extent = extent,
			canvas_extent = extent,
			source = full_rect,
			destination = full_rect,
			dirty = dirty,
			interval = 0,
			source_kind = .Gsw_Snapshot,
			ownership = .Mailbox_Surface,
		},
	}
	frame := vga.Display_Frame {
		kind                      = .Xrgb_8888,
		width                     = width,
		height                    = height,
		aspect_width              = width,
		aspect_height             = height,
		generation                = sequence,
		content_generation        = sequence,
		guest_activity_generation = sequence,
		pixels                    = pixels,
		dirty                     = dirty,
		updated_pixels            = u64(dirty_rect.width) * u64(dirty_rect.height),
	}
	reason := full ? contract.Damage_Full_Reason.Initial_Surface : .None
	return present, frame, reason, true
}

presentation_pump_events :: proc() -> bool {
	event: sdl3.Event
	for _ in 0 ..< 64 {
		if !sdl3.PollEvent(&event) {break}
		if event.type == .QUIT {return false}
	}
	return true
}

presentation_run_frame :: proc(
	h: ^host.Host,
	pixels: []u32,
	width, height: int,
	sequence: ^u64,
) -> Presentation_Frame_Result {
	result: Presentation_Frame_Result
	if sequence == nil || sequence^ == max(u64) {
		result.diagnostic = .Sequence_Overflow
		return result
	}
	sequence^ += 1
	full := sequence^ == 1
	present, frame, full_reason, built := presentation_synthetic_frame(
		pixels,
		width,
		height,
		sequence^,
		full,
	)
	if !built {
		result.diagnostic = .Admission_Failed
		return result
	}
	result.started_at = time.tick_now()
	source_capacity := u64(width) * u64(height) * size_of(u32)
	admission := host.host_presentation_admit_gsw(h, present, source_capacity, full_reason)
	if !admission.valid {
		result.diagnostic = .Admission_Failed
		return result
	}
	staged := host.host_presentation_stage_gsw_snapshot(h, &admission, &frame)
	if !staged.valid {
		if staged.in_place && staged.mutated {_ = host.host_presentation_retire_mutated(h, staged)}
		result.diagnostic = .Upload_Failed
		return result
	}
	if !host.host_presentation_commit_gsw_snapshot_staged(h, &admission, staged) {
		if staged.in_place && staged.mutated {_ = host.host_presentation_retire_mutated(h, staged)}
		result.diagnostic = .Commit_Failed
		return result
	}
	if !host.host_render_guest(h, true) {
		result.diagnostic = .Composition_Failed
		return result
	}
	present_started := time.tick_now()
	if !sdl3.RenderPresent(h.ren) {
		result.diagnostic = .Present_Failed
		return result
	}
	result.completed_at = time.tick_now()
	result.pipeline_ns = presentation_tick_elapsed_ns(result.started_at, result.completed_at)
	result.present_ns = presentation_tick_elapsed_ns(present_started, result.completed_at)
	return result
}

presentation_run_phase :: proc(
	h: ^host.Host,
	pixels: []u32,
	options: Presentation_Options,
	seconds: int,
	sequence: ^u64,
	recorder: ^Presentation_Sample_Recorder = nil,
) -> Presentation_Phase_Result {
	result: Presentation_Phase_Result
	phase_started := time.tick_now()
	limit_ns := u64(seconds) * PRESENTATION_NANOSECONDS_PER_SECOND
	total_slots := u64(seconds) * PRESENTATION_RATE_HZ
	next_slot: u64

	for {
		now := time.tick_now()
		now_ns := presentation_tick_elapsed_ns(phase_started, now)
		decision := presentation_cadence_decide(now_ns, next_slot)
		if !decision.valid {
			result.diagnostic = .Cadence_Overflow
			break
		}
		if decision.due_ns >= limit_ns {
			result.skipped += presentation_cadence_trailing_skips(next_slot, total_slots)
			break
		}
		if decision.wait_ns > 0 {time.sleep(time.Duration(decision.wait_ns))}

		now = time.tick_now()
		now_ns = presentation_tick_elapsed_ns(phase_started, now)
		decision = presentation_cadence_decide(now_ns, next_slot)
		if !decision.valid {
			result.diagnostic = .Cadence_Overflow
			break
		}
		if decision.due_ns >= limit_ns {
			result.skipped += presentation_cadence_trailing_skips(next_slot, total_slots)
			break
		}
		if decision.wait_ns > 0 {continue}
		if !presentation_pump_events() {
			result.diagnostic = .Quit_Requested
			break
		}

		result.skipped += decision.skipped_slots
		result.attempted += 1
		frame_result := presentation_run_frame(h, pixels, options.width, options.height, sequence)
		if frame_result.diagnostic != .None {
			result.diagnostic = frame_result.diagnostic
			break
		}
		result.presented += 1
		if recorder != nil {
			sample := Presentation_Sample {
				index               = result.presented - 1,
				slot                = decision.slot,
				skipped_before      = decision.skipped_slots,
				scheduled_offset_ns = decision.due_ns,
				started_offset_ns   = presentation_tick_elapsed_ns(
					phase_started,
					frame_result.started_at,
				),
				completed_offset_ns = presentation_tick_elapsed_ns(
					phase_started,
					frame_result.completed_at,
				),
				pipeline_ns         = frame_result.pipeline_ns,
				present_ns          = frame_result.present_ns,
			}
			if !presentation_sample_record(recorder, sample) {
				result.diagnostic = .Sample_Overflow
				break
			}
		}
		if decision.slot == max(u64) {
			result.diagnostic = .Cadence_Overflow
			break
		}
		next_slot = decision.slot + 1
	}

	if result.diagnostic == .None {
		for {
			elapsed_ns := presentation_tick_elapsed_ns(phase_started, time.tick_now())
			if elapsed_ns >= limit_ns {break}
			time.sleep(time.Duration(limit_ns - elapsed_ns))
		}
	}
	result.elapsed_ns = presentation_tick_elapsed_ns(phase_started, time.tick_now())
	return result
}

presentation_metric_delta :: proc(before, after: u64) -> (u64, bool) {
	if after < before {return 0, false}
	return after - before, true
}

presentation_metrics_delta :: proc(
	before, after: host.Host_Presentation_Metrics,
) -> (
	Presentation_Metrics_Evidence,
	bool,
) {
	result: Presentation_Metrics_Evidence
	valid := true
	result.legacy_full_updates, valid = presentation_metric_delta(
		before.legacy_full_updates,
		after.legacy_full_updates,
	)
	value_valid: bool
	result.legacy_partial_updates, value_valid = presentation_metric_delta(
		before.legacy_partial_updates,
		after.legacy_partial_updates,
	); valid = valid && value_valid
	result.gsw_snapshot_full_updates, value_valid = presentation_metric_delta(
		before.gsw_snapshot_full_updates,
		after.gsw_snapshot_full_updates,
	); valid = valid && value_valid
	result.gsw_snapshot_partial_updates, value_valid = presentation_metric_delta(
		before.gsw_snapshot_partial_updates,
		after.gsw_snapshot_partial_updates,
	); valid = valid && value_valid
	result.copy_bytes, value_valid = presentation_metric_delta(
		before.copy_bytes,
		after.copy_bytes,
	); valid = valid && value_valid
	result.conversion_pixels, value_valid = presentation_metric_delta(
		before.conversion_pixels,
		after.conversion_pixels,
	); valid = valid && value_valid
	result.upload_bytes, value_valid = presentation_metric_delta(
		before.upload_bytes,
		after.upload_bytes,
	); valid = valid && value_valid
	result.upload_regions, value_valid = presentation_metric_delta(
		before.upload_regions,
		after.upload_regions,
	); valid = valid && value_valid
	result.stale_generation_drops, value_valid = presentation_metric_delta(
		before.stale_generation_drops,
		after.stale_generation_drops,
	); valid = valid && value_valid
	result.stale_finalization_drops, value_valid = presentation_metric_delta(
		before.stale_finalization_drops,
		after.stale_finalization_drops,
	); valid = valid && value_valid
	result.invalid_rejections, value_valid = presentation_metric_delta(
		before.invalid_rejections,
		after.invalid_rejections,
	); valid = valid && value_valid
	result.closed_rejections, value_valid = presentation_metric_delta(
		before.closed_rejections,
		after.closed_rejections,
	); valid = valid && value_valid
	result.resident_presents, value_valid = presentation_metric_delta(
		before.resident_presents,
		after.resident_presents,
	); valid = valid && value_valid
	result.readback_requests, value_valid = presentation_metric_delta(
		before.readback_requests,
		after.readback_requests,
	); valid = valid && value_valid
	result.readback_bytes, value_valid = presentation_metric_delta(
		before.readback_bytes,
		after.readback_bytes,
	); valid = valid && value_valid
	result.last_good_restorations, value_valid = presentation_metric_delta(
		before.last_good_restorations,
		after.last_good_restorations,
	); valid = valid && value_valid
	result.resource_reuses, value_valid = presentation_metric_delta(
		before.resource_reuses,
		after.resource_reuses,
	); valid = valid && value_valid
	result.resource_recreations, value_valid = presentation_metric_delta(
		before.resource_recreations,
		after.resource_recreations,
	); valid = valid && value_valid
	result.resource_retirements, value_valid = presentation_metric_delta(
		before.resource_retirements,
		after.resource_retirements,
	); valid = valid && value_valid
	result.full_fallback_uploads, value_valid = presentation_metric_delta(
		before.full_fallback_uploads,
		after.full_fallback_uploads,
	); valid = valid && value_valid
	result.overlay_invalidated_regions, value_valid = presentation_metric_delta(
		before.overlay_invalidated_regions,
		after.overlay_invalidated_regions,
	); valid = valid && value_valid
	result.overlay_full_invalidations, value_valid = presentation_metric_delta(
		before.overlay_full_invalidations,
		after.overlay_full_invalidations,
	); valid = valid && value_valid
	result.source_full_initial, value_valid = presentation_metric_delta(
		before.source_full_initial,
		after.source_full_initial,
	); valid = valid && value_valid
	result.source_full_mode, value_valid = presentation_metric_delta(
		before.source_full_mode,
		after.source_full_mode,
	); valid = valid && value_valid
	result.source_full_ambiguous, value_valid = presentation_metric_delta(
		before.source_full_ambiguous,
		after.source_full_ambiguous,
	); valid = valid && value_valid
	result.source_full_capacity, value_valid = presentation_metric_delta(
		before.source_full_capacity,
		after.source_full_capacity,
	); valid = valid && value_valid
	result.source_full_external, value_valid = presentation_metric_delta(
		before.source_full_external,
		after.source_full_external,
	); valid = valid && value_valid
	return result, valid
}

presentation_metrics_valid :: proc(
	metrics: Presentation_Metrics_Evidence,
	presented: u64,
) -> bool {
	expected_upload_bytes :=
		presented * u64(PRESENTATION_DIRTY_SIZE * PRESENTATION_DIRTY_SIZE * size_of(u32))
	return(
		presented > 0 &&
		metrics.legacy_full_updates == 0 &&
		metrics.legacy_partial_updates == 0 &&
		metrics.gsw_snapshot_full_updates == 0 &&
		metrics.gsw_snapshot_partial_updates == presented &&
		metrics.copy_bytes == 0 &&
		metrics.conversion_pixels == 0 &&
		metrics.upload_bytes == expected_upload_bytes &&
		metrics.upload_regions == presented &&
		metrics.stale_generation_drops == 0 &&
		metrics.stale_finalization_drops == 0 &&
		metrics.invalid_rejections == 0 &&
		metrics.closed_rejections == 0 &&
		metrics.resident_presents == 0 &&
		metrics.readback_requests == 0 &&
		metrics.readback_bytes == 0 &&
		metrics.last_good_restorations == 0 &&
		metrics.resource_reuses == presented &&
		metrics.resource_recreations == 0 &&
		metrics.resource_retirements == 0 &&
		metrics.full_fallback_uploads == 0 &&
		metrics.overlay_invalidated_regions == 0 &&
		metrics.overlay_full_invalidations == 0 &&
		metrics.source_full_initial == 0 &&
		metrics.source_full_mode == 0 &&
		metrics.source_full_ambiguous == 0 &&
		metrics.source_full_capacity == 0 &&
		metrics.source_full_external == 0 \
	)
}

presentation_collect_timings :: proc(
	recorder: ^Presentation_Sample_Recorder,
) -> (
	Presentation_Timing_Summary,
	Presentation_Timing_Summary,
) {
	if recorder == nil || recorder.count <= 0 {return {}, {}}
	pipeline := make([]u64, recorder.count)
	present := make([]u64, recorder.count)
	defer delete(pipeline)
	defer delete(present)
	for sample, index in recorder.values[:recorder.count] {
		pipeline[index] = sample.pipeline_ns
		present[index] = sample.present_ns
	}
	return presentation_timing_summary(pipeline), presentation_timing_summary(present)
}

presentation_samples_valid :: proc(
	recorder: ^Presentation_Sample_Recorder,
	phase: Presentation_Phase_Result,
	total_slots: u64,
) -> bool {
	if recorder == nil ||
	   recorder.overflow ||
	   recorder.count <= 0 ||
	   recorder.count != int(phase.presented) ||
	   phase.presented > max(u64) - phase.skipped ||
	   phase.presented + phase.skipped != total_slots {return false}
	next_slot: u64
	total_skipped: u64
	for sample, index in recorder.values[:recorder.count] {
		if sample.index != u64(index) ||
		   sample.skipped_before > max(u64) - next_slot ||
		   sample.slot != next_slot + sample.skipped_before ||
		   sample.slot >= total_slots {return false}
		due_ns, due_valid := presentation_cadence_due_ns(sample.slot)
		if !due_valid ||
		   sample.scheduled_offset_ns != due_ns ||
		   sample.started_offset_ns < sample.scheduled_offset_ns ||
		   sample.completed_offset_ns < sample.started_offset_ns ||
		   sample.completed_offset_ns > phase.elapsed_ns ||
		   sample.pipeline_ns != sample.completed_offset_ns - sample.started_offset_ns ||
		   sample.present_ns > sample.pipeline_ns ||
		   total_skipped > max(u64) - sample.skipped_before ||
		   sample.slot == max(u64) {return false}
		total_skipped += sample.skipped_before
		next_slot = sample.slot + 1
	}
	trailing_skips := presentation_cadence_trailing_skips(next_slot, total_slots)
	return(
		total_skipped <= max(u64) - trailing_skips &&
		total_skipped + trailing_skips == phase.skipped \
	)
}

presentation_run :: proc(
	options: Presentation_Options,
	recorder: ^Presentation_Sample_Recorder,
) -> Presentation_Run_Result {
	result: Presentation_Run_Result
	result.pipeline_p95_limit_ns, _ = presentation_pipeline_p95_limit_ns(
		options.width,
		options.height,
	)
	h: host.Host
	if !host.host_init(&h) {
		fmt.eprintfln("presentation proof: %s", sdl3.GetError())
		result.diagnostic = .Host_Initialization_Failed
		return result
	}
	defer host.host_destroy(&h)
	result.vsync = h.vsync
	if !h.vsync {
		result.diagnostic = .Vsync_Unavailable
		return result
	}
	_ = sdl3.SetWindowTitle(h.win, "RETVRN99 presentation 60 Hz proof")
	if !sdl3.SetWindowSize(h.win, c.int(options.width), c.int(options.height)) ||
	   !sdl3.SyncWindow(h.win) {
		result.diagnostic = .Window_Target_Failed
		return result
	}
	output_width, output_height: c.int
	if !sdl3.GetRenderOutputSize(h.ren, &output_width, &output_height) {
		result.diagnostic = .Window_Target_Failed
		return result
	}
	result.output_width = int(output_width)
	result.output_height = int(output_height)
	if result.output_width != options.width || result.output_height != options.height {
		result.diagnostic = .Output_Target_Mismatch
		return result
	}

	pixels := make([]u32, options.width * options.height)
	defer delete(pixels)
	sequence: u64
	warmup := presentation_run_phase(&h, pixels, options, options.warmup_seconds, &sequence)
	result.warmup_presented = warmup.presented
	if warmup.diagnostic != .None {
		result.diagnostic = warmup.diagnostic
		return result
	}

	metrics_before := h.presentation_metrics
	result.stable = presentation_run_phase(
		&h,
		pixels,
		options,
		options.stable_seconds,
		&sequence,
		recorder,
	)
	metrics_after := h.presentation_metrics
	if result.stable.diagnostic != .None {
		result.diagnostic = result.stable.diagnostic
		return result
	}
	result.metrics, result.metrics_valid = presentation_metrics_delta(
		metrics_before,
		metrics_after,
	)
	if !result.metrics_valid {
		result.diagnostic = .Metric_Counter_Reversed
		return result
	}
	result.metrics_valid = presentation_metrics_valid(result.metrics, result.stable.presented)
	stable_slots := u64(options.stable_seconds) * PRESENTATION_RATE_HZ
	if !result.metrics_valid ||
	   result.stable.attempted != result.stable.presented ||
	   !presentation_samples_valid(recorder, result.stable, stable_slots) {
		result.diagnostic = .Metric_Invariant_Failed
		return result
	}
	result.fps_milli, _ = presentation_fps_milli(result.stable.presented, result.stable.elapsed_ns)
	result.pipeline_timing, result.present_timing = presentation_collect_timings(recorder)
	if !presentation_rate_gate_pass(
		result.stable.presented,
		result.stable.elapsed_ns,
		recorder.overflow,
	) {
		result.diagnostic = .Rate_Threshold_Failed
		return result
	}
	if !presentation_pipeline_p95_gate_pass(
		options.width,
		options.height,
		result.pipeline_timing,
	) {
		result.diagnostic = .Pipeline_P95_Threshold_Failed
		return result
	}
	result.gate_pass = true
	return result
}

presentation_emit_evidence :: proc(
	options: Presentation_Options,
	result: Presentation_Run_Result,
	recorder: ^Presentation_Sample_Recorder,
) -> bool {
	samples: []Presentation_Sample
	sample_count := 0
	sample_overflow := false
	if recorder != nil {
		sample_count = clamp(recorder.count, 0, len(recorder.values))
		sample_overflow = recorder.overflow
		samples = recorder.values[:sample_count]
	}
	evidence := Presentation_Evidence {
		schema                         = PRESENTATION_EVIDENCE_SCHEMA,
		tool                           = "retvrn99-presentation-60hz-proof",
		proof_scope                    = "synthetic host presentation/upload/render/present only",
		synthetic_source               = "GSW2D snapshot with moving 64x64 dirty region",
		presentation_path              = "host_presentation_admit_gsw>host_presentation_stage_gsw_snapshot>host_presentation_commit_gsw_snapshot_staged>host_render_guest>SDL_RenderPresent",
		target_hz                      = PRESENTATION_RATE_HZ,
		minimum_fps_milli              = PRESENTATION_MINIMUM_FPS_MILLI,
		host_presentation_metric       = "pipeline_ns",
		host_presentation_p95_limit_ns = result.pipeline_p95_limit_ns,
		width                          = options.width,
		height                         = options.height,
		warmup_seconds                 = options.warmup_seconds,
		stable_seconds                 = options.stable_seconds,
		output_width                   = result.output_width,
		output_height                  = result.output_height,
		vsync                          = result.vsync,
		warmup_presented               = result.warmup_presented,
		stable_attempted               = result.stable.attempted,
		stable_presented               = result.stable.presented,
		stable_skipped_slots           = result.stable.skipped,
		stable_elapsed_ns              = result.stable.elapsed_ns,
		presented_fps_milli            = result.fps_milli,
		sample_count                   = sample_count,
		sample_capacity                = PRESENTATION_SAMPLE_CAPACITY,
		sample_overflow                = sample_overflow,
		pipeline_timing                = result.pipeline_timing,
		present_timing                 = result.present_timing,
		metrics                        = result.metrics,
		metrics_valid                  = result.metrics_valid,
		gate_pass                      = result.gate_pass,
		failure                        = presentation_run_diagnostic_text(result.diagnostic),
		samples                        = samples,
	}
	payload, err := json.marshal(evidence)
	if err != nil {return false}
	defer delete(payload)
	fmt.printfln("%s%s", PRESENTATION_RESULT_PREFIX, string(payload))
	return true
}

presentation_usage :: proc() {
	fmt.eprintln(
		"usage: retvrn99-presentation-60hz-proof --width:<1024|1920> --height:<768|1080> --warmup-seconds:2 --stable-seconds:10",
	)
}

main :: proc() {
	if len(os.args) == 2 && os.args[1] == "--help" {
		presentation_usage()
		return
	}
	options, diagnostic := presentation_options_parse(os.args[1:])
	if diagnostic != .None {
		presentation_usage()
		fmt.eprintfln("presentation proof: %s", presentation_options_diagnostic_text(diagnostic))
		os.exit(2)
	}
	recorder := new(Presentation_Sample_Recorder)
	defer free(recorder)
	result := presentation_run(options, recorder)
	if !presentation_emit_evidence(options, result, recorder) {
		fmt.eprintln("presentation proof: evidence encoding failed")
		os.exit(1)
	}
	if !result.gate_pass {os.exit(1)}
}
