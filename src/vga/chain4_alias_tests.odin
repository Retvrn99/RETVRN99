// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

// The stock BIOS mode 13h register set, reached the way `test_bochs_legacy_mode`
// records it: SR02=0Fh, SR04=0Eh, GR01=00h, GR03=00h, GR05=40h, GR06=05h,
// GR08=FFh.
@(private = "file")
chain4_alias_available :: proc(v: ^Vga) -> bool {
	_, available := vga_vbe_bank_alias(v)
	return available
}

@(test)
vga_test_chain4_alias_covers_stock_mode_13h :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	alias, available := vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	testing.expect_value(t, alias, Vbe_Bank_Alias{offset = 0, size = DISPI_BANK_SIZE})
}

@(test)
vga_test_chain4_alias_needs_pci_memory_decode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	vga_set_pci_decode(&v, true, false, VBE_LFB_BASE)
	testing.expect(t, !chain4_alias_available(&v))
	vga_set_pci_decode(&v, true, true, VBE_LFB_BASE)
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_legacy_video_memory :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// Video subsystem enable, then Miscellaneous Output RAM enable. Either one
	// takes the legacy aperture away from the device.
	vga_out(&v, 0x3C3, 0)
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3C3, 1)
	testing.expect(t, chain4_alias_available(&v))

	vga_out(&v, 0x3C2, v.misc & ~u8(0x02))
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3C2, v.misc | 0x02)
	testing.expect(t, chain4_alias_available(&v))
}

// With DISPI enabled the bank branch owns this range, and it answers with the
// programmed bank rather than the chain 4 identity.
@(test)
vga_test_chain4_alias_yields_to_enabled_dispi :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 2))
	alias, available := vga_vbe_bank_alias(&v)
	testing.expect(t, available)
	testing.expect_value(t, alias.offset, 2 * DISPI_BANK_GRANULARITY)

	// Four bits per pixel is planar under DISPI too, and the bank branch rejects
	// it even though the legacy registers still describe chain 4.
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ENABLE, 0))
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 4))
	testing.expect(t, !chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_chain4 :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// Sequencer 04h with the chain bit cleared is Mode X, where the address no
	// longer selects the plane.
	vga_out(&v, 0x3C4, 0x04)
	vga_out(&v, 0x3C5, v.seq[4] & ~u8(0x08))
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3C5, v.seq[4] | 0x08)
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_window_at_a0000 :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	for select in 0 ..< 4 {
		vga_out(&v, 0x3CE, 0x06)
		vga_out(&v, 0x3CF, (v.gfx[6] & ~u8(0x0C)) | u8(select << 2))
		testing.expect_value(t, chain4_alias_available(&v), select <= 1)
	}
}

@(test)
vga_test_chain4_alias_needs_every_plane_writable :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// Chain 4 narrows the map mask to the plane the address selects, so any
	// cleared bit silently drops one address in four. VirtualBox checks the low
	// two bits only; 03h has to be rejected here.
	for mask in u8(0) ..< u8(0x0F) {
		vga_out(&v, 0x3C4, 0x02)
		vga_out(&v, 0x3C5, mask)
		testing.expect(t, !chain4_alias_available(&v))
	}
	vga_out(&v, 0x3C5, 0x0F)
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_write_mode_zero :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	for mode in u8(1) ..= u8(3) {
		vga_out(&v, 0x3CE, 0x05)
		vga_out(&v, 0x3CF, (v.gfx[5] & ~u8(0x03)) | mode)
		testing.expect(t, !chain4_alias_available(&v))
	}
	vga_out(&v, 0x3CF, v.gfx[5] & ~u8(0x03))
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_read_mode_zero :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// Read mode 1 answers a colour compare rather than the stored byte.
	vga_out(&v, 0x3CE, 0x05)
	vga_out(&v, 0x3CF, v.gfx[5] | 0x08)
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3CF, v.gfx[5] & ~u8(0x08))
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_set_reset_disabled :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	for plane in 0 ..< 4 {
		vga_out(&v, 0x3CE, 0x01)
		vga_out(&v, 0x3CF, u8(1) << uint(plane))
		testing.expect(t, !chain4_alias_available(&v))
	}
	vga_out(&v, 0x3CF, 0)
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_no_rotation_or_logic_op :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// Data Rotate 03h holds both the rotate count and the function select, and
	// neither survives a plain store.
	for value in u8(1) ..= u8(0x1F) {
		vga_out(&v, 0x3CE, 0x03)
		vga_out(&v, 0x3CF, value)
		testing.expect(t, !chain4_alias_available(&v))
	}
	vga_out(&v, 0x3CF, 0)
	testing.expect(t, chain4_alias_available(&v))
}

@(test)
vga_test_chain4_alias_needs_full_bit_mask :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x13)

	// A partial bit mask merges the latches into the result, and the latches are
	// exactly what an aliased write never loads.
	vga_out(&v, 0x3CE, 0x08)
	vga_out(&v, 0x3CF, 0xFE)
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3CF, 0x00)
	testing.expect(t, !chain4_alias_available(&v))
	vga_out(&v, 0x3CF, 0xFF)
	testing.expect(t, chain4_alias_available(&v))
}

@(private = "file")
CHAIN4_IDENTITY_OFFSETS := [?]int {
	0,
	1,
	2,
	3,
	4,
	319,
	320,
	321,
	0x1234,
	0x7FFF,
	0x8000,
	DISPI_BANK_SIZE - 4,
	DISPI_BANK_SIZE - 3,
	DISPI_BANK_SIZE - 2,
	DISPI_BANK_SIZE - 1,
}

// The claim the alias rests on: for a mode 13h configuration a write through the
// graphics controller and a plain store into the backing at the same aperture
// offset leave the same video memory and render the same pixels.
@(test)
vga_test_chain4_aliased_store_matches_emulated_write :: proc(t: ^testing.T) {
	emulated: Vga
	emulated_backing := test_vga_init(t, &emulated)
	defer delete(emulated_backing)
	defer vga_destroy(&emulated)
	aliased: Vga
	aliased_backing := test_vga_init(t, &aliased)
	defer delete(aliased_backing)
	defer vga_destroy(&aliased)
	test_bochs_legacy_mode(&emulated, 0x13)
	test_bochs_legacy_mode(&aliased, 0x13)
	testing.expect(t, chain4_alias_available(&emulated))

	for offset, index in CHAIN4_IDENTITY_OFFSETS {
		value := u8(0x11 * u8(index + 1) ~ 0x3C)
		data := [1]u8{value}
		testing.expect(t, vga_aperture_access(&emulated, 0xA0000 + u64(offset), true, data[:], 0))
		// What the hypervisor does once the range is plain writable memory.
		aliased_backing[offset] = value
	}

	for byte, index in emulated_backing {
		if !testing.expect_value(t, byte, aliased_backing[index]) {return}
	}

	// And the read side: the aperture answers with the byte the alias exposes.
	for offset in CHAIN4_IDENTITY_OFFSETS {
		data := [1]u8{0}
		testing.expect(t, vga_aperture_access(&emulated, 0xA0000 + u64(offset), false, data[:], 0))
		testing.expect_value(t, data[0], aliased_backing[offset])
	}

	emulated_frame := vga_display_frame(&emulated)
	aliased_frame := vga_display_frame(&aliased)
	testing.expect_value(t, emulated_frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, emulated_frame.width, 320)
	testing.expect_value(t, emulated_frame.height, 200)
	testing.expect_value(t, aliased_frame.kind, emulated_frame.kind)
	testing.expect_value(t, len(aliased_frame.pixels), len(emulated_frame.pixels))
	if len(aliased_frame.pixels) != len(emulated_frame.pixels) {return}
	for pixel, index in emulated_frame.pixels {
		if !testing.expect_value(t, pixel, aliased_frame.pixels[index]) {return}
	}
	// The pattern reached the visible surface rather than agreeing on blank.
	testing.expect(t, emulated_frame.pixels[0] != emulated_frame.pixels[1])
}
