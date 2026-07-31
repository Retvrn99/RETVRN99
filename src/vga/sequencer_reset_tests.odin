// SPDX-License-Identifier: GPL-3.0-only
package vga

import contract "../presentation"
import "core:bytes"
import "core:testing"

sequencer_reset_test_write :: proc(v: ^Vga, index, value: u8) {
	vga_out(v, 0x3C4, index)
	vga_out(v, 0x3C5, value)
}

sequencer_reset_test_black :: proc(frame: ^Display_Frame) -> bool {
	if frame == nil || len(frame.pixels) == 0 {return false}
	for pixel in frame.pixels {
		if pixel != 0xFF00_0000 {return false}
	}
	return true
}

@(test)
vga_test_sequencer_reset_public_port_matrix_preserves_state :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	sequencer_reset_test_write(&v, 1, 0x01)
	sequencer_reset_test_write(&v, 2, 0x05)
	sequencer_reset_test_write(&v, 3, 0x2A)
	sequencer_reset_test_write(&v, 4, 0x0E)
	set_plane_byte(&v, 0, 0, 0x80)
	vga_out(&v, 0x3C8, 1)
	vga_out(&v, 0x3C9, 0x3F)
	vga_out(&v, 0x3C9, 0x12)
	vga_out(&v, 0x3C9, 0x08)
	vga_note_content_change(&v)

	baseline := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	seq_before := v.seq
	gfx_before := v.gfx
	attr_before := v.attr
	dac_before := v.dac
	dispi_before := v.dispi
	vram_before := make([]u8, len(backing))
	defer delete(vram_before)
	copy(vram_before, backing)

	for reset_value in ([3]u8{0x02, 0x01, 0x00}) {
		sequencer_reset_test_write(&v, 0, reset_value)
		testing.expect_value(t, vga_in(&v, 0x3C5), reset_value)
		testing.expect(t, !video_output_enabled(&v))
		testing.expect(t, sequencer_reset_test_black(vga_display_frame(&v)))
		testing.expect(t, bytes.equal(v.seq[1:], seq_before[1:]))
		testing.expect_value(t, v.gfx, gfx_before)
		testing.expect_value(t, v.attr, attr_before)
		testing.expect_value(t, v.dac, dac_before)
		testing.expect_value(t, v.dispi, dispi_before)
		testing.expect(t, bytes.equal(backing, vram_before))

		sequencer_reset_test_write(&v, 0, 0x03)
		testing.expect(t, video_output_enabled(&v))
		testing.expect_value(t, vga_test_pixels_crc32(vga_display_frame(&v).pixels), baseline)
	}
}

@(test)
vga_test_sequencer_reset_and_screen_off_are_independent :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0x80)
	vga_note_content_change(&v)
	baseline := vga_test_pixels_crc32(vga_display_frame(&v).pixels)

	sequencer_reset_test_write(&v, 1, v.seq[1] | 0x20)
	testing.expect(t, sequencer_reset_test_black(vga_display_frame(&v)))
	sequencer_reset_test_write(&v, 0, 0x02)
	sequencer_reset_test_write(&v, 1, v.seq[1] & ~u8(0x20))
	testing.expect(t, !video_output_enabled(&v))
	testing.expect(t, sequencer_reset_test_black(vga_display_frame(&v)))
	sequencer_reset_test_write(&v, 0, 0x03)
	testing.expect_value(t, vga_test_pixels_crc32(vga_display_frame(&v).pixels), baseline)

	vga_out(&v, 0x3D8, CGA_MODE_GRAPHICS | CGA_MODE_VIDEO_ENABLE)
	vga_out(&v, 0x3D9, 0x0F)
	_ = vga_mmio_write(&v, 0xB8000, 1, 0x80)
	cga_crc := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	sequencer_reset_test_write(&v, 0, 0x01)
	testing.expect(t, sequencer_reset_test_black(vga_display_frame(&v)))
	sequencer_reset_test_write(&v, 0, 0x03)
	testing.expect_value(t, vga_test_pixels_crc32(vga_display_frame(&v).pixels), cga_crc)
}

@(test)
vga_test_sequencer_reset_drives_damage_generation_and_descriptor_restore :: proc(t: ^testing.T) {
	v: Vga
	backing := test_vga_init(t, &v)
	defer delete(backing)
	defer vga_destroy(&v)
	test_bochs_legacy_mode(&v, 0x12)
	set_plane_byte(&v, 0, 0, 0x80)
	vga_note_content_change(&v)
	baseline := vga_test_pixels_crc32(vga_display_frame(&v).pixels)
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	sequence := v.legacy_presentation_sequence
	content := v.content_generation
	activity := v.guest_activity_generation
	timing_before := v.timing

	sequencer_reset_test_write(&v, 0, 0x02)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence + 1)
	testing.expect_value(t, v.content_generation, content + 1)
	testing.expect_value(t, v.guest_activity_generation, activity + 1)
	testing.expect_value(t, v.timing, timing_before)
	damage := vga_damage_snapshot(&v)
	testing.expect_value(t, damage.kind, contract.Damage_Kind.Pixel_Memory)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.Mode_Boundary)

	reset_descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&reset_descriptor)
	testing.expect(t, scanout_descriptor_capture(&reset_descriptor, &v, 1))
	testing.expect(t, sequencer_reset_test_black(scanout_test_expand_legacy(&reset_descriptor)))
	testing.expect(t, vga_damage_acknowledge(&v, v.legacy_presentation_sequence))
	sequence = v.legacy_presentation_sequence
	content = v.content_generation
	activity = v.guest_activity_generation

	sequencer_reset_test_write(&v, 0, 0x03)
	testing.expect_value(t, v.legacy_presentation_sequence, sequence + 1)
	testing.expect_value(t, v.content_generation, content + 1)
	testing.expect_value(t, v.guest_activity_generation, activity + 1)
	testing.expect_value(t, v.timing, timing_before)
	damage = vga_damage_snapshot(&v)
	testing.expect_value(t, damage.full_reason, contract.Damage_Full_Reason.Mode_Boundary)

	release_descriptor: Scanout_Descriptor
	defer scanout_descriptor_destroy(&release_descriptor)
	testing.expect(t, scanout_descriptor_capture(&release_descriptor, &v, 1))
	restored := scanout_test_expand_legacy(&release_descriptor)
	if testing.expect(t, restored != nil) {
		testing.expect_value(t, vga_test_pixels_crc32(restored.pixels), baseline)
	}
}
