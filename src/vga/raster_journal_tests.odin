// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:testing"

// Mirrors machine_vga_write: every guest port write is stamped with the device
// time it lands at before it reaches the register file.
@(private = "file")
raster_journal_test_out :: proc(v: ^Vga, now_ns: u64, port: u16, value: u8) {
	vga_begin_raster_change(v, now_ns)
	vga_io_write(v, port, 1, u32(value))
}

@(private = "file")
raster_journal_test_dac :: proc(v: ^Vga, now_ns: u64, index, r, g, b: u8) {
	raster_journal_test_out(v, now_ns, 0x3C8, index)
	raster_journal_test_out(v, now_ns, 0x3C9, r)
	raster_journal_test_out(v, now_ns, 0x3C9, g)
	raster_journal_test_out(v, now_ns, 0x3C9, b)
}

// A 64x32 indexed surface whose left third carries palette index 1, middle
// index 2, and right index 3. Deferred scanout is on, as production runs it.
@(private = "file")
raster_journal_test_surface :: proc(t: ^testing.T, v: ^Vga) -> bool {
	if !testing.expect(t, test_set_vbe_mode(v, 64, 32, 8)) {return false}
	vga_set_deferred_scanout(v, true)
	pitch := vga_vbe_pitch(v)
	for y in 0 ..< 32 {
		for x in 0 ..< 64 {v.vram[y * pitch + x] = u8(x / 16) + 1}
	}
	vga_note_content_change(v)
	return true
}

@(private = "file")
raster_journal_test_line_ns :: proc(v: ^Vga, line: u64) -> u64 {
	return line * v.timing.line_period_ns + v.timing.line_period_ns / 2
}

@(private = "file")
raster_journal_test_acknowledge :: proc(t: ^testing.T, v: ^Vga, descriptor: ^Scanout_Descriptor) {
	header := descriptor.legacy_update.header
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			v,
			header.sequence,
			header.mode_generation,
			header.surface.id,
			header.surface.generation,
		),
	)
}

// ADR 0012. Two palette splits programmed through the public DAC ports at
// timestamps inside one frame reach the descriptor as scan-line-stamped deltas,
// and host replay paints three bands from one palette index.
@(test)
raster_journal_test_palette_splits_replay_above_and_below_the_split :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !raster_journal_test_surface(t, &v) {return}

	// Index 1 starts red, index 2 holds the first split colour, index 3 the
	// second. Every component differs, so every write is a recorded delta.
	raster_journal_test_dac(&v, 0, 1, 0x3F, 0x00, 0x10)
	raster_journal_test_dac(&v, 0, 2, 0x00, 0x3F, 0x20)
	raster_journal_test_dac(&v, 0, 3, 0x10, 0x00, 0x3F)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	testing.expect_value(t, descriptor.journal.count, u32(0))
	raster_journal_test_acknowledge(t, &v, &descriptor)

	split_a := raster_journal_test_line_ns(&v, 8)
	split_b := raster_journal_test_line_ns(&v, 20)
	raster_journal_test_dac(&v, split_a, 1, 0x00, 0x3F, 0x20)
	raster_journal_test_dac(&v, split_b, 1, 0x10, 0x00, 0x3F)

	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	// Nothing but the palette moved, which is the path a real split takes.
	testing.expect_value(
		t,
		descriptor.legacy_update.damage_kind,
		contract.Damage_Kind.Palette_Only,
	)
	testing.expect(t, !descriptor.journal.truncated)
	if !testing.expect_value(t, descriptor.journal.count, u32(6)) {return}
	expected := [6]Raster_Delta {
		{line = 8, index = 3, kind = .Dac_Entry, value = 0x00, previous = 0x3F},
		{line = 8, index = 4, kind = .Dac_Entry, value = 0x3F, previous = 0x00},
		{line = 8, index = 5, kind = .Dac_Entry, value = 0x20, previous = 0x10},
		{line = 20, index = 3, kind = .Dac_Entry, value = 0x10, previous = 0x00},
		{line = 20, index = 4, kind = .Dac_Entry, value = 0x00, previous = 0x3F},
		{line = 20, index = 5, kind = .Dac_Entry, value = 0x3F, previous = 0x20},
	}
	for entry, i in expected {testing.expect_value(t, descriptor.journal.entries[i], entry)}

	frame := scanout_descriptor_render(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.width, 64)
	testing.expect_value(t, frame.height, 32)
	band :: proc(frame: ^Display_Frame, row, band: int) -> u32 {
		return frame.pixels[row * frame.width + band * 16]
	}
	// Above the first split index 1 still carries its own colour.
	testing.expect(t, band(frame, 4, 0) != band(frame, 4, 1))
	testing.expect(t, band(frame, 4, 0) != band(frame, 4, 2))
	testing.expect(t, band(frame, 7, 0) != band(frame, 7, 1))
	// Between the splits it carries the colour index 2 carries.
	testing.expect_value(t, band(frame, 8, 0), band(frame, 8, 1))
	testing.expect_value(t, band(frame, 12, 0), band(frame, 12, 1))
	testing.expect(t, band(frame, 12, 0) != band(frame, 12, 2))
	// Below the second split it carries the colour index 3 carries.
	testing.expect_value(t, band(frame, 20, 0), band(frame, 20, 2))
	testing.expect_value(t, band(frame, 24, 0), band(frame, 24, 2))
	testing.expect(t, band(frame, 24, 0) != band(frame, 24, 1))
	// The reference bands never move.
	testing.expect_value(t, band(frame, 4, 1), band(frame, 24, 1))
	testing.expect_value(t, band(frame, 4, 2), band(frame, 24, 2))
	// Replay leaves the descriptor state final, so the register snapshot is
	// still the one the guest last wrote.
	testing.expect_value(t, descriptor.state.dac[3], u8(0x10))
	testing.expect_value(t, descriptor.state.dac[5], u8(0x3F))
}

// The common path is untouched: no mid-frame write means no journal and the
// same pixels the descriptor produced before this existed.
@(test)
raster_journal_test_frame_without_mid_frame_writes_expands_identically :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !raster_journal_test_surface(t, &v) {return}
	raster_journal_test_dac(&v, 0, 1, 0x3F, 0x00, 0x10)
	raster_journal_test_dac(&v, 0, 2, 0x00, 0x3F, 0x20)
	raster_journal_test_dac(&v, 0, 3, 0x10, 0x00, 0x3F)
	// Device time inside the frame, but with no register write landing there.
	vga_advance(&v, raster_journal_test_line_ns(&v, 12))

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	testing.expect_value(t, descriptor.journal.count, u32(0))
	testing.expect(t, !descriptor.journal.truncated)

	frame := scanout_descriptor_render(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	reference := vga_display_frame(&v)
	if !testing.expect(t, reference != nil) {return}
	if !testing.expect_value(t, len(frame.pixels), len(reference.pixels)) {return}
	identical := true
	for pixel, i in frame.pixels {identical = identical && pixel == reference.pixels[i]}
	testing.expect(t, identical)
}

// Overflow marks the frame truncated, counts the event, and falls back to
// today's expansion from the final register state.
@(test)
raster_journal_test_overflow_truncates_and_expands_from_final_state :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !raster_journal_test_surface(t, &v) {return}
	raster_journal_test_dac(&v, 0, 1, 0x3F, 0x00, 0x10)

	// Three whole-DAC reloads are 2,304 changed byte writes against a cap of
	// 2,048. Each sweep shifts the gradient so every byte moves.
	split := raster_journal_test_line_ns(&v, 8)
	for sweep in 0 ..< 3 {
		raster_journal_test_out(&v, split, 0x3C8, 0)
		for i in 0 ..< 256 * 3 {
			raster_journal_test_out(&v, split, 0x3C9, u8((i + sweep) % 0x3F) + 1)
		}
	}
	testing.expect(t, v.raster_journal.truncated)
	testing.expect_value(t, v.raster_journal.count, u32(0))
	testing.expect_value(t, v.raster_journal_truncations, u64(1))
	observability := vga_mode_observability(&v)
	testing.expect(t, observability.raster_journal_truncated)
	testing.expect_value(t, observability.raster_journal_truncations, u64(1))

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	testing.expect(t, descriptor.journal.truncated)
	testing.expect_value(t, descriptor.journal.count, u32(0))
	testing.expect_value(t, descriptor.mode_observability.raster_journal_truncations, u64(1))

	frame := scanout_descriptor_render(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	reference := vga_display_frame(&v)
	if !testing.expect(t, reference != nil) {return}
	identical := true
	for pixel, i in frame.pixels {identical = identical && pixel == reference.pixels[i]}
	testing.expect(t, identical)
	// The final gradient still separates the three bands, so the comparison is
	// against a real image rather than a flat one.
	testing.expect(t, frame.pixels[0] != frame.pixels[16])
	testing.expect(t, frame.pixels[16] != frame.pixels[32])
}

// A journal the guest stopped repeating goes stale rather than rolling a later
// frame back to a palette it no longer uses.
@(test)
raster_journal_test_stale_journal_is_dropped_after_one_frame :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !raster_journal_test_surface(t, &v) {return}
	raster_journal_test_dac(&v, 0, 1, 0x3F, 0x00, 0x10)
	raster_journal_test_dac(&v, raster_journal_test_line_ns(&v, 8), 1, 0x00, 0x3F, 0x20)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	testing.expect_value(t, descriptor.journal.count, u32(3))

	// The next frame still carries it, the one after that does not.
	vga_advance(&v, v.timing.frame_period_ns + raster_journal_test_line_ns(&v, 8))
	vga_note_content_change(&v)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.journal.count, u32(3))

	vga_advance(&v, 2 * v.timing.frame_period_ns + raster_journal_test_line_ns(&v, 8))
	vga_note_content_change(&v)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.journal.count, u32(0))
}
