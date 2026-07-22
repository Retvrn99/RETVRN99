// SPDX-License-Identifier: GPL-3.0-only
package vga

import "base:runtime"
import "core:time"

Scanout_State :: struct {
	crtc:                      [32]u8,
	seq:                       [8]u8,
	gfx:                       [16]u8,
	attr:                      [32]u8,
	video_on:                  bool,
	misc:                      u8,
	pel_mask:                  u8,
	dac:                       [256 * 3]u8,
	video_subsystem_enable:    u8,
	cga:                       Cga_State,
	dispi:                     [12]u16,
	bank_read:                 u16,
	bank_write:                u16,
	timing:                    Video_Timing,
	latched_start:             u16,
	pending_start:             u16,
	start_pending:             bool,
	present_generation:        u64,
	content_generation:        u64,
	guest_activity_generation: u64,
}

Scanout_Descriptor :: struct {
	allocator:          runtime.Allocator,
	state:              Scanout_State,
	mode_observability: Vga_Mode_Observability,
	vram:               []u8,
	frame_pixels:       []u32,
	frame:              Display_Frame,
	generation:         u64,
	bytes_copied:       int,
	copy_duration_ns:   u64,
}

@(private = "file")
scanout_required_vram :: proc(v: ^Vga) -> int {
	legacy_bytes := LEGACY_PLANE_SIZE * 4
	if !vga_vbe_enabled(v) {return legacy_bytes}
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {return legacy_bytes}
	bpp := int(v.dispi[DISPI_INDEX_BPP])
	if bpp == 4 {return legacy_bytes}
	bytes_per_pixel := (bpp + 7) / 8
	pitch := vga_vbe_pitch(v)
	x_end := int(v.dispi[DISPI_INDEX_X_OFFSET]) + width
	y_end := int(v.dispi[DISPI_INDEX_Y_OFFSET]) + height
	needed := (y_end - 1) * pitch + x_end * bytes_per_pixel
	return min(max(needed, legacy_bytes), VRAM_SIZE)
}

@(private = "file")
scanout_state_capture :: proc(state: ^Scanout_State, source: ^Vga) {
	state^ = {
		crtc                      = source.crtc,
		seq                       = source.seq,
		gfx                       = source.gfx,
		attr                      = source.attr,
		video_on                  = source.video_on,
		misc                      = source.misc,
		pel_mask                  = source.pel_mask,
		dac                       = source.dac,
		video_subsystem_enable    = source.video_subsystem_enable,
		cga                       = source.cga,
		dispi                     = source.dispi,
		bank_read                 = source.bank_read,
		bank_write                = source.bank_write,
		timing                    = source.timing,
		latched_start             = source.latched_start,
		pending_start             = source.pending_start,
		start_pending             = source.start_pending,
		present_generation        = source.present_generation,
		content_generation        = source.content_generation,
		guest_activity_generation = source.guest_activity_generation,
	}
}

@(private = "file")
scanout_state_to_vga :: proc(
	state: ^Scanout_State,
	vram: []u8,
	frame_pixels: []u32,
	allocator: runtime.Allocator,
) -> Vga {
	return {
		allocator = allocator,
		vram = vram,
		frame_pixels = frame_pixels,
		pci_io_enabled = true,
		pci_memory_enabled = true,
		framebuffer_base = VBE_LFB_BASE,
		crtc = state.crtc,
		seq = state.seq,
		gfx = state.gfx,
		attr = state.attr,
		video_on = state.video_on,
		misc = state.misc,
		pel_mask = state.pel_mask,
		dac = state.dac,
		video_subsystem_enable = state.video_subsystem_enable,
		cga = state.cga,
		dispi = state.dispi,
		bank_read = state.bank_read,
		bank_write = state.bank_write,
		timing = state.timing,
		latched_start = state.latched_start,
		pending_start = state.pending_start,
		start_pending = state.start_pending,
		present_generation = state.present_generation,
		content_generation = state.content_generation,
		guest_activity_generation = state.guest_activity_generation,
		initialized = true,
	}
}

scanout_descriptor_capture :: proc(descriptor: ^Scanout_Descriptor, source: ^Vga) -> bool {
	if descriptor == nil || source == nil || source.vram == nil {return false}
	if descriptor.allocator.procedure == nil {descriptor.allocator = context.allocator}
	if len(descriptor.vram) != VRAM_SIZE {
		if descriptor.vram != nil {delete(descriptor.vram, descriptor.allocator)}
		descriptor.vram = make([]u8, VRAM_SIZE, descriptor.allocator)
	}
	bytes := scanout_required_vram(source)
	copy_started := time.tick_now()
	copy(descriptor.vram[:bytes], source.vram[:bytes])
	descriptor.copy_duration_ns = u64(max(time.Duration(0), time.tick_since(copy_started)))
	scanout_state_capture(&descriptor.state, source)
	descriptor.mode_observability = vga_mode_observability(source)
	descriptor.frame = {}
	descriptor.generation = source.content_generation
	descriptor.bytes_copied = bytes
	return true
}

scanout_descriptor_render :: proc(descriptor: ^Scanout_Descriptor) -> ^Display_Frame {
	if descriptor == nil || descriptor.vram == nil {return nil}
	if descriptor.allocator.procedure == nil {descriptor.allocator = context.allocator}
	state := scanout_state_to_vga(
		&descriptor.state,
		descriptor.vram,
		descriptor.frame_pixels,
		descriptor.allocator,
	)
	frame := vga_display_frame(&state)
	descriptor.frame_pixels = state.frame_pixels
	descriptor.frame = frame^
	descriptor.frame.pixels = descriptor.frame_pixels
	descriptor.state.present_generation = state.present_generation
	return &descriptor.frame
}

scanout_descriptor_destroy :: proc(descriptor: ^Scanout_Descriptor) {
	if descriptor == nil {return}
	allocator := descriptor.allocator
	if allocator.procedure == nil {allocator = context.allocator}
	if descriptor.frame_pixels != nil {delete(descriptor.frame_pixels, allocator)}
	if descriptor.vram != nil {delete(descriptor.vram, allocator)}
	descriptor^ = {}
}
