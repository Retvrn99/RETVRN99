// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
vga_observability_test_vbe_mode_start_and_bank_counts :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 320, 200, 16))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 640))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 4))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_Y_OFFSET, 3))

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 2 | DISPI_BANK_WR))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 2 | DISPI_BANK_WR))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 1 | DISPI_BANK_RD))
	io_writes_before := v.io_write_count
	io_write_bytes_before := v.io_write_bytes
	vga_io_write(&v, 0x3C2, 1, 0x67)
	vga_io_write(&v, DISPI_PORT_INDEX, 2, DISPI_INDEX_XRES)

	mode := vga_mode_observability(&v)
	testing.expect_value(t, mode.kind, Display_Kind.Rgb_565)
	testing.expect_value(t, mode.width, 320)
	testing.expect_value(t, mode.height, 200)
	testing.expect(t, mode.vbe_enabled)
	testing.expect_value(t, mode.vbe_bpp_raw, u16(16))
	testing.expect_value(t, mode.vbe_bpp_effective, u16(16))
	testing.expect_value(t, mode.vbe_pitch_bytes_derived, 1280)
	testing.expect_value(t, mode.vbe_x_offset_raw, u16(4))
	testing.expect_value(t, mode.vbe_y_offset_raw, u16(3))
	testing.expect(t, mode.vbe_display_start_derived_valid)
	testing.expect_value(t, mode.vbe_display_start_byte_offset_derived, u64(3 * 1280 + 8))
	testing.expect_value(t, mode.vbe_display_start_bit_offset_derived, u8(0))
	testing.expect_value(t, mode.bank_read, u16(1))
	testing.expect_value(t, mode.bank_write, u16(2))
	testing.expect_value(t, mode.bank_program_count, u64(3))
	testing.expect_value(t, mode.bank_change_count, u64(2))
	testing.expect_value(t, mode.bank_read_change_count, u64(1))
	testing.expect_value(t, mode.bank_write_change_count, u64(1))
	testing.expect_value(t, mode.io_write_count, io_writes_before + 2)
	testing.expect_value(t, mode.io_write_bytes, io_write_bytes_before + 3)
}

@(test)
vga_observability_test_counts_disabled_and_zero_width_io_writes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.pci_io_enabled = false

	vga_io_write(&v, 0x3C2, 0, 0)
	vga_io_write(&v, 0x3C2, 4, 0)

	mode := vga_mode_observability(&v)
	testing.expect_value(t, mode.io_write_count, u64(2))
	testing.expect_value(t, mode.io_write_bytes, u64(5))
}

@(test)
vga_observability_test_legacy_start_stays_raw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.crtc[0x0C] = 0x56
	v.crtc[0x0D] = 0x78
	v.latched_start = 0x1234
	v.pending_start = 0x4321
	v.start_pending = true

	mode := vga_mode_observability(&v)
	testing.expect(t, !mode.vbe_enabled)
	testing.expect_value(t, mode.legacy_display_start_register_raw, u16(0x5678))
	testing.expect_value(t, mode.legacy_display_start_latched, u16(0x1234))
	testing.expect_value(t, mode.legacy_display_start_pending, u16(0x4321))
	testing.expect(t, mode.legacy_display_start_pending_valid)
	testing.expect_value(t, mode.legacy_display_start_selected_derived, u16(0x4321))
	testing.expect(t, !mode.vbe_display_start_derived_valid)
}
