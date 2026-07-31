// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

import "core:mem"
import "core:testing"

@(test)
gsw_presentation_test_external_backing_writes_refresh_full_active_surface :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	testing.expect(t, !gsw_presentation_publish_external_backing_writes(&g, true))
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)
	sequence := vga_presentation_sequence(&v)
	testing.expect(t, !vga_publish_external_backing_writes_paired(&v, &g, false))
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	framebuffer[20], framebuffer[21], framebuffer[22] = 0x11, 0x22, 0x33
	testing.expect(t, vga_publish_external_backing_writes_paired(&v, &g, true))
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect_value(t, snapshot.active.header.sequence, sequence + 1)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 2)
	testing.expect_value(
		t,
		contract.generation_order(snapshot.active.header.sequence, vga_presentation_sequence(&v)),
		contract.Generation_Order.Older,
	)
	testing.expect_value(t, snapshot.damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(
		t,
		snapshot.damage.full_reason,
		contract.Damage_Full_Reason.External_Tracking,
	)
	testing.expect_value(t, snapshot.damage.rects, contract.rect_set_full({4, 2}))

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(
		t,
		gsw_presentation_descriptor_capture(&descriptor.gsw_presentation, &g, 1, nil),
	)
	testing.expect_value(t, descriptor.gsw_presentation.bytes_copied, 32)
	testing.expect_value(
		t,
		descriptor.gsw_presentation.full_reason,
		contract.Damage_Full_Reason.External_Tracking,
	)
	frame := scanout_test_expand_gsw(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(8))
	testing.expect_value(t, frame.pixels[5], u32(0xFF332211))
}

@(test)
gsw_presentation_test_surface_damage_captures_and_converts_exact_rect :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 64)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)
	framebuffer[20], framebuffer[21], framebuffer[22] = 0x11, 0x22, 0x33
	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 1, 1, 1, 1))
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect_value(t, snapshot.active.header.dirty.count, u32(1))
	testing.expect_value(t, snapshot.active.header.dirty.rects[0], contract.Rect{1, 1, 1, 1})

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(
		t,
		gsw_presentation_descriptor_capture(&descriptor.gsw_presentation, &g, 1, nil),
	)
	testing.expect_value(t, descriptor.gsw_presentation.bytes_copied, 4)
	for i in 0 ..< len(framebuffer) {framebuffer[i] = 0}
	frame := scanout_test_expand_gsw(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(1))
	testing.expect_value(t, frame.pixels[5], u32(0xFF332211))
	testing.expect_value(t, frame.pixels[0], u32(0))
}

@(test)
gsw_presentation_test_palette_only_copies_raw_source_without_conversion :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 8)
	defer delete(framebuffer)
	framebuffer[0], framebuffer[1] = 1, 2
	framebuffer[2], framebuffer[3] = 1, 2
	framebuffer[4], framebuffer[5] = 2, 1
	framebuffer[6], framebuffer[7] = 2, 1
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 8, 4, 2, 4, .Indexed_8, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)
	g.palette.entries[3], g.palette.entries[4], g.palette.entries[5] = 0xFF, 0, 0
	g.palette.entries[6], g.palette.entries[7], g.palette.entries[8] = 0, 0xFF, 0
	testing.expect(t, gsw_presentation_note_palette_damage(&g))

	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	descriptor: Scanout_Descriptor
	descriptor.gsw_presentation.allocator = mem.tracking_allocator(&tracker)
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(
		t,
		gsw_presentation_descriptor_capture(&descriptor.gsw_presentation, &g, 1, nil),
	)
	testing.expect_value(t, descriptor.gsw_presentation.bytes_copied, 8)
	testing.expect_value(t, tracker.total_allocation_count, i64(1))
	testing.expect_value(t, tracker.current_memory_allocated, i64(8))
	for &value in framebuffer {value = 0}
	g.palette = {}
	frame := scanout_test_expand_gsw(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.updated_pixels, u64(8))
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
	testing.expect_value(t, frame.pixels[1], u32(0xFF00FF00))
	testing.expect_value(t, frame.pixels[4], u32(0xFF00FF00))
	testing.expect_value(t, frame.pixels[7], u32(0xFFFF0000))
}

@(test)
gsw_presentation_test_compatible_damage_accumulates_until_exact_ack :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 64)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)

	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 0, 0, 1, 1))
	first := g.presentation_state.active.header
	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 3, 1, 1, 1))
	newest := g.presentation_state.active.header
	testing.expect_value(t, newest.dirty.count, u32(2))
	testing.expect_value(t, newest.dirty.rects[0], contract.Rect{0, 0, 1, 1})
	testing.expect_value(t, newest.dirty.rects[1], contract.Rect{3, 1, 1, 1})
	testing.expect(
		t,
		!gsw_presentation_acknowledge(
			&g,
			first.sequence,
			first.device_generation,
			first.surface.id,
			first.surface.generation,
		),
	)
	testing.expect_value(t, g.presentation_state.damage.rects.count, u32(2))
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			newest.sequence,
			newest.device_generation,
			newest.surface.id,
			newest.surface.generation,
		),
	)
	testing.expect_value(t, g.presentation_state.damage, contract.Damage_Record{})
}

@(test)
gsw_presentation_test_acknowledgement_preserves_damage_after_capture :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 64)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)

	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 0, 0, 1, 1))
	captured := gsw_vga_presentation_snapshot(&g)
	testing.expect_value(t, captured.damage.rects.count, u32(1))
	testing.expect_value(t, captured.damage.rects.rects[0], contract.Rect{0, 0, 1, 1})
	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 3, 1, 1, 1))
	testing.expect(
		t,
		g.presentation_state.active.header.sequence != captured.active.header.sequence,
	)
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			captured.active.header.sequence,
			captured.active.header.device_generation,
			captured.active.header.surface.id,
			captured.active.header.surface.generation,
		),
	)
	remaining := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, remaining.active_valid)
	testing.expect_value(t, remaining.damage.rects.count, u32(1))
	testing.expect_value(t, remaining.damage.rects.rects[0], contract.Rect{3, 1, 1, 1})
}

@(test)
gsw_presentation_test_oldest_ack_at_batch_capacity_preserves_pending_damage :: proc(
	t: ^testing.T,
) {
	framebuffer := make([]u8, 96)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 0, 96, 6, 1, 24, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	testing.expect(t, gsw_presentation_submit_surface(&g, surface, 1))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)

	oldest: Gsw_Presentation_Snapshot
	for x in 0 ..< GSW_PRESENT_DAMAGE_MAX_BATCHES {
		testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, u32(x), 0, 1, 1))
		captured := gsw_vga_presentation_snapshot(&g)
		if x == 0 {oldest = captured}
	}
	testing.expect_value(
		t,
		g.presentation_state.damage_batch_count,
		u32(GSW_PRESENT_DAMAGE_MAX_BATCHES),
	)
	testing.expect(t, gsw_presentation_note_surface_damage(&g, surface, 4, 0, 1, 1))
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			oldest.active.header.sequence,
			oldest.active.header.device_generation,
			oldest.active.header.surface.id,
			oldest.active.header.surface.generation,
		),
	)
	remaining := gsw_vga_presentation_snapshot(&g)
	testing.expect_value(t, remaining.damage.rects.count, u32(1))
	testing.expect_value(t, remaining.damage.rects.rects[0], contract.Rect{1, 0, 4, 1})
}

@(test)
gsw_presentation_test_raw_pitch_overlap_maps_only_visible_rows :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 256)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(t, gsw_presentation_submit_raw(&g, 64, 4, 2, 20, .Xrgb_8888, 0))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)
	testing.expect(t, gsw_presentation_note_raw_damage(&g, 64, 20, 2, 1, 2, 1, .Xrgb_8888))
	damage := g.presentation_state.damage
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{2, 1, 2, 1})
	sequence := g.presentation_state.active.header.sequence
	testing.expect(t, !gsw_presentation_note_raw_damage(&g, 0, 16, 0, 0, 1, 1, .Xrgb_8888))
	testing.expect_value(t, g.presentation_state.active.header.sequence, sequence)
}

@(test)
gsw_presentation_test_raw_damage_row_spans_sweep_across_visible_rows :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 512)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(t, gsw_presentation_submit_raw(&g, 64, 2, 3, 12, .Xrgb_8888, 0))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)

	testing.expect(t, gsw_presentation_note_raw_damage(&g, 64, 32, 0, 0, 8, 1, .Xrgb_8888))
	damage := g.presentation_state.damage
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 2, 3})
}

@(test)
gsw_presentation_test_raw_damage_visible_row_sweeps_across_row_spans :: proc(t: ^testing.T) {
	framebuffer := make([]u8, 512)
	defer delete(framebuffer)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	testing.expect(t, gsw_presentation_submit_raw(&g, 64, 8, 1, 32, .Xrgb_8888, 0))
	initial := g.presentation_state.active.header
	testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			initial.sequence,
			initial.device_generation,
			initial.surface.id,
			initial.surface.generation,
		),
	)

	testing.expect(t, gsw_presentation_note_raw_damage(&g, 64, 12, 0, 0, 2, 3, .Xrgb_8888))
	damage := g.presentation_state.damage
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.None)
	testing.expect_value(t, damage.rects.count, u32(3))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 2, 1})
	testing.expect_value(t, damage.rects.rects[1], contract.Rect{3, 0, 2, 1})
	testing.expect_value(t, damage.rects.rects[2], contract.Rect{6, 0, 2, 1})
}

Gsw_Test_Legacy_State :: struct {
	pci_io_enabled:                         bool,
	pci_memory_enabled:                     bool,
	framebuffer_base:                       u64,
	frame_valid:                            bool,
	present_generation:                     u64,
	content_generation:                     u64,
	guest_activity_generation:              u64,
	legacy_presentation_sequence:           u64,
	legacy_presentation_mode_generation:    u64,
	legacy_presentation_mode_key:           contract.Mode_Key,
	legacy_presentation_surface_generation: u64,
	legacy_presentation_surface_key:        contract.Mode_Key,
	full_frame_renders:                     u64,
	raster_pixels_rendered:                 u64,
	crtc:                                   [32]u8,
	crtc_ix:                                u8,
	seq:                                    [8]u8,
	seq_ix:                                 u8,
	gfx:                                    [16]u8,
	gfx_ix:                                 u8,
	attr:                                   [32]u8,
	attr_ix:                                u8,
	attr_flip:                              bool,
	video_on:                               bool,
	misc:                                   u8,
	feature:                                u8,
	pel_mask:                               u8,
	dac_read:                               u8,
	dac_write:                              u8,
	dac_sub:                                u8,
	dac_state:                              u8,
	dac:                                    [256 * 3]u8,
	latch:                                  [4]u8,
	video_subsystem_enable:                 u8,
	cga:                                    Cga_State,
	dispi_index:                            u16,
	dispi:                                  [12]u16,
	bank_read:                              u16,
	bank_write:                             u16,
	bank_program_count:                     u64,
	bank_change_count:                      u64,
	bank_read_change_count:                 u64,
	bank_write_change_count:                u64,
	io_write_count:                         u64,
	io_write_bytes:                         u64,
	timing:                                 Video_Timing,
	latched_start:                          u16,
	pending_start:                          u16,
	start_pending:                          bool,
}

gsw_test_legacy_state :: proc(v: ^Vga) -> Gsw_Test_Legacy_State {
	return {
		pci_io_enabled = v.pci_io_enabled,
		pci_memory_enabled = v.pci_memory_enabled,
		framebuffer_base = v.framebuffer_base,
		frame_valid = v.frame_valid,
		present_generation = v.present_generation,
		content_generation = v.content_generation,
		guest_activity_generation = v.guest_activity_generation,
		legacy_presentation_sequence = v.legacy_presentation_sequence,
		legacy_presentation_mode_generation = v.legacy_presentation_mode_generation,
		legacy_presentation_mode_key = v.legacy_presentation_mode_key,
		legacy_presentation_surface_generation = v.legacy_presentation_surface_generation,
		legacy_presentation_surface_key = v.legacy_presentation_surface_key,
		full_frame_renders = v.full_frame_renders,
		raster_pixels_rendered = v.raster_pixels_rendered,
		crtc = v.crtc,
		crtc_ix = v.crtc_ix,
		seq = v.seq,
		seq_ix = v.seq_ix,
		gfx = v.gfx,
		gfx_ix = v.gfx_ix,
		attr = v.attr,
		attr_ix = v.attr_ix,
		attr_flip = v.attr_flip,
		video_on = v.video_on,
		misc = v.misc,
		feature = v.feature,
		pel_mask = v.pel_mask,
		dac_read = v.dac_read,
		dac_write = v.dac_write,
		dac_sub = v.dac_sub,
		dac_state = v.dac_state,
		dac = v.dac,
		latch = v.latch,
		video_subsystem_enable = v.video_subsystem_enable,
		cga = v.cga,
		dispi_index = v.dispi_index,
		dispi = v.dispi,
		bank_read = v.bank_read,
		bank_write = v.bank_write,
		bank_program_count = v.bank_program_count,
		bank_change_count = v.bank_change_count,
		bank_read_change_count = v.bank_read_change_count,
		bank_write_change_count = v.bank_write_change_count,
		io_write_count = v.io_write_count,
		io_write_bytes = v.io_write_bytes,
		timing = v.timing,
		latched_start = v.latched_start,
		pending_start = v.pending_start,
		start_pending = v.start_pending,
	}
}

gsw_test_expect_legacy_unchanged :: proc(t: ^testing.T, v: ^Vga, before: Gsw_Test_Legacy_State) {
	testing.expect_value(t, gsw_test_legacy_state(v), before)
}

gsw_test_raw_present_command :: proc(
	command: []u8,
	offset, width, height, pitch: u32,
	format: Gsw_Pixel_Format,
	fence: u64,
) {
	gsw_test_header(command, .Present, fence, GSW_VGA_COMMAND_VERSION_2)
	gsw_test_wr32(command, 16, offset)
	gsw_test_wr32(command, 20, width)
	gsw_test_wr32(command, 24, height)
	gsw_test_wr32(command, 28, pitch)
	gsw_test_wr32(command, 32, u32(format))
}

gsw_test_surface_present_command :: proc(command: []u8, id: u32, fence: u64) {
	gsw_test_header(command, .Surface_Present, fence, GSW_VGA_COMMAND_VERSION_3)
	gsw_test_wr32(command, 16, id)
}

@(test)
gsw_presentation_surface_present_isolated_from_legacy_state :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	gsw2d_test_register(t, &g, 7, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	surface, found := gsw_surface_get(&g, 7)
	testing.expect(t, found)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	command := ram[:20]
	gsw_test_surface_present_command(command, 7, 77)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)

	gsw_vga_process(&g, ram[:])

	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect_value(t, snapshot.active.header.surface.id, u64(7))
	testing.expect_value(t, snapshot.active.header.surface.generation, surface.generation)
	testing.expect_value(t, snapshot.active.source_offset, u64(32))
	testing.expect_value(t, snapshot.active.source_pitch, u32(8))
	testing.expect_value(t, snapshot.active.header.canvas_extent.width, u32(4))
	testing.expect_value(t, snapshot.active.header.canvas_extent.height, u32(2))
	testing.expect_value(t, snapshot.active.header.dirty.count, u32(1))
	testing.expect_value(t, snapshot.active.header.completion.value, u64(77))
	testing.expect_value(t, snapshot.active.header.completion.generation, u64(1))
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Gsw2d)
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, g.metrics.presents, u64(1))
	testing.expect_value(t, g.metrics.commands, u64(1))
	sequence = vga_presentation_sequence(&v)
	legacy = gsw_test_legacy_state(&v)
	mode_generation := v.presentation_mode_clock.generation
	legacy_surface_generation := v.legacy_presentation_surface_generation
	testing.expect(t, gsw_surface_unregister(&g, 7))
	legacy.legacy_presentation_mode_generation = v.legacy_presentation_mode_generation
	legacy.legacy_presentation_mode_key = v.legacy_presentation_mode_key
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(
		t,
		v.presentation_mode_clock.generation,
		contract.generation_next(mode_generation),
	)
	testing.expect_value(t, v.legacy_presentation_surface_generation, legacy_surface_generation)
	testing.expect(t, gsw_vga_presentation_snapshot(&g).invalidation_valid)
}

@(test)
gsw_presentation_invalid_present_is_transactional :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_raw_present_command(ram[:40], 0, 2, 2, 8, .Xrgb_8888, 3)
	gsw_test_raw_present_command(ram[40:80], 0, 0, 2, 8, .Xrgb_8888, 4)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	before := gsw_vga_presentation_snapshot(&g)
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	mode_clock := v.presentation_mode_clock
	present_generation := g.present_generation
	presents := g.metrics.presents
	commands := g.metrics.commands
	width, height, pitch, format := g.width, g.height, g.pitch, g.format

	g.ring_tail = 80
	gsw_vga_process(&g, ram[:])

	after := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, contract.gsw_present_equal(after.active, before.active))
	testing.expect_value(t, after.active_valid, before.active_valid)
	testing.expect_value(t, after.state_generation, before.state_generation)
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, v.presentation_mode_clock.generation, mode_clock.generation)
	testing.expect(t, contract.mode_key_equal(v.presentation_mode_clock.key, mode_clock.key))
	testing.expect_value(t, g.present_generation, present_generation)
	testing.expect_value(t, g.metrics.presents, presents)
	testing.expect_value(t, g.metrics.commands, commands)
	testing.expect_value(t, g.width, width)
	testing.expect_value(t, g.height, height)
	testing.expect_value(t, g.pitch, pitch)
	testing.expect_value(t, g.format, format)
	testing.expect_value(t, g.ring_head, u32(40))
}

@(test)
gsw_presentation_invalid_surface_present_is_transactional :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	gsw2d_test_register(t, &g, 6, 32, 4, 2, 8, .Indexed_8)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_surface_present_command(ram[:20], 6, 5)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	before := gsw_vga_presentation_snapshot(&g)
	legacy := gsw_test_legacy_state(&v)
	sequence := vga_presentation_sequence(&v)
	mode_clock := v.presentation_mode_clock

	gsw_vga_process(&g, ram[:])

	after := gsw_vga_presentation_snapshot(&g)
	testing.expect_value(t, after.state_generation, before.state_generation)
	testing.expect_value(t, after.active_valid, before.active_valid)
	testing.expect_value(t, after.invalidation_valid, before.invalidation_valid)
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, v.presentation_mode_clock.generation, mode_clock.generation)
	testing.expect(t, contract.mode_key_equal(v.presentation_mode_clock.key, mode_clock.key))
	testing.expect_value(t, g.present_generation, u64(0))
	testing.expect_value(t, g.metrics.presents, u64(0))
	testing.expect_value(t, g.metrics.commands, u64(0))
	testing.expect_value(t, g.ring_head, u32(0))
}

@(test)
gsw_presentation_content_only_represent_preserves_surface_and_mode :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_raw_present_command(ram[:40], 16, 4, 2, 8, .Indexed_8, 1)
	gsw_test_raw_present_command(ram[40:80], 16, 4, 2, 8, .Indexed_8, 2)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	first := gsw_vga_presentation_snapshot(&g).active
	framebuffer[16] = 9
	g.ring_tail = 80
	gsw_vga_process(&g, ram[:])
	second := gsw_vga_presentation_snapshot(&g).active

	testing.expect_value(t, second.header.surface, first.header.surface)
	testing.expect_value(t, second.header.mode_generation, first.header.mode_generation)
	testing.expect(t, contract.generation_is_newer(second.header.sequence, first.header.sequence))
	testing.expect_value(t, g.present_generation, u64(2))
	testing.expect_value(t, g.metrics.presents, u64(2))
}

@(test)
gsw_presentation_uses_square_pixel_display_aspect :: proc(t: ^testing.T) {
	framebuffer: [160]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	cases := []struct {
		width, height: u32,
		aspect:        contract.Aspect_Ratio,
	}{{4, 3, {4, 3}}, {5, 4, {5, 4}}, {16, 9, {16, 9}}, {16, 10, {8, 5}}}
	for test_case in cases {
		if !testing.expect(
			t,
			gsw_presentation_submit_raw(
				&g,
				0,
				test_case.width,
				test_case.height,
				test_case.width,
				.Indexed_8,
				0,
			),
		) {continue}
		snapshot := gsw_vga_presentation_snapshot(&g)
		testing.expect_value(t, snapshot.active.header.display_aspect, test_case.aspect)
		testing.expect_value(t, snapshot.active.header.mode_key.display_aspect, test_case.aspect)
	}
}

@(test)
vga_presentation_legacy_surface_clock_is_independent_from_visible_owner :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	if !testing.expect(t, test_set_vbe_mode(&v, 4, 4, 32)) {return}
	vga_note_content_change(&v)
	mode_generation := v.presentation_mode_clock.generation
	surface_generation := v.legacy_presentation_surface_generation
	gsw_key := vga_presentation_mode_key(8, 8)

	vga_note_content_change(&v)
	testing.expect_value(t, v.presentation_mode_clock.generation, mode_generation)
	testing.expect_value(t, v.legacy_presentation_surface_generation, surface_generation)

	gsw_generation := vga_presentation_mode_observe(&v, .Gsw2d, gsw_key)
	testing.expect_value(t, gsw_generation, contract.generation_next(mode_generation))
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Gsw2d)
	testing.expect_value(t, v.legacy_presentation_surface_generation, surface_generation)
	vga_note_animation_change(&v)
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Gsw2d)
	testing.expect_value(t, v.presentation_mode_clock.generation, gsw_generation)
	testing.expect_value(t, v.legacy_presentation_surface_generation, surface_generation)

	v.dispi[DISPI_INDEX_XRES] = 8
	v.dispi[DISPI_INDEX_VIRT_WIDTH] = 8
	vga_recalculate_timing(&v)
	vga_note_content_change(&v)
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(
		t,
		v.presentation_mode_clock.generation,
		contract.generation_next(gsw_generation),
	)
	testing.expect_value(
		t,
		v.legacy_presentation_surface_generation,
		contract.generation_next(surface_generation),
	)
}

@(test)
gsw_presentation_surface_reuse_gets_a_new_generation :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	gsw2d_test_register(t, &g, 9, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	first_surface, found := gsw_surface_get(&g, 9)
	testing.expect(t, found)
	first_generation := first_surface.generation
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_surface_present_command(ram[:20], 9, 1)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	gsw_vga_process(&g, ram[:])
	active := gsw_vga_presentation_snapshot(&g).active

	testing.expect(t, gsw_surface_unregister(&g, 9))
	invalidation := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, !invalidation.active_valid)
	testing.expect(t, invalidation.invalidation_valid)
	testing.expect(t, invalidation.invalidation.reason == .Surface_Destroyed)
	testing.expect_value(t, invalidation.invalidation.surface.id, active.header.surface.id)
	testing.expect_value(
		t,
		invalidation.invalidation.surface.generation,
		active.header.surface.generation,
	)
	gsw2d_test_register(t, &g, 9, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	second_surface, recreated := gsw_surface_get(&g, 9)
	testing.expect(t, recreated)
	testing.expect(t, second_surface.generation != first_generation)
	gsw_test_surface_present_command(ram[20:40], 9, 2)
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	replacement := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, replacement.active_valid)
	testing.expect_value(
		t,
		replacement.active.header.surface.generation,
		second_surface.generation,
	)
	testing.expect(t, !replacement.invalidation_valid)
}

@(test)
gsw_presentation_ring_reset_invalidates_only_the_active_surface :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	gsw2d_test_register(t, &g, 1, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	gsw2d_test_register(t, &g, 2, 96, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_surface_present_command(ram[:20], 2, 5)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	gsw_vga_process(&g, ram[:])
	active := gsw_vga_presentation_snapshot(&g).active
	device_generation := g.presentation_state.device_generation
	sequence := vga_presentation_sequence(&v)
	legacy := gsw_test_legacy_state(&v)
	mode_generation := v.presentation_mode_clock.generation
	legacy_surface_generation := v.legacy_presentation_surface_generation
	write: [4]u8

	gsw_vga_mmio_write(&g, GSW_VGA_REG_RING_SIZE, write[:], nil)

	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, !snapshot.active_valid)
	testing.expect(t, snapshot.invalidation_valid)
	testing.expect(t, snapshot.invalidation.reason == .Device_Reset)
	testing.expect_value(t, snapshot.invalidation.surface, active.header.surface)
	testing.expect_value(t, snapshot.invalidation.device_generation, device_generation)
	legacy.legacy_presentation_mode_generation = v.legacy_presentation_mode_generation
	legacy.legacy_presentation_mode_key = v.legacy_presentation_mode_key
	gsw_test_expect_legacy_unchanged(t, &v, legacy)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	testing.expect_value(t, v.presentation_mode_clock.owner, contract.Display_Owner.Legacy)
	testing.expect_value(
		t,
		v.presentation_mode_clock.generation,
		contract.generation_next(mode_generation),
	)
	testing.expect_value(t, v.legacy_presentation_surface_generation, legacy_surface_generation)
	testing.expect(
		t,
		g.presentation_state.device_generation != snapshot.invalidation.device_generation,
	)
	_, first_stale := gsw_surface_get(&g, 1)
	_, second_stale := gsw_surface_get(&g, 2)
	testing.expect(t, !first_stale && !second_stale)
}

@(test)
gsw_presentation_process_exit_invalidates_the_owning_surface :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_raw_present_command(ram[:40], 16, 4, 2, 8, .Indexed_8, 1)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	active := gsw_vga_presentation_snapshot(&g).active
	mode_generation := g.presentation_state.mode_clock.generation

	gsw_presentation_process_exit(&g)

	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, !snapshot.active_valid)
	testing.expect(t, snapshot.invalidation_valid)
	testing.expect_value(
		t,
		snapshot.invalidation.reason,
		contract.Invalidation_Reason.Process_Exit,
	)
	testing.expect_value(
		t,
		snapshot.invalidation.identity_namespace,
		contract.Identity_Namespace.Gsw2d,
	)
	testing.expect_value(t, snapshot.invalidation.surface, active.header.surface)
	testing.expect_value(t, g.presentation_state.mode_clock.owner, contract.Display_Owner.None)
	testing.expect_value(
		t,
		g.presentation_state.mode_clock.generation,
		contract.generation_next(mode_generation),
	)
}

@(test)
gsw_presentation_generations_wrap_without_zero :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	g.presentation_state.surface_generation = max(u64)
	gsw2d_test_register(t, &g, 3, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	surface, found := gsw_surface_get(&g, 3)
	testing.expect(t, found)
	testing.expect_value(t, surface.generation, u64(1))
	g.present_generation = max(u64)
	g.presentation_state.sequence = max(u64)
	g.presentation_state.mode_clock = {
		initialized = true,
		generation  = max(u64),
		key         = vga_presentation_mode_key(1, 1),
	}
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_surface_present_command(ram[:20], 3, 8)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	gsw_vga_process(&g, ram[:])
	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect_value(t, g.present_generation, u64(1))
	testing.expect_value(t, snapshot.active.header.sequence, u64(1))
	testing.expect_value(t, snapshot.active.header.mode_generation, u64(1))
	testing.expect(t, snapshot.active.header.surface.generation != 0)
}

@(test)
gsw_presentation_descriptor_owns_a_tight_mailbox_copy :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	framebuffer[32], framebuffer[33], framebuffer[34], framebuffer[35] = 1, 2, 3, 4
	framebuffer[40], framebuffer[41], framebuffer[42], framebuffer[43] = 5, 6, 7, 8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	g.palette.entries[3], g.palette.entries[4], g.palette.entries[5] = 0x12, 0x34, 0x56
	gsw2d_test_register(t, &g, 4, 32, 4, 2, 8, .Indexed_8, GSW_SURFACE_PRESENTABLE)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_surface_present_command(ram[:20], 4, 9)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 20
	gsw_vga_process(&g, ram[:])
	descriptor: Gsw_Presentation_Descriptor
	defer gsw_presentation_descriptor_destroy(&descriptor)
	mode_clock: contract.Mode_Clock

	testing.expect(t, gsw_presentation_descriptor_capture(&descriptor, &g, 11, &mode_clock))
	testing.expect(t, descriptor.present_valid)
	testing.expect(t, !descriptor.invalidation_valid)
	testing.expect_value(t, descriptor.present.header.lifecycle_generation, u64(11))
	testing.expect(t, descriptor.present.header.ownership == .Mailbox_Surface)
	testing.expect_value(t, descriptor.present.source_offset, u64(0))
	testing.expect_value(t, descriptor.present.source_pitch, u32(4))
	testing.expect_value(t, descriptor.bytes_copied, 8)
	testing.expect_value(t, descriptor.palette.dac_bits, GSW_PALETTE_DAC_BITS)
	testing.expect_value(t, descriptor.palette.entries[3], u8(0x12))
	testing.expect_value(t, descriptor.palette.entries[4], u8(0x34))
	testing.expect_value(t, descriptor.palette.entries[5], u8(0x56))
	expected := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	for value, index in expected {
		testing.expect_value(t, descriptor.source[index], value)
	}
	framebuffer[32] = 99
	g.palette.entries[3], g.palette.entries[4], g.palette.entries[5] = 1, 2, 3
	testing.expect_value(t, descriptor.source[0], u8(1))
	testing.expect_value(t, descriptor.palette.entries[3], u8(0x12))
	testing.expect_value(t, descriptor.palette.entries[4], u8(0x34))
	testing.expect_value(t, descriptor.palette.entries[5], u8(0x56))
	g.palette.dac_bits = 6
	testing.expect(t, !gsw_presentation_descriptor_capture(&descriptor, &g, 11, &mode_clock))
	testing.expect(t, descriptor.present_valid)
	testing.expect_value(t, descriptor.source[0], u8(1))
	testing.expect_value(t, descriptor.palette.dac_bits, GSW_PALETTE_DAC_BITS)
	g.palette.dac_bits = GSW_PALETTE_DAC_BITS

	testing.expect(t, gsw_surface_unregister(&g, 4))
	testing.expect(t, gsw_presentation_descriptor_capture(&descriptor, &g, 11, &mode_clock))
	testing.expect(t, !descriptor.present_valid)
	testing.expect(t, descriptor.invalidation_valid)
	testing.expect(t, descriptor.invalidation.reason == .Surface_Destroyed)
	testing.expect_value(t, len(descriptor.source), 0)
	testing.expect_value(t, descriptor.bytes_copied, 0)
	testing.expect_value(t, descriptor.palette, Gsw_Palette_State{})
}

@(test)
gsw_presentation_descriptor_preserves_a_stale_mode_identity :: proc(t: ^testing.T) {
	v: Vga
	framebuffer := test_vga_init(t, &v)
	defer delete(framebuffer)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_raw_present_command(ram[:40], 0, 2, 2, 8, .Xrgb_8888, 1)
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	accepted := gsw_vga_presentation_snapshot(&g).active
	new_mode_generation := vga_presentation_mode_generation(&v, 4, 4)
	clock_before := v.presentation_mode_clock
	descriptor: Gsw_Presentation_Descriptor
	defer gsw_presentation_descriptor_destroy(&descriptor)

	testing.expect(
		t,
		gsw_presentation_descriptor_capture(&descriptor, &g, 3, &v.presentation_mode_clock),
	)
	testing.expect(t, descriptor.present_valid)
	testing.expect_value(
		t,
		descriptor.present.header.mode_generation,
		accepted.header.mode_generation,
	)
	testing.expect(t, descriptor.present.header.mode_generation != new_mode_generation)
	testing.expect(
		t,
		contract.mode_key_equal(descriptor.present.header.mode_key, accepted.header.mode_key),
	)
	testing.expect_value(t, v.presentation_mode_clock.generation, clock_before.generation)
	testing.expect(t, contract.mode_key_equal(v.presentation_mode_clock.key, clock_before.key))
}

@(test)
gsw_presentation_set_mode_invalidates_only_output_geometry_changes :: proc(t: ^testing.T) {
	framebuffer: [256]u8
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	ram: [GSW_VGA_RING_MIN_SIZE]u8
	gsw_test_raw_present_command(ram[:40], 0, 2, 2, 8, .Xrgb_8888, 1)
	mode := ram[40:72]
	gsw_test_header(mode, .Set_Mode, 2)
	gsw_test_wr32(mode, 16, 2)
	gsw_test_wr32(mode, 20, 2)
	gsw_test_wr32(mode, 24, 2)
	gsw_test_wr32(mode, 28, u32(Gsw_Pixel_Format.Indexed_8))
	g.ring_size = GSW_VGA_RING_MIN_SIZE
	g.ring_tail = 40
	gsw_vga_process(&g, ram[:])
	active := gsw_vga_presentation_snapshot(&g).active
	mode_generation := active.header.mode_generation
	testing.expect_value(t, active.header.identity_namespace, contract.Identity_Namespace.Gsw2d)
	testing.expect_value(t, active.header.mode_key.format, contract.Pixel_Format.Bgrx_8888)

	g.ring_tail = 72
	gsw_vga_process(&g, ram[:])

	snapshot := gsw_vga_presentation_snapshot(&g)
	testing.expect(t, snapshot.active_valid)
	testing.expect(t, !snapshot.invalidation_valid)
	testing.expect_value(t, snapshot.active.header.surface, active.header.surface)
	testing.expect_value(t, snapshot.active.header.mode_generation, mode_generation)

	geometry := ram[72:104]
	gsw_test_header(geometry, .Set_Mode, 3)
	gsw_test_wr32(geometry, 16, 3)
	gsw_test_wr32(geometry, 20, 2)
	gsw_test_wr32(geometry, 24, 3)
	gsw_test_wr32(geometry, 28, u32(Gsw_Pixel_Format.Indexed_8))
	g.ring_tail = 104
	gsw_vga_process(&g, ram[:])

	snapshot = gsw_vga_presentation_snapshot(&g)
	testing.expect(t, !snapshot.active_valid)
	testing.expect(t, snapshot.invalidation_valid)
	testing.expect(t, snapshot.invalidation.reason == .Mode_Changed)
	testing.expect_value(
		t,
		snapshot.invalidation.identity_namespace,
		contract.Identity_Namespace.Gsw2d,
	)
	testing.expect_value(t, snapshot.invalidation.surface, active.header.surface)
	testing.expect_value(t, g.presentation_state.mode_clock.owner, contract.Display_Owner.None)
	testing.expect_value(
		t,
		g.presentation_state.mode_clock.generation,
		contract.generation_next(mode_generation),
	)
	testing.expect_value(t, g.width, u32(3))
	testing.expect_value(t, g.height, u32(2))
}
