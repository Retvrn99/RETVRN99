// SPDX-License-Identifier: GPL-3.0-only
package presentation

Rect_Set_Result :: enum u8 {
	Invalid,
	Empty,
	Exact,
	Capacity_Exceeded,
}

Damage_Kind :: enum u8 {
	Invalid,
	Pixel_Memory,
	Palette_Only,
	Pixel_And_Palette,
}

Damage_Full_Reason :: enum u8 {
	None,
	Initial_Surface,
	Mode_Boundary,
	Ambiguous_Mapping,
	Capacity_Exceeded,
	External_Tracking,
}

Damage_Record :: struct {
	kind:        Damage_Kind,
	full_reason: Damage_Full_Reason,
	rects:       Rect_Set,
}

rect_valid_nonempty :: proc(rect: Rect) -> bool {
	return(
		rect.width != 0 &&
		rect.height != 0 &&
		rect.x <= max(u32) - rect.width &&
		rect.y <= max(u32) - rect.height \
	)
}

rect_intersection :: proc(a, b: Rect) -> (Rect, bool) {
	if !rect_valid_nonempty(a) || !rect_valid_nonempty(b) {return {}, false}
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.width, b.x + b.width)
	y1 := min(a.y + a.height, b.y + b.height)
	if x0 >= x1 || y0 >= y1 {return {}, false}
	return {x0, y0, x1 - x0, y1 - y0}, true
}

rect_clip_to_extent :: proc(rect: Rect, extent: Extent) -> (Rect, bool) {
	if !rect_valid_nonempty(rect) || extent.width == 0 || extent.height == 0 {
		return {}, false
	}
	return rect_intersection(rect, {0, 0, extent.width, extent.height})
}

rect_set_full :: proc(extent: Extent) -> Rect_Set {
	result: Rect_Set
	if extent.width != 0 && extent.height != 0 {
		_ = rect_set_append(&result, {0, 0, extent.width, extent.height})
	}
	return result
}

@(private = "file")
rect_sort_less :: proc(a, b: Rect) -> bool {
	if a.y != b.y {return a.y < b.y}
	if a.x != b.x {return a.x < b.x}
	if a.height != b.height {return a.height < b.height}
	return a.width < b.width
}

@(private = "file")
rect_set_sort :: proc(set: ^Rect_Set) {
	if set == nil || set.count <= 1 || set.count > MAX_RECTS {return}
	for i in 1 ..< int(set.count) {
		value := set.rects[i]
		j := i
		for j > 0 && rect_sort_less(value, set.rects[j - 1]) {
			set.rects[j] = set.rects[j - 1]
			j -= 1
		}
		set.rects[j] = value
	}
}

@(private = "file")
rect_exact_merge :: proc(a, b: Rect) -> (Rect, bool) {
	if !rect_valid_nonempty(a) || !rect_valid_nonempty(b) {return {}, false}
	if a.y == b.y && a.height == b.height {
		if a.x + a.width == b.x {
			return {a.x, a.y, a.width + b.width, a.height}, true
		}
		if b.x + b.width == a.x {
			return {b.x, b.y, b.width + a.width, b.height}, true
		}
	}
	if a.x == b.x && a.width == b.width {
		if a.y + a.height == b.y {
			return {a.x, a.y, a.width, a.height + b.height}, true
		}
		if b.y + b.height == a.y {
			return {b.x, b.y, b.width, b.height + a.height}, true
		}
	}
	return {}, false
}

@(private = "file")
rect_set_compact :: proc(set: ^Rect_Set) {
	if set == nil || set.count <= 1 || set.count > MAX_RECTS {return}
	changed := true
	for changed {
		changed = false
		rect_set_sort(set)
		for i in 0 ..< int(set.count) {
			for j in i + 1 ..< int(set.count) {
				merged, ok := rect_exact_merge(set.rects[i], set.rects[j])
				if !ok {continue}
				set.rects[i] = merged
				for k in j ..< int(set.count) - 1 {set.rects[k] = set.rects[k + 1]}
				set.count -= 1
				set.rects[set.count] = {}
				changed = true
				break
			}
			if changed {break}
		}
	}
	rect_set_sort(set)
}

@(private = "file")
rect_subtract :: proc(rect, cover: Rect, out: ^[4]Rect) -> int {
	intersection, overlaps := rect_intersection(rect, cover)
	if !overlaps {
		out[0] = rect
		return 1
	}
	count := 0
	rect_end_x := rect.x + rect.width
	rect_end_y := rect.y + rect.height
	intersection_end_x := intersection.x + intersection.width
	intersection_end_y := intersection.y + intersection.height
	if rect.y < intersection.y {
		out[count] = {rect.x, rect.y, rect.width, intersection.y - rect.y}
		count += 1
	}
	if intersection_end_y < rect_end_y {
		out[count] = {rect.x, intersection_end_y, rect.width, rect_end_y - intersection_end_y}
		count += 1
	}
	if rect.x < intersection.x {
		out[count] = {rect.x, intersection.y, intersection.x - rect.x, intersection.height}
		count += 1
	}
	if intersection_end_x < rect_end_x {
		out[count] = {
			intersection_end_x,
			intersection.y,
			rect_end_x - intersection_end_x,
			intersection.height,
		}
		count += 1
	}
	return count
}

@(private = "file")
rect_set_add_union :: proc(set: ^Rect_Set, rect: Rect) -> bool {
	if set == nil || set.count > MAX_RECTS || !rect_valid_nonempty(rect) {return false}
	candidate := set^
	pieces: [MAX_RECTS]Rect
	piece_count := 1
	pieces[0] = rect
	for i in 0 ..< int(candidate.count) {
		next: [MAX_RECTS]Rect
		next_count := 0
		for piece_index in 0 ..< piece_count {
			split: [4]Rect
			split_count := rect_subtract(pieces[piece_index], candidate.rects[i], &split)
			if split_count > MAX_RECTS - next_count {return false}
			for split_index in 0 ..< split_count {
				next[next_count] = split[split_index]
				next_count += 1
			}
		}
		pieces = next
		piece_count = next_count
		if piece_count == 0 {break}
	}
	if piece_count > MAX_RECTS - int(candidate.count) {return false}
	for i in 0 ..< piece_count {
		candidate.rects[candidate.count] = pieces[i]
		candidate.count += 1
	}
	rect_set_compact(&candidate)
	set^ = candidate
	return true
}

rect_set_canonicalize :: proc(source: Rect_Set, extent: Extent) -> (Rect_Set, Rect_Set_Result) {
	if source.count > MAX_RECTS || extent.width == 0 || extent.height == 0 {
		return {}, .Invalid
	}
	result: Rect_Set
	for i in 0 ..< int(source.count) {
		input := source.rects[i]
		if !rect_valid_nonempty(input) {return {}, .Invalid}
		clipped, visible := rect_clip_to_extent(input, extent)
		if !visible {continue}
		if !rect_set_add_union(&result, clipped) {return {}, .Capacity_Exceeded}
	}
	for i in int(source.count) ..< MAX_RECTS {
		if !rect_equal(source.rects[i], {}) {return {}, .Invalid}
	}
	if result.count == 0 {return {}, .Empty}
	return result, .Exact
}

rect_set_union :: proc(a, b: Rect_Set, extent: Extent) -> (Rect_Set, Rect_Set_Result) {
	left, left_result := rect_set_canonicalize(a, extent)
	if left_result == .Invalid || left_result == .Capacity_Exceeded {return {}, left_result}
	right, right_result := rect_set_canonicalize(b, extent)
	if right_result == .Invalid || right_result == .Capacity_Exceeded {return {}, right_result}
	result := left
	for i in 0 ..< int(right.count) {
		if !rect_set_add_union(&result, right.rects[i]) {return {}, .Capacity_Exceeded}
	}
	if result.count == 0 {return {}, .Empty}
	return result, .Exact
}

rect_set_intersection :: proc(a, b: Rect_Set, extent: Extent) -> (Rect_Set, Rect_Set_Result) {
	left, left_result := rect_set_canonicalize(a, extent)
	right, right_result := rect_set_canonicalize(b, extent)
	if left_result == .Invalid || right_result == .Invalid {return {}, .Invalid}
	if left_result == .Capacity_Exceeded || right_result == .Capacity_Exceeded {
		return {}, .Capacity_Exceeded
	}
	result: Rect_Set
	for i in 0 ..< int(left.count) {
		for j in 0 ..< int(right.count) {
			intersection, ok := rect_intersection(left.rects[i], right.rects[j])
			if !ok {continue}
			if !rect_set_add_union(&result, intersection) {return {}, .Capacity_Exceeded}
		}
	}
	if result.count == 0 {return {}, .Empty}
	return result, .Exact
}

rect_set_subtract :: proc(
	source, remove: Rect_Set,
	extent: Extent,
) -> (
	Rect_Set,
	Rect_Set_Result,
) {
	base, base_result := rect_set_canonicalize(source, extent)
	cut, cut_result := rect_set_canonicalize(remove, extent)
	if base_result == .Invalid || cut_result == .Invalid {return {}, .Invalid}
	if base_result == .Capacity_Exceeded || cut_result == .Capacity_Exceeded {
		return {}, .Capacity_Exceeded
	}
	if base_result == .Empty {return {}, .Empty}
	if cut_result == .Empty {return base, .Exact}
	pieces: [MAX_RECTS]Rect
	piece_count := int(base.count)
	for i in 0 ..< piece_count {pieces[i] = base.rects[i]}
	for cut_index in 0 ..< int(cut.count) {
		next: [MAX_RECTS]Rect
		next_count := 0
		for piece_index in 0 ..< piece_count {
			split: [4]Rect
			split_count := rect_subtract(pieces[piece_index], cut.rects[cut_index], &split)
			if split_count > MAX_RECTS - next_count {return {}, .Capacity_Exceeded}
			for split_index in 0 ..< split_count {
				next[next_count] = split[split_index]
				next_count += 1
			}
		}
		pieces = next
		piece_count = next_count
		if piece_count == 0 {return {}, .Empty}
	}
	result: Rect_Set
	for i in 0 ..< piece_count {
		if !rect_set_add_union(&result, pieces[i]) {return {}, .Capacity_Exceeded}
	}
	if result.count == 0 {return {}, .Empty}
	return result, .Exact
}

gsw_present_normalize_clips :: proc(present: ^Gsw_Present) -> Rect_Set_Result {
	if present == nil {return .Invalid}
	#partial switch present.clip_mode {
	case .Fullscreen:
		_, result := rect_set_canonicalize(present.clips, present.header.canvas_extent)
		if result != .Empty {return .Invalid}
		present.clips = {}
		return .Empty
	case .Windowed:
		clips, result := rect_set_canonicalize(present.clips, present.header.canvas_extent)
		if result == .Exact {present.clips = clips}
		if result == .Empty {present.clips = {}}
		return result
	case:
		return .Invalid
	}
}

damage_kind_has_pixels :: proc(kind: Damage_Kind) -> bool {
	return kind == .Pixel_Memory || kind == .Pixel_And_Palette
}

damage_kind_has_palette :: proc(kind: Damage_Kind) -> bool {
	return kind == .Palette_Only || kind == .Pixel_And_Palette
}

damage_kind_merge :: proc(a, b: Damage_Kind) -> Damage_Kind {
	pixels := damage_kind_has_pixels(a) || damage_kind_has_pixels(b)
	palette := damage_kind_has_palette(a) || damage_kind_has_palette(b)
	if pixels && palette {return .Pixel_And_Palette}
	if pixels {return .Pixel_Memory}
	if palette {return .Palette_Only}
	return .Invalid
}

@(private = "file")
damage_full_reason_priority :: proc(reason: Damage_Full_Reason) -> u8 {
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
damage_full_reason_merge :: proc(a, b: Damage_Full_Reason) -> Damage_Full_Reason {
	return damage_full_reason_priority(b) > damage_full_reason_priority(a) ? b : a
}

damage_record_full :: proc(
	extent: Extent,
	kind: Damage_Kind,
	reason: Damage_Full_Reason,
) -> Damage_Record {
	if kind == .Invalid || reason == .None {return {}}
	return {kind = kind, full_reason = reason, rects = rect_set_full(extent)}
}

damage_record_merge :: proc(a, b: Damage_Record, extent: Extent) -> Damage_Record {
	kind := damage_kind_merge(a.kind, b.kind)
	if kind == .Invalid {return {}}
	reason := damage_full_reason_merge(a.full_reason, b.full_reason)
	if a.full_reason != .None || b.full_reason != .None {
		if reason == .None {reason = .Ambiguous_Mapping}
		return damage_record_full(extent, kind, reason)
	}
	rects, result := rect_set_union(a.rects, b.rects, extent)
	if result == .Exact {return {kind = kind, rects = rects}}
	if result == .Empty {return {}}
	return damage_record_full(extent, kind, .Capacity_Exceeded)
}
