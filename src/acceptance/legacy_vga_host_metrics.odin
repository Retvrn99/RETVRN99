// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:fmt"
import "core:strings"

LEGACY_VGA_PRE_CAPTURE_LABEL :: u8(224)
LEGACY_VGA_POST_CAPTURE_LABEL :: u8(225)

Legacy_Vga_Host_Capture_Sample :: struct {
	valid:                           bool,
	label:                           u8,
	time_ns:                         u64,
	width, height:                   u32,
	owner_generation:                u64,
	mode_generation:                 u64,
	surface_generation:              u64,
	content_generation:              u64,
	aperture_exits:                   u64,
}

Legacy_Vga_Host_Metrics :: struct {
	enabled:                         bool,
	mode:                            Legacy_Aperture_Mode,
	pre:                             Legacy_Vga_Host_Capture_Sample,
	post:                            Legacy_Vga_Host_Capture_Sample,
	performance:                     Legacy_Aperture_Performance,
}

legacy_vga_host_metrics_init :: proc(
	metrics: ^Legacy_Vga_Host_Metrics,
	enabled: bool,
	mode: Legacy_Aperture_Mode,
) {
	if metrics == nil {return}
	metrics^ = {enabled = enabled, mode = mode}
}

@(private = "file")
legacy_vga_host_capture_valid :: proc(sample: Legacy_Vga_Host_Capture_Sample) -> bool {
	return sample.valid && sample.width != 0 && sample.height != 0 &&
		sample.owner_generation != 0 && sample.mode_generation != 0 &&
		sample.surface_generation != 0 && sample.content_generation != 0
}

legacy_vga_host_metrics_note_capture :: proc(
	metrics: ^Legacy_Vga_Host_Metrics,
	sample: Legacy_Vga_Host_Capture_Sample,
) {
	if metrics == nil || !metrics.enabled || !legacy_vga_host_capture_valid(sample) {return}
	switch sample.label {
	case LEGACY_VGA_PRE_CAPTURE_LABEL:
		if !metrics.pre.valid {metrics.pre = sample}
	case LEGACY_VGA_POST_CAPTURE_LABEL:
		if !metrics.post.valid {metrics.post = sample}
	case:
	}
}

legacy_vga_host_metrics_sample :: proc(
	metrics: ^Legacy_Vga_Host_Metrics,
	sample: Legacy_Aperture_Performance_Sample,
) {
	if metrics == nil || !metrics.enabled {return}
	legacy_aperture_performance_step(&metrics.performance, sample)
}

@(private = "file")
legacy_vga_host_metrics_mode_name :: proc(mode: Legacy_Aperture_Mode) -> string {
	return mode == .Scalar ? "scalar" : "auto"
}

@(private = "file")
legacy_vga_host_metrics_capture_row :: proc(
	builder: ^strings.Builder,
	record, mode: string,
	sample: Legacy_Vga_Host_Capture_Sample,
) {
	fmt.sbprintfln(
		builder,
		"1\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t0\t0\t0\t0\t%d\t0\t0",
		record,
		mode,
		sample.label,
		sample.valid ? 1 : 0,
		sample.time_ns,
		sample.width,
		sample.height,
		sample.owner_generation,
		sample.mode_generation,
		sample.surface_generation,
		sample.content_generation,
		sample.aperture_exits,
	)
}

legacy_vga_host_metrics_text :: proc(metrics: ^Legacy_Vga_Host_Metrics) -> string {
	if metrics == nil || !metrics.enabled {return ""}
	builder: strings.Builder
	fmt.sbprintln(
		&builder,
		"schema\trecord\tmode\tlabel\tvalid\ttime_ns\twidth\theight\towner_generation\tmode_generation\tsurface_generation\tcontent_generation\telapsed_ns\tsample_count\tpresented_frames\tpresented_hz_milli\taperture_exits\tcounter_regressions\tcomplete",
	)
	mode := legacy_vga_host_metrics_mode_name(metrics.mode)
	legacy_vga_host_metrics_capture_row(&builder, "pre-pif", mode, metrics.pre)
	legacy_vga_host_metrics_capture_row(&builder, "desktop-restored", mode, metrics.post)
	result := metrics.performance.result
	fmt.sbprintfln(
		&builder,
		"1\tperformance\t%s\t0\t%d\t0\t%d\t%d\t%d\t%d\t%d\t0\t%d\t%d\t%d\t%d\t%d\t%d\t%d",
		mode,
		result.valid ? 1 : 0,
		result.width,
		result.height,
		result.owner_generation,
		result.mode_generation,
		result.surface_generation,
		result.elapsed_ns,
		result.sample_count,
		result.presented_frames,
		result.presented_hz_milli,
		result.aperture_exits,
		metrics.performance.counter_regressions,
		metrics.performance.phase == .Complete ? 1 : 0,
	)
	return strings.to_string(builder)
}
