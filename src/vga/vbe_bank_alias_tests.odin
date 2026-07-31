// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
vga_test_vbe_bank_alias_tracks_packed_pixel_bank :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 800, 600, 32))

	alias, available := vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	testing.expect_value(t, alias, Vbe_Bank_Alias{offset = 0, size = DISPI_BANK_SIZE})

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 3))
	alias, available = vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	testing.expect_value(t, alias.offset, 3 * DISPI_BANK_GRANULARITY)
}

@(test)
vga_test_vbe_bank_alias_rejects_semantically_complex_modes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	_, available := vga_vbe_bank_alias(&v)
	testing.expect(t, !available)
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 4))
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, !available)

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ENABLE, 0))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BPP, 8))
	testing.expect(
		t,
		dispi_write_register(
			&v,
			DISPI_INDEX_ENABLE,
			DISPI_ENABLED | DISPI_NOCLEARMEM | DISPI_BANK_GRANULARITY_32K,
		),
	)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, DISPI_BANK_WR | 1))
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, !available)

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, DISPI_BANK_RD | 1))
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	vga_out(&v, 0x3C3, 0)
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, !available)
	vga_out(&v, 0x3C3, 1)
	vga_out(&v, 0x3C2, v.misc & ~u8(0x02))
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, !available)
	vga_out(&v, 0x3C2, v.misc | 0x02)
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	vga_set_pci_decode(&v, true, false, VBE_LFB_BASE)
	_, available = vga_vbe_bank_alias(&v)
	testing.expect(t, !available)
}

@(test)
vga_test_external_vbe_dirty_publication_accepts_banked_mode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8))

	generation := v.content_generation
	testing.expect(t, !vga_publish_external_vbe_writes(&v, false))
	testing.expect_value(t, v.content_generation, generation)
	testing.expect(t, vga_publish_external_vbe_writes(&v, true))
	testing.expect_value(t, v.content_generation, generation + 1)
}

@(test)
vga_test_external_backing_dirty_invalidates_cached_frame_during_raster_fallback :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8)) {return}
	v.raster_fallback = true
	v.frame_valid = true
	content_generation := v.content_generation
	presentation_sequence := v.legacy_presentation_sequence

	testing.expect(t, vga_publish_external_backing_writes(&v, true))
	testing.expect(t, !v.frame_valid)
	testing.expect_value(t, v.content_generation, content_generation + 1)
	testing.expect(t, v.legacy_presentation_sequence != presentation_sequence)
}
