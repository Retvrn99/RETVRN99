// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

@(test)
test_sb16_adpcm4_predictor_matches_reference_arithmetic :: proc(t: ^testing.T) {
	state: Sb16_Adpcm
	sb16_adpcm_init(&state, .Bits_4, false)
	sb16_adpcm_decode_byte(&state, 0x50)
	first, first_ok := sb16_adpcm_pop(&state)
	second, second_ok := sb16_adpcm_pop(&state)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first, u8(133))
	testing.expect_value(t, second, u8(134))
	testing.expect_value(t, state.step, i32(0))
}

@(test)
test_sb16_adpcm_reference_command_counts_dma_bytes_and_drains_samples :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	dma: Sb16_Test_Dma
	dma.bytes[0] = 0x80
	dma.bytes[1] = 0x00
	dma.bytes[2] = 0x00
	sb16_test_command(&sb, 0x75, 0x02, 0x00)
	testing.expect(t, sb16_adpcm_active(&sb.adpcm))
	testing.expect_value(t, sb.block_remaining, u32(3))

	for _ in 0 ..< 4 {
		frame, produced := sb16_render_sample(&sb, &dma, sb16_test_read_byte, nil)
		testing.expect(t, produced)
		testing.expect_value(t, frame, Audio_Frame{})
	}
	testing.expect_value(t, dma.byte_at, 3)
	testing.expect(t, !sb.playing)
	testing.expect(t, !sb16_adpcm_active(&sb.adpcm))
	dma16, pending := sb16_take_irq(&sb)
	testing.expect(t, pending)
	testing.expect(t, !dma16)
}

@(test)
test_sb16_adpcm_auto_init_uses_programmed_block_size :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x48, 0x03, 0x00)
	sb16_test_command(&sb, 0x7D)
	testing.expect(t, sb.playing)
	testing.expect(t, sb.auto_init)
	testing.expect_value(t, sb.block_remaining, u32(4))
	testing.expect_value(t, sb.adpcm.mode, Sb16_Adpcm_Mode.Bits_4)
}

@(test)
test_sb16_pcm_arm_clears_prior_adpcm_state :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x75, 0x02, 0x00)
	testing.expect(t, sb16_adpcm_active(&sb.adpcm))
	sb16_test_command(&sb, 0x14, 0x00, 0x00)
	testing.expect(t, !sb16_adpcm_active(&sb.adpcm))
}
