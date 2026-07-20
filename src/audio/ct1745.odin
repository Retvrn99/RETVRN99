// SPDX-License-Identifier: GPL-3.0-only
package audio

// CT1745 register behavior adapted from IzarraVM commit
// b88a9fe68a8109f26632ff2802262cc38a6a5ad9. That implementation is a
// clean-room derivation from the Creative Sound Blaster 16 Hardware
// Programming Guide.

CT1745_INDEX_PORT :: u16(0x224)
CT1745_DATA_PORT :: u16(0x225)
// The upper nibble identifies the SB16 mixer/DSP generation to Creative's
// Windows 9x driver.  DSP 4.05 cards report 20h; bits 0-2 remain the live
// DMA8, DMA16, and MPU interrupt-source latches.
CT1745_IRQ_IDENTITY :: u8(0x20)

CT1745_GAIN_5_Q16 := [32]u32 {
	0,
	66,
	83,
	104,
	131,
	165,
	207,
	261,
	328,
	414,
	521,
	655,
	825,
	1_039,
	1_308,
	1_646,
	2_072,
	2_609,
	3_285,
	4_135,
	5_206,
	6_554,
	8_250,
	10_387,
	13_076,
	16_462,
	20_724,
	26_090,
	32_846,
	41_350,
	52_057,
	65_536,
}

CT1745_OUT_GAIN_Q16 := [4]u32{65_536, 130_762, 260_906, 520_581}
CT1745_SPEAKER_GAIN_Q16 := [4]u32{0, 8_250, 32_846, 65_536}

Ct1745 :: struct {
	index:        u8,
	irq_setup:    u8,
	dma_setup:    u8,
	irq_status:   u8,
	master_left:  u8,
	master_right: u8,
	voice_left:   u8,
	voice_right:  u8,
	out_left:     u8,
	out_right:    u8,
	registers:    [256]u8,
}

ct1745_reset :: proc(mixer: ^Ct1745) {
	mixer^ = {}
	mixer.irq_setup = 0x02
	mixer.dma_setup = 0x22
	mixer.master_left = 24
	mixer.master_right = 24
	mixer.voice_left = 24
	mixer.voice_right = 24
	mixer.registers[0x26] = 0xCC
	mixer.registers[0x28] = 0xCC
	mixer.registers[0x34] = 24
	mixer.registers[0x35] = 24
	mixer.registers[0x36] = 24
	mixer.registers[0x37] = 24
	mixer.registers[0x3C] = 0x1F
	mixer.registers[0x3D] = 0x15
	mixer.registers[0x3E] = 0x0B
	mixer.registers[0x3B] = 0x03
	mixer.registers[0x44] = 8
	mixer.registers[0x45] = 8
	mixer.registers[0x46] = 8
	mixer.registers[0x47] = 8
}

ct1745_selected_irq :: proc(mixer: ^Ct1745) -> u8 {
	if mixer.irq_setup & 0x01 != 0 {return 2}
	if mixer.irq_setup & 0x02 != 0 {return 5}
	if mixer.irq_setup & 0x04 != 0 {return 7}
	if mixer.irq_setup & 0x08 != 0 {return 10}
	return 5
}

ct1745_selected_dma8 :: proc(mixer: ^Ct1745) -> int {
	if mixer.dma_setup & 0x01 != 0 {return 0}
	if mixer.dma_setup & 0x02 != 0 {return 1}
	if mixer.dma_setup & 0x08 != 0 {return 3}
	return 1
}

ct1745_selected_dma16 :: proc(mixer: ^Ct1745) -> int {
	if mixer.dma_setup & 0x20 != 0 {return 5}
	if mixer.dma_setup & 0x40 != 0 {return 6}
	if mixer.dma_setup & 0x80 != 0 {return 7}
	return ct1745_selected_dma8(mixer)
}

ct1745_set_irq_status :: proc(mixer: ^Ct1745, dma16: bool) {
	mixer.irq_status |= dma16 ? 0x02 : 0x01
}

ct1745_set_midi_irq_status :: proc(mixer: ^Ct1745) {
	mixer.irq_status |= 0x04
}

ct1745_ack_irq_status :: proc(mixer: ^Ct1745, mask: u8) {
	mixer.irq_status &= ~mask
}

ct1745_clear_irq_status :: proc(mixer: ^Ct1745) {
	mixer.irq_status = 0
}

ct1745_sbpro_stereo :: proc(mixer: ^Ct1745) -> bool {
	return mixer.registers[0x0E] & 0x02 != 0
}

ct1745_pack_compat :: proc(left, right: u8) -> u8 {
	return ((left >> 1) & 0x0F) << 4 | (right >> 1) & 0x0F
}

ct1745_unpack_compat :: proc(value: u8) -> (u8, u8) {
	return min(((value >> 4) & 0x0F) << 1, u8(31)), min((value & 0x0F) << 1, u8(31))
}

ct1745_pack_extended :: proc(level: u8) -> u8 {
	return (level & 0x1F) << 3
}

ct1745_unpack_extended :: proc(value: u8) -> u8 {
	return (value >> 3) & 0x1F
}

ct1745_set_cd_levels :: proc(mixer: ^Ct1745, left, right: u8) {
	mixer.registers[0x36] = min(left, u8(31))
	mixer.registers[0x37] = min(right, u8(31))
	mixer.registers[0x28] = ct1745_pack_compat(mixer.registers[0x36], mixer.registers[0x37])
}

ct1745_read_register :: proc(mixer: ^Ct1745, index: u8) -> u8 {
	switch index {
	case 0x00:
		return 0
	case 0x04:
		return ct1745_pack_compat(mixer.voice_left, mixer.voice_right)
	case 0x22:
		return ct1745_pack_compat(mixer.master_left, mixer.master_right)
	case 0x28:
		return ct1745_pack_compat(mixer.registers[0x36], mixer.registers[0x37])
	case 0x30:
		return ct1745_pack_extended(mixer.master_left)
	case 0x31:
		return ct1745_pack_extended(mixer.master_right)
	case 0x32:
		return ct1745_pack_extended(mixer.voice_left)
	case 0x33:
		return ct1745_pack_extended(mixer.voice_right)
	case 0x34, 0x35, 0x36, 0x37:
		return ct1745_pack_extended(mixer.registers[index])
	case 0x41:
		return mixer.out_left
	case 0x42:
		return mixer.out_right
	case 0x80:
		return mixer.irq_setup
	case 0x81:
		return mixer.dma_setup
	case 0x82:
		return CT1745_IRQ_IDENTITY | mixer.irq_status
	}
	return mixer.registers[index]
}

ct1745_write_register :: proc(mixer: ^Ct1745, index, value: u8) {
	switch index {
	case 0x00:
		ct1745_reset(mixer)
	case 0x04:
		mixer.voice_left, mixer.voice_right = ct1745_unpack_compat(value)
	case 0x22:
		mixer.master_left, mixer.master_right = ct1745_unpack_compat(value)
	case 0x28:
		left, right := ct1745_unpack_compat(value)
		ct1745_set_cd_levels(mixer, left, right)
	case 0x30:
		mixer.master_left = ct1745_unpack_extended(value)
	case 0x31:
		mixer.master_right = ct1745_unpack_extended(value)
	case 0x32:
		mixer.voice_left = ct1745_unpack_extended(value)
	case 0x33:
		mixer.voice_right = ct1745_unpack_extended(value)
	case 0x34, 0x35:
		mixer.registers[index] = ct1745_unpack_extended(value)
	case 0x3B:
		mixer.registers[index] = value & 0x03
	case 0x36:
		ct1745_set_cd_levels(mixer, ct1745_unpack_extended(value), mixer.registers[0x37])
	case 0x37:
		ct1745_set_cd_levels(mixer, mixer.registers[0x36], ct1745_unpack_extended(value))
	case 0x41:
		mixer.out_left = value & 0x03
	case 0x42:
		mixer.out_right = value & 0x03
	case 0x80:
		mixer.irq_setup = value
	case 0x81:
		mixer.dma_setup = value
	case 0x82:
	case:
		mixer.registers[index] = value
	}
}

ct1745_read_port :: proc(mixer: ^Ct1745, port: u16) -> (u8, bool) {
	switch port {
	case CT1745_INDEX_PORT:
		return mixer.index, true
	case CT1745_DATA_PORT:
		return ct1745_read_register(mixer, mixer.index), true
	}
	return 0xFF, false
}

ct1745_write_port :: proc(mixer: ^Ct1745, port: u16, value: u8) -> bool {
	switch port {
	case CT1745_INDEX_PORT:
		mixer.index = value
	case CT1745_DATA_PORT:
		ct1745_write_register(mixer, mixer.index, value)
	case:
		return false
	}
	return true
}

ct1745_gain_pair :: proc(mixer: ^Ct1745, voice: bool) -> (u32, u32) {
	left := CT1745_GAIN_5_Q16[voice ? mixer.voice_left : mixer.registers[0x34]]
	right := CT1745_GAIN_5_Q16[voice ? mixer.voice_right : mixer.registers[0x35]]
	return ct1745_apply_master_output_gain(mixer, left, right)
}

ct1745_apply_master_output_gain :: proc(mixer: ^Ct1745, left, right: u32) -> (u32, u32) {
	result_left :=
		u32(u64(left) * u64(CT1745_GAIN_5_Q16[mixer.master_left]) / u64(AUDIO_GAIN_UNITY))
	result_right :=
		u32(u64(right) * u64(CT1745_GAIN_5_Q16[mixer.master_right]) / u64(AUDIO_GAIN_UNITY))
	result_left =
		u32(u64(result_left) * u64(CT1745_OUT_GAIN_Q16[mixer.out_left]) / u64(AUDIO_GAIN_UNITY))
	result_right =
		u32(u64(result_right) * u64(CT1745_OUT_GAIN_Q16[mixer.out_right]) / u64(AUDIO_GAIN_UNITY))
	return result_left, result_right
}

ct1745_cd_gain_pair :: proc(mixer: ^Ct1745) -> (u32, u32) {
	left := CT1745_GAIN_5_Q16[mixer.registers[0x36]]
	right := CT1745_GAIN_5_Q16[mixer.registers[0x37]]
	return ct1745_apply_master_output_gain(mixer, left, right)
}

ct1745_speaker_gain_pair :: proc(mixer: ^Ct1745) -> (u32, u32) {
	gain := CT1745_SPEAKER_GAIN_Q16[mixer.registers[0x3B] & 0x03]
	return ct1745_apply_master_output_gain(mixer, gain, gain)
}

ct1745_apply_gain :: proc(mixer: ^Ct1745, frame: Audio_Frame, voice := true) -> Audio_Frame {
	left, right := ct1745_gain_pair(mixer, voice)
	return {
		left = audio_clamp_i16(i64(audio_scale_q16(frame.left, left))),
		right = audio_clamp_i16(i64(audio_scale_q16(frame.right, right))),
	}
}
