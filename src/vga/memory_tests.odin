// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"

import "core:testing"

test_planar_mode :: proc(v: ^Vga) {
	v.seq[2] = 0x0F
	v.seq[4] = 0x06
	v.gfx[5] = 0
	v.gfx[6] = 0x05
	v.gfx[7] = 0x0F
	v.gfx[8] = 0xFF
}

@(test)
vga_test_aperture_maps :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	for selection in 0 ..< 4 {
		v.gfx[6] = u8(selection << 2)
		_, a0 := legacy_aperture_offset(&v, 0xA0000)
		_, b0 := legacy_aperture_offset(&v, 0xB0000)
		_, b8 := legacy_aperture_offset(&v, 0xB8000)
		switch selection {
		case 0:
			testing.expect(t, a0 && b0 && b8)
		case 1:
			testing.expect(t, a0 && !b0 && !b8)
		case 2:
			testing.expect(t, !a0 && b0 && !b8)
		case 3:
			testing.expect(t, !a0 && !b0 && b8)
		}
	}
	testing.expect(t, vga_mmio_contains(&v, 0xA0000, 4))
	testing.expect(t, vga_mmio_contains(&v, VBE_LFB_BASE, 4))
	testing.expect(t, !vga_mmio_contains(&v, VBE_LFB_END - 1, 4))
}

@(test)
vga_test_partial_mmio_write_notifies_prior_mutation :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	v.gfx[6] = 1 << 2
	sequence := v.legacy_presentation_sequence
	content := v.content_generation

	testing.expect(t, !vga_mmio_write(&v, 0xAFFFF, 2, 0x005A))
	testing.expect_value(t, plane_byte(&v, 0, LEGACY_PLANE_SIZE - 1), u8(0x5A))
	testing.expect_value(t, v.legacy_presentation_sequence, sequence + 1)
	testing.expect_value(t, v.content_generation, content + 1)
}

@(test)
vga_test_pci_command_and_framebuffer_bar_control_decode :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	new_base := u64(0xD000_0000)

	vga_set_pci_decode(&v, false, false, new_base)
	testing.expect_value(t, vga_io_read(&v, 0x3C2, 1), u32(0xFF))
	testing.expect(t, !vga_mmio_contains(&v, LEGACY_APERTURE_BASE, 1))
	testing.expect(t, !vga_mmio_contains(&v, new_base, 1))

	vga_set_pci_decode(&v, true, true, new_base)
	testing.expect_value(t, vga_io_read(&v, 0x3C2, 1), u32(0x10))
	testing.expect(t, vga_mmio_contains(&v, LEGACY_APERTURE_BASE, 1))
	testing.expect(t, !vga_mmio_contains(&v, VBE_LFB_BASE, 1))
	testing.expect(t, vga_mmio_contains(&v, new_base, 4))
	testing.expect(t, vga_mmio_write(&v, new_base + 4, 4, 0x4433_2211))
	testing.expect_value(t, backing[4], u8(0x11))
}

@(test)
vga_test_write_modes_zero_and_set_reset :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	for p in 0 ..< 4 {set_plane_byte(&v, p, 0, 0xAA)}
	_, _ = vga_mmio_read(&v, 0xA0000, 1)
	v.gfx[3] = 1
	v.gfx[8] = 0x0F
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, 3))
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 0), u8(0xA1))}

	v.gfx[3] = 0
	v.gfx[8] = 0xFF
	v.gfx[0] = 0x05
	v.gfx[1] = 0x0F
	testing.expect(t, vga_mmio_write(&v, 0xA0001, 1, 0))
	testing.expect_value(t, plane_byte(&v, 0, 1), u8(0xFF))
	testing.expect_value(t, plane_byte(&v, 1, 1), u8(0))
	testing.expect_value(t, plane_byte(&v, 2, 1), u8(0xFF))
	testing.expect_value(t, plane_byte(&v, 3, 1), u8(0))
}

@(test)
vga_test_write_modes_one_two_three :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	for p in 0 ..< 4 {set_plane_byte(&v, p, 0, u8(0x10 + p))}
	_, _ = vga_mmio_read(&v, 0xA0000, 1)
	v.gfx[5] = 1
	vga_mmio_write(&v, 0xA0001, 1, 0xFF)
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 1), u8(0x10 + p))}

	v.gfx[5] = 2
	v.gfx[8] = 0xFF
	vga_mmio_write(&v, 0xA0002, 1, 0x05)
	testing.expect_value(t, plane_byte(&v, 0, 2), u8(0xFF))
	testing.expect_value(t, plane_byte(&v, 1, 2), u8(0))
	testing.expect_value(t, plane_byte(&v, 2, 2), u8(0xFF))
	testing.expect_value(t, plane_byte(&v, 3, 2), u8(0))

	v.gfx[5] = 3
	v.gfx[0] = 0x0F
	v.gfx[3] = 0
	v.gfx[8] = 0x0F
	for p in 0 ..< 4 {v.latch[p] = 0xA0}
	vga_mmio_write(&v, 0xA0003, 1, 0x03)
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 3), u8(0xA3))}
}

@(test)
vga_test_read_modes_and_raster_xor :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	set_plane_byte(&v, 0, 0, 0xF0)
	set_plane_byte(&v, 1, 0, 0x0F)
	set_plane_byte(&v, 2, 0, 0xFF)
	set_plane_byte(&v, 3, 0, 0x00)
	v.gfx[5] = 0x08
	v.gfx[2] = 0x05
	v.gfx[7] = 0x0F
	value, ok := vga_mmio_read(&v, 0xA0000, 1)
	testing.expect(t, ok)
	testing.expect_value(t, u8(value), u8(0xF0))
	v.gfx[5] = 0
	v.gfx[3] = 3 << 3
	v.gfx[8] = 0xFF
	v.gfx[1] = 0
	vga_mmio_write(&v, 0xA0000, 1, 0xFF)
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 0), ~v.latch[p])}
}

@(test)
vga_test_odd_even_and_chain_four :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.seq[2] = 0x0F
	v.seq[4] = 0x02
	v.gfx[5] = 0
	v.gfx[6] = 0x0E
	v.gfx[8] = 0xFF
	vga_mmio_write(&v, 0xB8000, 2, 0x0741)
	testing.expect_value(t, plane_byte(&v, 0, 0), u8(0x41))
	testing.expect_value(t, plane_byte(&v, 1, 0), u8(0x07))

	v.seq[4] = 0x0E
	v.gfx[6] = 0x05
	for i in 0 ..< 4 {vga_mmio_write(&v, 0xA0010 + u64(i), 1, u32(0x20 + i))}
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 4), u8(0x20 + p))}
}

// Odd/even addressing consumes A0 to pick the plane pair and substitutes a
// higher-order bit in its place, so consecutive even host addresses land two
// plane offsets apart rather than one. Sequencer 04h bit 1 chooses A14 or A16
// as the substitute; the firmware sets it in every mode, so A16 applies here
// and the substituted bit is zero inside a 64 KiB window.
@(test)
vga_test_odd_even_replaces_bit_zero_rather_than_shifting :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.seq[2] = 0x0F
	v.seq[4] = 0x02
	v.gfx[5] = 0
	v.gfx[6] = 0x02
	v.gfx[8] = 0xFF
	vga_mmio_write(&v, 0xA0000, 1, 0xAA)
	vga_mmio_write(&v, 0xA0002, 1, 0xBB)

	v.seq[4] = 0x06
	v.gfx[6] = 0x00
	v.gfx[4] = 0
	first, first_ok := vga_mmio_read(&v, 0xA0000, 1)
	second, second_ok := vga_mmio_read(&v, 0xA0002, 1)
	testing.expect(t, first_ok)
	testing.expect(t, second_ok)
	testing.expect_value(t, u8(first), u8(0xAA))
	testing.expect_value(t, u8(second), u8(0xBB))
}


@(test)
vga_test_aperture_slice_access_is_one_visible_transaction :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.seq[2] = 0x0F
	v.seq[4] = 0x0E
	v.gfx[5] = 0
	v.gfx[6] = 0x05
	v.gfx[8] = 0xFF
	initial_content := v.content_generation
	initial_activity := v.guest_activity_generation
	data := [4]u8{0x31, 0x32, 0x33, 0x34}

	testing.expect(t, vga_aperture_access(&v, 0xA0010, true, data[:], 500_000))
	testing.expect_value(t, v.content_generation, initial_content + 1)
	testing.expect_value(t, v.guest_activity_generation, initial_activity + 1)
	testing.expect(t, v.raster_fallback)
	for p in 0 ..< 4 {testing.expect_value(t, plane_byte(&v, p, 4), data[p])}

	readback: [4]u8
	testing.expect(t, vga_aperture_access(&v, 0xA0010, false, readback[:], 500_000))
	testing.expect_value(t, readback, data)
	testing.expect_value(t, v.content_generation, initial_content + 1)
}

@(test)
vga_test_aperture_write_invalidates_cached_frame_during_raster_fallback :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_planar_mode(&v)
	v.frame_valid = true
	content := v.content_generation
	data := [1]u8{0x5A}

	testing.expect(t, vga_aperture_access(&v, 0xA0000, true, data[:], 500_000))
	testing.expect(t, v.raster_fallback)
	testing.expect(t, !v.frame_valid)
	testing.expect_value(t, v.content_generation, content + 1)

	v.frame_valid = true
	content = v.content_generation
	sequence := v.legacy_presentation_sequence
	testing.expect(t, vga_aperture_access(&v, 0xA0000, true, data[:], 500_001))
	testing.expect(t, !v.frame_valid)
	testing.expect_value(t, v.content_generation, content)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence)

	v.frame_valid = true
	content = v.content_generation
	sequence = v.legacy_presentation_sequence
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, u32(data[0])))
	testing.expect(t, !v.frame_valid)
	testing.expect_value(t, v.content_generation, content)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence)
}

@(private = "file")
vga_test_paired_aperture_present :: proc(t: ^testing.T, v: ^Vga, g: ^Gsw_Vga) -> bool {
	if !test_set_vbe_mode(v, 4, 2, 32) {return false}
	gsw_vga_attach_scanout(g, v)
	if !gsw_surface_register(g, 3, 0, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE) {
		return false
	}
	surface, found := gsw_surface_get(g, 3)
	if !found || !gsw_presentation_submit_surface(g, surface, 1) {return false}
	active := g.presentation_state.active.header
	return gsw_presentation_acknowledge(
		g,
		active.sequence,
		active.device_generation,
		active.surface.id,
		active.surface.generation,
	)
}

@(test)
vga_test_paired_aperture_write_publishes_gsw_before_legacy :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, vga_test_paired_aperture_present(t, &v, &g)) {return}
	sequence := vga_presentation_sequence(&v)
	data := [4]u8{0x11, 0x22, 0x33, 0x44}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0004, true, data[:], 500_000))
	snapshot := gsw_vga_presentation_snapshot(&g)
	legacy := vga_legacy_frame_update(&v)
	testing.expect(t, snapshot.active_valid)
	testing.expect_value(t, snapshot.active.header.sequence, sequence + 1)
	testing.expect_value(t, legacy.header.sequence, sequence + 2)
	testing.expect_value(
		t,
		contract.generation_order(snapshot.active.header.sequence, legacy.header.sequence),
		contract.Generation_Order.Older,
	)
	testing.expect_value(t, snapshot.damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(
		t,
		snapshot.damage.full_reason,
		contract.Damage_Full_Reason.External_Tracking,
	)
	testing.expect_value(t, snapshot.damage.rects, contract.rect_set_full({4, 2}))
}

@(test)
vga_test_paired_aperture_without_active_gsw_publishes_legacy_only :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32)) {return}
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	gsw_sequence := g.presentation_state.sequence
	sequence := vga_presentation_sequence(&v)
	data := [1]u8{0x51}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, data[:], 500_000))
	testing.expect_value(t, g.presentation_state.sequence, gsw_sequence)
	testing.expect(t, !g.presentation_state.active_valid)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
	testing.expect(t, vga_legacy_frame_update(&v).header.sequence != 0)
}

@(test)
vga_test_paired_aperture_read_and_unchanged_write_do_not_refresh_gsw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, vga_test_paired_aperture_present(t, &v, &g)) {return}
	sequence := vga_presentation_sequence(&v)
	active_sequence := g.presentation_state.active.header.sequence
	readback: [1]u8

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, false, readback[:], 500_000))
	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, readback[:], 500_000))
	testing.expect_value(t, vga_presentation_sequence(&v), sequence)
	testing.expect_value(t, g.presentation_state.active.header.sequence, active_sequence)
	testing.expect_value(t, g.presentation_state.damage, contract.Damage_Record{})
}

@(test)
vga_test_paired_aperture_stale_surface_does_not_refresh_gsw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, vga_test_paired_aperture_present(t, &v, &g)) {return}
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found) {return}
	surface.generation = contract.generation_next(surface.generation)
	active_sequence := g.presentation_state.active.header.sequence
	sequence := vga_presentation_sequence(&v)
	data := [1]u8{0x61}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, data[:], 500_000))
	testing.expect_value(t, g.presentation_state.active.header.sequence, active_sequence)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
}

@(test)
vga_test_paired_aperture_destroyed_surface_does_not_refresh_gsw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, vga_test_paired_aperture_present(t, &v, &g)) {return}
	testing.expect(t, gsw_surface_unregister(&g, 3))
	gsw_sequence := g.presentation_state.sequence
	sequence := vga_presentation_sequence(&v)
	data := [1]u8{0x71}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, data[:], 500_000))
	testing.expect(t, !g.presentation_state.active_valid)
	testing.expect_value(t, g.presentation_state.sequence, gsw_sequence)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
}

@(test)
vga_test_paired_aperture_non_aliasing_backing_does_not_refresh_gsw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	separate := make([]u8, VRAM_SIZE)
	defer delete(separate)
	g: Gsw_Vga
	gsw_vga_init(&g, separate)
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, vga_test_paired_aperture_present(t, &v, &g)) {return}
	active_sequence := g.presentation_state.active.header.sequence
	sequence := vga_presentation_sequence(&v)
	data := [1]u8{0x81}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, data[:], 500_000))
	testing.expect_value(t, g.presentation_state.active.header.sequence, active_sequence)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
}

@(test)
vga_test_paired_aperture_non_overlapping_surface_does_not_refresh_gsw :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	if !testing.expect(t, test_set_vbe_mode(&v, 4, 2, 32)) {return}
	g: Gsw_Vga
	gsw_vga_init(&g, backing)
	defer gsw_vga_destroy(&g)
	gsw_vga_attach_scanout(&g, &v)
	testing.expect(
		t,
		gsw_surface_register(&g, 3, 64, 32, 4, 2, 16, .Xrgb_8888, GSW_SURFACE_PRESENTABLE),
	)
	surface, found := gsw_surface_get(&g, 3)
	if !testing.expect(t, found && gsw_presentation_submit_surface(&g, surface, 1)) {return}
	active := g.presentation_state.active.header
	if !testing.expect(
		t,
		gsw_presentation_acknowledge(
			&g,
			active.sequence,
			active.device_generation,
			active.surface.id,
			active.surface.generation,
		),
	) {
		return
	}
	active_sequence := g.presentation_state.active.header.sequence
	sequence := vga_presentation_sequence(&v)
	data := [1]u8{0x91}

	testing.expect(t, vga_aperture_access_paired(&v, &g, 0xA0000, true, data[:], 500_000))
	testing.expect_value(t, g.presentation_state.active.header.sequence, active_sequence)
	testing.expect_value(t, vga_presentation_sequence(&v), sequence + 1)
}

@(test)
vga_test_odd_even_read_uses_graphics_controls :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.seq[4] = 0x06
	v.gfx[4] = 0
	v.gfx[5] = 0x10
	v.gfx[6] = 0x0E
	set_plane_byte(&v, 1, 0, 0x55)
	value, ok := vga_mmio_read(&v, 0xB8001, 1)
	testing.expect(t, ok)
	testing.expect_value(t, u8(value), u8(0x55))
	v.gfx[6] &= ~u8(0x02)
	v.gfx[6] = (v.gfx[6] & 3) | 3 << 2
	set_plane_byte(&v, 0, 1, 0x66)
	value, ok = vga_mmio_read(&v, 0xB8001, 1)
	testing.expect(t, ok)
	testing.expect_value(t, u8(value), u8(0x66))
}
