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

// Planar 640x480 with the line-compare split parked past the last row, so the
// only split in play is the one the journal introduces.
@(private = "file")
raster_journal_test_planar :: proc(v: ^Vga) {
	test_bochs_legacy_mode(v, 0x12)
	vga_set_deferred_scanout(v, true)
}

// Pixel (x, y) reads plane bit 0x80 >> ((x + pel) & 7) at byte
// y * 80 + byte_pan + (x + pel) / 8, which is what the stripes below rely on.
@(private = "file")
raster_journal_test_planar_row :: proc(v: ^Vga, row, byte_offset: int, bits: u8) {
	set_plane_byte(v, 0, row * 80 + byte_offset, bits)
}

// Software that pans mid-frame writes the index with bit 5 set. Clearing it
// turns off the Palette Address Source and blanks the display, which would
// swallow the very rows the split is meant to move.
@(private = "file")
raster_journal_test_attribute :: proc(v: ^Vga, now_ns: u64, index, value: u8) {
	_ = vga_in(v, 0x3DA)
	raster_journal_test_out(v, now_ns, 0x3C0, index | 0x20)
	raster_journal_test_out(v, now_ns, 0x3C0, value)
}

@(private = "file")
raster_journal_test_crtc :: proc(v: ^Vga, now_ns: u64, index, value: u8) {
	raster_journal_test_out(v, now_ns, 0x3D4, index)
	raster_journal_test_out(v, now_ns, 0x3D5, value)
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

	frame := scanout_test_expand_legacy(&descriptor)
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

	frame := scanout_test_expand_legacy(&descriptor)
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

	frame := scanout_test_expand_legacy(&descriptor)
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

// IBM 2-95. Attribute Controller 13h shifts the image horizontally and takes
// effect where it is written, so rows above the split keep the old pan.
@(test)
raster_journal_test_pel_pan_split_shifts_only_the_rows_below_it :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	raster_journal_test_planar(&v)
	// A four-pixel stripe at x=4..7 on both sample rows.
	raster_journal_test_planar_row(&v, 4, 0, 0x0F)
	raster_journal_test_planar_row(&v, 24, 0, 0x0F)
	vga_note_content_change(&v)

	raster_journal_test_attribute(&v, raster_journal_test_line_ns(&v, 12), 0x13, 0x04)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	if !testing.expect_value(t, descriptor.journal.count, u32(1)) {return}
	testing.expect_value(
		t,
		descriptor.journal.entries[0],
		Raster_Delta{line = 12, index = 0, kind = .Pel_Pan, value = 0x04, previous = 0x00},
	)

	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	above_left := frame.pixels[4 * 640 + 0]
	above_stripe := frame.pixels[4 * 640 + 4]
	below_left := frame.pixels[24 * 640 + 0]
	below_stripe := frame.pixels[24 * 640 + 4]
	// The stripe is where it was written above the split.
	testing.expect(t, above_left != above_stripe)
	// Panning by four pulls it four pixels left below the split.
	testing.expect_value(t, below_left, above_stripe)
	testing.expect_value(t, below_stripe, above_left)
}

// IBM 2-63. CRT Controller 08h byte panning moves the row start, and the same
// split rule applies.
@(test)
raster_journal_test_byte_pan_split_moves_only_the_rows_below_it :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	raster_journal_test_planar(&v)
	// Above the split the stripe sits at x=4..7; below it, one byte further on,
	// so a byte pan of one lands it at x=0..3.
	raster_journal_test_planar_row(&v, 4, 0, 0x0F)
	raster_journal_test_planar_row(&v, 24, 1, 0xF0)
	vga_note_content_change(&v)

	raster_journal_test_crtc(&v, raster_journal_test_line_ns(&v, 12), 0x08, 0x20)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	if !testing.expect_value(t, descriptor.journal.count, u32(1)) {return}
	testing.expect_value(
		t,
		descriptor.journal.entries[0],
		Raster_Delta{line = 12, index = 0, kind = .Byte_Pan, value = 0x20, previous = 0x00},
	)

	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	above_left := frame.pixels[4 * 640 + 0]
	above_stripe := frame.pixels[4 * 640 + 4]
	testing.expect(t, above_left != above_stripe)
	testing.expect_value(t, frame.pixels[24 * 640 + 0], above_stripe)
	testing.expect_value(t, frame.pixels[24 * 640 + 4], above_left)
}

// IBM 2-67 and 2-99. The Start Address pair loads into the address counter at
// vertical retrace, so a mid-frame write is not a mid-frame effect and is
// deliberately not journalled. This pins both halves of that.
@(test)
raster_journal_test_display_start_write_waits_for_vertical_retrace :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	raster_journal_test_planar(&v)
	// Pixel (0,0) reads plane 0 at the start address, so two starts give two
	// different colour indices.
	set_plane_byte(&v, 0, 0, 0x80)
	set_plane_byte(&v, 1, 100, 0x80)
	vga_note_content_change(&v)
	// Leave time zero, where a pending start is still taken as the live one.
	vga_advance(&v, raster_journal_test_line_ns(&v, 4))

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	before := frame.pixels[0]

	split := v.timing.frame_period_ns + raster_journal_test_line_ns(&v, 12)
	raster_journal_test_crtc(&v, split, 0x0C, 0x00)
	raster_journal_test_crtc(&v, split, 0x0D, 100)
	testing.expect(t, v.start_pending)
	testing.expect_value(t, v.latched_start, u16(0))
	vga_note_content_change(&v)

	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	testing.expect_value(t, descriptor.journal.count, u32(0))
	frame = scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect_value(t, frame.pixels[0], before)

	// Past vertical retrace the new start is live and the image moves.
	vga_advance(&v, v.timing.frame_period_ns + raster_journal_test_line_ns(&v, 495))
	testing.expect_value(t, v.latched_start, u16(100))
	testing.expect(t, !v.start_pending)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	frame = scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	testing.expect(t, frame.pixels[0] != before)
}

// IBM 2-89 to 2-91. Reaching Attribute 00h-0Fh means clearing the Palette
// Address Source first, so a mid-frame palette change is really three writes.
// Done inside one scan line it leaves no visible blank.
@(test)
raster_journal_test_attribute_palette_split_replays_below_the_split :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	raster_journal_test_planar(&v)
	// Every sample row carries colour index 1 at x=0..3 and index 2 at x=4..7,
	// including the split row itself, so a blank there is distinguishable from
	// the ordinary black of an empty row.
	for row in ([3]int{4, 12, 24}) {
		set_plane_byte(&v, 0, row * 80, 0xF0)
		set_plane_byte(&v, 1, row * 80, 0x0F)
	}
	vga_note_content_change(&v)

	split := raster_journal_test_line_ns(&v, 12)
	_ = vga_in(&v, 0x3DA)
	raster_journal_test_out(&v, split, 0x3C0, 0x01)
	raster_journal_test_out(&v, split, 0x3C0, 0x02)
	raster_journal_test_out(&v, split, 0x3C0, 0x20)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	if !testing.expect_value(t, descriptor.journal.count, u32(3)) {return}
	expected := [3]Raster_Delta {
		{line = 12, index = 0, kind = .Palette_Source, value = 0, previous = 1},
		{line = 12, index = 1, kind = .Attribute_Palette, value = 2, previous = 1},
		{line = 12, index = 0, kind = .Palette_Source, value = 1, previous = 0},
	}
	for entry, i in expected {testing.expect_value(t, descriptor.journal.entries[i], entry)}

	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	// Above the split the two indices still resolve differently.
	testing.expect(t, frame.pixels[4 * 640 + 0] != frame.pixels[4 * 640 + 4])
	// Below it index 1 resolves through the entry index 2 already used.
	testing.expect_value(t, frame.pixels[24 * 640 + 0], frame.pixels[24 * 640 + 4])
	testing.expect_value(t, frame.pixels[24 * 640 + 0], frame.pixels[4 * 640 + 4])
	// The whole dance fits inside one scan line, so that row is not blanked and
	// already shows the new palette.
	testing.expect(t, frame.pixels[12 * 640 + 0] != 0xFF00_0000)
	testing.expect_value(t, frame.pixels[12 * 640 + 0], frame.pixels[12 * 640 + 4])
}

// Held open across scan lines, the same dance blanks every row it covers, which
// is what the hardware shows and why the Palette Address Source is journalled
// alongside the palette itself.
@(test)
raster_journal_test_palette_source_blanks_the_rows_it_is_held_off_for :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	raster_journal_test_planar(&v)
	for row in ([3]int{4, 16, 24}) {
		set_plane_byte(&v, 0, row * 80, 0xF0)
		set_plane_byte(&v, 1, row * 80, 0x0F)
	}
	vga_note_content_change(&v)

	_ = vga_in(&v, 0x3DA)
	raster_journal_test_out(&v, raster_journal_test_line_ns(&v, 12), 0x3C0, 0x01)
	raster_journal_test_out(&v, raster_journal_test_line_ns(&v, 12), 0x3C0, 0x02)
	raster_journal_test_out(&v, raster_journal_test_line_ns(&v, 20), 0x3C0, 0x20)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	if !testing.expect(t, scanout_descriptor_capture(&descriptor, &v)) {return}
	if !testing.expect_value(t, descriptor.journal.count, u32(3)) {return}
	testing.expect_value(t, descriptor.journal.entries[2].line, u16(20))

	frame := scanout_test_expand_legacy(&descriptor)
	if !testing.expect(t, frame != nil) {return}
	// Before the source is cleared the old palette is still on screen.
	testing.expect(t, frame.pixels[4 * 640 + 0] != frame.pixels[4 * 640 + 4])
	testing.expect(t, frame.pixels[4 * 640 + 0] != 0xFF00_0000)
	// While it is clear the display is blank, image content or not.
	testing.expect_value(t, frame.pixels[16 * 640 + 0], u32(0xFF00_0000))
	testing.expect_value(t, frame.pixels[16 * 640 + 4], u32(0xFF00_0000))
	// Once restored the new palette is live.
	testing.expect_value(t, frame.pixels[24 * 640 + 0], frame.pixels[24 * 640 + 4])
	testing.expect_value(t, frame.pixels[24 * 640 + 0], frame.pixels[4 * 640 + 4])
}
