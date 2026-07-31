// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import presentation "../presentation"
import vga "../vga"
import "base:runtime"

Expansion_Baseline :: struct {
	valid:  bool,
	header: presentation.Header,
}

Expansion :: struct {
	allocator:       runtime.Allocator,
	legacy_pixels:   []u32,
	legacy_frame:    vga.Display_Frame,
	legacy_baseline: Expansion_Baseline,
	gsw_pixels:      []u32,
	gsw_frame:       vga.Display_Frame,
	gsw_baseline:    Expansion_Baseline,
}

expansion_baseline_matches :: proc(
	baseline: ^Expansion_Baseline,
	header: presentation.Header,
) -> bool {
	if baseline == nil || !baseline.valid {return false}
	previous := baseline.header
	return(
		previous.lifecycle_generation == header.lifecycle_generation &&
		previous.mode_generation == header.mode_generation &&
		presentation.mode_key_equal(previous.mode_key, header.mode_key) &&
		previous.identity_namespace == header.identity_namespace &&
		previous.device_generation == header.device_generation &&
		presentation.surface_identity_equal(previous.surface, header.surface) &&
		previous.format == header.format &&
		presentation.extent_equal(previous.surface_extent, header.surface_extent) &&
		presentation.extent_equal(previous.canvas_extent, header.canvas_extent) \
	)
}

expansion_init :: proc(expansion: ^Expansion, allocator := context.allocator) {
	if expansion == nil {return}
	expansion^ = {
		allocator = allocator,
	}
}

expand_legacy :: proc(
	expansion: ^Expansion,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame {
	if expansion == nil || descriptor == nil {return nil}
	if expansion.allocator.procedure == nil {expansion.allocator = context.allocator}
	header := descriptor.legacy_update.header
	if !expansion_baseline_matches(&expansion.legacy_baseline, header) &&
	   !descriptor.raw_complete {return nil}
	expansion.legacy_frame = {}
	frame := vga.scanout_descriptor_expand_legacy(
		descriptor,
		&expansion.legacy_pixels,
		&expansion.legacy_frame,
		expansion.allocator,
	)
	if frame != nil {expansion.legacy_baseline = {true, header}}
	return frame
}

expand_gsw :: proc(
	expansion: ^Expansion,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame {
	if expansion == nil || descriptor == nil {return nil}
	if expansion.allocator.procedure == nil {expansion.allocator = context.allocator}
	header := descriptor.gsw_presentation.present.header
	if !expansion_baseline_matches(&expansion.gsw_baseline, header) &&
	   !descriptor.gsw_presentation.raw_complete {return nil}
	expansion.gsw_frame = {}
	frame := vga.scanout_descriptor_expand_gsw(
		descriptor,
		&expansion.gsw_pixels,
		&expansion.gsw_frame,
		expansion.allocator,
	)
	if frame != nil {expansion.gsw_baseline = {true, header}}
	return frame
}

expansion_destroy :: proc(expansion: ^Expansion) {
	if expansion == nil {return}
	allocator := expansion.allocator
	if allocator.procedure == nil {allocator = context.allocator}
	if expansion.legacy_pixels != nil {delete(expansion.legacy_pixels, allocator)}
	if expansion.gsw_pixels != nil {delete(expansion.gsw_pixels, allocator)}
	expansion^ = {}
}
