// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:testing"

@(test)
vga_baseline_test_request_is_identity_checked_without_content_change :: proc(t: ^testing.T) {
	v: Vga
	backing := make([]u8, VRAM_SIZE)
	defer delete(backing)
	if !testing.expect(t, vga_init(&v, backing)) {return}
	defer vga_destroy(&v)
	v.legacy_damage = {}
	v.legacy_damage_batches = {}
	v.legacy_damage_batch_count = 0

	mode_generation := v.legacy_presentation_mode_generation
	surface_generation := v.legacy_presentation_surface_generation
	presentation_sequence := v.presentation_sequence
	content_generation := v.content_generation
	guest_generation := v.guest_activity_generation

	testing.expect(
		t,
		!vga_request_full_baseline(
			&v,
			contract.generation_next(mode_generation),
			LEGACY_PRESENTATION_SURFACE_ID,
			surface_generation,
		),
	)
	testing.expect_value(t, v.presentation_sequence, presentation_sequence)
	testing.expect(
		t,
		vga_request_full_baseline(
			&v,
			mode_generation,
			LEGACY_PRESENTATION_SURFACE_ID,
			surface_generation,
		),
	)
	testing.expect_value(t, v.presentation_sequence, contract.generation_next(presentation_sequence))
	testing.expect_value(t, v.legacy_presentation_sequence, v.presentation_sequence)
	testing.expect_value(t, v.content_generation, content_generation)
	testing.expect_value(t, v.guest_activity_generation, guest_generation)
	testing.expect_value(t, v.legacy_damage.full_reason, contract.Damage_Full_Reason.External_Tracking)
}
