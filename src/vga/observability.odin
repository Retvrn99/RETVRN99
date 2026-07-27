// SPDX-License-Identifier: GPL-3.0-only
package vga

Vga_Mode_Observability :: struct {
	scanout_generation:                    u64,
	kind:                                  Display_Kind,
	width:                                 int,
	height:                                int,
	vbe_enabled:                           bool,
	vbe_bpp_raw:                           u16,
	vbe_bpp_effective:                     u16,
	vbe_pitch_bytes_derived:               int,
	bank_read:                             u16,
	bank_write:                            u16,
	legacy_display_start_register_raw:     u16,
	legacy_display_start_latched:          u16,
	legacy_display_start_pending:          u16,
	legacy_display_start_pending_valid:    bool,
	legacy_display_start_selected_derived: u16,
	vbe_x_offset_raw:                      u16,
	vbe_y_offset_raw:                      u16,
	vbe_display_start_byte_offset_derived: u64,
	vbe_display_start_bit_offset_derived:  u8,
	vbe_display_start_derived_valid:       bool,
	bank_program_count:                    u64,
	bank_change_count:                     u64,
	bank_read_change_count:                u64,
	bank_write_change_count:               u64,
	io_write_count:                        u64,
	io_write_bytes:                        u64,
	raster_journal_entries:                u32,
	raster_journal_truncated:              bool,
	raster_journal_truncations:            u64,
}

vga_mode_observability :: proc(v: ^Vga) -> Vga_Mode_Observability {
	if v == nil {return {}}
	kind, width, height := display_geometry(v)
	raw_bpp := v.dispi[DISPI_INDEX_BPP]
	effective_bpp := dispi_effective_bpp(raw_bpp)
	pitch := vga_vbe_pitch(v)
	result := Vga_Mode_Observability {
		scanout_generation                    = v.content_generation,
		kind                                  = kind,
		width                                 = width,
		height                                = height,
		vbe_enabled                           = vga_vbe_enabled(v),
		vbe_bpp_raw                           = raw_bpp,
		vbe_bpp_effective                     = effective_bpp,
		vbe_pitch_bytes_derived               = pitch,
		bank_read                             = v.bank_read,
		bank_write                            = v.bank_write,
		legacy_display_start_register_raw     = u16(v.crtc[0x0C]) << 8 | u16(v.crtc[0x0D]),
		legacy_display_start_latched          = v.latched_start,
		legacy_display_start_pending          = v.pending_start,
		legacy_display_start_pending_valid    = v.start_pending,
		legacy_display_start_selected_derived = display_start(v),
		vbe_x_offset_raw                      = v.dispi[DISPI_INDEX_X_OFFSET],
		vbe_y_offset_raw                      = v.dispi[DISPI_INDEX_Y_OFFSET],
		bank_program_count                    = v.bank_program_count,
		bank_change_count                     = v.bank_change_count,
		bank_read_change_count                = v.bank_read_change_count,
		bank_write_change_count               = v.bank_write_change_count,
		io_write_count                        = v.io_write_count,
		io_write_bytes                        = v.io_write_bytes,
		raster_journal_entries                = v.raster_journal.count,
		raster_journal_truncated              = v.raster_journal.truncated,
		raster_journal_truncations            = v.raster_journal_truncations,
	}
	if !result.vbe_enabled || pitch <= 0 {return result}
	x := u64(result.vbe_x_offset_raw)
	y := u64(result.vbe_y_offset_raw)
	result.vbe_display_start_derived_valid = true
	result.vbe_display_start_byte_offset_derived = y * u64(pitch)
	if effective_bpp == 4 {
		result.vbe_display_start_byte_offset_derived += x / 8
		result.vbe_display_start_bit_offset_derived = u8(x & 7)
	} else {
		result.vbe_display_start_byte_offset_derived += x * u64((effective_bpp + 7) / 8)
	}
	return result
}

Gsw2d_Observability :: struct {
	metrics:         Gsw_Vga_Metrics,
	completed_fence: u64,
}

gsw2d_observability :: proc(g: ^Gsw_Vga) -> Gsw2d_Observability {
	if g == nil {return {}}
	return {metrics = g.metrics, completed_fence = g.completed_fence}
}
