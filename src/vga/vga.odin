// SPDX-License-Identifier: GPL-3.0-only
package vga

import persona "../persona"
import contract "../presentation"

import "base:runtime"

VRAM_SIZE :: persona.GUEST_PERSONA.vram_bytes
LEGACY_PLANE_SIZE :: 64 * 1024
LEGACY_APERTURE_BASE :: u64(0x000A0000)
LEGACY_APERTURE_END :: u64(0x000C0000)
VBE_LFB_BASE :: u64(0xE0000000)
VBE_LFB_END :: VBE_LFB_BASE + u64(VRAM_SIZE)

Display_Kind :: enum {
	Invalid,
	Text,
	Planar_4,
	Cga_1,
	Cga_2,
	Indexed_8,
	Rgb_555,
	Rgb_565,
	Rgb_888,
	Xrgb_8888,
}

TEXT_SNAPSHOT_DEFAULT_COLUMNS :: 80
TEXT_SNAPSHOT_DEFAULT_ROWS :: 25
TEXT_SNAPSHOT_MAX_COLUMNS :: 80
TEXT_SNAPSHOT_MAX_ROWS :: 50

Text_Snapshot :: struct {
	columns:    int,
	rows:       int,
	cell_count: int,
	cells:      [TEXT_SNAPSHOT_MAX_COLUMNS * TEXT_SNAPSHOT_MAX_ROWS]u16,
	cursor_row: int,
	cursor_col: int,
	cursor_on:  bool,
}

text_snapshot_columns :: proc(snapshot: ^Text_Snapshot) -> int {
	if snapshot == nil || snapshot.columns <= 0 {return TEXT_SNAPSHOT_DEFAULT_COLUMNS}
	return clamp(snapshot.columns, 1, TEXT_SNAPSHOT_MAX_COLUMNS)
}

text_snapshot_rows :: proc(snapshot: ^Text_Snapshot) -> int {
	if snapshot == nil || snapshot.rows <= 0 {return TEXT_SNAPSHOT_DEFAULT_ROWS}
	return clamp(snapshot.rows, 1, TEXT_SNAPSHOT_MAX_ROWS)
}

text_snapshot_cell_count :: proc(snapshot: ^Text_Snapshot) -> int {
	if snapshot == nil {return TEXT_SNAPSHOT_DEFAULT_COLUMNS * TEXT_SNAPSHOT_DEFAULT_ROWS}
	if snapshot.cell_count > 0 {
		return clamp(snapshot.cell_count, 0, TEXT_SNAPSHOT_MAX_COLUMNS * TEXT_SNAPSHOT_MAX_ROWS)
	}
	return text_snapshot_columns(snapshot) * text_snapshot_rows(snapshot)
}

text_snapshot_cell_index :: proc(snapshot: ^Text_Snapshot, row, column: int) -> int {
	return row * text_snapshot_columns(snapshot) + column
}

text_snapshot_equal :: proc(a, b: ^Text_Snapshot) -> bool {
	if a == nil || b == nil {return a == b}
	if a.columns != b.columns ||
	   a.rows != b.rows ||
	   a.cell_count != b.cell_count ||
	   a.cursor_row != b.cursor_row ||
	   a.cursor_col != b.cursor_col ||
	   a.cursor_on != b.cursor_on {
		return false
	}
	count := max(text_snapshot_cell_count(a), text_snapshot_cell_count(b))
	for i in 0 ..< count {
		if a.cells[i] != b.cells[i] {return false}
	}
	return true
}

Display_Frame :: struct {
	kind:                      Display_Kind,
	width:                     int,
	height:                    int,
	aspect_width:              int,
	aspect_height:             int,
	generation:                u64,
	content_generation:        u64,
	guest_activity_generation: u64,
	pixels:                    []u32,
	text:                      Text_Snapshot,
	dirty:                     contract.Rect_Set,
	updated_pixels:            u64,
	// Attribute Controller 11h resolved through the palette and DAC. The
	// border is outside the active image, so presentation paints the surround
	// with it rather than a fixed black.
	overscan:                  u32,
}

Legacy_Irq_Proc :: proc(ctx: rawptr, asserted: bool)

Video_Timing :: struct {
	elapsed_ns:      u64,
	frame_period_ns: u64,
	line_period_ns:  u64,
	total_lines:     int,
	visible_lines:   int,
	visible_dots:    int,
	total_dots:      int,
	hblank_start:    int,
	hblank_end:      int,
	hretrace_start:  int,
	hretrace_end:    int,
	vblank_start:    int,
	vblank_end:      int,
	retrace_start:   int,
	retrace_end:     int,
	generation:      u64,
}

Vga :: struct {
	allocator:                              runtime.Allocator,
	vram:                                   []u8,
	pci_io_enabled:                         bool,
	pci_memory_enabled:                     bool,
	framebuffer_base:                       u64,
	frame_pixels:                           []u32,
	frame:                                  Display_Frame,
	raster_pixels:                          []u32,
	raster_kind:                            Display_Kind,
	raster_width:                           int,
	raster_height:                          int,
	raster_next_line:                       int,
	raster_frame:                           u64,
	raster_valid:                           bool,
	raster_fallback:                        bool,
	raster_change_frame:                    u64,
	raster_journal:                         Raster_Journal,
	raster_journal_truncations:             u64,
	defer_scanout_conversion:               bool,
	frame_valid:                            bool,
	present_generation:                     u64,
	content_generation:                     u64,
	guest_activity_generation:              u64,
	presentation_sequence:                  u64,
	legacy_presentation_sequence:           u64,
	presentation_mode_clock:                contract.Mode_Clock,
	legacy_presentation_mode_generation:    u64,
	legacy_presentation_mode_key:           contract.Mode_Key,
	legacy_presentation_surface_generation: u64,
	legacy_presentation_surface_key:        contract.Mode_Key,
	legacy_damage:                          Vga_Damage_State,
	legacy_damage_batch_count:              u32,
	legacy_damage_batches:                  [VGA_DAMAGE_MAX_BATCHES]Vga_Damage_Batch,
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
	ddc_host_scl_release:                   bool,
	ddc_host_sda_release:                   bool,
	ddc_drive_sda_low:                      bool,
	ddc_phase:                              Ddc_Phase,
	ddc_after_ack_phase:                    Ddc_Phase,
	ddc_bit_count:                          int,
	ddc_shift:                              u8,
	ddc_offset:                             u8,
	ddc_read_byte:                          u8,
	ddc_read_bit:                           int,
	ddc_master_ack:                         bool,
	timing:                                 Video_Timing,
	latched_start:                          u16,
	pending_start:                          u16,
	start_pending:                          bool,
	legacy_irq_ctx:                         rawptr,
	legacy_irq:                             Legacy_Irq_Proc,
	legacy_irq_asserted:                    bool,
	vertical_interrupt_pending:             bool,
	initialized:                            bool,
}

vga_init :: proc(v: ^Vga, backing: []u8) -> bool {
	if len(backing) < VRAM_SIZE {return false}
	if v.initialized {vga_destroy(v)}
	v^ = {}
	v.allocator = context.allocator
	v.vram = backing[:VRAM_SIZE]
	v.pci_io_enabled = true
	v.pci_memory_enabled = true
	v.framebuffer_base = VBE_LFB_BASE
	v.frame_pixels = make([]u32, 0, v.allocator)
	v.initialized = true
	vga_reset(v)
	return true
}

vga_set_pci_decode :: proc(
	v: ^Vga,
	io_space_enabled, memory_space_enabled: bool,
	framebuffer_base: u64,
) {
	if v == nil {return}
	v.pci_io_enabled = io_space_enabled
	v.pci_memory_enabled = memory_space_enabled
	v.framebuffer_base = framebuffer_base
}

vga_framebuffer_base :: proc(v: ^Vga) -> u64 {
	return v == nil ? u64(0) : v.framebuffer_base
}

vga_destroy :: proc(v: ^Vga) {
	if v.frame_pixels != nil {delete(v.frame_pixels, v.allocator)}
	if v.raster_pixels != nil {delete(v.raster_pixels, v.allocator)}
	v^ = {}
}

vga_vram :: proc(v: ^Vga) -> []u8 {
	return v.vram
}

vga_set_deferred_scanout :: proc(v: ^Vga, deferred: bool) {
	if v == nil {return}
	v.defer_scanout_conversion = deferred
	if deferred {
		v.raster_valid = false
		v.frame_valid = false
	}
}

vga_reset :: proc(v: ^Vga) {
	// Power-on values describe the conventional 80x25 color text mode. The
	// option ROM will replace these while setting its first mode.
	v.seq = {}
	v.seq[0] = 0x03
	v.seq[1] = 0x00
	v.seq[2] = 0x03
	v.seq[4] = 0x02
	v.gfx = {}
	v.gfx[5] = 0x10
	v.gfx[6] = 0x0E
	v.gfx[7] = 0x0F
	v.gfx[8] = 0xFF
	v.attr = {}
	for i in 0 ..< 16 {v.attr[i] = u8(i)}
	v.attr[0x10] = 0x08
	v.attr[0x12] = 0x0F
	v.video_on = true
	v.misc = 0x67
	v.pel_mask = 0xFF
	v.video_subsystem_enable = 1
	v.cga = {
		mode_control = CGA_MODE_80_COLUMNS | CGA_MODE_VIDEO_ENABLE | CGA_MODE_BLINK,
	}
	v.crtc = {}
	v.crtc[0x00] = 0x5F
	v.crtc[0x01] = 0x4F
	v.crtc[0x06] = 0xBF
	v.crtc[0x07] = 0x1F
	v.crtc[0x09] = 0x4F
	v.crtc[0x0A] = 0x0D
	v.crtc[0x0B] = 0x0E
	v.crtc[0x10] = 0x9C
	v.crtc[0x11] = 0x8E
	v.crtc[0x12] = 0x8F
	v.crtc[0x13] = 0x28
	v.crtc[0x15] = 0x96
	v.crtc[0x16] = 0xB9
	v.crtc[0x17] = 0xA3
	v.crtc[0x18] = 0xFF
	vga_init_dac(v)
	v.dispi = {}
	v.dispi[DISPI_INDEX_ID] = DISPI_ID5
	v.dispi[DISPI_INDEX_XRES] = 640
	v.dispi[DISPI_INDEX_YRES] = 480
	v.dispi[DISPI_INDEX_BPP] = 8
	v.dispi[DISPI_INDEX_VIRT_WIDTH] = 640
	v.dispi[DISPI_INDEX_VIRT_HEIGHT] = u16(min(VRAM_SIZE / 640, 0xFFFF))
	v.dispi[DISPI_INDEX_VIDEO_MEMORY_64K] = u16(VRAM_SIZE / 65536)
	ddc_reset(v)
	v.latched_start = 0
	v.pending_start = 0
	v.vertical_interrupt_pending = false
	v.timing = {}
	v.legacy_damage = {}
	v.raster_journal.count = 0
	v.raster_journal.truncated = false
	v.legacy_damage_batch_count = 0
	v.legacy_damage_batches = {}
	v.content_generation = 1
	v.guest_activity_generation = 1
	v.presentation_sequence = 1
	v.legacy_presentation_sequence = 1
	vga_recalculate_timing(v)
	_ = vga_legacy_presentation_mode_generation(v, true)
	vga_damage_record_full(v, .Pixel_Memory, .Initial_Surface)
	vga_refresh_legacy_irq(v)
}

@(private = "file")
vga_advance_presentation_sequence :: proc(v: ^Vga) -> u64 {
	if v == nil {return 0}
	v.presentation_sequence += 1
	if v.presentation_sequence == 0 {v.presentation_sequence = 1}
	return v.presentation_sequence
}

vga_note_gsw_presentation :: proc(v: ^Vga) -> u64 {
	return vga_advance_presentation_sequence(v)
}

vga_presentation_sequence :: proc(v: ^Vga) -> u64 {
	return v == nil ? u64(0) : v.presentation_sequence
}

vga_note_content_change :: proc(v: ^Vga) {
	if v == nil {return}
	vga_damage_record_full(v, .Pixel_Memory, .Ambiguous_Mapping)
	vga_note_recorded_change(v, true)
}

@(private = "package")
vga_note_recorded_change :: proc(v: ^Vga, guest_activity: bool) {
	if v == nil {return}
	v.legacy_presentation_sequence = vga_advance_presentation_sequence(v)
	_ = vga_legacy_presentation_mode_generation(v)
	v.content_generation += 1
	if v.content_generation == 0 {v.content_generation = 1}
	if guest_activity {
		v.guest_activity_generation += 1
		if v.guest_activity_generation == 0 {v.guest_activity_generation = 1}
	}
	if !v.raster_fallback {v.frame_valid = false}
}

@(private = "package")
vga_note_memory_change :: proc(v: ^Vga) {
	vga_note_recorded_change(v, true)
}

@(private = "package")
vga_note_palette_change :: proc(v: ^Vga) {
	if v == nil || !vga_damage_record_palette(v) {return}
	vga_note_recorded_change(v, true)
}

vga_set_legacy_irq :: proc(v: ^Vga, ctx: rawptr, irq: Legacy_Irq_Proc) {
	if v == nil {return}
	if v.legacy_irq != nil && v.legacy_irq_asserted {
		v.legacy_irq(v.legacy_irq_ctx, false)
	}
	v.legacy_irq_ctx = ctx
	v.legacy_irq = irq
	v.legacy_irq_asserted = false
	vga_refresh_legacy_irq(v)
}

vga_legacy_irq_line :: proc(v: ^Vga) -> bool {
	return v != nil && v.legacy_irq_asserted
}

vga_note_animation_change :: proc(v: ^Vga) {
	if v == nil {return}
	kind, _, _ := display_geometry(v)
	if kind != .Text || !video_output_enabled(v) {return}
	vga_damage_record_full(v, .Pixel_Memory, .Ambiguous_Mapping)
	vga_note_recorded_change(v, false)
}

@(private = "package")
vga_init_dac :: proc(v: ^Vga) {
	base := [16][3]u8 {
		{0x00, 0x00, 0x00},
		{0x00, 0x00, 0x2A},
		{0x00, 0x2A, 0x00},
		{0x00, 0x2A, 0x2A},
		{0x2A, 0x00, 0x00},
		{0x2A, 0x00, 0x2A},
		{0x2A, 0x15, 0x00},
		{0x2A, 0x2A, 0x2A},
		{0x15, 0x15, 0x15},
		{0x15, 0x15, 0x3F},
		{0x15, 0x3F, 0x15},
		{0x15, 0x3F, 0x3F},
		{0x3F, 0x15, 0x15},
		{0x3F, 0x15, 0x3F},
		{0x3F, 0x3F, 0x15},
		{0x3F, 0x3F, 0x3F},
	}
	for i in 0 ..< 16 {
		v.dac[i * 3 + 0] = base[i][0]
		v.dac[i * 3 + 1] = base[i][1]
		v.dac[i * 3 + 2] = base[i][2]
	}
	for i in 16 ..< 256 {
		c := u8(i & 0x3F)
		v.dac[i * 3 + 0] = c
		v.dac[i * 3 + 1] = c
		v.dac[i * 3 + 2] = c
	}
}
