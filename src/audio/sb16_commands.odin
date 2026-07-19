// SPDX-License-Identifier: GPL-3.0-only
package audio

sb16_dispatch :: proc(sb: ^Sb16, command: u8, args: []u8) {
	if command >= 0xB0 && command <= 0xBF {
		if command & 0x08 != 0 {return}
		mode := len(args) > 0 ? args[0] : 0
		count := len(args) >= 3 ? u32(args[1]) | u32(args[2]) << 8 : 0
		sb16_arm(sb, true, command & 0x04 != 0, mode & 0x20 != 0, mode & 0x10 != 0, count + 1)
		return
	}
	if command >= 0xC0 && command <= 0xCF {
		if command & 0x08 != 0 {return}
		mode := len(args) > 0 ? args[0] : 0
		count := len(args) >= 3 ? u32(args[1]) | u32(args[2]) << 8 : 0
		sb16_arm(sb, false, command & 0x04 != 0, mode & 0x20 != 0, mode & 0x10 != 0, count + 1)
		return
	}

	switch command {
	case 0x04:
		if len(args) > 0 {sb.asp_mode = args[0]}
	case 0x05:
	case 0x08:
		sb16_queue_read(sb, len(args) > 0 && args[0] == 0x03 ? 0x10 : 0xFF)
	case 0x0E:
		if len(args) >= 2 {sb.asp_registers[args[0]] = args[1]}
	case 0x0F:
		if len(args) > 0 {
			index := args[0]
			if index == 0x83 && sb.asp_mode & 0x88 != 0x88 {sb.asp_registers[index] = 0x10}
			sb16_queue_read(sb, sb.asp_registers[index])
		}
	case 0x10:
		if len(args) > 0 {
			sb.direct_dac = args[0]
			sb.direct_dac_valid = true
			sample := audio_pcm_u8(args[0])
			sb.raw_frame = {sample, sample}
		}
	case 0x14:
		count := len(args) >= 2 ? u32(args[0]) | u32(args[1]) << 8 : 0
		sb16_arm(sb, false, false, false, false, count + 1)
	case 0x1C, 0x90:
		sb16_arm(sb, false, true, false, false, sb.block_size)
	case 0x1F:
		sb16_arm_adpcm(sb, .Bits_2, true, true, sb.block_size)
	case 0x40:
		if len(args) > 0 {
			divisor := u32(256) - u32(args[0])
			if divisor > 0 {sb.rate_hz = 1_000_000 / divisor}
			sb.rate_is_byte_rate = true
		}
	case 0x41:
		if len(args) >= 2 {
			sb.rate_hz = clamp(u32(args[0]) << 8 | u32(args[1]), u32(1), SB16_MAX_OUTPUT_RATE)
			sb.rate_is_byte_rate = false
		}
	case 0x48:
		if len(args) >= 2 {sb.block_size = (u32(args[0]) | u32(args[1]) << 8) + 1}
	case 0x74, 0x75, 0x76, 0x77, 0x16, 0x17:
		count := len(args) >= 2 ? u32(args[0]) | u32(args[1]) << 8 : 0
		mode: Sb16_Adpcm_Mode
		switch command {
		case 0x74, 0x75:
			mode = .Bits_4
		case 0x76, 0x77:
			mode = .Bits_26
		case:
			mode = .Bits_2
		}
		wants_reference := command == 0x75 || command == 0x77 || command == 0x17
		sb16_arm_adpcm(sb, mode, wants_reference, false, count + 1)
	case 0x7D:
		sb16_arm_adpcm(sb, .Bits_4, true, true, sb.block_size)
	case 0x7F:
		sb16_arm_adpcm(sb, .Bits_26, true, true, sb.block_size)
	case 0x80:
		count := len(args) >= 2 ? u32(args[0]) | u32(args[1]) << 8 : 0
		sb16_arm_silence(sb, count + 1)
	case 0x91:
		sb16_arm(sb, false, false, false, false, sb.block_size)
	case 0xD0, 0xD5:
		sb16_halt(sb)
	case 0xD1:
		sb.speaker_enabled = true
	case 0xD3:
		sb.speaker_enabled = false
	case 0xD4, 0xD6:
		sb16_continue(sb)
	case 0xD8:
		sb16_queue_read(sb, sb.speaker_enabled ? 0xFF : 0x00)
	case 0xD9, 0xDA:
		sb.auto_init = false
	case 0xE0:
		if len(args) > 0 {sb16_queue_read(sb, ~args[0])}
	case 0xE1:
		sb16_queue_read(sb, SB16_DSP_VERSION_MAJOR)
		sb16_queue_read(sb, SB16_DSP_VERSION_MINOR)
	case 0xE3:
		for value in "COPYRIGHT (C) CREATIVE TECHNOLOGY LTD, 1992." {
			sb16_queue_read(sb, u8(value))
		}
		sb16_queue_read(sb, 0)
	case 0xE4:
		if len(args) > 0 {sb.test_register = args[0]}
	case 0xE8:
		sb16_queue_read(sb, sb.test_register)
	case 0xF2:
		sb16_raise_dma_irq(sb, false)
	case 0xF3:
		sb16_raise_dma_irq(sb, true)
	case 0xF9:
		if len(args) > 0 {sb16_queue_read(sb, sb.controller_ram[args[0]])}
	case 0xFA:
		if len(args) >= 2 {sb.controller_ram[args[0]] = args[1]}
	}
}

sb16_write_command_byte :: proc(sb: ^Sb16, value: u8) {
	if sb.pending_need > 0 {
		sb.pending_args[sb.pending_count] = value
		sb.pending_count += 1
		if sb.pending_count == sb.pending_need {
			sb16_dispatch(sb, sb.pending_command, sb.pending_args[:sb.pending_count])
			sb.pending_need = 0
			sb.pending_count = 0
		}
		return
	}
	need := sb16_command_arity(value)
	if need == 0 {
		sb16_dispatch(sb, value, nil)
		return
	}
	sb.pending_command = value
	sb.pending_need = need
	sb.pending_count = 0
}
