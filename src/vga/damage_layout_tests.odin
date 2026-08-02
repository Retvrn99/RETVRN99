// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:testing"

@(test)
vga_damage_layout_test_vbe_bank_and_lfb_boundaries :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8, DISPI_NOCLEARMEM))

	v.legacy_damage = {}
	testing.expect(t, vga_mmio_write(&v, 0xAFFFF, 1, 0x31))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 1 | DISPI_BANK_WR))
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, 0x32))
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{255, 102, 2, 1})

	v.legacy_damage = {}
	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE + 639, 2, 0x4241))
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(2))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{639, 0, 1, 1})
	testing.expect_value(t, damage.rects.rects[1], contract.Rect{0, 1, 1, 1})
}

@(test)
vga_damage_layout_test_vbe_offsets_and_capture_clipping :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 8))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 2))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_Y_OFFSET, 1))

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 54, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{3, 0, 1, 1})

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 36, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage, contract.Damage_Record{})

	requested: contract.Rect_Set
	requested.count = 1
	requested.rects[0] = {3, 1, 4, 3}
	ranges: Vga_Capture_Range_Set
	testing.expect(t, vga_damage_capture_ranges(&v, requested, &ranges))
	testing.expect_value(t, ranges.count, u32(1))
	testing.expect_value(t, ranges.ranges[0], Vga_Damage_Range{84, 88})
}

@(test)
vga_damage_layout_test_chain_four_crosses_rows_exactly :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_graphics_geometry(&v, 16, 2)
	v.gfx[5] = 0x40
	v.seq[4] = 0x0E
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 7, 2)

	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(t, damage.rects.count, u32(2))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{7, 0, 1, 1})
	testing.expect_value(t, damage.rects.rects[1], contract.Rect{0, 1, 1, 1})
}

@(test)
vga_damage_layout_test_text_odd_even_and_unchanged_store :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.gfx[6] = 0x0E
	v.attr[0x10] &= ~u8(1)
	v.seq[1] = 1
	v.seq[4] = 0x02
	v.crtc[1] = 1
	v.crtc[9] = 7 | 0x40
	v.crtc[0x13] = 1
	v.crtc[0x18] = 0xFF
	v.crtc[7] |= 0x10
	v.timing.visible_dots = 16
	v.timing.visible_lines = 8
	v.legacy_damage = {}

	serial := v.legacy_damage.write_serial
	testing.expect(t, vga_store_backing_byte(&v, 1, v.vram[1]))
	testing.expect_value(t, v.legacy_damage.write_serial, serial)
	testing.expect_value(t, vga_damage_snapshot(&v), contract.Damage_Record{})

	testing.expect(t, vga_store_backing_byte(&v, 1, 0x07))
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 8, 8})

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 8, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{8, 0, 8, 8})
}

@(test)
vga_damage_layout_test_cga_interleaved_scanline_banks :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0, 1)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 0, 4, 1})

	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0x8000, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 1, 4, 1})

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_HIGH_RES | CGA_MODE_VIDEO_ENABLE)
	v.legacy_damage = {}
	_ = vga_damage_record_backing_range(&v, 0x8000, 1)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.rects.count, u32(1))
	testing.expect_value(t, damage.rects.rects[0], contract.Rect{0, 1, 8, 1})
}

@(test)
vga_damage_layout_test_acknowledgement_rejects_each_stale_identity :: proc(t: ^testing.T) {
	v: Vga
	backing := damage_test_vga(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 1, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	v.legacy_damage = {}
	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE, 1, 0x51))
	update := vga_legacy_frame_update(&v)
	testing.expect(t, update.header.sequence != 0)

	testing.expect(
		t,
		!vga_damage_acknowledge_identity(
			&v,
			contract.generation_next(update.header.sequence),
			update.header.mode_generation,
			update.header.surface.id,
			update.header.surface.generation,
		),
	)
	testing.expect(
		t,
		!vga_damage_acknowledge_identity(
			&v,
			update.header.sequence,
			contract.generation_next(update.header.mode_generation),
			update.header.surface.id,
			update.header.surface.generation,
		),
	)
	testing.expect(
		t,
		!vga_damage_acknowledge_identity(
			&v,
			update.header.sequence,
			update.header.mode_generation,
			contract.generation_next(update.header.surface.id),
			update.header.surface.generation,
		),
	)
	testing.expect(t, vga_damage_snapshot(&v).kind != .Invalid)
	testing.expect(
		t,
		vga_damage_acknowledge_identity(
			&v,
			update.header.sequence,
			update.header.mode_generation,
			update.header.surface.id,
			update.header.surface.generation,
		),
	)
	testing.expect_value(t, vga_damage_snapshot(&v), contract.Damage_Record{})
}
