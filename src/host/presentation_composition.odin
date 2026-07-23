// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import sdl3 "vendor:sdl3"

Host_Presentation_Draw_Segment :: struct {
	source:      sdl3.FRect,
	destination: sdl3.FRect,
}

Host_Presentation_Draw_Plan :: struct {
	valid:    bool,
	count:    u32,
	segments: [contract.MAX_RECTS]Host_Presentation_Draw_Segment,
}

Host_Presentation_Overlay_Plan :: struct {
	valid:               bool,
	clips:               contract.Rect_Set,
	active:              contract.Active_Identity,
	fallback:            bool,
	invalidated_regions: u64,
}

host_presentation_resident_requires_desktop :: proc(present: contract.Gsw_Present) -> bool {
	return present.clip_mode == .Windowed
}

host_presentation_resident_texture_extent :: proc(
	present: contract.Gsw_Present,
) -> (
	int,
	int,
	bool,
) {
	width := present.header.surface_extent.width
	height := present.header.surface_extent.height
	if width == 0 || height == 0 || u64(width) > u64(max(int)) || u64(height) > u64(max(int)) {
		return 0, 0, false
	}
	return int(width), int(height), true
}

host_presentation_guest_rect :: proc(
	guest_view: sdl3.FRect,
	rect: contract.Rect,
	canvas: contract.Extent,
) -> (
	sdl3.FRect,
	bool,
) {
	if canvas.width == 0 ||
	   canvas.height == 0 ||
	   !contract.rect_valid_nonempty(rect) ||
	   rect.x + rect.width > canvas.width ||
	   rect.y + rect.height > canvas.height {return {}, false}
	return {
			guest_view.x + guest_view.w * f32(rect.x) / f32(canvas.width),
			guest_view.y + guest_view.h * f32(rect.y) / f32(canvas.height),
			guest_view.w * f32(rect.width) / f32(canvas.width),
			guest_view.h * f32(rect.height) / f32(canvas.height),
		},
		true
}

host_presentation_active_matches :: proc(
	active: contract.Active_Identity,
	header: contract.Header,
) -> bool {
	return(
		active.kind == .Gsw &&
		active.display_owner == contract.display_owner_from_header(header) &&
		active.sequence == header.sequence &&
		active.lifecycle_generation == header.lifecycle_generation &&
		active.mode_generation == header.mode_generation &&
		active.identity_namespace == header.identity_namespace &&
		active.device_generation == header.device_generation &&
		contract.surface_identity_equal(active.surface, header.surface) &&
		active.source_kind == header.source_kind &&
		active.ownership == header.ownership \
	)
}

host_presentation_active_equal :: proc(a, b: contract.Active_Identity) -> bool {
	return(
		a.kind == b.kind &&
		a.display_owner == b.display_owner &&
		a.sequence == b.sequence &&
		a.lifecycle_generation == b.lifecycle_generation &&
		a.mode_generation == b.mode_generation &&
		a.identity_namespace == b.identity_namespace &&
		a.device_generation == b.device_generation &&
		contract.surface_identity_equal(a.surface, b.surface) &&
		a.source_kind == b.source_kind &&
		a.ownership == b.ownership \
	)
}

host_presentation_overlay_background_eligible :: proc(
	state: ^Host_Presentation_State,
	present: contract.Gsw_Present,
) -> bool {
	if state == nil ||
	   state.selector.active.source_kind != .Gsw_Resident ||
	   state.gsw.clip_mode != .Windowed ||
	   present.header.source_kind != .Gsw_Snapshot ||
	   present.header.identity_namespace != .Gsw2d ||
	   present.header.completion.value != 0 ||
	   present.header.completion.generation != 0 ||
	   !host_presentation_active_matches(state.selector.active, state.gsw.header) ||
	   !contract.mode_key_equal(
			   contract.output_mode_key(present.header),
			   contract.output_mode_key(state.gsw.header),
		   ) {return false}
	previous := state.gsw_snapshot
	if previous.header.sequence == 0 {
		return host_presentation_full_update(present.header)
	}
	return(
		present.header.mode_generation == state.gsw_snapshot_source_mode_generation &&
		contract.gsw_snapshot_surface_transition_valid(previous, present) \
	)
}

@(private = "file")
host_presentation_map_rect_to_canvas :: proc(
	header: contract.Header,
	rect: contract.Rect,
) -> (
	contract.Rect,
	bool,
) {
	clipped, visible := contract.rect_intersection(rect, header.source)
	if !visible {return {}, false}
	source := header.source
	destination := header.destination
	left := u64(clipped.x - source.x) * u64(destination.width)
	right := u64(clipped.x + clipped.width - source.x) * u64(destination.width)
	top := u64(clipped.y - source.y) * u64(destination.height)
	bottom := u64(clipped.y + clipped.height - source.y) * u64(destination.height)
	if left % u64(source.width) != 0 ||
	   right % u64(source.width) != 0 ||
	   top % u64(source.height) != 0 ||
	   bottom % u64(source.height) != 0 {
		return {}, false
	}
	x0 := u64(destination.x) + left / u64(source.width)
	x1 := u64(destination.x) + right / u64(source.width)
	y0 := u64(destination.y) + top / u64(source.height)
	y1 := u64(destination.y) + bottom / u64(source.height)
	if x1 <= x0 || y1 <= y0 || x1 > u64(max(u32)) || y1 > u64(max(u32)) {
		return {}, false
	}
	return {u32(x0), u32(y0), u32(x1 - x0), u32(y1 - y0)}, true
}

@(private = "file")
host_presentation_damage_to_canvas :: proc(
	present: contract.Gsw_Present,
) -> (
	contract.Rect_Set,
	bool,
	bool,
) {
	damage: contract.Rect_Set
	for i in 0 ..< int(present.header.dirty.count) {
		mapped, exact := host_presentation_map_rect_to_canvas(
			present.header,
			present.header.dirty.rects[i],
		)
		if !exact {
			full: contract.Rect_Set
			_ = contract.rect_set_append(&full, present.header.destination)
			return full, true, true
		}
		input: contract.Rect_Set
		_ = contract.rect_set_append(&input, mapped)
		next, result := contract.rect_set_union(damage, input, present.header.canvas_extent)
		if result == .Capacity_Exceeded {
			full: contract.Rect_Set
			_ = contract.rect_set_append(&full, present.header.destination)
			return full, true, true
		}
		if result == .Invalid {return {}, false, false}
		if result == .Exact {damage = next}
	}
	return damage, false, true
}

host_presentation_overlay_plan :: proc(
	state: ^Host_Presentation_State,
	present: contract.Gsw_Present,
) -> Host_Presentation_Overlay_Plan {
	if !host_presentation_overlay_background_eligible(state, present) {return {}}
	result := Host_Presentation_Overlay_Plan {
		valid  = true,
		clips  = state.gsw.clips,
		active = state.selector.active,
	}
	damage, mapped_fallback, valid := host_presentation_damage_to_canvas(present)
	if !valid {return {}}
	intersection, overlap_result := contract.rect_set_intersection(
		result.clips,
		damage,
		present.header.canvas_extent,
	)
	if overlap_result == .Invalid {return {}}
	if overlap_result == .Capacity_Exceeded {
		result.clips = {}
		result.fallback = true
		return result
	}
	if overlap_result == .Empty {return result}
	result.invalidated_regions = u64(intersection.count)
	remaining, subtract_result := contract.rect_set_subtract(
		result.clips,
		damage,
		present.header.canvas_extent,
	)
	if subtract_result == .Invalid {return {}}
	if subtract_result == .Capacity_Exceeded {
		result.clips = {}
		result.fallback = true
		return result
	}
	result.clips = subtract_result == .Exact ? remaining : contract.Rect_Set{}
	result.fallback = mapped_fallback
	return result
}

host_presentation_build_resident_draw_plan :: proc(
	present: contract.Gsw_Present,
	guest_view: sdl3.FRect,
) -> Host_Presentation_Draw_Plan {
	if present.header.source_kind != .Gsw_Resident ||
	   present.header.canvas_extent.width == 0 ||
	   present.header.canvas_extent.height == 0 ||
	   guest_view.w <= 0 ||
	   guest_view.h <= 0 {return {}}
	normalized := present
	clip_result := contract.gsw_present_normalize_clips(&normalized)
	if clip_result == .Invalid ||
	   clip_result == .Capacity_Exceeded ||
	   !contract.rect_set_equal(normalized.clips, present.clips) {return {}}
	visible: contract.Rect_Set
	if present.clip_mode == .Fullscreen {
		_ = contract.rect_set_append(&visible, present.header.destination)
	} else if present.clip_mode == .Windowed {
		destination: contract.Rect_Set
		_ = contract.rect_set_append(&destination, present.header.destination)
		clipped, result := contract.rect_set_intersection(
			present.clips,
			destination,
			present.header.canvas_extent,
		)
		if result == .Invalid || result == .Capacity_Exceeded {return {}}
		if result == .Exact {visible = clipped}
	} else {
		return {}
	}
	plan := Host_Presentation_Draw_Plan {
		valid = true,
	}
	canvas := present.header.canvas_extent
	source := present.header.source
	destination := present.header.destination
	for i in 0 ..< int(visible.count) {
		clip := visible.rects[i]
		dx0 := f32(clip.x - destination.x)
		dy0 := f32(clip.y - destination.y)
		dx1 := dx0 + f32(clip.width)
		dy1 := dy0 + f32(clip.height)
		plan.segments[plan.count] = {
			source      = {
				f32(source.x) + dx0 * f32(source.width) / f32(destination.width),
				f32(source.y) + dy0 * f32(source.height) / f32(destination.height),
				(dx1 - dx0) * f32(source.width) / f32(destination.width),
				(dy1 - dy0) * f32(source.height) / f32(destination.height),
			},
			destination = {
				guest_view.x + guest_view.w * f32(clip.x) / f32(canvas.width),
				guest_view.y + guest_view.h * f32(clip.y) / f32(canvas.height),
				guest_view.w * f32(clip.width) / f32(canvas.width),
				guest_view.h * f32(clip.height) / f32(canvas.height),
			},
		}
		plan.count += 1
	}
	return plan
}
