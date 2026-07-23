// SPDX-License-Identifier: GPL-3.0-only
package presentation

MAX_RECTS :: 256
MAX_PRESENT_INTERVAL :: u32(4)
PIXEL_FORMAT_MASK_ALL :: u32(0xFE)
PRESENT_INTERVAL_MASK_ALL :: u32(0x1F)
GENERATION_HALF_RANGE :: u64(1) << 63
NO_RECT_INDEX :: ~u32(0)

Rect :: struct {
	x, y:          u32,
	width, height: u32,
}

Extent :: struct {
	width, height: u32,
}

Rect_Set :: struct {
	count: u32,
	rects: [MAX_RECTS]Rect,
}

Source_Kind :: enum u8 {
	Invalid,
	Legacy_Snapshot,
	Gsw_Snapshot,
	Gsw_Resident,
}

Identity_Namespace :: enum u8 {
	Invalid,
	Gsw2d,
	Gsw3d,
}

Display_Owner :: enum u8 {
	None,
	Legacy,
	Gsw2d,
	Gsw3d,
}

Ownership :: enum u8 {
	Invalid,
	Mailbox_Descriptor,
	Vm_Framebuffer,
	Mailbox_Surface,
	Host_Resident,
}

Pixel_Format :: enum u8 {
	Invalid,
	Indexed_8,
	Rgb_555,
	Rgb_565,
	Bgr_888,
	Bgrx_8888,
	Bgra_8888,
	Rgba_8888,
}

Clip_Mode :: enum u8 {
	Invalid,
	Fullscreen,
	Windowed,
}

Surface_Identity :: struct {
	id:         u64,
	generation: u64, // Advances when an allocation is created, replaced, or destroyed.
}

Completion :: struct {
	value:      u64,
	generation: u64,
}

Completion_Identity :: Completion

Header :: struct {
	sequence:             u64,
	lifecycle_generation: u64,
	mode_generation:      u64, // Advances only when display ownership or geometry changes.
	mode_key:             Mode_Key,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	format:               Pixel_Format,
	surface_extent:       Extent,
	canvas_extent:        Extent,
	source:               Rect,
	destination:          Rect,
	dirty:                Rect_Set,
	interval:             u32,
	completion:           Completion_Identity,
	source_kind:          Source_Kind,
	ownership:            Ownership,
}

Legacy_Frame_Update :: struct {
	header:      Header,
	damage_kind: Damage_Kind,
	full_reason: Damage_Full_Reason,
}

Gsw_Present :: struct {
	header:        Header,
	clip_mode:     Clip_Mode,
	clips:         Rect_Set,
	source_offset: u64,
	source_pitch:  u32,
}

Invalidation_Reason :: enum u8 {
	Invalid,
	Surface_Destroyed,
	Device_Reset,
	Process_Exit,
	Mode_Changed,
}

Gsw_Invalidation :: struct {
	lifecycle_generation: u64,
	mode_generation:      u64,
	mode_key:             Mode_Key,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	reason:               Invalidation_Reason,
}

Validation_Context :: struct {
	lifecycle_generation: u64,
	mode_generation:      u64,
	mode_key:             Mode_Key,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	format_mask:          u32,
	interval_mask:        u32,
	source_byte_capacity: u64,
}

Diagnostic_Code :: enum u16 {
	Valid,
	Missing_Sequence,
	Missing_Lifecycle_Generation,
	Missing_Current_Lifecycle_Generation,
	Stale_Lifecycle_Generation,
	Missing_Mode_Generation,
	Missing_Current_Mode_Generation,
	Stale_Mode_Generation,
	Stale_Mode_Key,
	Header_Mode_Key_Mismatch,
	Missing_Identity_Namespace,
	Missing_Current_Identity_Namespace,
	Stale_Identity_Namespace,
	Unexpected_Identity_Namespace,
	Missing_Device_Generation,
	Missing_Current_Device_Generation,
	Stale_Device_Generation,
	Unexpected_Device_Generation,
	Missing_Surface_Identity,
	Missing_Current_Surface_Identity,
	Stale_Surface_Identity,
	Unsupported_Format,
	Zero_Surface_Extent,
	Zero_Canvas_Extent,
	Zero_Source_Rect,
	Source_Rect_Overflow,
	Source_Rect_Out_Of_Bounds,
	Zero_Destination_Rect,
	Destination_Rect_Overflow,
	Destination_Rect_Out_Of_Bounds,
	Missing_Dirty_Rects,
	Dirty_Count_Overflow,
	Dirty_Rect_Zero,
	Dirty_Rect_Overflow,
	Dirty_Rect_Out_Of_Bounds,
	Dirty_Rect_Duplicate,
	Dirty_Rect_Unsorted,
	Dirty_Rect_Overlap,
	Dirty_Rect_Mergeable,
	Dirty_Unused_Tail_Nonzero,
	Clip_Count_Overflow,
	Clip_Rect_Zero,
	Clip_Rect_Overflow,
	Clip_Rect_Out_Of_Bounds,
	Clip_Rect_Duplicate,
	Clip_Unused_Tail_Nonzero,
	Invalid_Clip_Mode,
	Fullscreen_Clips_Not_Empty,
	Fullscreen_Destination_Not_Canvas,
	Unsupported_Interval,
	Invalid_Source_Ownership,
	Invalid_Display_Owner,
	Invalid_Completion,
	Completion_Generation_Mismatch,
	Missing_Source_Capacity,
	Invalid_Source_Pitch,
	Source_Layout_Overflow,
	Source_Layout_Out_Of_Bounds,
	Unexpected_Source_Layout,
	Invalid_Invalidation,
	Invalid_Damage_Kind,
	Invalid_Damage_Full_Reason,
	Palette_Damage_Not_Full,
}

Diagnostic :: struct {
	code:  Diagnostic_Code,
	index: u32,
}

Generation_Order :: enum u8 {
	Invalid,
	Same,
	Older,
	Newer,
	Ambiguous,
}

Mode_Key :: struct {
	format:         Pixel_Format,
	surface_extent: Extent,
	canvas_extent:  Extent,
	source:         Rect,
	destination:    Rect,
}

Mode_Clock :: struct {
	initialized: bool,
	generation:  u64,
	owner:       Display_Owner,
	key:         Mode_Key,
}

Active_Kind :: enum u8 {
	None,
	Legacy,
	Gsw,
}

Active_Identity :: struct {
	kind:                 Active_Kind,
	display_owner:        Display_Owner,
	sequence:             u64,
	lifecycle_generation: u64,
	mode_generation:      u64,
	identity_namespace:   Identity_Namespace,
	device_generation:    u64,
	surface:              Surface_Identity,
	source_kind:          Source_Kind,
	ownership:            Ownership,
}

Selector :: struct {
	lifecycle_generation: u64,
	mode_generation:      u64,
	display_owner:        Display_Owner,
	mode_key:             Mode_Key,
	sequence:             u64,
	active:               Active_Identity,
	has_last_good_legacy: bool,
	last_good_legacy:     Legacy_Frame_Update,
	has_last_good_gsw:    bool,
	last_good_gsw:        Gsw_Present,
}

Selector_Action :: enum u8 {
	None,
	Present_Legacy,
	Present_Gsw,
	Refresh_Legacy,
	Refresh_Gsw,
	Drop_Stale,
	Reject_Invalid,
	Restore_Legacy,
	Restore_Gsw,
	Clear,
}

Selector_Result :: struct {
	action:     Selector_Action,
	active:     Active_Identity,
	diagnostic: Diagnostic,
}

diagnostic_valid :: proc(diagnostic: Diagnostic) -> bool {
	return diagnostic.code == .Valid
}

generation_next :: proc(generation: u64) -> u64 {
	next := generation + 1
	if next == 0 {return 1}
	return next
}

generation_order :: proc(candidate, reference: u64) -> Generation_Order {
	if candidate == 0 || reference == 0 {return .Invalid}
	delta := candidate - reference
	if delta == 0 {return .Same}
	if delta == GENERATION_HALF_RANGE {return .Ambiguous}
	if delta < GENERATION_HALF_RANGE {return .Newer}
	return .Older
}

generation_is_newer :: proc(candidate, reference: u64) -> bool {
	return generation_order(candidate, reference) == .Newer
}

pixel_format_mask :: proc(format: Pixel_Format) -> u32 {
	#partial switch format {
	case .Indexed_8, .Rgb_555, .Rgb_565, .Bgr_888, .Bgrx_8888, .Bgra_8888, .Rgba_8888:
		return u32(1) << u32(format)
	case:
		return 0
	}
}

@(private = "file")
identity_namespace_valid :: proc(namespace: Identity_Namespace) -> bool {
	#partial switch namespace {
	case .Gsw2d, .Gsw3d:
		return true
	case:
		return false
	}
}

display_owner_is_gsw :: proc(owner: Display_Owner) -> bool {
	return owner == .Gsw2d || owner == .Gsw3d
}

display_owner_from_header :: proc(header: Header) -> Display_Owner {
	#partial switch header.source_kind {
	case .Legacy_Snapshot:
		if header.identity_namespace == .Invalid {return .Legacy}
	case .Gsw_Snapshot:
		if header.identity_namespace == .Gsw2d {return .Gsw2d}
	case .Gsw_Resident:
		if header.identity_namespace == .Gsw3d {return .Gsw3d}
	case:
	}
	return .None
}

display_owner_from_namespace :: proc(namespace: Identity_Namespace) -> Display_Owner {
	#partial switch namespace {
	case .Gsw2d:
		return .Gsw2d
	case .Gsw3d:
		return .Gsw3d
	case:
		return .None
	}
}

pixel_format_bytes :: proc(format: Pixel_Format) -> (u32, bool) {
	#partial switch format {
	case .Indexed_8:
		return 1, true
	case .Rgb_555, .Rgb_565:
		return 2, true
	case .Bgr_888:
		return 3, true
	case .Bgrx_8888, .Bgra_8888, .Rgba_8888:
		return 4, true
	case:
		return 0, false
	}
}

presentation_interval_mask :: proc(interval: u32) -> u32 {
	if interval > MAX_PRESENT_INTERVAL {return 0}
	return u32(1) << interval
}

rect_equal :: proc(a, b: Rect) -> bool {
	return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
}

extent_equal :: proc(a, b: Extent) -> bool {
	return a.width == b.width && a.height == b.height
}

surface_identity_equal :: proc(a, b: Surface_Identity) -> bool {
	return a.id == b.id && a.generation == b.generation
}

completion_identity_equal :: proc(a, b: Completion_Identity) -> bool {
	return a.value == b.value && a.generation == b.generation
}

rect_set_append :: proc(set: ^Rect_Set, rect: Rect) -> bool {
	if set == nil || set.count >= MAX_RECTS {return false}
	set.rects[set.count] = rect
	set.count += 1
	return true
}

rect_set_equal :: proc(a, b: Rect_Set) -> bool {
	if a.count != b.count || a.count > MAX_RECTS {return false}
	for i in 0 ..< MAX_RECTS {
		if !rect_equal(a.rects[i], b.rects[i]) {return false}
	}
	return true
}

mode_key_equal :: proc(a, b: Mode_Key) -> bool {
	return(
		a.format == b.format &&
		extent_equal(a.surface_extent, b.surface_extent) &&
		extent_equal(a.canvas_extent, b.canvas_extent) &&
		rect_equal(a.source, b.source) &&
		rect_equal(a.destination, b.destination) \
	)
}

output_mode_key_from_key :: proc(mode_key: Mode_Key) -> Mode_Key {
	key := mode_key
	key.format = .Bgra_8888
	return key
}

output_mode_key :: proc(header: Header) -> Mode_Key {
	return output_mode_key_from_key(header.mode_key)
}

@(private = "file")
header_mode_key_matches :: proc(header: Header) -> bool {
	return mode_key_equal(
		header.mode_key,
		{
			format = header.format,
			surface_extent = header.surface_extent,
			canvas_extent = header.canvas_extent,
			source = header.source,
			destination = header.destination,
		},
	)
}

mode_clock_observe :: proc(
	clock: ^Mode_Clock,
	owner: Display_Owner,
	key: Mode_Key,
) -> (
	u64,
	bool,
) {
	if clock == nil {return 0, false}
	if !clock.initialized {
		clock.initialized = true
		clock.generation = 1
		clock.owner = owner
		clock.key = key
		return clock.generation, true
	}
	if clock.owner == owner && mode_key_equal(clock.key, key) {
		return clock.generation, false
	}
	clock.generation = generation_next(clock.generation)
	clock.owner = owner
	clock.key = key
	return clock.generation, true
}

@(private = "file")
diagnostic_make :: proc(code: Diagnostic_Code, index: u32 = NO_RECT_INDEX) -> Diagnostic {
	return {code = code, index = index}
}

@(private = "file")
extent_valid :: proc(extent: Extent) -> bool {
	return extent.width != 0 && extent.height != 0
}

@(private = "file")
rect_zero :: proc(rect: Rect) -> bool {
	return rect.width == 0 || rect.height == 0
}

@(private = "file")
rect_overflows :: proc(rect: Rect) -> bool {
	return rect.x > ~u32(0) - rect.width || rect.y > ~u32(0) - rect.height
}

@(private = "file")
rect_fits :: proc(rect: Rect, extent: Extent) -> bool {
	if rect_zero(rect) || rect_overflows(rect) {return false}
	return rect.x + rect.width <= extent.width && rect.y + rect.height <= extent.height
}

@(private = "file")
validate_rect :: proc(
	rect: Rect,
	extent: Extent,
	zero_code, overflow_code, bounds_code: Diagnostic_Code,
	index: u32 = NO_RECT_INDEX,
) -> Diagnostic {
	if rect_zero(rect) {return diagnostic_make(zero_code, index)}
	if rect_overflows(rect) {return diagnostic_make(overflow_code, index)}
	if !rect_fits(rect, extent) {return diagnostic_make(bounds_code, index)}
	return diagnostic_make(.Valid)
}

@(private = "file")
validate_rect_set :: proc(
	set: Rect_Set,
	extent: Extent,
	allow_empty: bool,
	count_code,
	zero_code,
	overflow_code,
	bounds_code,
	duplicate_code,
	unused_code: Diagnostic_Code,
) -> Diagnostic {
	if set.count > MAX_RECTS {return diagnostic_make(count_code)}
	if !allow_empty && set.count == 0 {return diagnostic_make(.Missing_Dirty_Rects)}
	for i in 0 ..< int(set.count) {
		diagnostic := validate_rect(
			set.rects[i],
			extent,
			zero_code,
			overflow_code,
			bounds_code,
			u32(i),
		)
		if !diagnostic_valid(diagnostic) {return diagnostic}
		for j in 0 ..< i {
			if rect_equal(set.rects[i], set.rects[j]) {
				return diagnostic_make(duplicate_code, u32(i))
			}
		}
	}
	for i in int(set.count) ..< MAX_RECTS {
		if !rect_equal(set.rects[i], {}) {return diagnostic_make(unused_code, u32(i))}
	}
	return diagnostic_make(.Valid)
}

@(private = "file")
dirty_rect_sort_less :: proc(a, b: Rect) -> bool {
	if a.y != b.y {return a.y < b.y}
	if a.x != b.x {return a.x < b.x}
	if a.height != b.height {return a.height < b.height}
	return a.width < b.width
}

@(private = "file")
dirty_rects_overlap :: proc(a, b: Rect) -> bool {
	return(
		a.x < b.x + b.width &&
		b.x < a.x + a.width &&
		a.y < b.y + b.height &&
		b.y < a.y + a.height \
	)
}

@(private = "file")
dirty_rects_mergeable :: proc(a, b: Rect) -> bool {
	if a.y == b.y && a.height == b.height {
		return a.x + a.width == b.x || b.x + b.width == a.x
	}
	if a.x == b.x && a.width == b.width {
		return a.y + a.height == b.y || b.y + b.height == a.y
	}
	return false
}

@(private = "file")
validate_dirty_rect_set :: proc(set: Rect_Set, extent: Extent) -> Diagnostic {
	diagnostic := validate_rect_set(
		set,
		extent,
		false,
		.Dirty_Count_Overflow,
		.Dirty_Rect_Zero,
		.Dirty_Rect_Overflow,
		.Dirty_Rect_Out_Of_Bounds,
		.Dirty_Rect_Duplicate,
		.Dirty_Unused_Tail_Nonzero,
	)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	for i in 0 ..< int(set.count) {
		if i > 0 && dirty_rect_sort_less(set.rects[i], set.rects[i - 1]) {
			return diagnostic_make(.Dirty_Rect_Unsorted, u32(i))
		}
		for j in 0 ..< i {
			if dirty_rects_overlap(set.rects[i], set.rects[j]) {
				return diagnostic_make(.Dirty_Rect_Overlap, u32(i))
			}
			if dirty_rects_mergeable(set.rects[i], set.rects[j]) {
				return diagnostic_make(.Dirty_Rect_Mergeable, u32(i))
			}
		}
	}
	return diagnostic_make(.Valid)
}

@(private = "file")
source_ownership_valid :: proc(source_kind: Source_Kind, ownership: Ownership) -> bool {
	#partial switch source_kind {
	case .Legacy_Snapshot:
		return ownership == .Mailbox_Descriptor
	case .Gsw_Snapshot:
		return ownership == .Vm_Framebuffer || ownership == .Mailbox_Surface
	case .Gsw_Resident:
		return ownership == .Host_Resident
	case:
		return false
	}
}

@(private = "file")
validate_common :: proc(header: Header, current: Validation_Context, gsw: bool) -> Diagnostic {
	if header.sequence == 0 {return diagnostic_make(.Missing_Sequence)}
	if header.lifecycle_generation == 0 {return diagnostic_make(.Missing_Lifecycle_Generation)}
	if current.lifecycle_generation ==
	   0 {return diagnostic_make(.Missing_Current_Lifecycle_Generation)}
	if header.lifecycle_generation != current.lifecycle_generation {
		return diagnostic_make(.Stale_Lifecycle_Generation)
	}
	if header.mode_generation == 0 {return diagnostic_make(.Missing_Mode_Generation)}
	if current.mode_generation == 0 {return diagnostic_make(.Missing_Current_Mode_Generation)}
	if header.mode_generation !=
	   current.mode_generation {return diagnostic_make(.Stale_Mode_Generation)}
	if !mode_key_equal(header.mode_key, current.mode_key) {return diagnostic_make(.Stale_Mode_Key)}
	if !header_mode_key_matches(header) {return diagnostic_make(.Header_Mode_Key_Mismatch)}
	if header.surface.id == 0 || header.surface.generation == 0 {
		return diagnostic_make(.Missing_Surface_Identity)
	}
	if current.surface.id == 0 || current.surface.generation == 0 {
		return diagnostic_make(.Missing_Current_Surface_Identity)
	}
	if !surface_identity_equal(header.surface, current.surface) {
		return diagnostic_make(.Stale_Surface_Identity)
	}
	if !source_ownership_valid(header.source_kind, header.ownership) {
		return diagnostic_make(.Invalid_Source_Ownership)
	}
	if gsw {
		if header.source_kind != .Gsw_Snapshot && header.source_kind != .Gsw_Resident {
			return diagnostic_make(.Invalid_Source_Ownership)
		}
		if header.identity_namespace == .Invalid {
			return diagnostic_make(.Missing_Identity_Namespace)
		}
		if !identity_namespace_valid(header.identity_namespace) {
			return diagnostic_make(.Unexpected_Identity_Namespace)
		}
		if current.identity_namespace == .Invalid {
			return diagnostic_make(.Missing_Current_Identity_Namespace)
		}
		if !identity_namespace_valid(current.identity_namespace) {
			return diagnostic_make(.Unexpected_Identity_Namespace)
		}
		if header.identity_namespace != current.identity_namespace {
			return diagnostic_make(.Stale_Identity_Namespace)
		}
		if header.device_generation == 0 {return diagnostic_make(.Missing_Device_Generation)}
		if current.device_generation ==
		   0 {return diagnostic_make(.Missing_Current_Device_Generation)}
		if header.device_generation != current.device_generation {
			return diagnostic_make(.Stale_Device_Generation)
		}
	} else {
		if header.source_kind !=
		   .Legacy_Snapshot {return diagnostic_make(.Invalid_Source_Ownership)}
		if header.identity_namespace != .Invalid {
			return diagnostic_make(.Unexpected_Identity_Namespace)
		}
		if header.device_generation != 0 {return diagnostic_make(.Unexpected_Device_Generation)}
	}
	if display_owner_from_header(header) == .None {
		return diagnostic_make(.Invalid_Display_Owner)
	}
	format_mask := pixel_format_mask(header.format)
	if format_mask == 0 || current.format_mask & format_mask == 0 {
		return diagnostic_make(.Unsupported_Format)
	}
	if !extent_valid(header.surface_extent) {return diagnostic_make(.Zero_Surface_Extent)}
	if !extent_valid(header.canvas_extent) {return diagnostic_make(.Zero_Canvas_Extent)}
	diagnostic := validate_rect(
		header.source,
		header.surface_extent,
		.Zero_Source_Rect,
		.Source_Rect_Overflow,
		.Source_Rect_Out_Of_Bounds,
	)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	diagnostic = validate_rect(
		header.destination,
		header.canvas_extent,
		.Zero_Destination_Rect,
		.Destination_Rect_Overflow,
		.Destination_Rect_Out_Of_Bounds,
	)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	diagnostic = validate_dirty_rect_set(header.dirty, header.surface_extent)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	interval_mask := presentation_interval_mask(header.interval)
	if interval_mask == 0 || current.interval_mask & interval_mask == 0 {
		return diagnostic_make(.Unsupported_Interval)
	}
	has_completion := header.completion.value != 0
	has_completion_generation := header.completion.generation != 0
	if has_completion != has_completion_generation {return diagnostic_make(.Invalid_Completion)}
	if !gsw && has_completion {return diagnostic_make(.Invalid_Completion)}
	if gsw && has_completion && header.completion.generation != header.device_generation {
		return diagnostic_make(.Completion_Generation_Mismatch)
	}
	return diagnostic_make(.Valid)
}

validate_legacy :: proc(update: Legacy_Frame_Update, current: Validation_Context) -> Diagnostic {
	diagnostic := validate_common(update.header, current, false)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	#partial switch update.damage_kind {
	case .Pixel_Memory, .Palette_Only, .Pixel_And_Palette:
	case:
		return diagnostic_make(.Invalid_Damage_Kind)
	}
	#partial switch update.full_reason {
	case .None,
	     .Initial_Surface,
	     .Mode_Boundary,
	     .Ambiguous_Mapping,
	     .Capacity_Exceeded,
	     .External_Tracking:
	case:
		return diagnostic_make(.Invalid_Damage_Full_Reason)
	}
	if update.full_reason != .None &&
	   (update.header.dirty.count != 1 ||
			   !rect_equal(update.header.dirty.rects[0], update.header.source)) {
		return diagnostic_make(.Invalid_Damage_Full_Reason)
	}
	if damage_kind_has_palette(update.damage_kind) &&
	   (update.header.dirty.count != 1 ||
			   !rect_equal(update.header.dirty.rects[0], update.header.source)) {
		return diagnostic_make(.Palette_Damage_Not_Full)
	}
	return diagnostic_make(.Valid)
}

@(private = "file")
checked_add :: proc(a, b: u64) -> (u64, bool) {
	if a > ~u64(0) - b {return 0, false}
	return a + b, true
}

@(private = "file")
checked_mul :: proc(a, b: u64) -> (u64, bool) {
	if a != 0 && b > ~u64(0) / a {return 0, false}
	return a * b, true
}

@(private = "file")
validate_snapshot_layout :: proc(present: Gsw_Present, current: Validation_Context) -> Diagnostic {
	if current.source_byte_capacity == 0 {return diagnostic_make(.Missing_Source_Capacity)}
	bytes_per_pixel, known := pixel_format_bytes(present.header.format)
	if !known {return diagnostic_make(.Unsupported_Format)}
	minimum_pitch, pitch_ok := checked_mul(
		u64(present.header.surface_extent.width),
		u64(bytes_per_pixel),
	)
	if !pitch_ok || minimum_pitch > u64(~u32(0)) || u64(present.source_pitch) < minimum_pitch {
		return diagnostic_make(.Invalid_Source_Pitch)
	}
	y_offset, y_ok := checked_mul(u64(present.header.source.y), u64(present.source_pitch))
	if !y_ok {return diagnostic_make(.Source_Layout_Overflow)}
	x_offset, x_ok := checked_mul(u64(present.header.source.x), u64(bytes_per_pixel))
	if !x_ok {return diagnostic_make(.Source_Layout_Overflow)}
	start, start_ok := checked_add(present.source_offset, y_offset)
	if !start_ok {return diagnostic_make(.Source_Layout_Overflow)}
	start, start_ok = checked_add(start, x_offset)
	if !start_ok {return diagnostic_make(.Source_Layout_Overflow)}
	row_advance, advance_ok := checked_mul(
		u64(present.header.source.height - 1),
		u64(present.source_pitch),
	)
	if !advance_ok {return diagnostic_make(.Source_Layout_Overflow)}
	row_bytes, row_ok := checked_mul(u64(present.header.source.width), u64(bytes_per_pixel))
	if !row_ok {return diagnostic_make(.Source_Layout_Overflow)}
	end, end_ok := checked_add(start, row_advance)
	if !end_ok {return diagnostic_make(.Source_Layout_Overflow)}
	end, end_ok = checked_add(end, row_bytes)
	if !end_ok {return diagnostic_make(.Source_Layout_Overflow)}
	if end > current.source_byte_capacity {return diagnostic_make(.Source_Layout_Out_Of_Bounds)}
	return diagnostic_make(.Valid)
}

validate_gsw :: proc(present: Gsw_Present, current: Validation_Context) -> Diagnostic {
	diagnostic := validate_common(present.header, current, true)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	#partial switch present.clip_mode {
	case .Fullscreen:
		if present.clips.count != 0 {return diagnostic_make(.Fullscreen_Clips_Not_Empty)}
		if !rect_equal(
			present.header.destination,
			{
				width = present.header.canvas_extent.width,
				height = present.header.canvas_extent.height,
			},
		) {return diagnostic_make(.Fullscreen_Destination_Not_Canvas)}
	case .Windowed:
	case:
		return diagnostic_make(.Invalid_Clip_Mode)
	}
	diagnostic = validate_rect_set(
		present.clips,
		present.header.canvas_extent,
		true,
		.Clip_Count_Overflow,
		.Clip_Rect_Zero,
		.Clip_Rect_Overflow,
		.Clip_Rect_Out_Of_Bounds,
		.Clip_Rect_Duplicate,
		.Clip_Unused_Tail_Nonzero,
	)
	if !diagnostic_valid(diagnostic) {return diagnostic}
	if present.header.source_kind == .Gsw_Snapshot {
		return validate_snapshot_layout(present, current)
	}
	if present.source_offset != 0 || present.source_pitch != 0 {
		return diagnostic_make(.Unexpected_Source_Layout)
	}
	return diagnostic_make(.Valid)
}

validate_gsw_invalidation :: proc(
	invalidation: Gsw_Invalidation,
	current: Validation_Context,
) -> Diagnostic {
	if invalidation.lifecycle_generation == 0 || current.lifecycle_generation == 0 {
		return diagnostic_make(.Missing_Lifecycle_Generation)
	}
	if invalidation.lifecycle_generation != current.lifecycle_generation {
		return diagnostic_make(.Stale_Lifecycle_Generation)
	}
	if invalidation.mode_generation == 0 || current.mode_generation == 0 {
		return diagnostic_make(.Missing_Mode_Generation)
	}
	if invalidation.mode_generation != current.mode_generation {
		return diagnostic_make(.Stale_Mode_Generation)
	}
	if !mode_key_equal(invalidation.mode_key, current.mode_key) {
		return diagnostic_make(.Stale_Mode_Key)
	}
	if invalidation.identity_namespace == .Invalid {
		return diagnostic_make(.Missing_Identity_Namespace)
	}
	if !identity_namespace_valid(invalidation.identity_namespace) {
		return diagnostic_make(.Unexpected_Identity_Namespace)
	}
	if current.identity_namespace == .Invalid {
		return diagnostic_make(.Missing_Current_Identity_Namespace)
	}
	if !identity_namespace_valid(current.identity_namespace) {
		return diagnostic_make(.Unexpected_Identity_Namespace)
	}
	if invalidation.identity_namespace != current.identity_namespace {
		return diagnostic_make(.Stale_Identity_Namespace)
	}
	if invalidation.device_generation == 0 || current.device_generation == 0 {
		return diagnostic_make(.Missing_Device_Generation)
	}
	if invalidation.device_generation != current.device_generation {
		return diagnostic_make(.Stale_Device_Generation)
	}
	if invalidation.surface.id == 0 || invalidation.surface.generation == 0 {
		return diagnostic_make(.Missing_Surface_Identity)
	}
	if !surface_identity_equal(invalidation.surface, current.surface) {
		return diagnostic_make(.Stale_Surface_Identity)
	}
	#partial switch invalidation.reason {
	case .Surface_Destroyed, .Device_Reset, .Process_Exit, .Mode_Changed:
		return diagnostic_make(.Valid)
	case:
		return diagnostic_make(.Invalid_Invalidation)
	}
}

header_equal :: proc(a, b: Header) -> bool {
	return(
		a.sequence == b.sequence &&
		a.lifecycle_generation == b.lifecycle_generation &&
		a.mode_generation == b.mode_generation &&
		mode_key_equal(a.mode_key, b.mode_key) &&
		a.identity_namespace == b.identity_namespace &&
		a.device_generation == b.device_generation &&
		surface_identity_equal(a.surface, b.surface) &&
		a.format == b.format &&
		extent_equal(a.surface_extent, b.surface_extent) &&
		extent_equal(a.canvas_extent, b.canvas_extent) &&
		rect_equal(a.source, b.source) &&
		rect_equal(a.destination, b.destination) &&
		rect_set_equal(a.dirty, b.dirty) &&
		a.interval == b.interval &&
		completion_identity_equal(a.completion, b.completion) &&
		a.source_kind == b.source_kind &&
		a.ownership == b.ownership \
	)
}

legacy_frame_update_equal :: proc(a, b: Legacy_Frame_Update) -> bool {
	return(
		header_equal(a.header, b.header) &&
		a.damage_kind == b.damage_kind &&
		a.full_reason == b.full_reason \
	)
}

gsw_present_equal :: proc(a, b: Gsw_Present) -> bool {
	return(
		header_equal(a.header, b.header) &&
		a.clip_mode == b.clip_mode &&
		rect_set_equal(a.clips, b.clips) &&
		a.source_offset == b.source_offset &&
		a.source_pitch == b.source_pitch \
	)
}

@(private = "file")
active_from_header :: proc(header: Header, kind: Active_Kind) -> Active_Identity {
	return {
		kind = kind,
		display_owner = display_owner_from_header(header),
		sequence = header.sequence,
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		source_kind = header.source_kind,
		ownership = header.ownership,
	}
}

@(private = "file")
selector_result :: proc(
	selector: ^Selector,
	action: Selector_Action,
	diagnostic: Diagnostic = {},
) -> Selector_Result {
	active: Active_Identity
	if selector != nil {active = selector.active}
	return {action = action, active = active, diagnostic = diagnostic}
}

diagnostic_stale :: proc(diagnostic: Diagnostic) -> bool {
	#partial switch diagnostic.code {
	case .Stale_Lifecycle_Generation,
	     .Stale_Mode_Generation,
	     .Stale_Mode_Key,
	     .Stale_Identity_Namespace,
	     .Stale_Device_Generation,
	     .Stale_Surface_Identity:
		return true
	case:
		return false
	}
}

@(private = "file")
selector_reject :: proc(selector: ^Selector, diagnostic: Diagnostic) -> Selector_Result {
	action := Selector_Action.Reject_Invalid
	if diagnostic_stale(diagnostic) {action = .Drop_Stale}
	return selector_result(selector, action, diagnostic)
}

legacy_surface_transition_valid :: proc(previous, update: Legacy_Frame_Update) -> bool {
	previous_surface := previous.header.surface
	current_surface := update.header.surface
	if previous_surface.id == 0 ||
	   previous_surface.generation == 0 ||
	   current_surface.id == 0 ||
	   current_surface.generation == 0 {return false}
	geometry_equal := mode_key_equal(
		output_mode_key(previous.header),
		output_mode_key(update.header),
	)
	if current_surface.generation == previous_surface.generation {
		return current_surface.id == previous_surface.id && geometry_equal
	}
	return generation_order(current_surface.generation, previous_surface.generation) == .Newer
}

gsw_snapshot_surface_transition_valid :: proc(previous, update: Gsw_Present) -> bool {
	if previous.header.source_kind != .Gsw_Snapshot || update.header.source_kind != .Gsw_Snapshot {
		return false
	}
	previous_surface := previous.header.surface
	current_surface := update.header.surface
	if previous_surface.id == 0 ||
	   previous_surface.generation == 0 ||
	   current_surface.id == 0 ||
	   current_surface.generation == 0 {return false}
	geometry_equal := mode_key_equal(previous.header.mode_key, update.header.mode_key)
	identity_equal :=
		previous.header.lifecycle_generation == update.header.lifecycle_generation &&
		previous.header.identity_namespace == update.header.identity_namespace &&
		previous.header.device_generation == update.header.device_generation &&
		previous.header.format == update.header.format
	if current_surface.generation == previous_surface.generation {
		return current_surface.id == previous_surface.id && identity_equal && geometry_equal
	}
	return(
		identity_equal &&
		generation_order(current_surface.generation, previous_surface.generation) == .Newer \
	)
}

selector_submit_legacy :: proc(
	selector: ^Selector,
	update: Legacy_Frame_Update,
	current: Validation_Context,
	preserve_active_gsw: bool = false,
) -> Selector_Result {
	if selector == nil {return selector_result(nil, .Reject_Invalid)}
	diagnostic := validate_legacy(update, current)
	if !diagnostic_valid(diagnostic) {return selector_reject(selector, diagnostic)}
	header := update.header
	owner := Display_Owner.Legacy
	mode_key := output_mode_key(header)
	next := selector^
	fresh := next.lifecycle_generation == 0
	if next.lifecycle_generation == 0 {
		next.lifecycle_generation = header.lifecycle_generation
		next.mode_generation = header.mode_generation
		next.display_owner = owner
		next.mode_key = mode_key
	} else if next.lifecycle_generation != header.lifecycle_generation {
		return selector_result(selector, .Drop_Stale, diagnostic_make(.Stale_Lifecycle_Generation))
	}
	if next.sequence != 0 && generation_order(header.sequence, next.sequence) != .Newer {
		return selector_result(selector, .Drop_Stale)
	}
	if next.has_last_good_legacy &&
	   next.last_good_legacy.header.lifecycle_generation == header.lifecycle_generation &&
	   !legacy_surface_transition_valid(next.last_good_legacy, update) {
		return selector_result(selector, .Drop_Stale, diagnostic_make(.Stale_Surface_Identity))
	}
	if next.active.kind == .Gsw &&
	   header.mode_generation == next.mode_generation &&
	   (preserve_active_gsw || mode_key_equal(mode_key, next.mode_key)) {
		next.sequence = header.sequence
		next.last_good_legacy = update
		next.has_last_good_legacy = true
		selector^ = next
		return selector_result(selector, .Refresh_Legacy)
	}
	if !fresh {
		if next.mode_generation == 0 {
			next.mode_generation = header.mode_generation
			next.display_owner = owner
			next.mode_key = mode_key
		} else {
			identity_changed :=
				next.display_owner != owner || !mode_key_equal(next.mode_key, mode_key)
			if header.mode_generation == next.mode_generation {
				if identity_changed {
					return selector_result(
						selector,
						.Drop_Stale,
						diagnostic_make(.Stale_Mode_Generation),
					)
				}
			} else if !identity_changed ||
			   generation_order(header.mode_generation, next.mode_generation) != .Newer {
				return selector_result(
					selector,
					.Drop_Stale,
					diagnostic_make(.Stale_Mode_Generation),
				)
			} else {
				next.mode_generation = header.mode_generation
				next.display_owner = owner
				next.mode_key = mode_key
				next.active = {}
				next.has_last_good_legacy = false
				next.last_good_legacy = {}
				next.has_last_good_gsw = false
				next.last_good_gsw = {}
			}
		}
	}
	next.sequence = header.sequence
	next.last_good_legacy = update
	next.has_last_good_legacy = true
	next.display_owner = owner
	next.mode_key = mode_key
	next.active = active_from_header(header, .Legacy)
	selector^ = next
	return selector_result(selector, .Present_Legacy)
}

selector_submit_gsw :: proc(
	selector: ^Selector,
	present: Gsw_Present,
	current: Validation_Context,
	preserve_active_resident: bool = false,
) -> Selector_Result {
	if selector == nil {return selector_result(nil, .Reject_Invalid)}
	diagnostic := validate_gsw(present, current)
	if !diagnostic_valid(diagnostic) {return selector_reject(selector, diagnostic)}
	header := present.header
	owner := display_owner_from_header(header)
	mode_key := output_mode_key(header)
	next := selector^
	fresh := next.lifecycle_generation == 0
	if next.lifecycle_generation == 0 {
		next.lifecycle_generation = header.lifecycle_generation
		next.mode_generation = header.mode_generation
		next.display_owner = owner
		next.mode_key = mode_key
	} else if next.lifecycle_generation != header.lifecycle_generation {
		return selector_result(selector, .Drop_Stale, diagnostic_make(.Stale_Lifecycle_Generation))
	}
	if next.sequence != 0 && generation_order(header.sequence, next.sequence) != .Newer {
		return selector_result(selector, .Drop_Stale)
	}
	if preserve_active_resident &&
	   owner == .Gsw2d &&
	   next.active.kind == .Gsw &&
	   next.active.source_kind == .Gsw_Resident &&
	   next.active.identity_namespace == .Gsw3d &&
	   mode_key_equal(mode_key, next.mode_key) {
		if next.has_last_good_gsw &&
		   !gsw_snapshot_surface_transition_valid(next.last_good_gsw, present) {
			return selector_result(selector, .Drop_Stale, diagnostic_make(.Stale_Surface_Identity))
		}
		next.sequence = header.sequence
		next.last_good_gsw = present
		next.has_last_good_gsw = true
		selector^ = next
		return selector_result(selector, .Refresh_Gsw)
	}
	if !fresh {
		if next.mode_generation == 0 {
			next.mode_generation = header.mode_generation
			next.display_owner = owner
			next.mode_key = mode_key
		} else {
			identity_changed :=
				next.display_owner != owner || !mode_key_equal(next.mode_key, mode_key)
			if header.mode_generation == next.mode_generation {
				if identity_changed {
					return selector_result(
						selector,
						.Drop_Stale,
						diagnostic_make(.Stale_Mode_Generation),
					)
				}
			} else if !identity_changed ||
			   generation_order(header.mode_generation, next.mode_generation) != .Newer {
				return selector_result(
					selector,
					.Drop_Stale,
					diagnostic_make(.Stale_Mode_Generation),
				)
			} else {
				next.mode_generation = header.mode_generation
				next.display_owner = owner
				next.mode_key = mode_key
				next.active = {}
			}
		}
	}
	next.sequence = header.sequence
	next.display_owner = owner
	next.mode_key = mode_key
	next.active = active_from_header(header, .Gsw)
	if owner == .Gsw2d {
		next.last_good_gsw = present
		next.has_last_good_gsw = true
	}
	selector^ = next
	return selector_result(selector, .Present_Gsw)
}

selector_invalidate_gsw :: proc(
	selector: ^Selector,
	invalidation: Gsw_Invalidation,
	current: Validation_Context,
) -> Selector_Result {
	if selector == nil {return selector_result(nil, .Reject_Invalid)}
	diagnostic := validate_gsw_invalidation(invalidation, current)
	if !diagnostic_valid(diagnostic) {return selector_reject(selector, diagnostic)}
	active := selector.active
	owner := display_owner_from_namespace(invalidation.identity_namespace)
	if active.kind != .Gsw ||
	   selector.display_owner != owner ||
	   !mode_key_equal(selector.mode_key, output_mode_key_from_key(invalidation.mode_key)) ||
	   active.lifecycle_generation != invalidation.lifecycle_generation ||
	   active.mode_generation != invalidation.mode_generation ||
	   active.identity_namespace != invalidation.identity_namespace ||
	   active.device_generation != invalidation.device_generation ||
	   !surface_identity_equal(active.surface, invalidation.surface) {
		return selector_result(selector, .Drop_Stale)
	}
	next := selector^
	if next.sequence == 0 {next.sequence = active.sequence}
	next.sequence = generation_next(next.sequence)
	next.mode_generation = generation_next(next.mode_generation)
	legacy_valid :=
		next.has_last_good_legacy &&
		next.last_good_legacy.header.lifecycle_generation == next.lifecycle_generation
	gsw_valid :=
		next.has_last_good_gsw &&
		next.last_good_gsw.header.lifecycle_generation == next.lifecycle_generation &&
		next.last_good_gsw.header.source_kind == .Gsw_Snapshot
	restore_gsw :=
		gsw_valid &&
		(!legacy_valid ||
				generation_order(
					next.last_good_gsw.header.sequence,
					next.last_good_legacy.header.sequence,
				) ==
					.Newer)
	if restore_gsw {
		restored := next.last_good_gsw
		restored.header.sequence = next.sequence
		restored.header.mode_generation = next.mode_generation
		next.last_good_gsw = restored
		next.display_owner = .Gsw2d
		next.mode_key = output_mode_key(restored.header)
		next.active = active_from_header(restored.header, .Gsw)
		selector^ = next
		return selector_result(selector, .Restore_Gsw)
	}
	if legacy_valid {
		restored := next.last_good_legacy
		restored.header.sequence = next.sequence
		restored.header.mode_generation = next.mode_generation
		next.last_good_legacy = restored
		next.display_owner = .Legacy
		next.mode_key = output_mode_key(restored.header)
		next.active = active_from_header(restored.header, .Legacy)
		selector^ = next
		return selector_result(selector, .Restore_Legacy)
	}
	next.display_owner = .None
	next.mode_key = {}
	next.active = {}
	selector^ = next
	return selector_result(selector, .Clear)
}

selector_lifecycle_change :: proc(selector: ^Selector, generation: u64) -> Selector_Result {
	if selector == nil || generation == 0 {return selector_result(selector, .Reject_Invalid)}
	if selector.lifecycle_generation != 0 {
		order := generation_order(generation, selector.lifecycle_generation)
		if order == .Same {return selector_result(selector, .None)}
		if order != .Newer {return selector_result(selector, .Drop_Stale)}
	}
	selector^ = {
		lifecycle_generation = generation,
	}
	return selector_result(selector, .Clear)
}

selector_clear :: proc(selector: ^Selector) -> Selector_Result {
	if selector == nil {return selector_result(nil, .Reject_Invalid)}
	selector^ = {}
	return selector_result(selector, .Clear)
}

selector_vm_stop :: proc(selector: ^Selector) -> Selector_Result {
	return selector_clear(selector)
}
