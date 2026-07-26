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
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_XRES), u16(640))
	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID5)
	test_dispi_write(&v, DISPI_INDEX_ENABLE, DISPI_GETCAPS)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_XRES), u16(DISPI_MAX_XRES))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_YRES), u16(DISPI_MAX_YRES))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BPP), u16(32))
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BANK), u16(0x1000))
	testing.expect_value(
		t,
		test_dispi_read(&v, DISPI_INDEX_VIDEO_MEMORY_64K),
		u16(VRAM_SIZE / 65536),
	)
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
vga_test_dispi_id_gates_features_and_bpp_zero :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID0)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_VIRT_WIDTH), u16(0xFFFF))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 800))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_BPP, 16))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BPP, 0))
	testing.expect_value(t, v.dispi[DISPI_INDEX_BPP], u16(8))
	testing.expect(
		t,
		dispi_write_register(
			&v,
			DISPI_INDEX_ENABLE,
			DISPI_ENABLED | DISPI_LFB_ENABLED | DISPI_NOCLEARMEM,
		),
	)
	testing.expect_value(t, v.dispi[DISPI_INDEX_ENABLE], DISPI_ENABLED)

	test_dispi_write(&v, DISPI_INDEX_ENABLE, 0)
	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID1)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 800))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 160))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_BPP, 16))
	testing.expect(
		t,
		dispi_write_register(&v, DISPI_INDEX_ENABLE, DISPI_ENABLED | DISPI_LFB_ENABLED),
	)
	testing.expect_value(t, v.dispi[DISPI_INDEX_ENABLE], DISPI_ENABLED)

	test_dispi_write(&v, DISPI_INDEX_ENABLE, 0)
	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID2)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_BPP, 16))
	testing.expect(
		t,
		dispi_write_register(
			&v,
			DISPI_INDEX_ENABLE,
			DISPI_ENABLED | DISPI_LFB_ENABLED | DISPI_NOCLEARMEM | DISPI_GETCAPS,
		),
	)
	testing.expect_value(
		t,
		v.dispi[DISPI_INDEX_ENABLE],
		DISPI_ENABLED | DISPI_LFB_ENABLED | DISPI_NOCLEARMEM,
	)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BPP), u16(16))

	test_dispi_write(&v, DISPI_INDEX_ENABLE, 0)
	test_dispi_write(&v, DISPI_INDEX_ID, DISPI_ID3)
	testing.expect(
		t,
		dispi_write_register(
			&v,
			DISPI_INDEX_ENABLE,
			DISPI_GETCAPS | DISPI_8BIT_DAC | DISPI_BANK_GRANULARITY_32K,
		),
	)
	testing.expect_value(t, v.dispi[DISPI_INDEX_ENABLE], DISPI_GETCAPS | DISPI_8BIT_DAC)
	testing.expect_value(t, test_dispi_read(&v, DISPI_INDEX_BPP), u16(32))
}

@(test)
vga_test_dispi_virtual_pitch_and_offsets :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 320, 200, 16))
	testing.expect_value(t, vga_vbe_pitch(&v), 640)
	testing.expect_value(
		t,
		dispi_read_register(&v, DISPI_INDEX_VIRT_HEIGHT),
		u16(min(VRAM_SIZE / 640, 0xFFFF)),
	)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 640))
	testing.expect_value(t, vga_vbe_pitch(&v), 1280)
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 320))
	testing.expect(t, !dispi_write_register(&v, DISPI_INDEX_X_OFFSET, 321))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 400))
	testing.expect_value(t, v.dispi[DISPI_INDEX_X_OFFSET], u16(80))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_VIRT_WIDTH, 1))
	testing.expect_value(t, v.dispi[DISPI_INDEX_VIRT_WIDTH], u16(320))
	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_Y_OFFSET, 10))
}

@(test)
vga_test_dispi_enable_resets_virtual_width_and_offsets :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	test_dispi_write(&v, DISPI_INDEX_ENABLE, 0)
	test_dispi_write(&v, DISPI_INDEX_XRES, 320)
	test_dispi_write(&v, DISPI_INDEX_YRES, 200)
	test_dispi_write(&v, DISPI_INDEX_BPP, 8)
	test_dispi_write(&v, DISPI_INDEX_VIRT_WIDTH, 640)
	v.dispi[DISPI_INDEX_X_OFFSET] = 10
	v.dispi[DISPI_INDEX_Y_OFFSET] = 10
	testing.expect(
		t,
		dispi_write_register(&v, DISPI_INDEX_ENABLE, DISPI_ENABLED | DISPI_NOCLEARMEM),
	)
	testing.expect_value(t, v.dispi[DISPI_INDEX_VIRT_WIDTH], u16(320))
	testing.expect_value(t, v.dispi[DISPI_INDEX_X_OFFSET], u16(0))
	testing.expect_value(t, v.dispi[DISPI_INDEX_Y_OFFSET], u16(0))
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

ddc_test_drive :: proc(v: ^Vga, scl, sda: bool) {
	value: u16
	if scl {value |= 0x01}
	if sda {value |= 0x02}
	_ = dispi_write_register(v, DISPI_INDEX_DDC, value)
}

ddc_test_start :: proc(v: ^Vga) {
	ddc_test_drive(v, true, true)
	ddc_test_drive(v, true, false)
	ddc_test_drive(v, false, false)
}

ddc_test_stop :: proc(v: ^Vga) {
	ddc_test_drive(v, false, false)
	ddc_test_drive(v, true, false)
	ddc_test_drive(v, true, true)
}

ddc_test_write_bit :: proc(v: ^Vga, bit: bool) {
	ddc_test_drive(v, false, bit)
	ddc_test_drive(v, true, bit)
	ddc_test_drive(v, false, bit)
}

ddc_test_write_byte :: proc(v: ^Vga, value: u8) -> bool {
	for bit := 7; bit >= 0; bit -= 1 {
		ddc_test_write_bit(v, value & (u8(1) << uint(bit)) != 0)
	}
	ddc_test_drive(v, false, true)
	ddc_test_drive(v, true, true)
	ack := dispi_read_register(v, DISPI_INDEX_DDC) & 0x08 == 0
	ddc_test_drive(v, false, true)
	return ack
}

ddc_test_read_bit :: proc(v: ^Vga) -> bool {
	ddc_test_drive(v, false, true)
	ddc_test_drive(v, true, true)
	bit := dispi_read_register(v, DISPI_INDEX_DDC) & 0x08 != 0
	ddc_test_drive(v, false, true)
	return bit
}

ddc_test_read_byte :: proc(v: ^Vga, ack: bool) -> u8 {
	value: u8
	for _ in 0 ..< 8 {
		value <<= 1
		if ddc_test_read_bit(v) {value |= 1}
	}
	ddc_test_drive(v, false, !ack)
	ddc_test_drive(v, true, !ack)
	ddc_test_drive(v, false, !ack)
	return value
}

@(test)
vga_test_ddc2_reads_checksum_valid_edid :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)

	testing.expect(t, dispi_write_register(&v, DISPI_INDEX_DDC, 0x83))
	testing.expect_value(t, dispi_read_register(&v, DISPI_INDEX_DDC), u16(0x8F))
	testing.expect(t, ddc_edid_checksum_valid())

	ddc_test_start(&v)
	testing.expect(t, ddc_test_write_byte(&v, 0xA0))
	testing.expect(t, ddc_test_write_byte(&v, 0))
	ddc_test_stop(&v)
	ddc_test_start(&v)
	testing.expect(t, ddc_test_write_byte(&v, 0xA1))
	for i in 0 ..< len(VGA_EDID_BLOCK0) {
		value := ddc_test_read_byte(&v, i + 1 < len(VGA_EDID_BLOCK0))
		testing.expect_value(t, value, VGA_EDID_BLOCK0[i])
	}
	ddc_test_stop(&v)
	testing.expect_value(t, VGA_EDID_BLOCK0[8], u8(0x1E))
	testing.expect_value(t, VGA_EDID_BLOCK0[9], u8(0x77))
	testing.expect_value(t, VGA_EDID_BLOCK0[94], u8('G'))
	testing.expect_value(t, VGA_EDID_BLOCK0[95], u8('S'))
	testing.expect_value(t, VGA_EDID_BLOCK0[96], u8('W'))
}
