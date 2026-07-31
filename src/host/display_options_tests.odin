// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import "core:testing"
import sdl3 "vendor:sdl3"

@(test)
host_display_options_resolve_aspect_policy_without_changing_contract :: proc(t: ^testing.T) {
	header :=
		host_presentation_test_legacy(1, key = host_presentation_test_mode_key(320, 200)).header
	header.display_aspect = {4, 3}
	header.mode_key.display_aspect = header.display_aspect
	original := header

	testing.expect_value(
		t,
		host_resolve_display_aspect(header, .Auto),
		contract.Aspect_Ratio{4, 3},
	)
	testing.expect_value(
		t,
		host_resolve_display_aspect(header, .Square_Pixels),
		contract.Aspect_Ratio{8, 5},
	)
	testing.expect_value(
		t,
		host_resolve_display_aspect(header, .Force_4_3),
		contract.Aspect_Ratio{4, 3},
	)
	testing.expect_value(t, header, original)
}

@(test)
host_display_options_apply_aspect_policy_to_current_frame :: proc(t: ^testing.T) {
	h: Host
	header :=
		host_presentation_test_legacy(1, key = host_presentation_test_mode_key(1280, 1024)).header
	h.has_frame = true
	h.presentation_state.selector.active = {
		kind        = .Legacy,
		source_kind = .Legacy_Snapshot,
	}
	h.presentation_state.legacy.header = header

	testing.expect(t, host_set_aspect_policy(&h, .Auto))
	testing.expect_value(t, h.aspect_width, 5)
	testing.expect_value(t, h.aspect_height, 4)
	testing.expect(t, host_set_aspect_policy(&h, .Force_4_3))
	testing.expect_value(t, h.aspect_width, 4)
	testing.expect_value(t, h.aspect_height, 3)
}

@(test)
host_display_options_keep_scaling_filter_independent_from_visual_shader :: proc(t: ^testing.T) {
	h: Host
	h.scaling_filter = .Linear
	h.visual_shader = .None
	testing.expect(t, host_set_scaling_filter(&h, .Nearest))
	testing.expect_value(t, h.scaling_filter, Scaling_Filter.Nearest)
	testing.expect_value(t, h.visual_shader, Visual_Shader.None)
	testing.expect(t, !host_set_scaling_filter(&h, .Sharp))
	testing.expect_value(t, h.scaling_filter, Scaling_Filter.Nearest)
}

@(test)
host_display_options_effective_source_scale_includes_destination_transform :: proc(t: ^testing.T) {
	present := composition_test_windowed_resident()
	geometry := host_scaling_geometry_from_header(
		present.header,
		200,
		100,
		sdl3.FRect{0, 0, 200, 100},
	)
	x, y := host_scaling_effective_output_scale(geometry)
	testing.expect_value(t, x, f32(1))
	testing.expect_value(t, y, f32(0.5))
}

@(test)
host_display_options_activate_shader_for_sharp_or_crt_independently :: proc(t: ^testing.T) {
	h: Host
	h.scaling_filter = .Sharp
	h.visual_shader = .None
	testing.expect(t, host_shader_effect_requested(&h))
	h.scaling_filter = .Linear
	testing.expect(t, !host_shader_effect_requested(&h))
	h.visual_shader = .Subtle
	testing.expect(t, host_shader_effect_requested(&h))
}

@(test)
host_display_options_shader_failure_clears_unsupported_selections :: proc(t: ^testing.T) {
	h := Host {
		scaling_filter = .Sharp,
		visual_shader  = .Not_So_Subtle,
	}
	host_shader_fail_closed(&h)
	testing.expect_value(t, h.scaling_filter, Scaling_Filter.Linear)
	testing.expect_value(t, h.visual_shader, Visual_Shader.None)
	testing.expect(t, h.shader_state == nil)
}
