// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

VGA_DAMAGE_MAX_RANGES :: 256
VGA_DAMAGE_MAX_PARTIAL_RANGES :: 32
VGA_CAPTURE_MAX_RANGES :: 4096
VGA_DAMAGE_MAX_BATCHES :: 4

Vga_Damage_Range :: struct {
	start, end: u32,
}

Vga_Damage_State :: struct {
	range_count:  u32,
	ranges:       [VGA_DAMAGE_MAX_RANGES]Vga_Damage_Range,
	palette:      bool,
	full_reason:  contract.Damage_Full_Reason,
	write_serial: u64,
}

Vga_Damage_Batch :: struct {
	sequence: u64,
	state:    Vga_Damage_State,
}

Vga_Capture_Range_Set :: struct {
	count:  u32,
	ranges: [VGA_CAPTURE_MAX_RANGES]Vga_Damage_Range,
}

@(private = "file")
vga_damage_extent :: proc(v: ^Vga) -> contract.Extent {
	if v == nil {return {}}
	_, width, height := display_geometry(v)
	if width <= 0 || height <= 0 || width > int(max(u32)) || height > int(max(u32)) {
		return {}
	}
	return {u32(width), u32(height)}
}

@(private = "file")
vga_damage_kind :: proc(pixels, palette: bool) -> contract.Damage_Kind {
	if pixels && palette {return .Pixel_And_Palette}
	if pixels {return .Pixel_Memory}
	if palette {return .Palette_Only}
	return .Invalid
}

@(private = "file")
vga_damage_reason_priority :: proc(reason: contract.Damage_Full_Reason) -> u8 {
	#partial switch reason {
	case .Initial_Surface:
		return 1
	case .Mode_Boundary:
		return 2
	case .External_Tracking:
		return 3
	case .Ambiguous_Mapping:
		return 4
	case .Capacity_Exceeded:
		return 5
	case:
		return 0
	}
}

@(private = "file")
vga_damage_reason_merge :: proc(a, b: contract.Damage_Full_Reason) -> contract.Damage_Full_Reason {
	return vga_damage_reason_priority(b) > vga_damage_reason_priority(a) ? b : a
}

vga_damage_record_full :: proc(
	v: ^Vga,
	kind: contract.Damage_Kind,
	reason: contract.Damage_Full_Reason,
) {
	if v == nil || kind == .Invalid || reason == .None {return}
	v.legacy_damage.range_count = 0
	for &entry in v.legacy_damage.ranges {entry = {}}
	v.legacy_damage.palette = v.legacy_damage.palette || contract.damage_kind_has_palette(kind)
	v.legacy_damage.full_reason = vga_damage_reason_merge(v.legacy_damage.full_reason, reason)
	v.legacy_damage.write_serial = contract.generation_next(v.legacy_damage.write_serial)
}

@(private = "file")
vga_damage_uses_palette :: proc(v: ^Vga) -> bool {
	if v == nil {return false}
	kind, _, _ := display_geometry(v)
	if v.cga.active && !vga_vbe_enabled(v) {return false}
	return kind == .Text || kind == .Planar_4 || kind == .Indexed_8
}

vga_damage_record_palette :: proc(v: ^Vga) -> bool {
	if v == nil || !vga_damage_uses_palette(v) {return false}
	v.legacy_damage.palette = true
	v.legacy_damage.write_serial = contract.generation_next(v.legacy_damage.write_serial)
	return true
}

@(private = "file")
vga_damage_range_sort :: proc(state: ^Vga_Damage_State) {
	for i in 1 ..< int(state.range_count) {
		value := state.ranges[i]
		j := i
		for j > 0 && value.start < state.ranges[j - 1].start {
			state.ranges[j] = state.ranges[j - 1]
			j -= 1
		}
		state.ranges[j] = value
	}
}

@(private = "file")
vga_damage_state_has_damage :: proc(state: ^Vga_Damage_State) -> bool {
	return state != nil && (state.range_count != 0 || state.palette || state.full_reason != .None)
}

@(private = "file")
vga_damage_state_merge :: proc(destination, source: ^Vga_Damage_State) {
	if destination == nil || source == nil || !vga_damage_state_has_damage(source) {return}
	destination.palette = destination.palette || source.palette
	destination.full_reason = vga_damage_reason_merge(destination.full_reason, source.full_reason)
	if destination.full_reason != .None {
		destination.range_count = 0
		for &entry in destination.ranges {entry = {}}
		return
	}
	for source_index in 0 ..< int(source.range_count) {
		entry := source.ranges[source_index]
		for i := 0; i < int(destination.range_count); {
			current := destination.ranges[i]
			if entry.end < current.start || current.end < entry.start {
				i += 1
				continue
			}
			entry.start = min(entry.start, current.start)
			entry.end = max(entry.end, current.end)
			for j in i ..< int(destination.range_count) - 1 {
				destination.ranges[j] = destination.ranges[j + 1]
			}
			destination.range_count -= 1
			destination.ranges[destination.range_count] = {}
		}
		if destination.range_count >= VGA_DAMAGE_MAX_RANGES {
			destination.range_count = 0
			for &range in destination.ranges {range = {}}
			destination.full_reason = .Capacity_Exceeded
			return
		}
		destination.ranges[destination.range_count] = entry
		destination.range_count += 1
	}
	vga_damage_range_sort(destination)
}

@(private = "file")
vga_damage_accumulated :: proc(v: ^Vga) -> Vga_Damage_State {
	result: Vga_Damage_State
	if v == nil {return result}
	for i in 0 ..< int(v.legacy_damage_batch_count) {
		vga_damage_state_merge(&result, &v.legacy_damage_batches[i].state)
	}
	vga_damage_state_merge(&result, &v.legacy_damage)
	result.write_serial = v.legacy_damage.write_serial
	return result
}

@(private = "package")
vga_damage_seal_pending :: proc(v: ^Vga, sequence: u64) -> bool {
	if v == nil || sequence == 0 || !vga_damage_state_has_damage(&v.legacy_damage) {return false}
	count := int(v.legacy_damage_batch_count)
	if count > 0 && v.legacy_damage_batches[count - 1].sequence == sequence {
		vga_damage_state_merge(&v.legacy_damage_batches[count - 1].state, &v.legacy_damage)
	} else {
		if count >= VGA_DAMAGE_MAX_BATCHES {
			merged := v.legacy_damage_batches[0].state
			vga_damage_state_merge(&merged, &v.legacy_damage_batches[1].state)
			v.legacy_damage_batches[0] = {
				sequence = v.legacy_damage_batches[1].sequence,
				state    = merged,
			}
			for i in 1 ..< count - 1 {
				v.legacy_damage_batches[i] = v.legacy_damage_batches[i + 1]
			}
			count -= 1
			v.legacy_damage_batch_count = u32(count)
			v.legacy_damage_batches[count] = {}
		}
		v.legacy_damage_batches[count] = {
			sequence = sequence,
			state    = v.legacy_damage,
		}
		v.legacy_damage_batch_count += 1
	}
	serial := v.legacy_damage.write_serial
	v.legacy_damage = {
		write_serial = serial,
	}
	return true
}

vga_damage_record_backing_range :: proc(v: ^Vga, start, length: u32) -> bool {
	if v == nil || length == 0 || start >= u32(VRAM_SIZE) || length > u32(VRAM_SIZE) - start {
		return false
	}
	state := &v.legacy_damage
	if state.full_reason != .None {
		state.write_serial = contract.generation_next(state.write_serial)
		return true
	}
	entry := Vga_Damage_Range{start, start + length}
	for i := 0; i < int(state.range_count); {
		current := state.ranges[i]
		if entry.end < current.start || current.end < entry.start {
			i += 1
			continue
		}
		entry.start = min(entry.start, current.start)
		entry.end = max(entry.end, current.end)
		for j in i ..< int(state.range_count) - 1 {state.ranges[j] = state.ranges[j + 1]}
		state.range_count -= 1
		state.ranges[state.range_count] = {}
	}
	if state.range_count >= VGA_DAMAGE_MAX_RANGES {
		vga_damage_record_full(v, .Pixel_Memory, .Capacity_Exceeded)
		return true
	}
	state.ranges[state.range_count] = entry
	state.range_count += 1
	vga_damage_range_sort(state)
	state.write_serial = contract.generation_next(state.write_serial)
	return true
}

vga_store_backing_byte :: proc(v: ^Vga, index: int, value: u8) -> bool {
	if v == nil || index < 0 || index >= len(v.vram) {return false}
	if v.vram[index] == value {return true}
	v.vram[index] = value
	_ = vga_damage_record_backing_range(v, u32(index), 1)
	return true
}

@(private = "file")
vga_damage_index_changed :: proc(state: ^Vga_Damage_State, index: u32) -> bool {
	low, high := 0, int(state.range_count)
	for low < high {
		middle := low + (high - low) / 2
		range := state.ranges[middle]
		if index < range.start {
			high = middle
		} else if index >= range.end {
			low = middle + 1
		} else {
			return true
		}
	}
	return false
}

@(private = "file")
vga_damage_linear_source :: proc(v: ^Vga, raw: int) -> (u32, bool) {
	if raw < 0 {return 0, false}
	index: int
	if v.seq[4] & 0x08 != 0 {
		index = raw
	} else if v.seq[4] & 0x04 == 0 {
		index = (raw >> 1) * 4 + (raw & 1)
	} else {
		index = raw * 4
	}
	return u32(index), index >= 0 && index < len(v.vram)
}

@(private = "file")
vga_damage_text_sources :: proc(v: ^Vga, x, y, width: int, out: ^[3]u32) -> int {
	character_width := v.cga.active ? 8 : (v.seq[1] & 1 != 0 ? 8 : 9)
	character_height := max(int(v.crtc[9] & 0x1F) + 1, 1)
	columns := width / character_width
	first_line := legacy_split_first_line(v, .Text)
	below_split := y >= first_line
	origin_line := below_split ? first_line : 0
	start := below_split ? 0 : int(display_start(v))
	effective_line := y - origin_line + legacy_preset_row(v, below_split)
	row := effective_line / character_height
	glyph_y := effective_line % character_height
	pitch := v.cga.active ? columns * 2 : int(v.crtc[0x13]) * 2
	byte_pan := v.cga.active ? 0 : legacy_byte_pan(v, below_split)
	pan := v.cga.active ? 0 : legacy_text_pel_pan(v, below_split, character_width)
	column := (x + pan) / character_width
	cell := (start + row * pitch + column) & 0x3FFF
	raw := (cell * 2 + byte_pan) & 0x7FFF
	character := legacy_text_byte(v, raw)
	attribute := legacy_text_byte(v, raw + 1)
	char_index, char_ok := vga_damage_linear_source(v, raw)
	attribute_index, attribute_ok := vga_damage_linear_source(v, raw + 1)
	font_a, font_b := font_blocks(v)
	font_base := (attribute & 0x08 != 0 ? font_b : font_a) * 8192
	if v.cga.active {font_base = 0}
	font_offset := font_base + int(character) * 32 + min(glyph_y, 31)
	font_index := font_offset * 4 + 2
	count := 0
	if char_ok {out[count] = char_index; count += 1}
	if attribute_ok {out[count] = attribute_index; count += 1}
	if font_index >= 0 && font_index < len(v.vram) {out[count] = u32(font_index); count += 1}
	return count
}

@(private = "package")
vga_damage_pixel_sources :: proc(
	v: ^Vga,
	kind: Display_Kind,
	x, y, width: int,
	out: ^[4]u32,
) -> int {
	if vga_vbe_enabled(v) {
		pitch := vga_vbe_pitch(v)
		source_x := x + int(v.dispi[DISPI_INDEX_X_OFFSET])
		row := (y + int(v.dispi[DISPI_INDEX_Y_OFFSET])) * pitch
		bpp := int(v.dispi[DISPI_INDEX_BPP])
		if bpp == 4 {
			byte_offset := row + source_x / 8
			for plane in 0 ..< 4 {out[plane] = u32(byte_offset * 4 + plane)}
			return 4
		}
		bytes := (bpp + 7) / 8
		base := row + source_x * bytes
		for i in 0 ..< bytes {out[i] = u32(base + i)}
		return bytes
	}
	#partial switch kind {
	case .Text:
		text: [3]u32
		count := vga_damage_text_sources(v, x, y, width, &text)
		for i in 0 ..< count {out[i] = text[i]}
		return count
	case .Planar_4:
		geometry := legacy_graphics_row(v, kind, y)
		source_x := x + legacy_pel_pan(v, geometry.below_split)
		address := legacy_display_counter(v, geometry.row_base, u32(source_x / 8))
		offset := legacy_display_offset(v, address, geometry.row_scan)
		for plane in 0 ..< 4 {out[plane] = u32(offset * 4 + plane)}
		return 4
	case .Indexed_8:
		geometry := legacy_graphics_row(v, kind, y)
		source_x := x + (legacy_pel_pan(v, geometry.below_split) & 3)
		plane := source_x & 3
		offset := int(geometry.row_base + u32(source_x / 4)) & (LEGACY_PLANE_SIZE - 1)
		if v.seq[4] & 0x08 == 0 {
			address := legacy_display_counter(v, geometry.row_base, u32(source_x / 4))
			offset = legacy_display_offset(v, address, geometry.row_scan)
		}
		out[0] = u32(offset * 4 + plane)
		return 1
	case .Cga_1, .Cga_2:
		divisor := kind == .Cga_1 ? 8 : 4
		pitch := max(width / divisor, 1)
		start := int(display_start(v)) * 2
		row := (y & 1) * 0x2000 + (y >> 1) * pitch
		index, ok := vga_damage_linear_source(v, start + row + x / divisor)
		if ok {out[0] = index; return 1}
	case:
	}
	return 0
}

@(private = "file")
vga_capture_range_add :: proc(set: ^Vga_Capture_Range_Set, start, end: u32) -> bool {
	if set == nil || start >= end || end > u32(VRAM_SIZE) {return false}
	entry := Vga_Damage_Range{start, end}
	for i := 0; i < int(set.count); {
		current := set.ranges[i]
		if entry.end < current.start || current.end < entry.start {
			i += 1
			continue
		}
		entry.start = min(entry.start, current.start)
		entry.end = max(entry.end, current.end)
		for j in i ..< int(set.count) - 1 {set.ranges[j] = set.ranges[j + 1]}
		set.count -= 1
		set.ranges[set.count] = {}
	}
	if set.count >= VGA_CAPTURE_MAX_RANGES {return false}
	insert := int(set.count)
	for i in 0 ..< int(set.count) {
		if entry.start < set.ranges[i].start {insert = i; break}
	}
	for i := int(set.count); i > insert; i -= 1 {set.ranges[i] = set.ranges[i - 1]}
	set.ranges[insert] = entry
	set.count += 1
	return true
}

vga_damage_capture_ranges :: proc(
	v: ^Vga,
	rects: contract.Rect_Set,
	out: ^Vga_Capture_Range_Set,
) -> bool {
	if v == nil || out == nil {return false}
	out^ = {}
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {return false}
	extent := contract.Extent{u32(width), u32(height)}
	normalized, result := contract.rect_set_canonicalize(rects, extent)
	if result != .Exact {return false}
	if vga_vbe_enabled(v) {
		pitch := vga_vbe_pitch(v)
		x_offset := int(v.dispi[DISPI_INDEX_X_OFFSET])
		y_offset := int(v.dispi[DISPI_INDEX_Y_OFFSET])
		bpp := int(v.dispi[DISPI_INDEX_BPP])
		for rect_index in 0 ..< int(normalized.count) {
			rect := normalized.rects[rect_index]
			for y in int(rect.y) ..< int(rect.y + rect.height) {
				row := (y + y_offset) * pitch
				if bpp == 4 {
					start := (row + (int(rect.x) + x_offset) / 8) * 4
					end := (row + (int(rect.x + rect.width) + x_offset + 7) / 8) * 4
					if start < 0 ||
					   end > VRAM_SIZE ||
					   !vga_capture_range_add(out, u32(start), u32(end)) {return false}
				} else {
					bytes := (bpp + 7) / 8
					start := row + (int(rect.x) + x_offset) * bytes
					end := row + (int(rect.x + rect.width) + x_offset) * bytes
					if start < 0 ||
					   end > VRAM_SIZE ||
					   !vga_capture_range_add(out, u32(start), u32(end)) {return false}
				}
			}
		}
		return out.count != 0
	}
	for rect_index in 0 ..< int(normalized.count) {
		rect := normalized.rects[rect_index]
		for y in int(rect.y) ..< int(rect.y + rect.height) {
			for x in int(rect.x) ..< int(rect.x + rect.width) {
				sources: [4]u32
				count := vga_damage_pixel_sources(v, kind, x, y, width, &sources)
				if count == 0 {return false}
				for i in 0 ..< count {
					if !vga_capture_range_add(out, sources[i], sources[i] + 1) {return false}
				}
			}
		}
	}
	return out.count != 0
}

@(private = "file")
vga_damage_packed_vbe_rects :: proc(
	v: ^Vga,
	state: ^Vga_Damage_State,
	extent: contract.Extent,
) -> (
	contract.Rect_Set,
	bool,
) {
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	if bpp == 4 {return {}, false}
	bytes := (bpp + 7) / 8
	pitch := vga_vbe_pitch(v)
	x_offset := int(v.dispi[DISPI_INDEX_X_OFFSET])
	y_offset := int(v.dispi[DISPI_INDEX_Y_OFFSET])
	input: contract.Rect_Set
	for y in 0 ..< int(extent.height) {
		row_start := (y + y_offset) * pitch + x_offset * bytes
		row_end := row_start + int(extent.width) * bytes
		for range_index in 0 ..< int(state.range_count) {
			range := state.ranges[range_index]
			start := max(row_start, int(range.start))
			end := min(row_end, int(range.end))
			if start >= end {continue}
			x0 := (start - row_start) / bytes
			x1 := (end - row_start + bytes - 1) / bytes
			if !contract.rect_set_append(&input, {u32(x0), u32(y), u32(x1 - x0), 1}) {
				return {}, false
			}
		}
	}
	canonical, result := contract.rect_set_canonicalize(input, extent)
	return canonical, result == .Exact || result == .Empty
}

@(private = "file")
vga_damage_pixel_source_span :: proc(v: ^Vga, kind: Display_Kind, x, y, width: int) -> int {
	remaining := width - x
	if v == nil || remaining <= 0 {return 1}
	if vga_vbe_enabled(v) {
		if v.dispi[DISPI_INDEX_BPP] != 4 {return 1}
		source_x := x + int(v.dispi[DISPI_INDEX_X_OFFSET])
		return min(remaining, 8 - source_x % 8)
	}
	#partial switch kind {
	case .Text:
		character_width := v.cga.active ? 8 : (v.seq[1] & 1 != 0 ? 8 : 9)
		below_split := y >= legacy_split_first_line(v, .Text)
		pan := v.cga.active ? 0 : legacy_text_pel_pan(v, below_split, character_width)
		return min(remaining, character_width - (x + pan) % character_width)
	case .Planar_4:
		geometry := legacy_graphics_row(v, kind, y)
		source_x := x + legacy_pel_pan(v, geometry.below_split)
		return min(remaining, 8 - source_x % 8)
	case .Cga_1, .Cga_2:
		divisor := kind == .Cga_1 ? 8 : 4
		return min(remaining, divisor - x % divisor)
	case:
		return 1
	}
}

@(private = "file")
vga_damage_generic_rects :: proc(
	v: ^Vga,
	state: ^Vga_Damage_State,
	extent: contract.Extent,
) -> (
	contract.Rect_Set,
	bool,
) {
	kind, width, height := display_geometry(v)
	input: contract.Rect_Set
	for y in 0 ..< height {
		run_start := -1
		for x := 0; x < width; {
			span := vga_damage_pixel_source_span(v, kind, x, y, width)
			sources: [4]u32
			count := vga_damage_pixel_sources(v, kind, x, y, width, &sources)
			changed := false
			for i in 0 ..< count {
				if vga_damage_index_changed(state, sources[i]) {
					changed = true
					break
				}
			}
			if changed && run_start < 0 {run_start = x}
			if !changed && run_start >= 0 {
				if !contract.rect_set_append(
					&input,
					{u32(run_start), u32(y), u32(x - run_start), 1},
				) {return {}, false}
				run_start = -1
			}
			x += span
		}
		if run_start >= 0 {
			if !contract.rect_set_append(
				&input,
				{u32(run_start), u32(y), u32(width - run_start), 1},
			) {return {}, false}
		}
	}
	canonical, result := contract.rect_set_canonicalize(input, extent)
	return canonical, result == .Exact || result == .Empty
}

vga_damage_snapshot :: proc(v: ^Vga) -> contract.Damage_Record {
	if v == nil {return {}}
	extent := vga_damage_extent(v)
	if extent.width == 0 || extent.height == 0 {return {}}
	state := vga_damage_accumulated(v)
	pixels := state.range_count != 0 || state.full_reason != .None
	kind := vga_damage_kind(pixels, state.palette)
	if kind == .Invalid {return {}}
	if state.full_reason != .None || state.palette {
		reason := state.full_reason
		if reason == .None {return {kind = kind, rects = contract.rect_set_full(extent)}}
		return contract.damage_record_full(extent, kind, reason)
	}
	if state.range_count > VGA_DAMAGE_MAX_PARTIAL_RANGES {
		return contract.damage_record_full(extent, kind, .Capacity_Exceeded)
	}
	rects: contract.Rect_Set
	ok := false
	if vga_vbe_enabled(v) && v.dispi[DISPI_INDEX_BPP] != 4 {
		rects, ok = vga_damage_packed_vbe_rects(v, &state, extent)
	} else {
		rects, ok = vga_damage_generic_rects(v, &state, extent)
	}
	if !ok {return contract.damage_record_full(extent, kind, .Capacity_Exceeded)}
	if rects.count > VGA_DAMAGE_MAX_PARTIAL_RANGES {
		return contract.damage_record_full(extent, kind, .Capacity_Exceeded)
	}
	if rects.count == 0 {return {}}
	return {kind = kind, rects = rects}
}

vga_damage_acknowledge :: proc(v: ^Vga, sequence: u64) -> bool {
	if v == nil || sequence == 0 {return false}
	count := int(v.legacy_damage_batch_count)
	acknowledged := -1
	for i in 0 ..< count {
		if v.legacy_damage_batches[i].sequence == sequence {
			acknowledged = i
			break
		}
	}
	if acknowledged < 0 {
		if sequence != v.legacy_presentation_sequence ||
		   !vga_damage_seal_pending(v, v.legacy_presentation_sequence) {return false}
		count = int(v.legacy_damage_batch_count)
		for i in 0 ..< count {
			if v.legacy_damage_batches[i].sequence == sequence {
				acknowledged = i
				break
			}
		}
		if acknowledged < 0 {return false}
	}
	remaining := count - acknowledged - 1
	for i in 0 ..< remaining {
		v.legacy_damage_batches[i] = v.legacy_damage_batches[acknowledged + 1 + i]
	}
	for i in remaining ..< count {v.legacy_damage_batches[i] = {}}
	v.legacy_damage_batch_count = u32(remaining)
	_ = vga_damage_seal_pending(v, v.legacy_presentation_sequence)
	return true
}

vga_damage_acknowledge_identity :: proc(
	v: ^Vga,
	sequence, mode_generation, surface_id, surface_generation: u64,
) -> bool {
	if v == nil ||
	   mode_generation == 0 ||
	   mode_generation != v.legacy_presentation_mode_generation ||
	   surface_id != LEGACY_PRESENTATION_SURFACE_ID ||
	   surface_generation == 0 ||
	   surface_generation != v.legacy_presentation_surface_generation {return false}
	return vga_damage_acknowledge(v, sequence)
}
