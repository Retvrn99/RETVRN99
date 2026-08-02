// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

LEGACY_PRESENTATION_SURFACE_ID :: u64(1)

Legacy_Presentation_Identity :: struct {
	valid:              bool,
	mode_generation:    u64,
	surface_id:         u64,
	surface_generation: u64,
}

Active_Presentation_Identity :: struct {
	valid:              bool,
	owner:              contract.Display_Owner,
	width, height:      u32,
	sequence:           u64,
	mode_generation:    u64,
	surface_id:         u64,
	surface_generation: u64,
}

vga_presentation_mode_key :: proc(
	width, height: u32,
	display_aspect: contract.Aspect_Ratio = {},
) -> contract.Mode_Key {
	extent := contract.Extent{width, height}
	aspect := display_aspect
	if aspect.width == 0 || aspect.height == 0 {
		aspect = contract.aspect_ratio_make(width, height)
	}
	rect := contract.Rect {
		width  = width,
		height = height,
	}
	return {
		format = .Bgra_8888,
		display_aspect = aspect,
		surface_extent = extent,
		canvas_extent = extent,
		source = rect,
		destination = rect,
	}
}

vga_legacy_display_aspect :: proc(v: ^Vga, width, height: u32) -> contract.Aspect_Ratio {
	if !vga_vbe_enabled(v) || width == 320 && height == 200 || width == 640 && height == 400 {
		return {4, 3}
	}
	return contract.aspect_ratio_make(width, height)
}

vga_presentation_mode_observe :: proc(
	v: ^Vga,
	owner: contract.Display_Owner,
	key: contract.Mode_Key,
) -> u64 {
	if v == nil {return 0}
	generation, _ := contract.mode_clock_observe(&v.presentation_mode_clock, owner, key)
	return generation
}

vga_presentation_mode_generation :: proc(v: ^Vga, width, height: u32) -> u64 {
	if width == 0 || height == 0 {return 0}
	aspect := vga_legacy_display_aspect(v, width, height)
	return vga_presentation_mode_observe(
		v,
		.Legacy,
		vga_presentation_mode_key(width, height, aspect),
	)
}

@(private = "package")
vga_legacy_presentation_mode_generation :: proc(v: ^Vga, claim: bool = false) -> u64 {
	if v == nil {return 0}
	_, width, height := display_geometry(v)
	if width <= 0 || height <= 0 {return 0}
	aspect := vga_legacy_display_aspect(v, u32(width), u32(height))
	key := vga_presentation_mode_key(u32(width), u32(height), aspect)
	clock := &v.presentation_mode_clock
	generation := clock.generation
	if claim ||
	   !clock.initialized ||
	   !contract.display_owner_is_gsw(clock.owner) ||
	   !contract.mode_key_equal(v.legacy_presentation_mode_key, key) {
		generation = vga_presentation_mode_observe(v, .Legacy, key)
	}
	v.legacy_presentation_mode_generation = generation
	v.legacy_presentation_mode_key = key
	if v.legacy_presentation_surface_generation == 0 ||
	   !contract.mode_key_equal(v.legacy_presentation_surface_key, key) {
		v.legacy_presentation_surface_generation = contract.generation_next(
			v.legacy_presentation_surface_generation,
		)
		v.legacy_presentation_surface_key = key
	}
	return generation
}

@(private = "package")
vga_legacy_frame_header :: proc(v: ^Vga) -> contract.Header {
	if v == nil {return {}}
	_, width, height := display_geometry(v)
	if width <= 0 || height <= 0 {return {}}
	extent := contract.Extent{u32(width), u32(height)}
	display_aspect := vga_legacy_display_aspect(v, extent.width, extent.height)
	full := contract.Rect {
		width  = extent.width,
		height = extent.height,
	}
	mode_generation := v.legacy_presentation_mode_generation
	mode_key := v.legacy_presentation_mode_key
	surface_generation := v.legacy_presentation_surface_generation
	if mode_generation == 0 ||
	   surface_generation == 0 ||
	   !contract.mode_key_equal(
			   mode_key,
			   vga_presentation_mode_key(extent.width, extent.height, display_aspect),
		   ) {
		return {}
	}
	border_left, border_right, border_top, border_bottom := border_extents(v)
	return {
		sequence = v.legacy_presentation_sequence,
		mode_generation = mode_generation,
		mode_key = mode_key,
		surface = {id = LEGACY_PRESENTATION_SURFACE_ID, generation = surface_generation},
		format = .Bgra_8888,
		display_aspect = display_aspect,
		surface_extent = extent,
		canvas_extent = extent,
		overscan = overscan_color(v),
		border = {u32(border_left), u32(border_right), u32(border_top), u32(border_bottom)},
		source = full,
		destination = full,
		interval = 0,
		source_kind = .Legacy_Snapshot,
		ownership = .Mailbox_Descriptor,
	}
}

vga_legacy_presentation_identity :: proc(v: ^Vga) -> Legacy_Presentation_Identity {
	header := vga_legacy_frame_header(v)
	if header.mode_generation == 0 ||
	   header.surface.id == 0 ||
	   header.surface.generation == 0 {
		return {}
	}
	return {
		valid              = true,
		mode_generation    = header.mode_generation,
		surface_id         = header.surface.id,
		surface_generation = header.surface.generation,
	}
}

vga_active_presentation_identity :: proc(
	v: ^Vga,
	gsw: ^Gsw_Vga,
) -> Active_Presentation_Identity {
	if v == nil || !v.presentation_mode_clock.initialized {return {}}
	clock := v.presentation_mode_clock
	header: contract.Header
	switch clock.owner {
	case .Legacy:
		header = vga_legacy_frame_header(v)
	case .Gsw2d, .Gsw3d:
		if gsw == nil || !gsw.presentation_state.active_valid {return {}}
		header = gsw.presentation_state.active.header
	case .None:
		return {}
	}
	if header.mode_generation == 0 ||
	   header.mode_generation != clock.generation ||
	   contract.display_owner_from_header(header) != clock.owner ||
	   header.surface.id == 0 ||
	   header.surface.generation == 0 ||
	   header.canvas_extent.width == 0 ||
	   header.canvas_extent.height == 0 {
		return {}
	}
	return {
		valid              = true,
		owner              = clock.owner,
		width              = header.canvas_extent.width,
		height             = header.canvas_extent.height,
		sequence           = header.sequence,
		mode_generation    = header.mode_generation,
		surface_id         = header.surface.id,
		surface_generation = header.surface.generation,
	}
}

@(private = "package")
vga_legacy_frame_update :: proc(v: ^Vga) -> contract.Legacy_Frame_Update {
	header := vga_legacy_frame_header(v)
	if header.mode_generation == 0 {return {}}
	_ = vga_damage_seal_pending(v, v.legacy_presentation_sequence)
	damage := vga_damage_snapshot(v)
	if damage.kind == .Invalid || damage.rects.count == 0 {return {}}
	header.dirty = damage.rects
	return {
		damage_kind = damage.kind,
		full_reason = damage.full_reason,
		header = header,
	}
}
