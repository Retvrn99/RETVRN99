// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
vga_test_legacy_aperture_execution_layout_reports_only_unchained_indexed_modes :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	mode_13 := vga_legacy_aperture_execution_layout(&v)
	testing.expect_value(t, mode_13.kind, Legacy_Aperture_Layout_Kind.Unavailable)

	mode_x_program_320x240(&v)
	mode_x := vga_legacy_aperture_execution_layout(&v)
	testing.expect_value(t, mode_x.kind, Legacy_Aperture_Layout_Kind.Indexed_Unchained)
	testing.expect_value(t, mode_x.width, 320)
	testing.expect_value(t, mode_x.height, 240)
	testing.expect_value(t, mode_x.pitch_bytes, 80)
	testing.expect_value(t, mode_x.aperture_base, LEGACY_APERTURE_BASE)
	testing.expect_value(t, mode_x.aperture_size, u64(LEGACY_PLANE_SIZE))

	v.seq[4] = 0x02
	odd_even := vga_legacy_aperture_execution_layout(&v)
	testing.expect_value(t, odd_even.kind, Legacy_Aperture_Layout_Kind.Unavailable)

	v.seq[4] = 0x04
	short_plane_memory := vga_legacy_aperture_execution_layout(&v)
	testing.expect_value(t, short_plane_memory.kind, Legacy_Aperture_Layout_Kind.Unavailable)

	v.seq[4] = 0x06

	v.dispi[DISPI_INDEX_ENABLE] = DISPI_ENABLED
	vbe := vga_legacy_aperture_execution_layout(&v)
	testing.expect_value(t, vbe.kind, Legacy_Aperture_Layout_Kind.Unavailable)
}

@(test)
vga_test_legacy_presentation_identity_is_read_only_and_fail_closed :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)
	mode_x_program_320x240(&v)
	_ = vga_display_frame(&v)

	mode_generation := v.legacy_presentation_mode_generation
	surface_generation := v.legacy_presentation_surface_generation
	identity := vga_legacy_presentation_identity(&v)
	testing.expect(t, identity.valid)
	testing.expect_value(t, identity.mode_generation, mode_generation)
	testing.expect_value(t, identity.surface_id, LEGACY_PRESENTATION_SURFACE_ID)
	testing.expect_value(t, identity.surface_generation, surface_generation)
	testing.expect_value(t, v.legacy_presentation_mode_generation, mode_generation)
	testing.expect_value(t, v.legacy_presentation_surface_generation, surface_generation)
	active := vga_active_presentation_identity(&v, nil)
	testing.expect(t, active.valid)
	testing.expect_value(t, active.mode_generation, mode_generation)
	testing.expect_value(t, active.surface_generation, surface_generation)
	testing.expect_value(t, active.width, u32(320))
	testing.expect_value(t, active.height, u32(240))

	v.legacy_presentation_surface_generation = 0
	identity = vga_legacy_presentation_identity(&v)
	testing.expect(t, !identity.valid)
}
