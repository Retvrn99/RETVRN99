// SPDX-License-Identifier: GPL-3.0-only
package vga

import presentation "../presentation"

import "base:runtime"
import "core:time"

GSW_IMPLICIT_SURFACE_ID :: u64(1) << 63
GSW_PRESENT_MAX_WIDTH :: u32(2560)
GSW_PRESENT_MAX_HEIGHT :: u32(1600)

Gsw_Presentation_Surface_Key :: struct {
	offset: u32,
	width:  u32,
	height: u32,
	pitch:  u32,
	format: Gsw_Pixel_Format,
}

Gsw_Presentation_Producer_State :: struct {
	lifecycle_generation:   u64,
	device_generation:      u64,
	sequence:               u64,
	state_generation:       u64,
	surface_generation:     u64,
	mode_clock:             presentation.Mode_Clock,
	raw_surface_key:        Gsw_Presentation_Surface_Key,
	raw_surface_generation: u64,
	raw_surface_valid:      bool,
	active:                 presentation.Gsw_Present,
	active_valid:           bool,
	invalidation:           presentation.Gsw_Invalidation,
	invalidation_valid:     bool,
}

Gsw_Presentation_Snapshot :: struct {
	state_generation:   u64,
	active:             presentation.Gsw_Present,
	active_valid:       bool,
	invalidation:       presentation.Gsw_Invalidation,
	invalidation_valid: bool,
}

Gsw_Presentation_Descriptor :: struct {
	allocator:          runtime.Allocator,
	state_generation:   u64,
	present:            presentation.Gsw_Present,
	present_valid:      bool,
	invalidation:       presentation.Gsw_Invalidation,
	invalidation_valid: bool,
	palette:            Gsw_Palette_State,
	source:             []u8,
	bytes_copied:       int,
	copy_duration_ns:   u64,
}

@(private = "package")
gsw_presentation_state_init :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	g.presentation_state = {
		lifecycle_generation = 1,
		device_generation    = 1,
		sequence             = 1,
		state_generation     = 1,
	}
}

@(private = "file")
gsw_presentation_format :: proc(format: Gsw_Pixel_Format) -> (presentation.Pixel_Format, bool) {
	switch format {
	case .Indexed_8:
		return .Indexed_8, true
	case .Rgb_555:
		return .Rgb_555, true
	case .Rgb_565:
		return .Rgb_565, true
	case .Rgb_888:
		return .Bgr_888, true
	case .Xrgb_8888:
		return .Bgrx_8888, true
	}
	return .Invalid, false
}

@(private = "file")
gsw_presentation_full_rect :: proc(width, height: u32) -> presentation.Rect {
	return {width = width, height = height}
}

@(private = "file")
gsw_presentation_mode_key :: proc(
	width, height: u32,
	format: presentation.Pixel_Format,
) -> presentation.Mode_Key {
	extent := presentation.Extent{width, height}
	full := gsw_presentation_full_rect(width, height)
	return {
		format = format,
		surface_extent = extent,
		canvas_extent = extent,
		source = full,
		destination = full,
	}
}

@(private = "file")
gsw_presentation_output_mode_key :: proc(width, height: u32) -> presentation.Mode_Key {
	return vga_presentation_mode_key(width, height)
}

@(private = "file")
gsw_presentation_surface_key_equal :: proc(a, b: Gsw_Presentation_Surface_Key) -> bool {
	return(
		a.offset == b.offset &&
		a.width == b.width &&
		a.height == b.height &&
		a.pitch == b.pitch &&
		a.format == b.format \
	)
}

@(private = "file")
gsw_presentation_source_valid :: proc(
	g: ^Gsw_Vga,
	offset, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
) -> bool {
	if g == nil || width > GSW_PRESENT_MAX_WIDTH || height > GSW_PRESENT_MAX_HEIGHT {
		return false
	}
	bytes := gsw_format_bytes(format)
	if bytes == 0 || offset % u32(bytes) != 0 || pitch % u32(bytes) != 0 {return false}
	_, valid := gsw_surface_rect(len(g.framebuffer), offset, pitch, 0, 0, width, height, bytes)
	return valid
}

@(private = "file")
gsw_presentation_sequence_candidate :: proc(g: ^Gsw_Vga) -> u64 {
	if g.scanout != nil {
		return presentation.generation_next(vga_presentation_sequence(g.scanout))
	}
	return presentation.generation_next(g.presentation_state.sequence)
}

@(private = "file")
gsw_presentation_validation_context :: proc(
	record: presentation.Gsw_Present,
	source_byte_capacity: u64,
) -> presentation.Validation_Context {
	return {
		lifecycle_generation = record.header.lifecycle_generation,
		mode_generation = record.header.mode_generation,
		mode_key = record.header.mode_key,
		identity_namespace = record.header.identity_namespace,
		device_generation = record.header.device_generation,
		surface = record.header.surface,
		format_mask = presentation.PIXEL_FORMAT_MASK_ALL,
		interval_mask = presentation.PRESENT_INTERVAL_MASK_ALL,
		source_byte_capacity = source_byte_capacity,
	}
}

@(private = "file")
gsw_presentation_build :: proc(
	g: ^Gsw_Vga,
	surface: presentation.Surface_Identity,
	offset, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
	fence: u64,
) -> (
	presentation.Gsw_Present,
	presentation.Mode_Clock,
	bool,
) {
	if g == nil ||
	   surface.id == 0 ||
	   surface.generation == 0 ||
	   !gsw_presentation_source_valid(g, offset, width, height, pitch, format) {
		return {}, {}, false
	}
	pixel_format, format_valid := gsw_presentation_format(format)
	if !format_valid {return {}, {}, false}
	mode_key := gsw_presentation_mode_key(width, height, pixel_format)
	mode_clock := g.presentation_state.mode_clock
	if g.scanout != nil {mode_clock = g.scanout.presentation_mode_clock}
	mode_generation, _ := presentation.mode_clock_observe(
		&mode_clock,
		.Gsw2d,
		gsw_presentation_output_mode_key(width, height),
	)
	dirty: presentation.Rect_Set
	full := gsw_presentation_full_rect(width, height)
	if !presentation.rect_set_append(&dirty, full) {return {}, {}, false}
	completion: presentation.Completion_Identity
	if fence != 0 {
		completion = {
			value      = fence,
			generation = g.presentation_state.device_generation,
		}
	}
	record := presentation.Gsw_Present {
		header = {
			sequence = gsw_presentation_sequence_candidate(g),
			lifecycle_generation = g.presentation_state.lifecycle_generation,
			mode_generation = mode_generation,
			mode_key = mode_key,
			identity_namespace = .Gsw2d,
			device_generation = g.presentation_state.device_generation,
			surface = surface,
			format = pixel_format,
			surface_extent = {width = width, height = height},
			canvas_extent = {width = width, height = height},
			source = full,
			destination = full,
			dirty = dirty,
			interval = 0,
			completion = completion,
			source_kind = .Gsw_Snapshot,
			ownership = .Vm_Framebuffer,
		},
		source_offset = u64(offset),
		source_pitch = pitch,
	}
	ctx := gsw_presentation_validation_context(record, u64(len(g.framebuffer)))
	if !presentation.diagnostic_valid(presentation.validate_gsw(record, ctx)) {
		return {}, {}, false
	}
	return record, mode_clock, true
}

@(private = "file")
gsw_presentation_commit :: proc(
	g: ^Gsw_Vga,
	record: presentation.Gsw_Present,
	mode_clock: presentation.Mode_Clock,
) {
	committed := record
	committed_mode_clock := mode_clock
	if g.scanout != nil {
		committed.header.mode_generation = vga_presentation_mode_observe(
			g.scanout,
			.Gsw2d,
			gsw_presentation_output_mode_key(
				committed.header.canvas_extent.width,
				committed.header.canvas_extent.height,
			),
		)
		committed.header.sequence = vga_note_gsw_presentation(g.scanout)
		committed_mode_clock = g.scanout.presentation_mode_clock
	}
	g.presentation_state.sequence = committed.header.sequence
	g.presentation_state.state_generation = presentation.generation_next(
		g.presentation_state.state_generation,
	)
	g.presentation_state.mode_clock = committed_mode_clock
	g.presentation_state.active = committed
	g.presentation_state.active_valid = true
	g.presentation_state.invalidation = {}
	g.presentation_state.invalidation_valid = false
	g.width = committed.header.surface_extent.width
	g.height = committed.header.surface_extent.height
	g.pitch = committed.source_pitch
	#partial switch committed.header.format {
	case .Indexed_8:
		g.format = .Indexed_8
	case .Rgb_555:
		g.format = .Rgb_555
	case .Rgb_565:
		g.format = .Rgb_565
	case .Bgr_888:
		g.format = .Rgb_888
	case .Bgrx_8888:
		g.format = .Xrgb_8888
	case:
	}
	g.present_generation = presentation.generation_next(g.present_generation)
	g.metrics.presents += 1
}

@(private = "file")
gsw_presentation_release_display_owner :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	if g.scanout != nil {
		generation := vga_legacy_presentation_mode_generation(g.scanout, true)
		if generation == 0 {
			_, _ = presentation.mode_clock_observe(&g.scanout.presentation_mode_clock, .None, {})
		}
		g.presentation_state.mode_clock = g.scanout.presentation_mode_clock
		return
	}
	mode_clock := g.presentation_state.mode_clock
	_, _ = presentation.mode_clock_observe(&mode_clock, .None, {})
	g.presentation_state.mode_clock = mode_clock
}

@(private = "package")
gsw_presentation_submit_raw :: proc(
	g: ^Gsw_Vga,
	offset, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
	fence: u64,
) -> bool {
	if g == nil {return false}
	key := Gsw_Presentation_Surface_Key {
		offset = offset,
		width  = width,
		height = height,
		pitch  = pitch,
		format = format,
	}
	identity_changed :=
		!g.presentation_state.raw_surface_valid ||
		!gsw_presentation_surface_key_equal(g.presentation_state.raw_surface_key, key)
	surface_generation := g.presentation_state.raw_surface_generation
	if identity_changed {
		surface_generation = presentation.generation_next(g.presentation_state.surface_generation)
	}
	record, mode_clock, valid := gsw_presentation_build(
		g,
		{id = GSW_IMPLICIT_SURFACE_ID, generation = surface_generation},
		offset,
		width,
		height,
		pitch,
		format,
		fence,
	)
	if !valid {return false}
	if identity_changed {
		g.presentation_state.surface_generation = surface_generation
		g.presentation_state.raw_surface_generation = surface_generation
		g.presentation_state.raw_surface_key = key
		g.presentation_state.raw_surface_valid = true
	}
	gsw_presentation_commit(g, record, mode_clock)
	return true
}

@(private = "package")
gsw_presentation_submit_surface :: proc(g: ^Gsw_Vga, surface: ^Gsw_Surface, fence: u64) -> bool {
	if g == nil || surface == nil || surface.id == 0 || surface.generation == 0 {return false}
	record, mode_clock, valid := gsw_presentation_build(
		g,
		{id = u64(surface.id), generation = surface.generation},
		surface.base,
		surface.width,
		surface.height,
		surface.pitch,
		surface.format,
		fence,
	)
	if !valid {return false}
	gsw_presentation_commit(g, record, mode_clock)
	return true
}

@(private = "file")
gsw_presentation_invalidate_active :: proc(
	g: ^Gsw_Vga,
	reason: presentation.Invalidation_Reason,
) -> bool {
	if g == nil || !g.presentation_state.active_valid {return false}
	active := g.presentation_state.active
	invalidation := presentation.Gsw_Invalidation {
		lifecycle_generation = active.header.lifecycle_generation,
		mode_generation      = active.header.mode_generation,
		mode_key             = active.header.mode_key,
		identity_namespace   = active.header.identity_namespace,
		device_generation    = active.header.device_generation,
		surface              = active.header.surface,
		reason               = reason,
	}
	ctx := gsw_presentation_validation_context(active, u64(len(g.framebuffer)))
	if !presentation.diagnostic_valid(presentation.validate_gsw_invalidation(invalidation, ctx)) {
		return false
	}
	if g.scanout != nil {
		g.presentation_state.sequence = vga_note_gsw_presentation(g.scanout)
	} else {
		g.presentation_state.sequence = presentation.generation_next(g.presentation_state.sequence)
	}
	g.presentation_state.state_generation = presentation.generation_next(
		g.presentation_state.state_generation,
	)
	g.presentation_state.active_valid = false
	g.presentation_state.invalidation = invalidation
	g.presentation_state.invalidation_valid = true
	gsw_presentation_release_display_owner(g)
	return true
}

@(private = "package")
gsw_presentation_set_mode :: proc(g: ^Gsw_Vga, width, height: u32, format: Gsw_Pixel_Format) {
	if g == nil {return}
	_, format_valid := gsw_presentation_format(format)
	if !format_valid {return}
	if g.presentation_state.active_valid &&
	   !presentation.mode_key_equal(
			   presentation.output_mode_key(g.presentation_state.active.header),
			   gsw_presentation_output_mode_key(width, height),
		   ) {
		_ = gsw_presentation_invalidate_active(g, .Mode_Changed)
	}
}

@(private = "package")
gsw_presentation_surface_created :: proc(g: ^Gsw_Vga) -> u64 {
	if g == nil {return 0}
	g.presentation_state.surface_generation = presentation.generation_next(
		g.presentation_state.surface_generation,
	)
	return g.presentation_state.surface_generation
}

@(private = "package")
gsw_presentation_surface_destroyed :: proc(g: ^Gsw_Vga, surface: ^Gsw_Surface) {
	if g == nil || surface == nil || surface.id == 0 || surface.generation == 0 {return}
	identity := presentation.Surface_Identity {
		id         = u64(surface.id),
		generation = surface.generation,
	}
	if g.presentation_state.active_valid &&
	   presentation.surface_identity_equal(g.presentation_state.active.header.surface, identity) {
		_ = gsw_presentation_invalidate_active(g, .Surface_Destroyed)
	}
	g.presentation_state.surface_generation = presentation.generation_next(
		g.presentation_state.surface_generation,
	)
}

@(private = "package")
gsw_presentation_device_reset :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	invalidated := gsw_presentation_invalidate_active(g, .Device_Reset)
	for &surface in g.surfaces {
		if surface.id != 0 {
			g.presentation_state.surface_generation = presentation.generation_next(
				g.presentation_state.surface_generation,
			)
		}
	}
	if g.presentation_state.raw_surface_valid {
		g.presentation_state.surface_generation = presentation.generation_next(
			g.presentation_state.surface_generation,
		)
	}
	g.presentation_state.raw_surface_key = {}
	g.presentation_state.raw_surface_generation = 0
	g.presentation_state.raw_surface_valid = false
	g.presentation_state.device_generation = presentation.generation_next(
		g.presentation_state.device_generation,
	)
	if !invalidated {
		g.presentation_state.state_generation = presentation.generation_next(
			g.presentation_state.state_generation,
		)
		g.presentation_state.active = {}
		g.presentation_state.active_valid = false
		g.presentation_state.invalidation = {}
		g.presentation_state.invalidation_valid = false
	}
}

@(private = "package")
gsw_presentation_process_exit :: proc(g: ^Gsw_Vga) {
	if g == nil {return}
	_ = gsw_presentation_invalidate_active(g, .Process_Exit)
}

gsw_vga_presentation_snapshot :: proc(g: ^Gsw_Vga) -> Gsw_Presentation_Snapshot {
	if g == nil {return {}}
	return {
		state_generation = g.presentation_state.state_generation,
		active = g.presentation_state.active,
		active_valid = g.presentation_state.active_valid,
		invalidation = g.presentation_state.invalidation,
		invalidation_valid = g.presentation_state.invalidation_valid,
	}
}

@(private = "file")
gsw_presentation_descriptor_resize :: proc(
	descriptor: ^Gsw_Presentation_Descriptor,
	byte_count: int,
) {
	if descriptor.allocator.procedure == nil {descriptor.allocator = context.allocator}
	if len(descriptor.source) != byte_count {
		if descriptor.source != nil {delete(descriptor.source, descriptor.allocator)}
		descriptor.source = make([]u8, byte_count, descriptor.allocator)
	}
}

gsw_presentation_descriptor_capture :: proc(
	descriptor: ^Gsw_Presentation_Descriptor,
	source: ^Gsw_Vga,
	lifecycle_generation: u64,
	mode_clock: ^presentation.Mode_Clock,
) -> bool {
	if descriptor == nil || source == nil || lifecycle_generation == 0 {return false}
	snapshot := gsw_vga_presentation_snapshot(source)
	if snapshot.active_valid {
		palette := source.palette
		if palette.dac_bits != GSW_PALETTE_DAC_BITS {return false}
		record := snapshot.active
		record.header.lifecycle_generation = lifecycle_generation
		mode_clock_candidate := source.presentation_state.mode_clock
		commit_mode_clock := false
		if mode_clock != nil {
			mode_clock_candidate = mode_clock^
			if !mode_clock_candidate.initialized {
				record.header.mode_generation, _ = presentation.mode_clock_observe(
					&mode_clock_candidate,
					.Gsw2d,
					gsw_presentation_output_mode_key(
						record.header.canvas_extent.width,
						record.header.canvas_extent.height,
					),
				)
				commit_mode_clock = true
			}
		}
		bytes_per_pixel, known := presentation.pixel_format_bytes(record.header.format)
		if !known {return false}
		row_bytes_u64 := u64(record.header.source.width) * u64(bytes_per_pixel)
		byte_count_u64 := row_bytes_u64 * u64(record.header.source.height)
		if row_bytes_u64 > u64(~u32(0)) || byte_count_u64 > u64(max(int)) {return false}
		row_bytes := int(row_bytes_u64)
		byte_count := int(byte_count_u64)
		original_offset :=
			record.source_offset +
			u64(record.header.source.y) * u64(record.source_pitch) +
			u64(record.header.source.x) * u64(bytes_per_pixel)
		if original_offset > u64(len(source.framebuffer)) {return false}
		last_row := u64(record.header.source.height - 1) * u64(record.source_pitch)
		if last_row > u64(len(source.framebuffer)) - original_offset ||
		   row_bytes_u64 > u64(len(source.framebuffer)) - original_offset - last_row {
			return false
		}
		record.header.surface_extent = {
			width  = record.header.source.width,
			height = record.header.source.height,
		}
		record.header.source = gsw_presentation_full_rect(
			record.header.source.width,
			record.header.source.height,
		)
		record.header.ownership = .Mailbox_Surface
		record.source_offset = 0
		record.source_pitch = u32(row_bytes)
		ctx := gsw_presentation_validation_context(record, byte_count_u64)
		if !presentation.diagnostic_valid(presentation.validate_gsw(record, ctx)) {
			return false
		}
		gsw_presentation_descriptor_resize(descriptor, byte_count)
		copy_started := time.tick_now()
		for row in 0 ..< int(record.header.source.height) {
			source_start := int(original_offset) + row * int(snapshot.active.source_pitch)
			destination_start := row * row_bytes
			copy(
				descriptor.source[destination_start:destination_start + row_bytes],
				source.framebuffer[source_start:source_start + row_bytes],
			)
		}
		descriptor.copy_duration_ns = u64(max(time.Duration(0), time.tick_since(copy_started)))
		descriptor.bytes_copied = byte_count
		descriptor.state_generation = snapshot.state_generation
		descriptor.present = record
		descriptor.present_valid = true
		descriptor.invalidation = {}
		descriptor.invalidation_valid = false
		descriptor.palette = palette
		if commit_mode_clock {mode_clock^ = mode_clock_candidate}
		return true
	}
	if snapshot.invalidation_valid {
		invalidation := snapshot.invalidation
		invalidation.lifecycle_generation = lifecycle_generation
		mode_clock_candidate: presentation.Mode_Clock
		commit_mode_clock := false
		if mode_clock != nil && !mode_clock.initialized {
			mode_clock_candidate = mode_clock^
			invalidation.mode_generation, _ = presentation.mode_clock_observe(
				&mode_clock_candidate,
				presentation.display_owner_from_namespace(invalidation.identity_namespace),
				gsw_presentation_output_mode_key(
					invalidation.mode_key.canvas_extent.width,
					invalidation.mode_key.canvas_extent.height,
				),
			)
			commit_mode_clock = true
		}
		ctx := presentation.Validation_Context {
			lifecycle_generation = invalidation.lifecycle_generation,
			mode_generation      = invalidation.mode_generation,
			mode_key             = invalidation.mode_key,
			identity_namespace   = invalidation.identity_namespace,
			device_generation    = invalidation.device_generation,
			surface              = invalidation.surface,
		}
		if !presentation.diagnostic_valid(
			presentation.validate_gsw_invalidation(invalidation, ctx),
		) {
			return false
		}
		gsw_presentation_descriptor_resize(descriptor, 0)
		descriptor.copy_duration_ns = 0
		descriptor.bytes_copied = 0
		descriptor.state_generation = snapshot.state_generation
		descriptor.present = {}
		descriptor.present_valid = false
		descriptor.invalidation = invalidation
		descriptor.invalidation_valid = true
		descriptor.palette = {}
		if commit_mode_clock {mode_clock^ = mode_clock_candidate}
		return true
	}
	gsw_presentation_descriptor_resize(descriptor, 0)
	descriptor.copy_duration_ns = 0
	descriptor.bytes_copied = 0
	descriptor.state_generation = snapshot.state_generation
	descriptor.present = {}
	descriptor.present_valid = false
	descriptor.invalidation = {}
	descriptor.invalidation_valid = false
	descriptor.palette = {}
	return true
}

gsw_presentation_descriptor_destroy :: proc(descriptor: ^Gsw_Presentation_Descriptor) {
	if descriptor == nil {return}
	allocator := descriptor.allocator
	if allocator.procedure == nil {allocator = context.allocator}
	if descriptor.source != nil {delete(descriptor.source, allocator)}
	descriptor^ = {}
}
