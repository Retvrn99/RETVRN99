// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
scanout_descriptor_test_captures_active_vram_and_renders_later :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 1, 32))
	v.vram[0], v.vram[1], v.vram[2] = 0x11, 0x22, 0x33
	vga_note_content_change(&v)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	testing.expect_value(t, descriptor.generation, v.content_generation)
	testing.expect_value(t, descriptor.state.bank_read, v.bank_read)
	testing.expect_value(t, descriptor.state.bank_write, v.bank_write)
	testing.expect_value(t, descriptor.mode_observability.scanout_generation, v.content_generation)
	testing.expect_value(t, descriptor.mode_observability.kind, Display_Kind.Xrgb_8888)
	testing.expect(t, descriptor.bytes_copied < VRAM_SIZE)
	v.vram[0], v.vram[1], v.vram[2] = 0, 0, 0
	frame := scanout_descriptor_render(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect_value(t, frame.pixels[0], u32(0xFF332211))
	testing.expect_value(t, v.full_frame_renders, u64(0))
}

@(test)
scanout_descriptor_test_uses_explicit_state_without_source_vga_lifetime :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	testing.expect(t, test_set_vbe_mode(&v, 1, 1, 8))
	v.vram[0] = 3
	v.dac[9], v.dac[10], v.dac[11] = 0x3F, 0, 0
	vga_note_content_change(&v)

	descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&descriptor)
	testing.expect(t, scanout_descriptor_capture(&descriptor, &v))
	vga_destroy(&v)

	frame := scanout_descriptor_render(&descriptor)
	testing.expect(t, frame != nil)
	testing.expect_value(t, frame.kind, Display_Kind.Indexed_8)
	testing.expect_value(t, frame.pixels[0], u32(0xFFFF0000))
}

@(test)
scanout_descriptor_test_deferred_source_tracks_raster_mode_without_rendering :: proc(
	t: ^testing.T,
) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	testing.expect(t, test_set_vbe_mode(&v, 2, 2, 8))
	vga_set_deferred_scanout(&v, true)
	vga_begin_raster_change(&v, 500_000)
	vga_sync_to(&v, 1_500_000)
	testing.expect(t, v.raster_fallback)
	testing.expect_value(t, v.raster_pixels_rendered, u64(0))
	testing.expect_value(t, v.full_frame_renders, u64(0))
}
