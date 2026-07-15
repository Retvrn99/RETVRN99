// SPDX-License-Identifier: GPL-3.0-only
package vga

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
		case 0: testing.expect(t, a0 && b0 && b8)
		case 1: testing.expect(t, a0 && !b0 && !b8)
		case 2: testing.expect(t, !a0 && b0 && !b8)
		case 3: testing.expect(t, !a0 && !b0 && b8)
		}
	}
	testing.expect(t, vga_mmio_contains(&v, 0xA0000, 4))
	testing.expect(t, vga_mmio_contains(&v, VBE_LFB_BASE, 4))
	testing.expect(t, !vga_mmio_contains(&v, VBE_LFB_END - 1, 4))
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
	for p in 0 ..< 4 { set_plane_byte(&v, p, 0, 0xAA) }
	_, _ = vga_mmio_read(&v, 0xA0000, 1)
	v.gfx[3] = 1
	v.gfx[8] = 0x0F
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, 3))
	for p in 0 ..< 4 { testing.expect_value(t, plane_byte(&v, p, 0), u8(0xA1)) }

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
	for p in 0 ..< 4 { set_plane_byte(&v, p, 0, u8(0x10 + p)) }
	_, _ = vga_mmio_read(&v, 0xA0000, 1)
	v.gfx[5] = 1
	vga_mmio_write(&v, 0xA0001, 1, 0xFF)
	for p in 0 ..< 4 { testing.expect_value(t, plane_byte(&v, p, 1), u8(0x10 + p)) }

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
	for p in 0 ..< 4 { v.latch[p] = 0xA0 }
	vga_mmio_write(&v, 0xA0003, 1, 0x03)
	for p in 0 ..< 4 { testing.expect_value(t, plane_byte(&v, p, 3), u8(0xA3)) }
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
	for p in 0 ..< 4 { testing.expect_value(t, plane_byte(&v, p, 0), ~v.latch[p]) }
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
	for i in 0 ..< 4 { vga_mmio_write(&v, 0xA0010 + u64(i), 1, u32(0x20 + i)) }
	for p in 0 ..< 4 { testing.expect_value(t, plane_byte(&v, p, 4), u8(0x20 + p)) }
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
