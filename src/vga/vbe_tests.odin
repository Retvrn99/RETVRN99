// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

test_dispi_write :: proc(v: ^Vga, index, value: u16) {
	vga_io_write(v, DISPI_PORT_INDEX, 2, u32(index))
	vga_io_write(v, DISPI_PORT_DATA, 2, u32(value))
}

test_dispi_read :: proc(v: ^Vga, index: u16) -> u16 {
	vga_io_write(v, DISPI_PORT_INDEX, 2, u32(index))
	return u16(vga_io_read(v, DISPI_PORT_DATA, 2))
}

test_set_vbe_mode :: proc(
	v: ^Vga,
	width, height, bpp: u16,
	flags := DISPI_NOCLEARMEM | DISPI_BANK_GRANULARITY_32K,
) -> bool {
	test_dispi_write(v, DISPI_INDEX_ENABLE, 0)
	test_dispi_write(v, DISPI_INDEX_XRES, width)
	test_dispi_write(v, DISPI_INDEX_YRES, height)
	test_dispi_write(v, DISPI_INDEX_BPP, bpp)
	test_dispi_write(v, DISPI_INDEX_VIRT_WIDTH, width)
	return dispi_write_register(v, DISPI_INDEX_ENABLE, DISPI_ENABLED | flags)
}

@(test)
vga_test_dispi_width_and_capabilities :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_ID), DISPI_ID5)
	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID0)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_ID), DISPI_ID0)
	test_dispi_write(&v, DISPI_INDEX_ENABLE, DISPI_GETCAPS)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_XRES), u16(DISPI_MAX_XRES))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_YRES), u16(DISPI_MAX_YRES))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BPP), u16(32))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BANK), u16(0x1000))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_VIDEO_MEMORY_64K), u16(512))
}

@(test)
vga_test_dispi_atomic_validation_and_clear :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	v.vram[100] = 0xA5
	test_dispi_write(&v, DISPI_INDEX_XRES, 3000)
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_ENABLE, DISPI_ENABLED))
	testing.expect(t, !vga_vbe_enabled(&v))
	testing.expect_value(t, v.vram[100], u8(0xA5))
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 8, 0))
	testing.expect_value(t, v.vram[100], u8(0))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_XRES, 800))
	testing.expect_value(t, v.dispi[DISPI_INDEX_XRES], u16(640))
}

@(test)
vga_test_dispi_virtual_pitch_and_offsets :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 320, 200, 16))
	testing.expect_value(t, vga_vbe_pitch(&v), 640)
	testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_VIRT_HEIGHT), u16(VRAM_SIZE / 640))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 640))
	testing.expect_value(t, vga_vbe_pitch(&v), 1280)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 320))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 321))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_Y_OFFSET, 10))
}

@(test)
vga_test_dispi_banks_and_lfb_alias :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 320, 200, 8))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 2 | DISPI_BANK_WR))
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, 0x55))
	testing.expect_value(t, v.vram[2 * DISPI_BANK_GRANULARITY], u8(0x55))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 1 | DISPI_BANK_RD))
	v.vram[DISPI_BANK_GRANULARITY] = 0x66
	value, ok := vga_mmio_read(&v, 0xA0000, 1)
	testing.expect(t, ok)
	testing.expect_value(t, u8(value), u8(0x66))
	testing.expect_value(t, v.bank_write, u16(2))

	testing.expect(t, vga_mmio_write(&v, VBE_LFB_BASE + 1234, 4, 0x44332211))
	testing.expect_value(t, v.vram[1234], u8(0x11))
	testing.expect_value(t, v.vram[1237], u8(0x44))
}

@(test)
vga_test_dispi_all_advertised_depths :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	depths := []u16{4, 8, 15, 16, 24, 32}
	for bpp in depths {
		testing.expect(t, test_set_vbe_mode(&v, 1600, 1200, bpp))
		testing.expect(t, vga_vbe_pitch(&v) > 0)
	}
}

@(test)
vga_test_dispi_bank_granularity_flag :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 320, 200, 8, DISPI_NOCLEARMEM))
	testing.expect_value(t, dispi_bank_granularity(&v), 64 * 1024)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BANK, 2 | DISPI_BANK_RW))
	testing.expect(t, vga_mmio_write(&v, 0xA0000, 1, 0x44))
	testing.expect_value(t, v.vram[2 * 64 * 1024], u8(0x44))
	testing.expect(
		t,
		dispi_write_register(
			&v,
			DISPI_INDEX_ENABLE,
			DISPI_ENABLED | DISPI_NOCLEARMEM | DISPI_BANK_GRANULARITY_32K,
		),
	)
	testing.expect_value(t, dispi_bank_granularity(&v), 32 * 1024)
	testing.expect(t, vga_mmio_write(&v, 0xA0001, 1, 0x55))
	testing.expect_value(t, v.vram[2 * 32 * 1024 + 1], u8(0x55))
}

@(test)
vga_test_external_lfb_dirty_publication_requires_active_lfb :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	testing.expect(t, !vga_publish_external_lfb_writes(&v, true))
	testing.expect(t, test_set_vbe_mode(&v, 640, 480, 32, DISPI_NOCLEARMEM | DISPI_LFB_ENABLED))
	generation := v.content_generation
	testing.expect(t, !vga_publish_external_lfb_writes(&v, false))
	testing.expect_value(t, v.content_generation, generation)
	testing.expect(t, vga_publish_external_lfb_writes(&v, true))
	testing.expect_value(t, v.content_generation, generation + 1)

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_ENABLE, 0))
	testing.expect(t, !vga_publish_external_lfb_writes(&v, true))
}
