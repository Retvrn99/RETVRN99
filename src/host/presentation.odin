// SPDX-License-Identifier: GPL-3.0-only
package host

import contract "../presentation"
import vga "../vga"
import "core:c"
import sdl3 "vendor:sdl3"

Host_Presentation_Kind :: enum u8 {
	Invalid,
	Legacy,
	Gsw_Snapshot,
	Gsw_Resident,
}

Host_Presentation_Texture_Slot :: struct {
	texture:          ^sdl3.Texture,
	width:            int,
	height:           int,
	stage_generation: u64,
}

Host_Presentation_Staged_Texture :: struct {
	valid:                bool,
	kind:                 Host_Presentation_Kind,
	texture:              ^sdl3.Texture,
	width:                int,
	height:               int,
	stage_generation:     u64,
	lifecycle_generation: u64,
	admission_sequence:   u64,
	texture_recreated:    bool,
}

Host_Presentation_State :: struct {
	accepting:                  bool,
	lifecycle:                  u64,
	sequence:                   u64,
	last_vga_sequence:          u64,
	vga_mode_clock:             contract.Mode_Clock,
	mode_clock:                 contract.Mode_Clock,
	selector:                   contract.Selector,
	legacy:                     contract.Legacy_Frame_Update,
	gsw:                        contract.Gsw_Present,
	gsw_source_mode_generation: u64,
	texture_stage_generation:   u64,
	legacy_staging:             Host_Presentation_Texture_Slot,
	gsw_texture:                ^sdl3.Texture,
	gsw_texture_width:          int,
	gsw_texture_height:         int,
	gsw_staging:                Host_Presentation_Texture_Slot,
}

Host_Presentation_Admission :: struct {
	valid:                  bool,
	kind:                   Host_Presentation_Kind,
	selector:               contract.Selector,
	mode_clock:             contract.Mode_Clock,
	result:                 contract.Selector_Result,
	legacy:                 contract.Legacy_Frame_Update,
	gsw:                    contract.Gsw_Present,
	source_sequence:        u64,
	source_mode_generation: u64,
	source_byte_capacity:   u64,
	vga_mode_clock:         contract.Mode_Clock,
	vga_ordered:            bool,
}

Host_Presentation_Mode_Admission :: struct {
	valid:               bool,
	stale:               bool,
	preserve_active_gsw: bool,
	host_clock:          contract.Mode_Clock,
	vga_clock:           contract.Mode_Clock,
}

Host_Presentation_Admission_State :: enum u8 {
	Invalid,
	Current,
	Closed,
	Stale,
}

@(private = "package")
host_presentation_metric_add :: proc(target: ^u64, value: u64) {
	if target == nil {return}
	if value > max(u64) - target^ {target^ = max(u64)} else {target^ += value}
}

@(private = "file")
host_presentation_note_invalid :: proc(h: ^Host) {
	if h != nil {host_presentation_metric_add(&h.presentation_metrics.invalid_rejections, 1)}
}

@(private = "file")
host_presentation_note_closed :: proc(h: ^Host) {
	if h != nil {host_presentation_metric_add(&h.presentation_metrics.closed_rejections, 1)}
}

host_presentation_note_stale_finalization :: proc(h: ^Host) {
	if h == nil {return}
	host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
	host_presentation_metric_add(&h.presentation_metrics.stale_finalization_drops, 1)
}

host_presentation_record_descriptor_copy :: proc(h: ^Host, bytes: int) {
	if h != nil && bytes > 0 {
		host_presentation_metric_add(&h.presentation_metrics.copy_bytes, u64(bytes))
	}
}

host_presentation_record_conversion :: proc(h: ^Host, frame: ^vga.Display_Frame) {
	if h == nil || frame == nil || frame.width <= 0 || frame.height <= 0 {return}
	if frame.width > max(int) / frame.height {return}
	host_presentation_metric_add(
		&h.presentation_metrics.conversion_pixels,
		u64(frame.width * frame.height),
	)
}

host_presentation_record_upload :: proc(h: ^Host, width, height: int) {
	if h == nil || width <= 0 || height <= 0 || width > max(int) / height {return}
	pixels := u64(width * height)
	if pixels > max(u64) / size_of(u32) {return}
	host_presentation_metric_add(&h.presentation_metrics.upload_bytes, pixels * size_of(u32))
	host_presentation_metric_add(&h.presentation_metrics.upload_regions, 1)
}

host_presentation_start :: proc(h: ^Host, lifecycle: u64) -> bool {
	if h == nil || lifecycle == 0 {return false}
	state := &h.presentation_state
	if state.accepting && state.lifecycle == lifecycle {return true}
	texture := state.gsw_texture
	texture_width := state.gsw_texture_width
	texture_height := state.gsw_texture_height
	legacy_staging := state.legacy_staging
	gsw_staging := state.gsw_staging
	texture_stage_generation := state.texture_stage_generation
	state^ = {
		accepting                = true,
		lifecycle                = lifecycle,
		texture_stage_generation = texture_stage_generation,
		legacy_staging           = legacy_staging,
		gsw_texture              = texture,
		gsw_texture_width        = texture_width,
		gsw_texture_height       = texture_height,
		gsw_staging              = gsw_staging,
	}
	_ = contract.selector_lifecycle_change(&state.selector, lifecycle)
	h.gpu_present = {}
	h.has_frame = false
	return true
}

host_presentation_stop :: proc(h: ^Host) {
	if h == nil {return}
	state := &h.presentation_state
	_ = contract.selector_vm_stop(&state.selector)
	state.accepting = false
	state.legacy = {}
	state.gsw = {}
	state.gsw_source_mode_generation = 0
	state.vga_mode_clock = {}
	state.mode_clock = {}
	state.last_vga_sequence = 0
	h.gpu_present = {}
	h.has_frame = false
}

@(private = "file")
host_presentation_output_mode_key :: proc(header: contract.Header) -> contract.Mode_Key {
	return contract.output_mode_key(header)
}

@(private = "file")
host_presentation_vga_mode_admit :: proc(
	state: ^Host_Presentation_State,
	header: contract.Header,
	paired_invalidation: bool = false,
) -> Host_Presentation_Mode_Admission {
	if state == nil || header.mode_generation == 0 {return {}}
	owner := contract.display_owner_from_header(header)
	if owner != .Legacy && owner != .Gsw2d {return {}}
	output_key := host_presentation_output_mode_key(header)
	vga_clock := state.vga_mode_clock
	order := contract.Generation_Order.Invalid
	identity_changed := false
	if !vga_clock.initialized {
		vga_clock = {
			initialized = true,
			generation  = header.mode_generation,
			owner       = owner,
			key         = output_key,
		}
	} else {
		order = contract.generation_order(header.mode_generation, vga_clock.generation)
		identity_changed =
			vga_clock.owner != owner || !contract.mode_key_equal(vga_clock.key, output_key)
		switch order {
		case .Same:
			hidden_legacy :=
				state.selector.active.kind == .Gsw &&
				owner == .Legacy &&
				contract.display_owner_is_gsw(vga_clock.owner) &&
				state.legacy.header.lifecycle_generation == state.lifecycle &&
				contract.mode_key_equal(
					host_presentation_output_mode_key(state.legacy.header),
					output_key,
				)
			if identity_changed && !hidden_legacy {
				return {stale = true}
			}
		case .Newer:
			if !identity_changed {return {stale = true}}
			vga_clock = {
				initialized = true,
				generation  = header.mode_generation,
				owner       = owner,
				key         = output_key,
			}
		case .Invalid, .Older, .Ambiguous:
			return {stale = true}
		}
	}
	preserve_active_gsw :=
		state.selector.active.kind == .Gsw &&
		owner == .Legacy &&
		(!state.vga_mode_clock.initialized ||
				order == .Same ||
				(order == .Newer && paired_invalidation))
	host_clock := state.mode_clock
	if !preserve_active_gsw {
		_, _ = contract.mode_clock_observe(&host_clock, owner, output_key)
	}
	return {
		valid = true,
		preserve_active_gsw = preserve_active_gsw,
		host_clock = host_clock,
		vga_clock = vga_clock,
	}
}

@(private = "file")
host_presentation_local_mode_admit :: proc(
	state: ^Host_Presentation_State,
	header: contract.Header,
) -> Host_Presentation_Mode_Admission {
	if state == nil || header.mode_generation == 0 {return {}}
	owner := contract.display_owner_from_header(header)
	if owner != .Gsw3d {return {}}
	host_clock := state.mode_clock
	expected, _ := contract.mode_clock_observe(
		&host_clock,
		owner,
		host_presentation_output_mode_key(header),
	)
	if header.mode_generation != expected {return {stale = true}}
	return {valid = true, host_clock = host_clock}
}

@(private = "file")
host_presentation_vga_sequence_admit :: proc(
	state: ^Host_Presentation_State,
	sequence: u64,
) -> bool {
	if state == nil || sequence == 0 {return false}
	return(
		state.last_vga_sequence == 0 ||
		contract.generation_order(sequence, state.last_vga_sequence) == .Newer \
	)
}

@(private = "file")
host_presentation_validation_context :: proc(
	header: contract.Header,
	format_mask, interval_mask: u32,
	source_byte_capacity: u64,
) -> contract.Validation_Context {
	return {
		lifecycle_generation = header.lifecycle_generation,
		mode_generation = header.mode_generation,
		mode_key = header.mode_key,
		identity_namespace = header.identity_namespace,
		device_generation = header.device_generation,
		surface = header.surface,
		format_mask = format_mask,
		interval_mask = interval_mask,
		source_byte_capacity = source_byte_capacity,
	}
}

host_presentation_admit_legacy :: proc(
	h: ^Host,
	update: contract.Legacy_Frame_Update,
	paired_invalidation: bool = false,
) -> Host_Presentation_Admission {
	if h == nil {return {}}
	state := &h.presentation_state
	if !state.accepting {
		host_presentation_note_closed(h)
		return {}
	}
	if update.header.lifecycle_generation == 0 || update.header.sequence == 0 {
		host_presentation_note_invalid(h)
		return {}
	}
	if update.header.lifecycle_generation != state.lifecycle ||
	   !host_presentation_vga_sequence_admit(state, update.header.sequence) {
		host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		return {}
	}
	if update.header.surface.id != 0 &&
	   update.header.surface.generation != 0 &&
	   state.legacy.header.lifecycle_generation == state.lifecycle &&
	   !contract.legacy_surface_transition_valid(state.legacy, update) {
		host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		return {}
	}
	mode := host_presentation_vga_mode_admit(state, update.header, paired_invalidation)
	if !mode.valid {
		if mode.stale {
			host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		} else {
			host_presentation_note_invalid(h)
		}
		return {}
	}
	prepared := update
	source_sequence := prepared.header.sequence
	source_mode_generation := prepared.header.mode_generation
	prepared.header.sequence = contract.generation_next(state.sequence)
	prepared.header.mode_generation = mode.host_clock.generation
	current := host_presentation_validation_context(
		prepared.header,
		contract.pixel_format_mask(.Bgra_8888),
		contract.presentation_interval_mask(0),
		0,
	)
	next_selector := state.selector
	result := contract.selector_submit_legacy(
		&next_selector,
		prepared,
		current,
		mode.preserve_active_gsw,
	)
	if result.action != .Present_Legacy && result.action != .Refresh_Legacy {
		if result.action == .Drop_Stale {
			host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		} else {
			host_presentation_note_invalid(h)
		}
		return {}
	}
	state.sequence = prepared.header.sequence
	return {
		valid = true,
		kind = .Legacy,
		selector = next_selector,
		mode_clock = mode.host_clock,
		result = result,
		legacy = prepared,
		source_sequence = source_sequence,
		source_mode_generation = source_mode_generation,
		vga_mode_clock = mode.vga_clock,
		vga_ordered = true,
	}
}

host_presentation_admit_gsw :: proc(
	h: ^Host,
	present: contract.Gsw_Present,
	source_byte_capacity: u64 = 0,
) -> Host_Presentation_Admission {
	if h == nil {return {}}
	state := &h.presentation_state
	if !state.accepting {
		host_presentation_note_closed(h)
		return {}
	}
	if present.header.lifecycle_generation == 0 || present.header.sequence == 0 {
		host_presentation_note_invalid(h)
		return {}
	}
	vga_ordered := present.header.source_kind == .Gsw_Snapshot
	if present.header.lifecycle_generation != state.lifecycle ||
	   (vga_ordered && !host_presentation_vga_sequence_admit(state, present.header.sequence)) {
		host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		return {}
	}
	mode: Host_Presentation_Mode_Admission
	if vga_ordered {
		mode = host_presentation_vga_mode_admit(state, present.header)
	} else {
		mode = host_presentation_local_mode_admit(state, present.header)
	}
	if !mode.valid {
		if mode.stale {
			host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		} else {
			host_presentation_note_invalid(h)
		}
		return {}
	}
	prepared := present
	source_sequence := prepared.header.sequence
	source_mode_generation := prepared.header.mode_generation
	prepared.header.sequence = contract.generation_next(state.sequence)
	prepared.header.mode_generation = mode.host_clock.generation
	format_mask := contract.PIXEL_FORMAT_MASK_ALL
	interval_mask := contract.presentation_interval_mask(0)
	kind := Host_Presentation_Kind.Gsw_Snapshot
	if prepared.header.source_kind == .Gsw_Resident {
		format_mask =
			contract.pixel_format_mask(.Bgra_8888) | contract.pixel_format_mask(.Rgba_8888)
		interval_mask = contract.presentation_interval_mask(1)
		kind = .Gsw_Resident
	}
	current := host_presentation_validation_context(
		prepared.header,
		format_mask,
		interval_mask,
		source_byte_capacity,
	)
	next_selector := state.selector
	result := contract.selector_submit_gsw(&next_selector, prepared, current)
	if result.action != .Present_Gsw {
		if result.action == .Drop_Stale {
			host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		} else {
			host_presentation_note_invalid(h)
		}
		return {}
	}
	state.sequence = prepared.header.sequence
	return {
		valid = true,
		kind = kind,
		selector = next_selector,
		mode_clock = mode.host_clock,
		result = result,
		gsw = prepared,
		source_sequence = source_sequence,
		source_mode_generation = source_mode_generation,
		source_byte_capacity = source_byte_capacity,
		vga_mode_clock = mode.vga_clock,
		vga_ordered = vga_ordered,
	}
}

@(private = "file")
host_presentation_admission_state :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
) -> Host_Presentation_Admission_State {
	if h == nil || admission == nil || !admission.valid || admission.kind == .Invalid {
		return .Invalid
	}
	if !h.presentation_state.accepting {return .Closed}
	if h.presentation_state.lifecycle == 0 {return .Invalid}
	header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
	if h.presentation_state.lifecycle != header.lifecycle_generation ||
	   h.presentation_state.sequence != header.sequence {return .Stale}
	return .Current
}

@(private = "file")
host_presentation_admission_current :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
) -> bool {
	return host_presentation_admission_state(h, admission) == .Current
}

@(private = "file")
host_presentation_note_admission_state :: proc(
	h: ^Host,
	state: Host_Presentation_Admission_State,
	finalization: bool,
) {
	switch state {
	case .Invalid:
		host_presentation_note_invalid(h)
	case .Closed:
		host_presentation_note_closed(h)
	case .Stale:
		if finalization {
			host_presentation_note_stale_finalization(h)
		} else {
			host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		}
	case .Current:
	}
}

@(private = "file")
host_presentation_commit_common :: proc(h: ^Host, admission: ^Host_Presentation_Admission) {
	state := &h.presentation_state
	state.selector = admission.selector
	state.mode_clock = admission.mode_clock
	if admission.vga_ordered {state.vga_mode_clock = admission.vga_mode_clock}
	if admission.source_sequence != 0 && admission.kind != .Gsw_Resident {
		state.last_vga_sequence = admission.source_sequence
	}
	if admission.kind == .Gsw_Snapshot || admission.kind == .Gsw_Resident {
		state.gsw_source_mode_generation = admission.source_mode_generation
	}
}

@(private = "package")
host_presentation_full_update :: proc(header: contract.Header) -> bool {
	return header.dirty.count == 1 && contract.rect_equal(header.dirty.rects[0], header.source)
}

@(private = "file")
host_presentation_stage_texture :: proc(
	h: ^Host,
	slot: ^Host_Presentation_Texture_Slot,
	frame: ^vga.Display_Frame,
	admission: ^Host_Presentation_Admission,
) -> Host_Presentation_Staged_Texture {
	if h == nil ||
	   slot == nil ||
	   frame == nil ||
	   admission == nil ||
	   !admission.valid ||
	   admission.kind == .Invalid {return {}}
	header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
	if frame.width <= 0 ||
	   frame.height <= 0 ||
	   frame.width > int(max(i32)) ||
	   frame.height > int(max(i32)) ||
	   frame.width > max(int) / frame.height ||
	   len(frame.pixels) < frame.width * frame.height ||
	   u64(frame.width) != u64(header.surface_extent.width) ||
	   u64(frame.height) != u64(header.surface_extent.height) {return {}}
	recreated := false
	if slot.texture == nil || slot.width != frame.width || slot.height != frame.height {
		if slot.texture != nil {sdl3.DestroyTexture(slot.texture)}
		slot^ = {}
		slot.texture = sdl3.CreateTexture(
			h.ren,
			.ARGB8888,
			.STREAMING,
			i32(frame.width),
			i32(frame.height),
		)
		if slot.texture == nil {return {}}
		_ = sdl3.SetTextureScaleMode(slot.texture, h.visual_shader == .None ? .NEAREST : .LINEAR)
		slot.width = frame.width
		slot.height = frame.height
		recreated = true
	}
	state := &h.presentation_state
	state.texture_stage_generation = contract.generation_next(state.texture_stage_generation)
	slot.stage_generation = state.texture_stage_generation
	raw: rawptr
	pitch: c.int
	if !sdl3.LockTexture(slot.texture, nil, &raw, &pitch) {return {}}
	defer sdl3.UnlockTexture(slot.texture)
	if raw == nil || int(pitch) < frame.width * size_of(u32) {return {}}
	pitch_pixels := int(pitch) / size_of(u32)
	destination := ([^]u32)(raw)[:pitch_pixels * frame.height]
	for y in 0 ..< frame.height {
		copy(
			destination[y * pitch_pixels:][:frame.width],
			frame.pixels[y * frame.width:][:frame.width],
		)
	}
	host_presentation_record_upload(h, frame.width, frame.height)
	return {
		valid = true,
		kind = admission.kind,
		texture = slot.texture,
		width = slot.width,
		height = slot.height,
		stage_generation = slot.stage_generation,
		lifecycle_generation = header.lifecycle_generation,
		admission_sequence = header.sequence,
		texture_recreated = recreated,
	}
}

host_presentation_stage_legacy :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> Host_Presentation_Staged_Texture {
	current := host_presentation_admission_state(h, admission)
	if current != .Current {
		host_presentation_note_admission_state(h, current, true)
		return {}
	}
	if admission.kind != .Legacy {
		host_presentation_note_invalid(h)
		return {}
	}
	if h.presentation_state.legacy_staging.texture != nil &&
	   h.presentation_state.legacy_staging.texture == h.tex {return {}}
	return host_presentation_stage_texture(
		h,
		&h.presentation_state.legacy_staging,
		frame,
		admission,
	)
}

host_presentation_stage_gsw_snapshot :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> Host_Presentation_Staged_Texture {
	current := host_presentation_admission_state(h, admission)
	if current != .Current {
		host_presentation_note_admission_state(h, current, true)
		return {}
	}
	if admission.kind != .Gsw_Snapshot {
		host_presentation_note_invalid(h)
		return {}
	}
	if h.presentation_state.gsw_staging.texture != nil &&
	   h.presentation_state.gsw_staging.texture == h.presentation_state.gsw_texture {return {}}
	return host_presentation_stage_texture(h, &h.presentation_state.gsw_staging, frame, admission)
}

@(private = "file")
host_presentation_staged_current :: proc(
	slot: Host_Presentation_Texture_Slot,
	staged: Host_Presentation_Staged_Texture,
	admission: ^Host_Presentation_Admission,
) -> bool {
	if admission == nil || !admission.valid {return false}
	header := admission.kind == .Legacy ? admission.legacy.header : admission.gsw.header
	return(
		staged.valid &&
		staged.kind == admission.kind &&
		staged.texture != nil &&
		staged.texture == slot.texture &&
		staged.width > 0 &&
		staged.height > 0 &&
		staged.width == slot.width &&
		staged.height == slot.height &&
		u64(staged.width) == u64(header.surface_extent.width) &&
		u64(staged.height) == u64(header.surface_extent.height) &&
		staged.stage_generation != 0 &&
		staged.stage_generation == slot.stage_generation &&
		staged.lifecycle_generation == header.lifecycle_generation &&
		staged.admission_sequence == header.sequence \
	)
}

host_presentation_commit_legacy_staged :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
	staged: Host_Presentation_Staged_Texture,
) -> bool {
	current := host_presentation_admission_state(h, admission)
	if current != .Current {
		host_presentation_note_admission_state(h, current, true)
		return false
	}
	if admission.kind != .Legacy {
		host_presentation_note_invalid(h)
		return false
	}
	if !host_presentation_staged_current(h.presentation_state.legacy_staging, staged, admission) {
		if staged.valid {
			host_presentation_note_stale_finalization(h)
		} else {
			host_presentation_note_invalid(h)
		}
		return false
	}
	if staged.texture == h.tex {
		host_presentation_note_invalid(h)
		return false
	}
	previous := Host_Presentation_Texture_Slot {
		texture = h.tex,
		width   = h.tex_width,
		height  = h.tex_height,
	}
	h.tex = staged.texture
	h.tex_width = staged.width
	h.tex_height = staged.height
	h.presentation_state.legacy_staging = previous
	host_presentation_commit_common(h, admission)
	h.presentation_state.legacy = admission.legacy
	if admission.result.action == .Present_Legacy {
		h.gpu_present = {}
		h.aspect_width = int(admission.legacy.header.canvas_extent.width)
		h.aspect_height = int(admission.legacy.header.canvas_extent.height)
		h.has_frame = true
	}
	if host_presentation_full_update(admission.legacy.header) {
		host_presentation_metric_add(&h.presentation_metrics.legacy_full_updates, 1)
	} else {
		host_presentation_metric_add(&h.presentation_metrics.legacy_partial_updates, 1)
	}
	return true
}

host_presentation_commit_gsw_snapshot_staged :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
	staged: Host_Presentation_Staged_Texture,
) -> bool {
	current := host_presentation_admission_state(h, admission)
	if current != .Current {
		host_presentation_note_admission_state(h, current, true)
		return false
	}
	state := &h.presentation_state
	if admission.kind != .Gsw_Snapshot {
		host_presentation_note_invalid(h)
		return false
	}
	if !host_presentation_staged_current(state.gsw_staging, staged, admission) {
		if staged.valid {
			host_presentation_note_stale_finalization(h)
		} else {
			host_presentation_note_invalid(h)
		}
		return false
	}
	if staged.texture == state.gsw_texture {
		host_presentation_note_invalid(h)
		return false
	}
	previous := Host_Presentation_Texture_Slot {
		texture = state.gsw_texture,
		width   = state.gsw_texture_width,
		height  = state.gsw_texture_height,
	}
	state.gsw_texture = staged.texture
	state.gsw_texture_width = staged.width
	state.gsw_texture_height = staged.height
	state.gsw_staging = previous
	host_presentation_commit_common(h, admission)
	state.gsw = admission.gsw
	h.gpu_present = {}
	h.aspect_width = int(admission.gsw.header.canvas_extent.width)
	h.aspect_height = int(admission.gsw.header.canvas_extent.height)
	h.has_frame = true
	if host_presentation_full_update(admission.gsw.header) {
		host_presentation_metric_add(&h.presentation_metrics.gsw_snapshot_full_updates, 1)
	} else {
		host_presentation_metric_add(&h.presentation_metrics.gsw_snapshot_partial_updates, 1)
	}
	return true
}

host_presentation_commit_resident :: proc(
	h: ^Host,
	admission: ^Host_Presentation_Admission,
	present: Host_Gpu_Present,
) -> bool {
	current := host_presentation_admission_state(h, admission)
	if current != .Current {
		host_presentation_note_admission_state(h, current, true)
		return false
	}
	if admission.kind != .Gsw_Resident {
		host_presentation_note_invalid(h)
		return false
	}
	header := admission.gsw.header
	if u64(present.surface_id) != header.surface.id ||
	   present.source.x != header.source.x ||
	   present.source.y != header.source.y ||
	   present.source.width != header.source.width ||
	   present.source.height != header.source.height ||
	   present.destination.x != header.destination.x ||
	   present.destination.y != header.destination.y ||
	   present.destination.width != header.destination.width ||
	   present.destination.height != header.destination.height ||
	   present.canvas_width != header.canvas_extent.width ||
	   present.canvas_height != header.canvas_extent.height ||
	   present.interval != header.interval {
		host_presentation_note_invalid(h)
		return false
	}
	surface := host_gpu_surface_find(h, present.surface_id)
	if surface == nil ||
	   surface.render_texture == nil ||
	   surface.generation != admission.gsw.header.surface.generation {
		host_presentation_note_stale_finalization(h)
		return false
	}
	if !host_gpu_present_valid(present, surface.descriptor) {
		host_presentation_note_invalid(h)
		return false
	}
	host_presentation_commit_common(h, admission)
	h.presentation_state.gsw = admission.gsw
	h.gpu_present = present
	h.aspect_width = int(admission.gsw.header.canvas_extent.width)
	h.aspect_height = int(admission.gsw.header.canvas_extent.height)
	h.has_frame = true
	h.gpu_direct_presents += 1
	host_presentation_metric_add(&h.presentation_metrics.resident_presents, 1)
	return true
}

@(private = "file")
host_presentation_evaluate_invalidation :: proc(
	state: ^Host_Presentation_State,
	invalidation: contract.Gsw_Invalidation,
) -> (
	contract.Selector,
	contract.Mode_Clock,
	contract.Selector_Result,
) {
	if state == nil {return {}, {}, {action = .Reject_Invalid}}
	if state.selector.active.kind != .Gsw {
		return {}, {}, {action = .None, active = state.selector.active}
	}
	present := state.gsw
	source_header := present.header
	source_header.mode_generation = state.gsw_source_mode_generation
	source_current := host_presentation_validation_context(
		source_header,
		contract.PIXEL_FORMAT_MASK_ALL,
		contract.PRESENT_INTERVAL_MASK_ALL,
		0,
	)
	diagnostic := contract.validate_gsw_invalidation(invalidation, source_current)
	if !contract.diagnostic_valid(diagnostic) {
		action := contract.Selector_Action.Reject_Invalid
		if contract.diagnostic_stale(diagnostic) {action = .Drop_Stale}
		return {}, {}, {action, state.selector.active, diagnostic}
	}
	active := state.selector.active
	owner := contract.display_owner_from_namespace(invalidation.identity_namespace)
	output_key := host_presentation_output_mode_key(present.header)
	if owner == .None ||
	   !state.accepting ||
	   state.lifecycle == 0 ||
	   state.lifecycle != present.header.lifecycle_generation ||
	   contract.display_owner_from_header(present.header) != owner ||
	   state.selector.lifecycle_generation != state.lifecycle ||
	   state.selector.mode_generation != present.header.mode_generation ||
	   state.selector.display_owner != owner ||
	   !contract.mode_key_equal(state.selector.mode_key, output_key) ||
	   active.display_owner != owner ||
	   active.source_kind != present.header.source_kind ||
	   !state.mode_clock.initialized ||
	   state.mode_clock.owner != owner ||
	   state.mode_clock.generation != present.header.mode_generation ||
	   !contract.mode_key_equal(state.mode_clock.key, output_key) {
		return {}, {}, {action = .Drop_Stale, active = active}
	}
	prepared := invalidation
	prepared.mode_generation = present.header.mode_generation
	current := host_presentation_validation_context(
		present.header,
		contract.PIXEL_FORMAT_MASK_ALL,
		contract.PRESENT_INTERVAL_MASK_ALL,
		0,
	)
	next_selector := state.selector
	if state.sequence != 0 &&
	   (next_selector.sequence == 0 ||
			   contract.generation_order(state.sequence, next_selector.sequence) == .Newer) {
		next_selector.sequence = state.sequence
	}
	result := contract.selector_invalidate_gsw(&next_selector, prepared, current)
	if result.action != .Restore_Legacy && result.action != .Clear {
		return {}, {}, result
	}
	next_clock := state.mode_clock
	target_owner := contract.Display_Owner.None
	target_key: contract.Mode_Key
	if result.action == .Restore_Legacy {
		target_owner = .Legacy
		target_key = host_presentation_output_mode_key(next_selector.last_good_legacy.header)
	}
	clock_generation, clock_changed := contract.mode_clock_observe(
		&next_clock,
		target_owner,
		target_key,
	)
	if !clock_changed || clock_generation != next_selector.mode_generation {
		return {}, {}, {action = .Reject_Invalid, active = active}
	}
	return next_selector, next_clock, result
}

host_presentation_invalidation_matches_active :: proc(
	h: ^Host,
	invalidation: contract.Gsw_Invalidation,
) -> bool {
	if h == nil {return false}
	_, _, result := host_presentation_evaluate_invalidation(&h.presentation_state, invalidation)
	return result.action == .Restore_Legacy || result.action == .Clear
}

host_presentation_apply_invalidation :: proc(
	h: ^Host,
	invalidation: contract.Gsw_Invalidation,
) -> contract.Selector_Action {
	if h == nil {return .Reject_Invalid}
	state := &h.presentation_state
	next_selector, next_clock, result := host_presentation_evaluate_invalidation(
		state,
		invalidation,
	)
	if result.action == .Drop_Stale {
		host_presentation_metric_add(&h.presentation_metrics.stale_generation_drops, 1)
		return result.action
	}
	if result.action != .Restore_Legacy && result.action != .Clear {
		if result.action == .Reject_Invalid {host_presentation_note_invalid(h)}
		return result.action
	}
	state.selector = next_selector
	state.sequence = next_selector.sequence
	state.mode_clock = next_clock
	state.gsw = {}
	state.gsw_source_mode_generation = 0
	h.gpu_present = {}
	if result.action == .Restore_Legacy {
		state.legacy = next_selector.last_good_legacy
		legacy := state.legacy.header
		h.aspect_width = int(legacy.canvas_extent.width)
		h.aspect_height = int(legacy.canvas_extent.height)
		h.has_frame = true
		host_presentation_metric_add(&h.presentation_metrics.last_good_restorations, 1)
	} else if result.action == .Clear {
		h.has_frame = false
	}
	return result.action
}

host_presentation_invalidate_active :: proc(
	h: ^Host,
	expected_namespace: contract.Identity_Namespace,
	reason: contract.Invalidation_Reason,
) -> contract.Selector_Action {
	if h == nil ||
	   expected_namespace == .Invalid ||
	   h.presentation_state.selector.active.kind != .Gsw ||
	   h.presentation_state.selector.active.identity_namespace != expected_namespace {return .None}
	present := h.presentation_state.gsw.header
	return host_presentation_apply_invalidation(
		h,
		{
			lifecycle_generation = present.lifecycle_generation,
			mode_generation = h.presentation_state.gsw_source_mode_generation,
			mode_key = present.mode_key,
			identity_namespace = present.identity_namespace,
			device_generation = present.device_generation,
			surface = present.surface,
			reason = reason,
		},
	)
}

@(private = "package")
host_presentation_active_texture :: proc(
	h: ^Host,
) -> (
	^sdl3.Texture,
	sdl3.FRect,
	bool,
	^Host_Gpu_Present,
) {
	if h == nil {return nil, {}, false, nil}
	active := h.presentation_state.selector.active
	if active.kind == .Legacy {return h.tex, {}, false, nil}
	if active.kind == .Gsw && active.source_kind == .Gsw_Snapshot {
		present := h.presentation_state.gsw
		source := sdl3.FRect {
			f32(present.header.source.x),
			f32(present.header.source.y),
			f32(present.header.source.width),
			f32(present.header.source.height),
		}
		return h.presentation_state.gsw_texture, source, true, nil
	}
	if active.kind == .Gsw && active.source_kind == .Gsw_Resident {
		return host_active_gpu_texture(h)
	}
	return nil, {}, false, nil
}

@(private = "package")
host_presentation_destination :: proc(h: ^Host, base: sdl3.FRect) -> sdl3.FRect {
	if h == nil || h.presentation_state.selector.active.kind != .Gsw {return base}
	present := h.presentation_state.gsw.header
	canvas := present.canvas_extent
	if canvas.width == 0 || canvas.height == 0 {return {}}
	return {
		base.x + base.w * f32(present.destination.x) / f32(canvas.width),
		base.y + base.h * f32(present.destination.y) / f32(canvas.height),
		base.w * f32(present.destination.width) / f32(canvas.width),
		base.h * f32(present.destination.height) / f32(canvas.height),
	}
}

@(private = "package")
host_presentation_destroy :: proc(h: ^Host) {
	if h == nil {return}
	state := &h.presentation_state
	if state.legacy_staging.texture != nil && state.legacy_staging.texture != h.tex {
		sdl3.DestroyTexture(state.legacy_staging.texture)
	}
	if state.gsw_staging.texture != nil && state.gsw_staging.texture != state.gsw_texture {
		sdl3.DestroyTexture(state.gsw_staging.texture)
	}
	if state.gsw_texture != nil {sdl3.DestroyTexture(state.gsw_texture)}
	h.presentation_state = {}
}
