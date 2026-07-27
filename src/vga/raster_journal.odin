// SPDX-License-Identifier: GPL-3.0-only
package vga

// Mid-frame register changes travel to the host as an ordered journal of typed
// deltas stamped with the scan line they take effect on (ADR 0012). Replay is
// pure state mutation, so host expansion gains no timing, damage, or interrupt
// side effects. This slice carries DAC entries and nothing else.

// A full 256-entry DAC reload is 768 byte writes, and a three-byte-per-scan-line
// effect across a 480-line frame is 1,440. The cap holds either with headroom
// and costs 16 KiB per journal. Overflow degrades to today's whole-frame
// expansion, so the cap trades memory for fidelity and nothing else.
RASTER_JOURNAL_MAX_ENTRIES :: 2048

Raster_Delta_Kind :: enum u8 {
	Dac_Entry,
	// Attribute Controller 13h horizontal PEL panning.
	Pel_Pan,
	// CRT Controller 08h. Preset row scan shares the byte and travels with it.
	Byte_Pan,
	// Attribute Controller 00h-0Fh internal palette, index is the register.
	Attribute_Palette,
	// The Palette Address Source bit of the Attribute address register. Clearing
	// it is what lets software reach the internal palette, and it blanks the
	// display while clear, so the two kinds only make sense together.
	Palette_Source,
}

// index is a DAC byte index, so entry n component c is n * 3 + c. It is unused
// by the single-register kinds, which carry the whole byte in value. previous is
// the value the write replaced; it lets the host wind the state back to its
// frame-start value without the journal carrying a register snapshot.
Raster_Delta :: struct {
	line:     u16,
	index:    u16,
	kind:     Raster_Delta_Kind,
	value:    u8,
	previous: u8,
}

Raster_Journal :: struct {
	frame:     u64,
	count:     u32,
	truncated: bool,
	entries:   [RASTER_JOURNAL_MAX_ENTRIES]Raster_Delta,
}

@(private = "package")
raster_journal_active :: proc(journal: ^Raster_Journal) -> bool {
	return journal != nil && !journal.truncated && journal.count > 0
}

@(private = "file")
raster_journal_frame :: proc(v: ^Vga) -> u64 {
	return v.timing.elapsed_ns / max(v.timing.frame_period_ns, u64(1))
}

// The expansion scan line the current device time falls on, mapped from
// physical lines to image rows exactly as the VM-side raster path does.
@(private = "file")
raster_journal_line :: proc(v: ^Vga) -> (int, bool) {
	if v.timing.frame_period_ns == 0 || v.timing.line_period_ns == 0 {return 0, false}
	if v.timing.visible_lines <= 0 {return 0, false}
	physical := int((v.timing.elapsed_ns % v.timing.frame_period_ns) / v.timing.line_period_ns)
	// A delta on the first row covers the whole frame, which the final register
	// state the descriptor already carries describes exactly. Past the last
	// visible row the write belongs to the next frame.
	if physical <= 0 || physical >= v.timing.visible_lines {return 0, false}
	kind, width, height := display_geometry(v)
	if kind == .Invalid || width <= 0 || height <= 0 {return 0, false}
	line := physical * height / v.timing.visible_lines
	if line <= 0 || line >= height {return 0, false}
	return line, true
}

// Every legacy mode the Attribute Controller drives. VBE reads the DAC directly
// and the CGA persona has its own colour path, so neither observes it.
@(private = "file")
raster_journal_attribute_mode :: proc(v: ^Vga) -> bool {
	if vga_vbe_enabled(v) || v.cga.active {return false}
	mode, _, _ := display_geometry(v)
	return mode != .Invalid
}

// Only a delta the current mode can show is worth carrying. Panning reaches the
// legacy address generator alone, which VBE and the CGA persona both bypass.
@(private = "file")
raster_delta_observable :: proc(v: ^Vga, kind: Raster_Delta_Kind) -> bool {
	switch kind {
	case .Dac_Entry:
		return video_output_enabled(v) && vga_damage_uses_palette(v)
	case .Pel_Pan, .Byte_Pan:
		if !video_output_enabled(v) || vga_vbe_enabled(v) || v.cga.active {return false}
		mode, _, _ := display_geometry(v)
		return mode == .Text || mode == .Planar_4 || mode == .Indexed_8
	case .Attribute_Palette, .Palette_Source:
		// These two are the only kinds allowed to land while output is disabled.
		// Reaching the internal palette requires clearing the Palette Address
		// Source, which blanks the display, so recording the blank is the point
		// rather than something to filter out.
		return raster_journal_attribute_mode(v)
	}
	return false
}

@(private = "package")
raster_journal_record :: proc(v: ^Vga, kind: Raster_Delta_Kind, index: u16, previous, value: u8) {
	if v == nil || previous == value {return}
	line, inside := raster_journal_line(v)
	if !inside || !raster_delta_observable(v, kind) {return}
	journal := &v.raster_journal
	frame := raster_journal_frame(v)
	if journal.frame != frame {
		journal.frame = frame
		journal.count = 0
		journal.truncated = false
	}
	if journal.truncated {return}
	if journal.count >= RASTER_JOURNAL_MAX_ENTRIES {
		journal.count = 0
		journal.truncated = true
		v.raster_journal_truncations += 1
		return
	}
	journal.entries[journal.count] = {
		line     = u16(line),
		index    = index,
		kind     = kind,
		value    = value,
		previous = previous,
	}
	journal.count += 1
}

// Descriptor capture is not beam synchronized, so the journal of the frame
// immediately before the captured one still describes the split a guest repeats
// every frame. Anything older is stale and is dropped, which returns the frame
// to plain final-state expansion within two frames of the guest stopping.
@(private = "package")
raster_journal_capture :: proc(destination: ^Raster_Journal, v: ^Vga) {
	if destination == nil {return}
	destination.frame = 0
	destination.count = 0
	destination.truncated = false
	if v == nil {return}
	source := &v.raster_journal
	if source.count == 0 && !source.truncated {return}
	if raster_journal_frame(v) > source.frame + 1 {return}
	destination.frame = source.frame
	destination.truncated = source.truncated
	destination.count = source.count
	for i in 0 ..< int(source.count) {destination.entries[i] = source.entries[i]}
}

@(private = "file")
raster_delta_apply :: proc(v: ^Vga, delta: Raster_Delta, value: u8) {
	switch delta.kind {
	case .Dac_Entry:
		if int(delta.index) < len(v.dac) {v.dac[delta.index] = value}
	case .Pel_Pan:
		v.attr[0x13] = value
	case .Byte_Pan:
		v.crtc[0x08] = value
	case .Attribute_Palette:
		if int(delta.index) < 0x10 {v.attr[delta.index] = value}
	case .Palette_Source:
		// render_scanline_span already blanks a row whose output is disabled, so
		// replaying the bit is all the blank band needs.
		v.video_on = value != 0
	}
}

// Winds the reconstructed state back to its frame-start values, re-applies each
// delta as expansion reaches its scan line, and leaves the state final again.
// Entries are recorded in device-time order, so their scan lines ascend.
@(private = "package")
raster_journal_render :: proc(
	v: ^Vga,
	journal: ^Raster_Journal,
	pixels: []u32,
	kind: Display_Kind,
	width, height: int,
) {
	count := int(journal.count)
	for i := count - 1; i >= 0; i -= 1 {
		raster_delta_apply(v, journal.entries[i], journal.entries[i].previous)
	}
	next := 0
	for y in 0 ..< height {
		for next < count && int(journal.entries[next].line) <= y {
			raster_delta_apply(v, journal.entries[next], journal.entries[next].value)
			next += 1
		}
		render_scanline(v, pixels, kind, width, height, y)
	}
	for next < count {
		raster_delta_apply(v, journal.entries[next], journal.entries[next].value)
		next += 1
	}
}
