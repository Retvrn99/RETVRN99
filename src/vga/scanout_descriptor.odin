// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "base:runtime"
import "core:time"

Scanout_State :: struct {
	crtc:                         [32]u8,
	seq:                          [8]u8,
	gfx:                          [16]u8,
	attr:                         [32]u8,
	video_on:                     bool,
	misc:                         u8,
	pel_mask:                     u8,
	dac:                          [256 * 3]u8,
	video_subsystem_enable:       u8,
	cga:                          Cga_State,
	dispi:                        [12]u16,
	bank_read:                    u16,
	bank_write:                   u16,
	timing:                       Video_Timing,
	latched_start:                u16,
	pending_start:                u16,
	start_pending:                bool,
	present_generation:           u64,
	content_generation:           u64,
	guest_activity_generation:    u64,
	presentation_sequence:        u64,
	legacy_presentation_sequence: u64,
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
	legacy_update:      contract.Legacy_Frame_Update,
	gsw_presentation:   Gsw_Presentation_Descriptor,
	gsw_frame_pixels:   []u32,
	gsw_frame:          Display_Frame,
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
		crtc                         = source.crtc,
		seq                          = source.seq,
		gfx                          = source.gfx,
		attr                         = source.attr,
		video_on                     = source.video_on,
		misc                         = source.misc,
		pel_mask                     = source.pel_mask,
		dac                          = source.dac,
		video_subsystem_enable       = source.video_subsystem_enable,
		cga                          = source.cga,
		dispi                        = source.dispi,
		bank_read                    = source.bank_read,
		bank_write                   = source.bank_write,
		timing                       = source.timing,
		latched_start                = source.latched_start,
		pending_start                = source.pending_start,
		start_pending                = source.start_pending,
		present_generation           = source.present_generation,
		content_generation           = source.content_generation,
		guest_activity_generation    = source.guest_activity_generation,
		presentation_sequence        = source.presentation_sequence,
		legacy_presentation_sequence = source.legacy_presentation_sequence,
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
		presentation_sequence = state.presentation_sequence,
		legacy_presentation_sequence = state.legacy_presentation_sequence,
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
	descriptor.legacy_update = vga_legacy_frame_update(source)
	descriptor.frame = {}
	descriptor.generation = source.presentation_sequence
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

@(private = "file")
scanout_descriptor_gsw_palette_color :: proc(descriptor: ^Scanout_Descriptor, index: u8) -> u32 {
	base := int(index) * 3
	r := descriptor.gsw_presentation.palette.entries[base]
	g := descriptor.gsw_presentation.palette.entries[base + 1]
	b := descriptor.gsw_presentation.palette.entries[base + 2]
	return 0xFF00_0000 | u32(r) << 16 | u32(g) << 8 | u32(b)
}

scanout_descriptor_render_gsw :: proc(descriptor: ^Scanout_Descriptor) -> ^Display_Frame {
	if descriptor == nil || !descriptor.gsw_presentation.present_valid {return nil}
	present := descriptor.gsw_presentation.present
	if present.header.source_kind != .Gsw_Snapshot ||
	   present.header.ownership != .Mailbox_Surface ||
	   present.header.source.x != 0 ||
	   present.header.source.y != 0 ||
	   present.header.source.width != present.header.surface_extent.width ||
	   present.header.source.height != present.header.surface_extent.height ||
	   present.source_offset != 0 {return nil}
	validation := contract.Validation_Context {
		lifecycle_generation = present.header.lifecycle_generation,
		mode_generation      = present.header.mode_generation,
		mode_key             = present.header.mode_key,
		identity_namespace   = present.header.identity_namespace,
		device_generation    = present.header.device_generation,
		surface              = present.header.surface,
		format_mask          = contract.PIXEL_FORMAT_MASK_ALL,
		interval_mask        = contract.PRESENT_INTERVAL_MASK_ALL,
		source_byte_capacity = u64(len(descriptor.gsw_presentation.source)),
	}
	if !contract.diagnostic_valid(contract.validate_gsw(present, validation)) {return nil}
	width := int(present.header.surface_extent.width)
	height := int(present.header.surface_extent.height)
	if width <= 0 ||
	   height <= 0 ||
	   width > DISPI_MAX_XRES ||
	   height > DISPI_MAX_YRES ||
	   width > max(int) / height {return nil}
	bytes_per_pixel, known := contract.pixel_format_bytes(present.header.format)
	if !known || u64(present.source_pitch) != u64(width) * u64(bytes_per_pixel) {return nil}
	if present.header.format == .Indexed_8 &&
	   descriptor.gsw_presentation.palette.dac_bits != GSW_PALETTE_DAC_BITS {return nil}
	if descriptor.allocator.procedure == nil {descriptor.allocator = context.allocator}
	needed := width * height
	if len(descriptor.gsw_frame_pixels) != needed {
		if descriptor.gsw_frame_pixels != nil {
			delete(descriptor.gsw_frame_pixels, descriptor.allocator)
		}
		descriptor.gsw_frame_pixels = make([]u32, needed, descriptor.allocator)
	}
	source := descriptor.gsw_presentation.source
	pitch := int(present.source_pitch)
	for y in 0 ..< height {
		row := y * pitch
		for x in 0 ..< width {
			offset := row + x * int(bytes_per_pixel)
			pixel: u32
			#partial switch present.header.format {
			case .Indexed_8:
				pixel = scanout_descriptor_gsw_palette_color(descriptor, source[offset])
			case .Rgb_555:
				value := u16(source[offset]) | u16(source[offset + 1]) << 8
				r := u8((value >> 10) & 0x1F)
				g := u8((value >> 5) & 0x1F)
				b := u8(value & 0x1F)
				pixel =
					0xFF00_0000 |
					u32(r << 3 | r >> 2) << 16 |
					u32(g << 3 | g >> 2) << 8 |
					u32(b << 3 | b >> 2)
			case .Rgb_565:
				value := u16(source[offset]) | u16(source[offset + 1]) << 8
				r := u8((value >> 11) & 0x1F)
				g := u8((value >> 5) & 0x3F)
				b := u8(value & 0x1F)
				pixel =
					0xFF00_0000 |
					u32(r << 3 | r >> 2) << 16 |
					u32(g << 2 | g >> 4) << 8 |
					u32(b << 3 | b >> 2)
			case .Bgr_888, .Bgrx_8888, .Bgra_8888:
				pixel =
					0xFF00_0000 |
					u32(source[offset + 2]) << 16 |
					u32(source[offset + 1]) << 8 |
					u32(source[offset])
			case .Rgba_8888:
				pixel =
					0xFF00_0000 |
					u32(source[offset]) << 16 |
					u32(source[offset + 1]) << 8 |
					u32(source[offset + 2])
			case:
				return nil
			}
			descriptor.gsw_frame_pixels[y * width + x] = pixel
		}
	}
	kind := Display_Kind.Xrgb_8888
	#partial switch present.header.format {
	case .Indexed_8:
		kind = .Indexed_8
	case .Rgb_555:
		kind = .Rgb_555
	case .Rgb_565:
		kind = .Rgb_565
	case .Bgr_888:
		kind = .Rgb_888
	case .Bgrx_8888, .Bgra_8888, .Rgba_8888:
		kind = .Xrgb_8888
	case:
	}
	descriptor.gsw_frame = {
		kind               = kind,
		width              = width,
		height             = height,
		aspect_width       = int(present.header.canvas_extent.width),
		aspect_height      = int(present.header.canvas_extent.height),
		content_generation = present.header.sequence,
		pixels             = descriptor.gsw_frame_pixels,
	}
	return &descriptor.gsw_frame
}

scanout_descriptor_destroy :: proc(descriptor: ^Scanout_Descriptor) {
	if descriptor == nil {return}
	allocator := descriptor.allocator
	if allocator.procedure == nil {allocator = context.allocator}
	if descriptor.frame_pixels != nil {delete(descriptor.frame_pixels, allocator)}
	if descriptor.gsw_frame_pixels != nil {delete(descriptor.gsw_frame_pixels, allocator)}
	if descriptor.vram != nil {delete(descriptor.vram, allocator)}
	gsw_presentation_descriptor_destroy(&descriptor.gsw_presentation)
	descriptor^ = {}
}
