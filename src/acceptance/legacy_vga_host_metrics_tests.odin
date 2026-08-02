// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:strings"
import "core:testing"

legacy_vga_host_metrics_test_capture :: proc(
	label: u8,
	time_ns: u64,
	aperture_exits: u64,
) -> Legacy_Vga_Host_Capture_Sample {
	return {
		valid               = true,
		label               = label,
		time_ns             = time_ns,
		width               = 800,
		height              = 600,
		owner_generation    = 3,
		mode_generation     = 5,
		surface_generation  = 7,
		content_generation  = 9,
		aperture_exits      = aperture_exits,
	}
}

@(test)
legacy_vga_host_metrics_test_disabled_state_has_no_artifact :: proc(t: ^testing.T) {
	metrics: Legacy_Vga_Host_Metrics
	legacy_vga_host_metrics_init(&metrics, false, .Auto)
	legacy_vga_host_metrics_note_capture(
		&metrics,
		legacy_vga_host_metrics_test_capture(LEGACY_VGA_PRE_CAPTURE_LABEL, 1, 2),
	)
	testing.expect_value(t, legacy_vga_host_metrics_text(&metrics), "")
}

@(test)
legacy_vga_host_metrics_test_records_fixed_phases_and_complete_window :: proc(t: ^testing.T) {
	metrics: Legacy_Vga_Host_Metrics
	legacy_vga_host_metrics_init(&metrics, true, .Scalar)
	legacy_vga_host_metrics_note_capture(
		&metrics,
		legacy_vga_host_metrics_test_capture(LEGACY_VGA_PRE_CAPTURE_LABEL, 10, 20),
	)
	legacy_vga_host_metrics_note_capture(
		&metrics,
		legacy_vga_host_metrics_test_capture(LEGACY_VGA_POST_CAPTURE_LABEL, 30, 40),
	)
	legacy_vga_host_metrics_sample(
		&metrics,
		legacy_aperture_performance_test_sample(0, 1, 100),
	)
	legacy_vga_host_metrics_sample(
		&metrics,
		legacy_aperture_performance_test_sample(
			LEGACY_APERTURE_PERFORMANCE_WARMUP_NS,
			2,
			200,
		),
	)
	for i in 1 ..= 600 {
		elapsed := u64(i) * LEGACY_APERTURE_PERFORMANCE_MEASURE_NS / 600
		legacy_vga_host_metrics_sample(
			&metrics,
			legacy_aperture_performance_test_sample(
				LEGACY_APERTURE_PERFORMANCE_WARMUP_NS + elapsed,
				u64(2 + i),
				u64(200 + i),
			),
		)
	}
	text := legacy_vga_host_metrics_text(&metrics)
	defer delete(text)
	testing.expect(t, strings.has_prefix(text, "schema\trecord\tmode\tlabel\tvalid\t"))
	testing.expect(t, strings.contains(text, "1\tpre-pif\tscalar\t224\t1\t"))
	testing.expect(t, strings.contains(text, "1\tdesktop-restored\tscalar\t225\t1\t"))
	testing.expect(t, strings.contains(text, "1\tperformance\tscalar\t0\t1\t"))
	testing.expect(t, strings.contains(text, "\t10000000000\t600\t600\t60000\t600\t0\t1\n"))
}

@(test)
legacy_vga_host_metrics_test_duplicate_and_unknown_labels_do_not_replace_phase :: proc(
	t: ^testing.T,
) {
	metrics: Legacy_Vga_Host_Metrics
	legacy_vga_host_metrics_init(&metrics, true, .Auto)
	first := legacy_vga_host_metrics_test_capture(LEGACY_VGA_PRE_CAPTURE_LABEL, 10, 20)
	legacy_vga_host_metrics_note_capture(&metrics, first)
	duplicate := legacy_vga_host_metrics_test_capture(LEGACY_VGA_PRE_CAPTURE_LABEL, 99, 100)
	legacy_vga_host_metrics_note_capture(&metrics, duplicate)
	unknown := legacy_vga_host_metrics_test_capture(239, 77, 88)
	legacy_vga_host_metrics_note_capture(&metrics, unknown)
	testing.expect_value(t, metrics.pre.time_ns, u64(10))
	testing.expect_value(t, metrics.pre.aperture_exits, u64(20))
	testing.expect(t, !metrics.post.valid)
}
