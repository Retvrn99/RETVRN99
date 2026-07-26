// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// Every DISPI feature level RETVRN99 accepts.
@(private = "file")
DISPI_IDS := [?]u16{DISPI_ID0, DISPI_ID1, DISPI_ID2, DISPI_ID3, DISPI_ID4, DISPI_ID5}

// The selected ID gates capability, never capacity. See ADR 0011.
@(test)
vga_test_dispi_memory_size_is_reported_at_every_id :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	expected := u16(VRAM_SIZE / 65536)
	for id in DISPI_IDS {
		if !testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ID, id)) {continue}
		testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_ID), id)
		// The register never reads as open bus and never reports a Bochs-era
		// per-ID ceiling, so a guest at any feature level discovers the truth.
		testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_VIDEO_MEMORY_64K), expected)
		testing.expect(t, dispi_read_register(&v, DISPI_INDEX_VIDEO_MEMORY_64K) != 0xFFFF)
	}
}

// The register is read only at every level.
@(test)
vga_test_dispi_memory_size_register_rejects_writes :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	expected := u16(VRAM_SIZE / 65536)
	for id in DISPI_IDS {
		testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ID, id))
		testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_VIDEO_MEMORY_64K, 1))
		testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_VIDEO_MEMORY_64K), expected)
	}
}

// Capability still follows the Bochs ladder even though capacity does not.
@(test)
vga_test_dispi_feature_ladder_follows_selected_id :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	for id in DISPI_IDS {
		testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ID, id))
		mask := dispi_enable_mask(&v)
		lfb := mask & (DISPI_LFB_ENABLED | DISPI_NOCLEARMEM)
		caps := mask & (DISPI_GETCAPS | DISPI_8BIT_DAC)
		banks := mask & DISPI_BANK_GRANULARITY_32K
		testing.expect_value(
			t,
			lfb,
			id >= DISPI_ID2 ? DISPI_LFB_ENABLED | DISPI_NOCLEARMEM : u16(0),
		)
		testing.expect_value(t, caps, id >= DISPI_ID3 ? DISPI_GETCAPS | DISPI_8BIT_DAC : u16(0))
		testing.expect_value(t, banks, id >= DISPI_ID5 ? DISPI_BANK_GRANULARITY_32K : u16(0))
		// DDC remains gated at ID5, unlike the memory-size register.
		testing.expect_value(
			t,
			dispi_read_register(&v, DISPI_INDEX_DDC) != 0xFFFF,
			id >= DISPI_ID5,
		)
	}
}

// Only the documented Bochs identifiers are selectable.
@(test)
vga_test_dispi_id_range_is_bounded :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_ID, DISPI_ID0 - 1))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_ID, DISPI_ID5 + 1))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_ID, 0))
	// A rejected write must leave the previously negotiated level intact.
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ID, DISPI_ID4))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_ID, DISPI_ID5 + 1))
	testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_ID), DISPI_ID4)
}
