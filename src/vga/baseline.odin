// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

vga_request_full_baseline :: proc(
	v: ^Vga,
	mode_generation, surface_id, surface_generation: u64,
	reason: contract.Damage_Full_Reason = .External_Tracking,
) -> bool {
	if v == nil ||
	   reason == .None ||
	   mode_generation == 0 ||
	   mode_generation != v.legacy_presentation_mode_generation ||
	   surface_id != LEGACY_PRESENTATION_SURFACE_ID ||
	   surface_generation == 0 ||
	   surface_generation != v.legacy_presentation_surface_generation {return false}
	vga_damage_record_full(v, .Pixel_Memory, reason)
	v.presentation_sequence = contract.generation_next(v.presentation_sequence)
	v.legacy_presentation_sequence = v.presentation_sequence
	return true
}
