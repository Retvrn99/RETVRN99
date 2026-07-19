// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

@(test)
test_ct1745_reset_routing_and_compatibility_aliases :: proc(t: ^testing.T) {
	mixer: Ct1745
	ct1745_reset(&mixer)
	testing.expect_value(t, ct1745_selected_irq(&mixer), u8(5))
	testing.expect_value(t, ct1745_selected_dma8(&mixer), 1)
	testing.expect_value(t, ct1745_selected_dma16(&mixer), 5)

	ct1745_write_register(&mixer, 0x80, 0x04)
	ct1745_write_register(&mixer, 0x81, 0x48)
	testing.expect_value(t, ct1745_selected_irq(&mixer), u8(7))
	testing.expect_value(t, ct1745_selected_dma8(&mixer), 3)
	testing.expect_value(t, ct1745_selected_dma16(&mixer), 6)

	ct1745_write_register(&mixer, 0x22, 0xA5)
	testing.expect_value(t, mixer.master_left, u8(20))
	testing.expect_value(t, mixer.master_right, u8(10))
	testing.expect_value(t, ct1745_read_register(&mixer, 0x22), u8(0xA5))
}

@(test)
test_ct1745_irq_status_and_sbpro_stereo_round_trip :: proc(t: ^testing.T) {
	mixer: Ct1745
	ct1745_reset(&mixer)
	ct1745_set_irq_status(&mixer, true)
	testing.expect_value(t, ct1745_read_register(&mixer, 0x82), u8(0x22))
	ct1745_set_irq_status(&mixer, false)
	ct1745_set_midi_irq_status(&mixer)
	testing.expect_value(t, ct1745_read_register(&mixer, 0x82), u8(0x27))
	ct1745_ack_irq_status(&mixer, 0x01)
	testing.expect_value(t, ct1745_read_register(&mixer, 0x82), u8(0x26))
	ct1745_ack_irq_status(&mixer, 0x06)
	testing.expect_value(t, ct1745_read_register(&mixer, 0x82), CT1745_IRQ_IDENTITY)
	ct1745_write_register(&mixer, 0x0E, 0x22)
	testing.expect(t, ct1745_sbpro_stereo(&mixer))
}

@(test)
test_ct1745_line_gain_registers_stay_in_table_range :: proc(t: ^testing.T) {
	mixer: Ct1745
	ct1745_reset(&mixer)
	ct1745_write_register(&mixer, 0x34, 0xFF)
	ct1745_write_register(&mixer, 0x35, 0xFF)
	testing.expect_value(t, ct1745_read_register(&mixer, 0x34), u8(0x1F))
	testing.expect_value(t, ct1745_read_register(&mixer, 0x35), u8(0x1F))
	_ = ct1745_apply_gain(&mixer, Audio_Frame{1_000, -1_000}, false)
}

@(test)
test_ct1745_cd_and_pc_speaker_gains_follow_source_and_master_levels :: proc(t: ^testing.T) {
	mixer: Ct1745
	ct1745_reset(&mixer)
	cd_left, cd_right := ct1745_cd_gain_pair(&mixer)
	testing.expect(t, cd_left > 0 && cd_right > 0)
	speaker_left, speaker_right := ct1745_speaker_gain_pair(&mixer)
	testing.expect(t, speaker_left > 0 && speaker_right > 0)

	ct1745_write_register(&mixer, 0x36, 0)
	ct1745_write_register(&mixer, 0x37, 0)
	cd_left, cd_right = ct1745_cd_gain_pair(&mixer)
	testing.expect_value(t, cd_left, u32(0))
	testing.expect_value(t, cd_right, u32(0))
	ct1745_write_register(&mixer, 0x3B, 0)
	speaker_left, speaker_right = ct1745_speaker_gain_pair(&mixer)
	testing.expect_value(t, speaker_left, u32(0))
	testing.expect_value(t, speaker_right, u32(0))
}
