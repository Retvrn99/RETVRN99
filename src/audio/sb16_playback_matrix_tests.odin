// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

Sb16_Matrix_Dma :: struct {
	bytes:      [16]u8,
	words:      [16]u16,
	byte_limit: int,
	word_limit: int,
	byte_at:    int,
	word_at:    int,
}

sb16_matrix_read_byte :: proc(ctx: rawptr, channel: int) -> (u8, bool) {
	dma := (^Sb16_Matrix_Dma)(ctx)
	if dma.byte_at >= dma.byte_limit {return 0, false}
	value := dma.bytes[dma.byte_at]
	dma.byte_at += 1
	return value, true
}

sb16_matrix_read_word :: proc(ctx: rawptr, channel: int) -> (u16, bool) {
	dma := (^Sb16_Matrix_Dma)(ctx)
	if dma.word_at >= dma.word_limit {return 0, false}
	value := dma.words[dma.word_at]
	dma.word_at += 1
	return value, true
}

@(test)
test_sb16_native_pcm_playback_command_matrix :: proc(t: ^testing.T) {
	cases := [?]struct {
		dma16:         bool,
		stereo:       bool,
		signed:       bool,
		byte_left:    u8,
		byte_right:   u8,
		word_left:    u16,
		word_right:   u16,
		expected:      Audio_Frame,
	} {
		{false, false, false, 0x00, 0x00, 0, 0, {-32_768, -32_768}},
		{false, false, true, 0x80, 0x00, 0, 0, {-32_768, -32_768}},
		{false, true, false, 0x00, 0xFF, 0, 0, {-32_768, 32_512}},
		{false, true, true, 0x80, 0x7F, 0, 0, {-32_768, 32_512}},
		{true, false, false, 0, 0, 0x0000, 0, {-32_768, -32_768}},
		{true, false, true, 0, 0, 0x8000, 0, {-32_768, -32_768}},
		{true, true, false, 0, 0, 0x0000, 0xFFFF, {-32_768, 32_767}},
		{true, true, true, 0, 0, 0x8000, 0x7FFF, {-32_768, 32_767}},
	}

	for test_case in cases {
		for auto_index in 0 ..< 2 {
			auto_init := auto_index == 1
			sb: Sb16
			sb16_init(&sb)
			dma: Sb16_Test_Dma
			dma.bytes[0] = test_case.byte_left
			dma.bytes[1] = test_case.byte_right
			dma.words[0] = test_case.word_left
			dma.words[1] = test_case.word_right

			command := test_case.dma16 ? u8(0xB0) : u8(0xC0)
			if auto_init {command |= 0x04}
			mode: u8
			if test_case.stereo {mode |= 0x20}
			if test_case.signed {mode |= 0x10}
			count := test_case.stereo ? u8(1) : u8(0)
			sb16_test_command(&sb, command, mode, count, 0x00)

			frame, produced := sb16_render_sample(
				&sb,
				&dma,
				sb16_test_read_byte,
				sb16_test_read_word,
			)
			testing.expect(t, produced)
			testing.expect_value(t, frame, test_case.expected)
			testing.expect_value(t, sb.dma_16bit, test_case.dma16)
			testing.expect_value(t, sb.stereo, test_case.stereo)
			testing.expect_value(t, sb.signed_samples, test_case.signed)
			testing.expect_value(t, dma.byte_at, test_case.dma16 ? 0 : int(count) + 1)
			testing.expect_value(t, dma.word_at, test_case.dma16 ? int(count) + 1 : 0)
			dma16, pending := sb16_take_irq(&sb)
			testing.expect(t, pending)
			testing.expect_value(t, dma16, test_case.dma16)
			testing.expect_value(t, sb.playing, auto_init)
			testing.expect_value(t, sb.block_remaining, auto_init ? u32(count) + 1 : u32(0))
		}
	}
}

@(test)
test_sb16_legacy_pcm_single_auto_init_high_speed_and_sbpro_stereo_commands :: proc(t: ^testing.T) {
	cases := [?]struct {
		command:       u8,
		auto_init:     bool,
		uses_count:    bool,
		sbpro_stereo: bool,
	} {
		{0x14, false, true, false},
		{0x14, false, true, true},
		{0x1C, true, false, false},
		{0x90, true, false, false},
		{0x91, false, false, false},
	}
	for test_case in cases {
		sb: Sb16
		sb16_init(&sb)
		dma: Sb16_Test_Dma
		dma.bytes[0] = 0x00
		dma.bytes[1] = 0xFF
		if test_case.sbpro_stereo {ct1745_write_register(&sb.mixer, 0x0E, 0x02)}
		count := test_case.sbpro_stereo ? u8(1) : u8(0)
		if test_case.uses_count {
			sb16_test_command(&sb, test_case.command, count, 0x00)
		} else {
			sb16_test_command(&sb, 0x48, count, 0x00)
			sb16_test_command(&sb, test_case.command)
		}

		frame, produced := sb16_render_sample(&sb, &dma, sb16_test_read_byte, nil)
		testing.expect(t, produced)
		testing.expect_value(
			t,
			frame,
			test_case.sbpro_stereo ? Audio_Frame{-32_768, 32_512} : Audio_Frame{-32_768, -32_768},
		)
		testing.expect_value(t, dma.byte_at, test_case.sbpro_stereo ? 2 : 1)
		dma16, pending := sb16_take_irq(&sb)
		testing.expect(t, pending)
		testing.expect(t, !dma16)
		testing.expect_value(t, sb.playing, test_case.auto_init)
	}
}

@(test)
test_sb16_odd_stereo_blocks_publish_partial_frame_without_crossing_block :: proc(t: ^testing.T) {
	for dma16_index in 0 ..< 2 {
		for auto_index in 0 ..< 2 {
			dma16 := dma16_index == 1
			auto_init := auto_index == 1
			sb: Sb16
			sb16_init(&sb)
			dma: Sb16_Matrix_Dma
			dma.byte_limit = 4
			dma.word_limit = 4
			dma.bytes[0] = 0x80
			dma.bytes[1] = 0x7F
			dma.bytes[2] = 0x40
			dma.bytes[3] = 0x20
			dma.words[0] = 0x8000
			dma.words[1] = 0x7FFF
			dma.words[2] = 0x4000
			dma.words[3] = 0x2000

			command := dma16 ? u8(0xB0) : u8(0xC0)
			if auto_init {command |= 0x04}
			sb16_test_command(&sb, command, 0x30, 0x02, 0x00)
			first, first_produced := sb16_render_sample(
				&sb,
				&dma,
				sb16_matrix_read_byte,
				sb16_matrix_read_word,
			)
			testing.expect(t, first_produced)
			testing.expect_value(t, first, Audio_Frame{-32_768, 32_512 + (dma16 ? 255 : 0)})

			last, last_produced := sb16_render_sample(
				&sb,
				&dma,
				sb16_matrix_read_byte,
				sb16_matrix_read_word,
			)
			testing.expect(t, last_produced)
			testing.expect_value(t, last, Audio_Frame{16_384, 0})
			testing.expect_value(t, dma.byte_at, dma16 ? 0 : 3)
			testing.expect_value(t, dma.word_at, dma16 ? 3 : 0)
			irq_dma16, pending := sb16_take_irq(&sb)
			testing.expect(t, pending)
			testing.expect_value(t, irq_dma16, dma16)
			testing.expect_value(t, sb.playing, auto_init)
			testing.expect_value(t, sb.block_remaining, auto_init ? u32(3) : u32(0))
		}
	}
}

@(test)
test_sb16_pause_resume_and_auto_init_exit_for_both_dma_widths :: proc(t: ^testing.T) {
	for dma16_index in 0 ..< 2 {
		dma16 := dma16_index == 1
		sb: Sb16
		sb16_init(&sb)
		dma: Sb16_Test_Dma
		dma.bytes[0] = 0x80
		dma.bytes[1] = 0x90
		dma.words[0] = 0x8000
		dma.words[1] = 0x9000
		command := dma16 ? u8(0xB4) : u8(0xC4)
		sb16_test_command(&sb, command, 0x10, 0x00, 0x00)

		sb16_test_command(&sb, dma16 ? u8(0xD5) : u8(0xD0))
		_, produced := sb16_render_sample(
			&sb,
			&dma,
			sb16_test_read_byte,
			sb16_test_read_word,
		)
		testing.expect(t, !produced)
		testing.expect(t, sb.paused)
		testing.expect_value(t, dma.byte_at, 0)
		testing.expect_value(t, dma.word_at, 0)

		sb16_test_command(&sb, dma16 ? u8(0xD6) : u8(0xD4))
		_, produced = sb16_render_sample(
			&sb,
			&dma,
			sb16_test_read_byte,
			sb16_test_read_word,
		)
		testing.expect(t, produced)
		testing.expect(t, sb.playing && !sb.paused)
		_, pending := sb16_take_irq(&sb)
		testing.expect(t, pending)

		sb16_test_command(&sb, dma16 ? u8(0xD9) : u8(0xDA))
		testing.expect(t, !sb.auto_init)
		_, produced = sb16_render_sample(
			&sb,
			&dma,
			sb16_test_read_byte,
			sb16_test_read_word,
		)
		testing.expect(t, produced)
		testing.expect(t, !sb.playing)
		_, pending = sb16_take_irq(&sb)
		testing.expect(t, pending)
	}
}

@(test)
test_sb16_stereo_starvation_preserves_available_left_and_does_not_consume_right :: proc(t: ^testing.T) {
	for dma16_index in 0 ..< 2 {
		dma16 := dma16_index == 1
		sb: Sb16
		sb16_init(&sb)
		dma: Sb16_Matrix_Dma
		dma.bytes[0] = 0x40
		dma.bytes[1] = 0xC0
		dma.words[0] = 0x4000
		dma.words[1] = 0xC000
		dma.byte_limit = dma16 ? 0 : 1
		dma.word_limit = dma16 ? 1 : 0
		sb16_test_command(&sb, dma16 ? u8(0xB0) : u8(0xC0), 0x30, 0x01, 0x00)

		frame, produced := sb16_render_sample(
			&sb,
			&dma,
			sb16_matrix_read_byte,
			sb16_matrix_read_word,
		)
		testing.expect(t, produced)
		testing.expect_value(t, frame, Audio_Frame{})
		testing.expect(t, sb.pending_left_valid)
		testing.expect_value(t, sb.pending_left, i16(16_384))
		testing.expect_value(t, sb.block_remaining, u32(1))
		testing.expect_value(t, dma.byte_at, dma16 ? 0 : 1)
		testing.expect_value(t, dma.word_at, dma16 ? 1 : 0)

		frame, produced = sb16_render_sample(
			&sb,
			&dma,
			sb16_matrix_read_byte,
			sb16_matrix_read_word,
		)
		testing.expect(t, produced)
		testing.expect_value(t, frame, Audio_Frame{})
		testing.expect_value(t, sb.block_remaining, u32(1))
		testing.expect_value(t, dma.byte_at, dma16 ? 0 : 1)
		testing.expect_value(t, dma.word_at, dma16 ? 1 : 0)
		_, pending := sb16_take_irq(&sb)
		testing.expect(t, !pending)

		dma.byte_limit = dma16 ? 0 : 2
		dma.word_limit = dma16 ? 2 : 0
		frame, produced = sb16_render_sample(
			&sb,
			&dma,
			sb16_matrix_read_byte,
			sb16_matrix_read_word,
		)
		testing.expect(t, produced)
		testing.expect_value(t, frame, Audio_Frame{16_384, -16_384})
		testing.expect_value(t, dma.byte_at, dma16 ? 0 : 2)
		testing.expect_value(t, dma.word_at, dma16 ? 2 : 0)
		_, pending = sb16_take_irq(&sb)
		testing.expect(t, pending)
	}
}

@(test)
test_sb16_direct_dac_timed_silence_and_separate_irq_acknowledgements :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x10, 0xFF)
	testing.expect(t, sb.direct_dac_valid)
	testing.expect_value(t, sb.raw_frame, Audio_Frame{32_512, 32_512})

	sb16_test_command(&sb, 0x80, 0x00, 0x00)
	frame, produced := sb16_render_sample(&sb, nil, nil, nil)
	testing.expect(t, produced)
	testing.expect_value(t, frame, Audio_Frame{})
	testing.expect(t, !sb.direct_dac_valid)
	testing.expect(t, sb.irq_pending_dma8)
	sb16_raise_dma_irq(&sb, true)
	sb16_raise_midi_irq(&sb)
	_, _ = sb16_read_port(&sb, 0x22E)
	testing.expect(t, !sb.irq_pending_dma8)
	testing.expect(t, sb.irq_pending_dma16)
	testing.expect(t, sb.irq_pending_midi)
	_, _ = sb16_read_port(&sb, 0x22F)
	testing.expect(t, !sb.irq_pending_dma16)
	testing.expect(t, sb.irq_pending_midi)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x24))
}

@(test)
test_sb16_creative_adpcm_single_and_auto_init_command_families :: proc(t: ^testing.T) {
	single_cases := [?]struct {
		command:          u8,
		mode:             Sb16_Adpcm_Mode,
		wants_reference: bool,
		encoded:          u8,
		sample_count:     int,
		first_sample:     i16,
	} {
		{0x74, .Bits_4, false, 0x50, 2, 1_280},
		{0x75, .Bits_4, true, 0x50, 2, -15_104},
		{0x76, .Bits_26, false, 0xA4, 3, -256},
		{0x77, .Bits_26, true, 0xA4, 3, -16_640},
		{0x16, .Bits_2, false, 0x40, 4, 256},
		{0x17, .Bits_2, true, 0x40, 4, -16_128},
	}
	for test_case in single_cases {
		sb: Sb16
		sb16_init(&sb)
		dma: Sb16_Matrix_Dma
		if test_case.wants_reference {
			dma.bytes[0] = 0x40
			dma.bytes[1] = test_case.encoded
			dma.byte_limit = 2
			sb16_test_command(&sb, test_case.command, 0x01, 0x00)
		} else {
			dma.bytes[0] = test_case.encoded
			dma.byte_limit = 1
			sb16_test_command(&sb, test_case.command, 0x00, 0x00)
		}
		testing.expect_value(t, sb.adpcm.mode, test_case.mode)
		for sample_index in 0 ..< test_case.sample_count {
			frame, produced := sb16_render_sample(&sb, &dma, sb16_matrix_read_byte, nil)
			testing.expect(t, produced)
			testing.expect_value(t, frame.left, frame.right)
			if sample_index == 0 {testing.expect_value(t, frame.left, test_case.first_sample)}
		}
		testing.expect_value(t, dma.byte_at, test_case.wants_reference ? 2 : 1)
		testing.expect(t, !sb.playing)
		testing.expect(t, !sb16_adpcm_active(&sb.adpcm))
		dma16, pending := sb16_take_irq(&sb)
		testing.expect(t, pending)
		testing.expect(t, !dma16)
	}

	auto_cases := [?]struct {
		command:      u8,
		mode:         Sb16_Adpcm_Mode,
		encoded:      u8,
		sample_count: int,
	} {
		{0x7D, .Bits_4, 0x50, 2},
		{0x7F, .Bits_26, 0xA4, 3},
		{0x1F, .Bits_2, 0x40, 4},
	}
	for test_case in auto_cases {
		sb: Sb16
		sb16_init(&sb)
		dma: Sb16_Matrix_Dma
		dma.bytes[0] = 0x40
		dma.bytes[1] = test_case.encoded
		dma.byte_limit = 2
		sb16_test_command(&sb, 0x48, 0x01, 0x00)
		sb16_test_command(&sb, test_case.command)
		testing.expect(t, sb.playing)
		testing.expect(t, sb.auto_init)
		testing.expect_value(t, sb.block_size, u32(2))
		testing.expect_value(t, sb.block_remaining, u32(2))
		testing.expect_value(t, sb.adpcm.mode, test_case.mode)
		testing.expect(t, sb.adpcm.wants_reference)
		for _ in 0 ..< test_case.sample_count {
			frame, produced := sb16_render_sample(&sb, &dma, sb16_matrix_read_byte, nil)
			testing.expect(t, produced)
			testing.expect_value(t, frame.left, frame.right)
		}
		testing.expect_value(t, dma.byte_at, 2)
		testing.expect(t, sb.playing)
		testing.expect(t, sb.auto_init)
		testing.expect_value(t, sb.block_remaining, u32(2))
		dma16, pending := sb16_take_irq(&sb)
		testing.expect(t, pending)
		testing.expect(t, !dma16)
	}
}
