// SPDX-License-Identifier: GPL-3.0-only
package vga

import presentation "../presentation"

@(private = "package")
gsw_presentation_damage_accumulated :: proc(
	state: ^Gsw_Presentation_Producer_State,
	extent: presentation.Extent,
) -> presentation.Damage_Record {
	result: presentation.Damage_Record
	if state == nil {return result}
	for i in 0 ..< int(state.damage_batch_count) {
		result = presentation.damage_record_merge(result, state.damage_batches[i].damage, extent)
	}
	return presentation.damage_record_merge(result, state.damage, extent)
}

@(private = "package")
gsw_presentation_damage_seal :: proc(g: ^Gsw_Vga, sequence: u64) -> bool {
	if g == nil ||
	   !g.presentation_state.active_valid ||
	   sequence == 0 ||
	   g.presentation_state.damage.kind == .Invalid ||
	   g.presentation_state.damage.rects.count == 0 {return false}
	state := &g.presentation_state
	extent := state.active.header.surface_extent
	count := int(state.damage_batch_count)
	if count > 0 && state.damage_batches[count - 1].sequence == sequence {
		state.damage_batches[count - 1].damage = presentation.damage_record_merge(
			state.damage_batches[count - 1].damage,
			state.damage,
			extent,
		)
	} else {
		if count >= GSW_PRESENT_DAMAGE_MAX_BATCHES {
			merged := presentation.damage_record_merge(
				state.damage_batches[0].damage,
				state.damage_batches[1].damage,
				extent,
			)
			state.damage_batches[0] = {
				sequence = state.damage_batches[1].sequence,
				damage   = merged,
			}
			for i in 1 ..< count - 1 {
				state.damage_batches[i] = state.damage_batches[i + 1]
			}
			count -= 1
			state.damage_batch_count = u32(count)
			state.damage_batches[count] = {}
		}
		state.damage_batches[count] = {
			sequence = sequence,
			damage   = state.damage,
		}
		state.damage_batch_count += 1
	}
	state.damage = {}
	state.active.header.dirty = gsw_presentation_damage_accumulated(state, extent).rects
	return true
}

@(private = "package")
gsw_presentation_damage_clear :: proc(state: ^Gsw_Presentation_Producer_State) {
	if state == nil {return}
	state.damage = {}
	state.damage_batch_count = 0
	for &batch in state.damage_batches {batch = {}}
}

@(private = "file")
gsw_presentation_publish_damage :: proc(
	g: ^Gsw_Vga,
	incoming: presentation.Damage_Record,
) -> bool {
	if g == nil ||
	   !g.presentation_state.active_valid ||
	   incoming.kind == .Invalid ||
	   incoming.rects.count == 0 {return false}
	active := &g.presentation_state.active
	extent := active.header.surface_extent
	merged := presentation.damage_record_merge(g.presentation_state.damage, incoming, extent)
	if merged.kind == .Invalid || merged.rects.count == 0 {return false}
	g.presentation_state.damage = merged
	active.header.dirty = gsw_presentation_damage_accumulated(&g.presentation_state, extent).rects
	active.header.completion = {}
	if g.scanout != nil {
		active.header.sequence = vga_note_gsw_presentation(g.scanout)
	} else {
		active.header.sequence = presentation.generation_next(g.presentation_state.sequence)
	}
	g.presentation_state.sequence = active.header.sequence
	g.presentation_state.state_generation = presentation.generation_next(
		g.presentation_state.state_generation,
	)
	return true
}

@(private = "file")
gsw_presentation_damage_full :: proc(
	g: ^Gsw_Vga,
	kind: presentation.Damage_Kind,
	reason: presentation.Damage_Full_Reason = .None,
) -> bool {
	if g == nil || !g.presentation_state.active_valid {return false}
	extent := g.presentation_state.active.header.surface_extent
	damage := presentation.Damage_Record {
		kind        = kind,
		full_reason = reason,
		rects       = presentation.rect_set_full(extent),
	}
	return gsw_presentation_publish_damage(g, damage)
}

gsw_presentation_publish_external_backing_writes :: proc(g: ^Gsw_Vga, dirty: bool) -> bool {
	if !dirty {return false}
	return gsw_presentation_damage_full(g, .Pixel_Memory, .External_Tracking)
}

@(private = "package")
gsw_presentation_active_backing_valid :: proc(g: ^Gsw_Vga) -> bool {
	if g == nil || !g.presentation_state.active_valid {return false}
	active := g.presentation_state.active
	if active.header.lifecycle_generation != g.presentation_state.lifecycle_generation ||
	   active.header.device_generation != g.presentation_state.device_generation ||
	   !g.presentation_state.mode_clock.initialized ||
	   g.presentation_state.mode_clock.owner != .Gsw2d ||
	   active.header.mode_generation != g.presentation_state.mode_clock.generation ||
	   active.header.source_kind != .Gsw_Snapshot ||
	   active.header.ownership != .Vm_Framebuffer ||
	   active.header.identity_namespace != .Gsw2d {
		return false
	}
	if active.header.surface.id == GSW_IMPLICIT_SURFACE_ID {
		if active.source_offset > u64(max(u32)) {return false}
		key := Gsw_Presentation_Surface_Key {
			offset = u32(active.source_offset),
			width  = active.header.surface_extent.width,
			height = active.header.surface_extent.height,
			pitch  = active.source_pitch,
			format = g.format,
		}
		return(
			g.presentation_state.raw_surface_valid &&
			active.header.surface.generation == g.presentation_state.raw_surface_generation &&
			g.presentation_state.raw_surface_key == key \
		)
	}
	if active.header.surface.id > u64(max(u32)) {return false}
	surface, found := gsw_surface_get(g, u32(active.header.surface.id))
	if !found || surface.generation != active.header.surface.generation {return false}
	format_valid := false
	#partial switch surface.format {
	case .Indexed_8:
		format_valid = active.header.format == .Indexed_8
	case .Rgb_555:
		format_valid = active.header.format == .Rgb_555
	case .Rgb_565:
		format_valid = active.header.format == .Rgb_565
	case .Rgb_888:
		format_valid = active.header.format == .Bgr_888
	case .Xrgb_8888:
		format_valid = active.header.format == .Bgrx_8888
	case:
	}
	return(
		format_valid &&
		surface.flags & GSW_SURFACE_PRESENTABLE != 0 &&
		u64(surface.base) == active.source_offset &&
		surface.width == active.header.surface_extent.width &&
		surface.height == active.header.surface_extent.height &&
		surface.pitch == active.source_pitch &&
		surface.format == g.format \
	)
}

@(private = "package")
gsw_presentation_external_backing_range_overlaps :: proc(
	g: ^Gsw_Vga,
	v: ^Vga,
	start, length: u32,
) -> bool {
	if !gsw_presentation_active_backing_valid(g) ||
	   v == nil ||
	   g.scanout != v ||
	   length == 0 ||
	   len(g.framebuffer) == 0 ||
	   len(v.vram) == 0 ||
	   raw_data(g.framebuffer) != raw_data(v.vram) ||
	   !v.presentation_mode_clock.initialized ||
	   v.presentation_mode_clock.owner != .Gsw2d ||
	   v.presentation_mode_clock.generation != g.presentation_state.active.header.mode_generation ||
	   !presentation.mode_key_equal(
		   v.presentation_mode_clock.key,
		   vga_presentation_mode_key(
			   g.presentation_state.active.header.canvas_extent.width,
			   g.presentation_state.active.header.canvas_extent.height,
		   ),
	   ) ||
	   start >= u32(len(g.framebuffer)) ||
	   length > u32(len(g.framebuffer)) - start {
		return false
	}
	active := g.presentation_state.active
	bytes_per_pixel, format_valid := presentation.pixel_format_bytes(active.header.format)
	if !format_valid || active.header.source.width == 0 || active.header.source.height == 0 {
		return false
	}
	changed_start := u64(start)
	changed_end := changed_start + u64(length)
	row_bytes := u64(active.header.source.width) * u64(bytes_per_pixel)
	x_bytes := u64(active.header.source.x) * u64(bytes_per_pixel)
	y_bytes := u64(active.header.source.y) * u64(active.source_pitch)
	if active.source_offset > max(u64) - y_bytes ||
	   active.source_offset + y_bytes > max(u64) - x_bytes {
		return false
	}
	span_start := active.source_offset + y_bytes + x_bytes
	last_row_bytes := u64(active.header.source.height - 1) * u64(active.source_pitch)
	if span_start > max(u64) - last_row_bytes ||
	   span_start + last_row_bytes > max(u64) - row_bytes {
		return false
	}
	span_end := span_start + last_row_bytes + row_bytes
	if span_end > u64(len(g.framebuffer)) {return false}
	return changed_start < span_end && span_start < changed_end
}

@(private = "package")
gsw_presentation_note_surface_damage :: proc(
	g: ^Gsw_Vga,
	surface: ^Gsw_Surface,
	x, y, width, height: u32,
) -> bool {
	if g == nil || surface == nil || !g.presentation_state.active_valid {return false}
	active := g.presentation_state.active.header
	identity := presentation.Surface_Identity{u64(surface.id), surface.generation}
	if !presentation.surface_identity_equal(active.surface, identity) {return false}
	rects: presentation.Rect_Set
	if !presentation.rect_set_append(&rects, {x, y, width, height}) {return false}
	normalized, result := presentation.rect_set_canonicalize(rects, active.surface_extent)
	if result == .Empty {return false}
	if result != .Exact {
		return gsw_presentation_damage_full(g, .Pixel_Memory, .Capacity_Exceeded)
	}
	return gsw_presentation_publish_damage(g, {.Pixel_Memory, .None, normalized})
}

@(private = "file")
gsw_presentation_append_row_span :: proc(rects: ^presentation.Rect_Set, x, y, width: u32) -> bool {
	if rects == nil || width == 0 {return false}
	if rects.count != 0 {
		last := &rects.rects[rects.count - 1]
		if last.x == x && last.width == width && last.y + last.height == y {
			last.height += 1
			return true
		}
	}
	return presentation.rect_set_append(rects, {x, y, width, 1})
}

@(private = "package")
gsw_presentation_note_raw_damage :: proc(
	g: ^Gsw_Vga,
	base, pitch, x, y, width, height: u32,
	format: Gsw_Pixel_Format,
) -> bool {
	if g == nil || !g.presentation_state.active_valid || width == 0 || height == 0 {
		return false
	}
	active := g.presentation_state.active
	destination_bytes := gsw_format_bytes(format)
	active_bytes, active_known := presentation.pixel_format_bytes(active.header.format)
	if destination_bytes == 0 || !active_known {return false}
	destination_row_bytes := u64(width) * u64(destination_bytes)
	active_row_bytes := u64(active.header.source.width) * u64(active_bytes)
	rects: presentation.Rect_Set
	overlapped := false
	destination_y, active_y: u32
	for destination_y < height && active_y < active.header.source.height {
		destination_start :=
			u64(base) + u64(y + destination_y) * u64(pitch) + u64(x) * u64(destination_bytes)
		destination_end := destination_start + destination_row_bytes
		active_start :=
			active.source_offset +
			u64(active.header.source.y + active_y) * u64(active.source_pitch) +
			u64(active.header.source.x) * u64(active_bytes)
		active_end := active_start + active_row_bytes
		if destination_end <= active_start {
			destination_y += 1
			continue
		}
		if active_end <= destination_start {
			active_y += 1
			continue
		}
		overlapped = true
		if destination_bytes != int(active_bytes) {
			return gsw_presentation_damage_full(g, .Pixel_Memory, .Ambiguous_Mapping)
		}
		start := max(destination_start, active_start)
		end := min(destination_end, active_end)
		x0 := u32((start - active_start) / u64(active_bytes))
		x1 := u32((end - active_start + u64(active_bytes) - 1) / u64(active_bytes))
		if !gsw_presentation_append_row_span(&rects, x0, active_y, x1 - x0) {
			return gsw_presentation_damage_full(g, .Pixel_Memory, .Capacity_Exceeded)
		}
		if destination_end <= active_end {destination_y += 1}
		if active_end <= destination_end {active_y += 1}
	}
	if !overlapped {return false}
	normalized, result := presentation.rect_set_canonicalize(rects, active.header.surface_extent)
	if result != .Exact {
		return gsw_presentation_damage_full(g, .Pixel_Memory, .Capacity_Exceeded)
	}
	return gsw_presentation_publish_damage(g, {.Pixel_Memory, .None, normalized})
}

@(private = "package")
gsw_presentation_note_palette_damage :: proc(g: ^Gsw_Vga) -> bool {
	if g == nil ||
	   !g.presentation_state.active_valid ||
	   g.presentation_state.active.header.format != .Indexed_8 {return false}
	return gsw_presentation_damage_full(g, .Palette_Only)
}

gsw_presentation_acknowledge :: proc(
	g: ^Gsw_Vga,
	sequence, device_generation, surface_id, surface_generation: u64,
) -> bool {
	if g == nil || !g.presentation_state.active_valid {return false}
	header := g.presentation_state.active.header
	if sequence == 0 ||
	   device_generation == 0 ||
	   device_generation != header.device_generation ||
	   surface_id == 0 ||
	   surface_id != header.surface.id ||
	   surface_generation == 0 ||
	   surface_generation != header.surface.generation {return false}
	state := &g.presentation_state
	count := int(state.damage_batch_count)
	acknowledged := -1
	for i in 0 ..< count {
		if state.damage_batches[i].sequence == sequence {
			acknowledged = i
			break
		}
	}
	if acknowledged < 0 {
		if sequence != header.sequence || !gsw_presentation_damage_seal(g, header.sequence) {
			return false
		}
		count = int(state.damage_batch_count)
		for i in 0 ..< count {
			if state.damage_batches[i].sequence == sequence {
				acknowledged = i
				break
			}
		}
		if acknowledged < 0 {return false}
	}
	remaining := count - acknowledged - 1
	for i in 0 ..< remaining {
		state.damage_batches[i] = state.damage_batches[acknowledged + 1 + i]
	}
	for i in remaining ..< count {state.damage_batches[i] = {}}
	state.damage_batch_count = u32(remaining)
	_ = gsw_presentation_damage_seal(g, header.sequence)
	state.active.header.dirty =
		gsw_presentation_damage_accumulated(state, state.active.header.surface_extent).rects
	return true
}
