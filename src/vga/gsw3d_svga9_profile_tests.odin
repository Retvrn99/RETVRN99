// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(private = "file")
gsw3d_svga9_profile_test_destroy :: proc(first: u32, second: u32 = 0) -> ([24]u8, int) {
	data: [24]u8
	gsw_test_wr32(data[:], 0, 1041)
	gsw_test_wr32(data[:], 4, 4)
	gsw_test_wr32(data[:], 8, first)
	if second == 0 {return data, 12}
	gsw_test_wr32(data[:], 12, 1041)
	gsw_test_wr32(data[:], 16, 4)
	gsw_test_wr32(data[:], 20, second)
	return data, 24
}

@(private = "file")
gsw3d_svga9_profile_test_dynamic_word :: proc(offset: int, offsets: []int) -> bool {
	for candidate in offsets {if offset == candidate {return true}}
	return false
}

@(test)
gsw3d_svga9_profile_test_parses_captured_commands :: proc(t: ^testing.T) {
	definitions := gsw3d_triangle_fixture_definitions()
	command, ok := gsw3d_svga9_profile_parse(definitions[:])
	testing.expect(t, ok)
	testing.expect_value(
		t,
		command,
		Gsw3d_Svga9_Profile_Command{kind = .Define, width = 640, height = 480},
	)

	render := gsw3d_triangle_fixture_render()
	command, ok = gsw3d_svga9_profile_parse(render[:])
	testing.expect(t, ok)
	testing.expect_value(
		t,
		command,
		Gsw3d_Svga9_Profile_Command {
			kind = .Render,
			width = 640,
			height = 480,
			clear = 0xff10_1018,
		},
	)

	destroy, destroy_length := gsw3d_svga9_profile_test_destroy(2, 1)
	command, ok = gsw3d_svga9_profile_parse(destroy[:destroy_length])
	testing.expect(t, ok)
	testing.expect_value(
		t,
		command,
		Gsw3d_Svga9_Profile_Command{kind = .Destroy, destroyed = {true, true}},
	)
}

@(test)
gsw3d_svga9_profile_test_allows_bounded_extents_and_x8_clear_color :: proc(t: ^testing.T) {
	extents := [?][2]u32{{1, 1}, {320, 200}, {1920, 1200}, {8192, 8192}}
	colors := [?]u32{0x0012_3456, 0x7fab_cdef, 0xff00_0000, 0xffff_ffff}
	for extent, index in extents {
		width := extent[0]
		height := extent[1]
		definitions := gsw3d_triangle_fixture_definitions()
		gsw_test_wr32(definitions[:], 52, width)
		gsw_test_wr32(definitions[:], 56, height)
		defined, define_ok := gsw3d_svga9_profile_parse(definitions[:])
		testing.expect(t, define_ok)
		testing.expect_value(t, defined.width, width)
		testing.expect_value(t, defined.height, height)

		render := gsw3d_triangle_fixture_render()
		gsw_test_wr32(render[:], 48, width)
		gsw_test_wr32(render[:], 52, height)
		gsw_test_wr32(render[:], 212, colors[index])
		gsw_test_wr32(render[:], 232, width)
		gsw_test_wr32(render[:], 236, height)
		drawn, render_ok := gsw3d_svga9_profile_parse(render[:])
		testing.expect(t, render_ok)
		testing.expect_value(t, drawn.width, width)
		testing.expect_value(t, drawn.height, height)
		testing.expect_value(t, drawn.clear, colors[index] | 0xff00_0000)
	}
}

@(test)
gsw3d_svga9_profile_test_extent_limits_are_inclusive_and_budgeted :: proc(t: ^testing.T) {
	testing.expect(t, gsw3d_svga9_profile_extent_valid(1, 1))
	testing.expect(
		t,
		gsw3d_svga9_profile_extent_valid(
			GSW3D_SVGA9_PROFILE_MAX_DIMENSION,
			GSW3D_SVGA9_PROFILE_MAX_DIMENSION,
		),
	)
	testing.expect_value(
		t,
		u64(GSW3D_SVGA9_PROFILE_MAX_DIMENSION) * u64(GSW3D_SVGA9_PROFILE_MAX_DIMENSION) * 4,
		GSW3D_SVGA9_PROFILE_MAX_SURFACE_BYTES,
	)
	invalid := [?][2]u32 {
		{0, 1},
		{1, 0},
		{GSW3D_SVGA9_PROFILE_MAX_DIMENSION + 1, 1},
		{1, GSW3D_SVGA9_PROFILE_MAX_DIMENSION + 1},
		{~u32(0), ~u32(0)},
	}
	for extent in invalid {
		testing.expect(t, !gsw3d_svga9_profile_extent_valid(extent[0], extent[1]))
	}
}

@(test)
gsw3d_svga9_profile_test_rejects_invalid_or_mismatched_extents :: proc(t: ^testing.T) {
	invalid := [?][2]u32 {
		{0, 480},
		{640, 0},
		{GSW3D_SVGA9_PROFILE_MAX_DIMENSION + 1, 1},
		{1, GSW3D_SVGA9_PROFILE_MAX_DIMENSION + 1},
	}
	for extent in invalid {
		definitions := gsw3d_triangle_fixture_definitions()
		gsw_test_wr32(definitions[:], 52, extent[0])
		gsw_test_wr32(definitions[:], 56, extent[1])
		_, ok := gsw3d_svga9_profile_parse(definitions[:])
		testing.expect(t, !ok)

		render := gsw3d_triangle_fixture_render()
		gsw_test_wr32(render[:], 48, extent[0])
		gsw_test_wr32(render[:], 52, extent[1])
		gsw_test_wr32(render[:], 232, extent[0])
		gsw_test_wr32(render[:], 236, extent[1])
		_, ok = gsw3d_svga9_profile_parse(render[:])
		testing.expect(t, !ok)
	}

	render := gsw3d_triangle_fixture_render()
	gsw_test_wr32(render[:], 232, 639)
	_, ok := gsw3d_svga9_profile_parse(render[:])
	testing.expect(t, !ok)
	render = gsw3d_triangle_fixture_render()
	gsw_test_wr32(render[:], 236, 479)
	_, ok = gsw3d_svga9_profile_parse(render[:])
	testing.expect(t, !ok)
}

@(test)
gsw3d_svga9_profile_test_every_fixed_definition_word_rejects_drift :: proc(t: ^testing.T) {
	original := gsw3d_triangle_fixture_definitions()
	dynamic_offsets := [?]int{52, 56}
	for offset := 0; offset < len(original); offset += 4 {
		if gsw3d_svga9_profile_test_dynamic_word(offset, dynamic_offsets[:]) {continue}
		mutated := original
		gsw_test_wr32(mutated[:], offset, gsw_rd32(mutated[:], offset) ~ 1)
		_, ok := gsw3d_svga9_profile_parse(mutated[:])
		testing.expect(t, !ok)
	}
}

@(test)
gsw3d_svga9_profile_test_every_fixed_render_word_rejects_drift :: proc(t: ^testing.T) {
	original := gsw3d_triangle_fixture_render()
	dynamic_offsets := [?]int{48, 52, 212, 232, 236}
	for offset := 0; offset < len(original); offset += 4 {
		if gsw3d_svga9_profile_test_dynamic_word(offset, dynamic_offsets[:]) {continue}
		mutated := original
		gsw_test_wr32(mutated[:], offset, gsw_rd32(mutated[:], offset) ~ 1)
		_, ok := gsw3d_svga9_profile_parse(mutated[:])
		testing.expect(t, !ok)
	}
}

@(test)
gsw3d_svga9_profile_test_rejects_every_truncated_capture_and_trailing_data :: proc(t: ^testing.T) {
	definitions := gsw3d_triangle_fixture_definitions()
	for length in 0 ..< len(definitions) {
		_, ok := gsw3d_svga9_profile_parse(definitions[:length])
		testing.expect(t, !ok)
	}
	definitions_with_tail: [132]u8
	copy(definitions_with_tail[:], definitions[:])
	_, ok := gsw3d_svga9_profile_parse(definitions_with_tail[:])
	testing.expect(t, !ok)

	render := gsw3d_triangle_fixture_render()
	for length in 0 ..< len(render) {
		_, render_ok := gsw3d_svga9_profile_parse(render[:length])
		testing.expect(t, !render_ok)
	}
	render_with_tail: [364]u8
	copy(render_with_tail[:], render[:])
	_, ok = gsw3d_svga9_profile_parse(render_with_tail[:])
	testing.expect(t, !ok)
}

@(test)
gsw3d_svga9_profile_test_destroy_is_unique_bounded_and_exact :: proc(t: ^testing.T) {
	for id in GSW3D_SVGA9_PROFILE_TARGET_ID ..= GSW3D_SVGA9_PROFILE_BUFFER_ID {
		destroy, length := gsw3d_svga9_profile_test_destroy(id)
		command, ok := gsw3d_svga9_profile_parse(destroy[:length])
		testing.expect(t, ok)
		testing.expect_value(t, command.kind, Gsw3d_Svga9_Profile_Kind.Destroy)
		testing.expect_value(t, command.destroyed[int(id - GSW3D_SVGA9_PROFILE_TARGET_ID)], true)
	}

	orders := [?][2]u32{{1, 2}, {2, 1}}
	for order in orders {
		destroy, length := gsw3d_svga9_profile_test_destroy(order[0], order[1])
		command, ok := gsw3d_svga9_profile_parse(destroy[:length])
		testing.expect(t, ok)
		testing.expect_value(t, command.destroyed, [2]bool{true, true})
	}

	invalid_ids := [?][2]u32{{0, 0}, {3, 0}, {1, 1}, {2, 2}}
	for ids in invalid_ids {
		destroy, length := gsw3d_svga9_profile_test_destroy(ids[0], ids[1])
		_, ok := gsw3d_svga9_profile_parse(destroy[:length])
		testing.expect(t, !ok)
	}

	destroy, _ := gsw3d_svga9_profile_test_destroy(1, 2)
	for length in 0 ..< len(destroy) {
		_, ok := gsw3d_svga9_profile_parse(destroy[:length])
		testing.expect_value(t, ok, length == 12)
	}
	mutated := destroy
	gsw_test_wr32(mutated[:], 16, 8)
	_, ok := gsw3d_svga9_profile_parse(mutated[:])
	testing.expect(t, !ok)
}
