// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

Sb16_Test_Dma :: struct {
	bytes:   [16]u8,
	words:   [16]u16,
	byte_at: int,
	word_at: int,
}

sb16_test_read_byte :: proc(ctx: rawptr, channel: int) -> (u8, bool) {
	dma := (^Sb16_Test_Dma)(ctx)
	if dma.byte_at >= len(dma.bytes) {return 0, false}
	value := dma.bytes[dma.byte_at]
	dma.byte_at += 1
	return value, true
}

sb16_test_read_word :: proc(ctx: rawptr, channel: int) -> (u16, bool) {
	dma := (^Sb16_Test_Dma)(ctx)
	if dma.word_at >= len(dma.words) {return 0, false}
	value := dma.words[dma.word_at]
	dma.word_at += 1
	return value, true
}

sb16_test_command :: proc(sb: ^Sb16, bytes: ..u8) {
	for value in bytes {_ = sb16_write_port(sb, 0x22C, value)}
}

@(test)
test_sb16_reset_version_and_asp_probe_responses :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	_ = sb16_write_port(&sb, 0x226, 1)
	_ = sb16_write_port(&sb, 0x226, 0)
	sb16_advance_control_to(&sb, SB16_RESET_TICKS - 1)
	status, _ := sb16_read_port(&sb, 0x22E)
	testing.expect_value(t, status, u8(0))
	sb16_advance_control_to(&sb, SB16_RESET_TICKS)
	status, _ = sb16_read_port(&sb, 0x22E)
	testing.expect_value(t, status, u8(0x80))
	ack, _ := sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, ack, u8(0xAA))

	sb16_test_command(&sb, 0xE1)
	major, _ := sb16_read_port(&sb, 0x22A)
	minor, _ := sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, major, SB16_DSP_VERSION_MAJOR)
	testing.expect_value(t, minor, SB16_DSP_VERSION_MINOR)
	sb16_test_command(&sb, 0x0F, 0x83)
	asp_version, _ := sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, asp_version, u8(0x10))
}

@(test)
test_sb16_creative_copyright_response_is_exact :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	copyright := "COPYRIGHT (C) CREATIVE TECHNOLOGY LTD, 1992."
	sb16_test_command(&sb, 0xE3)
	testing.expect_value(t, sb.read_count, len(copyright) + 1)
	for expected in copyright {
		actual, _ := sb16_read_port(&sb, 0x22A)
		testing.expect_value(t, actual, u8(expected))
	}
	terminator, _ := sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, terminator, u8(0))
}

@(test)
test_sb16_software_irq_commands_latch_and_ack_separate_sources :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0xF2)
	testing.expect_value(t, sb.read_count, 0)
	testing.expect(t, sb.irq_pending_dma8)
	testing.expect(t, !sb.irq_pending_dma16)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x01))
	_, _ = sb16_read_port(&sb, 0x22E)
	testing.expect(t, !sb.irq_pending_dma8)

	sb16_test_command(&sb, 0xF3)
	testing.expect_value(t, sb.read_count, 0)
	testing.expect(t, !sb.irq_pending_dma8)
	testing.expect(t, sb.irq_pending_dma16)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x02))
	_, _ = sb16_read_port(&sb, 0x22F)
	testing.expect(t, !sb.irq_pending_dma16)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0))
}

@(test)
test_sb16_win98_fa_clone_probe_and_controller_ram_write_coexist :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)

	sb16_test_command(&sb, 0xFA)
	testing.expect_value(t, sb.pending_need, 2)
	status, _ := sb16_read_port(&sb, 0x22E)
	testing.expect_value(t, status, u8(0x80))
	testing.expect_value(t, sb.pending_need, 0)
	testing.expect_value(t, sb.read_count, 1)
	response, _ := sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, response, u8(0xFF))

	sb16_test_command(&sb, 0xE1)
	testing.expect_value(t, sb.read_count, 2)
	_, _ = sb16_read_port(&sb, 0x22A)
	_, _ = sb16_read_port(&sb, 0x22A)

	sb16_test_command(&sb, 0xFA, 0x42, 0xA5)
	testing.expect_value(t, sb.pending_need, 0)
	testing.expect_value(t, sb.controller_ram[0x42], u8(0xA5))
	sb16_test_command(&sb, 0xF9, 0x42)
	response, _ = sb16_read_port(&sb, 0x22A)
	testing.expect_value(t, response, u8(0xA5))
}

@(test)
test_sb16_single_and_auto_init_dma_frame_and_irq_semantics :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	dma: Sb16_Test_Dma
	dma.bytes[0] = 0x00
	dma.bytes[1] = 0x80
	dma.bytes[2] = 0xFF
	dma.bytes[3] = 0x40
	sb16_test_command(&sb, 0x41, 0x56, 0x22)
	sb16_test_command(&sb, 0xC0, 0x00, 0x01, 0x00)
	frame, produced := sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	testing.expect_value(t, frame, Audio_Frame{-32_768, -32_768})
	_, pending := sb16_take_irq(&sb)
	testing.expect(t, !pending)
	frame, produced = sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	testing.expect_value(t, frame, Audio_Frame{})
	_, pending = sb16_take_irq(&sb)
	testing.expect(t, pending)
	testing.expect(t, !sb.playing)

	sb16_test_command(&sb, 0xC4, 0x00, 0x00, 0x00)
	_, produced = sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	_, pending = sb16_take_irq(&sb)
	testing.expect(t, pending)
	testing.expect(t, sb.playing)
	_, produced = sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	_, pending = sb16_take_irq(&sb)
	testing.expect(t, pending)
}

@(test)
test_sb16_signed_16bit_stereo_consumes_dma5_words :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	dma: Sb16_Test_Dma
	dma.words[0] = 0x8000
	dma.words[1] = 0x7FFF
	sb16_test_command(&sb, 0xB0, 0x30, 0x01, 0x00)
	frame, produced := sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	testing.expect_value(t, frame, Audio_Frame{-32_768, 32_767})
	dma16, pending := sb16_take_irq(&sb)
	testing.expect(t, pending)
	testing.expect(t, dma16)
}

@(test)
test_sb16_dma_status_read_acknowledges_pending_irq :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	dma: Sb16_Test_Dma
	dma.bytes[0] = 0x80
	sb16_test_command(&sb, 0xC0, 0x00, 0x00, 0x00)
	_, produced := sb16_render_sample(&sb, &dma, sb16_test_read_byte, sb16_test_read_word)
	testing.expect(t, produced)
	_, _ = sb16_read_port(&sb, 0x22E)
	_, pending := sb16_take_irq(&sb)
	testing.expect(t, !pending)
}

@(test)
test_sb16_dma_ack_ports_clear_only_their_irq_source :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_raise_dma_irq(&sb, false)
	sb16_raise_dma_irq(&sb, true)
	sb16_raise_midi_irq(&sb)
	testing.expect_value(t, sb.irq_events_dma8, u64(1))
	testing.expect_value(t, sb.irq_events_dma16, u64(1))
	testing.expect_value(t, sb.irq_events_midi, u64(1))
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x07))

	_, _ = sb16_read_port(&sb, 0x22E)
	testing.expect(t, !sb.irq_pending_dma8)
	testing.expect(t, sb.irq_pending_dma16)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x06))

	_, _ = sb16_read_port(&sb, 0x22F)
	testing.expect(t, !sb.irq_pending_dma16)
	testing.expect(t, sb.irq_pending_midi)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x04))
	sb16_ack_midi_irq(&sb)
	testing.expect(t, !sb.irq_pending_midi)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0))
}

@(test)
test_sb16_dma_starvation_outputs_silence_without_consuming_block :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x10, 0xFF)
	sb16_test_command(&sb, 0xC0, 0x00, 0x00, 0x00)
	frame, produced := sb16_render_sample(&sb, nil, nil, nil)
	testing.expect(t, produced)
	testing.expect_value(t, frame, Audio_Frame{})
	testing.expect_value(t, sb.raw_frame, Audio_Frame{})
	testing.expect_value(t, sb.block_remaining, u32(1))
	testing.expect_value(t, sb.starvation_frames, u64(1))
	_, pending := sb16_take_irq(&sb)
	testing.expect(t, !pending)
}

@(test)
test_sb16_timed_silence_raises_dma8_irq_without_dma_reads :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x80, 0x01, 0x00)
	testing.expect(t, sb.silence_active)
	_, produced := sb16_render_sample(&sb, nil, nil, nil)
	testing.expect(t, produced)
	_, pending := sb16_take_irq(&sb)
	testing.expect(t, !pending)
	_, produced = sb16_render_sample(&sb, nil, nil, nil)
	testing.expect(t, produced)
	dma16: bool
	dma16, pending = sb16_take_irq(&sb)
	testing.expect(t, pending)
	testing.expect(t, !dma16)
	testing.expect(t, !sb.playing)
	testing.expect_value(t, ct1745_read_register(&sb.mixer, 0x82), u8(0x01))
}

@(test)
test_sb16_rate_commands_are_limited_to_host_output_rate :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb.now_tick = 1_000
	sb16_test_command(&sb, 0x40, 0xFF)
	testing.expect_value(t, sb.rate_hz, u32(1_000_000))
	testing.expect_value(t, sb16_output_rate(&sb), SB16_MAX_OUTPUT_RATE)
	sb16_arm(&sb, false, false, false, false, 1)
	testing.expect_value(
		t,
		sb.next_sample_tick - sb.now_tick,
		max(AUDIO_MASTER_CLOCK_HZ / u64(SB16_MAX_OUTPUT_RATE), u64(1)),
	)
	sb16_test_command(&sb, 0x41, 0xFF, 0xFF)
	testing.expect_value(t, sb.rate_hz, SB16_MAX_OUTPUT_RATE)
}

@(test)
test_sb16_time_constant_preserves_stereo_byte_rate :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x40, 0xF5)
	testing.expect_value(t, sb.rate_hz, u32(90_909))
	sb.stereo = true
	testing.expect_value(t, sb16_output_rate(&sb), u32(45_454))
}

@(test)
test_sb16_unimplemented_commands_still_consume_their_arguments :: proc(t: ^testing.T) {
	sb: Sb16
	sb16_init(&sb)
	sb16_test_command(&sb, 0x42, 0xE1, 0xE1)
	testing.expect_value(t, sb.read_count, 0)
	sb16_test_command(&sb, 0xE2, 0xE1)
	testing.expect_value(t, sb.read_count, 0)
	sb16_test_command(&sb, 0xE1)
	testing.expect_value(t, sb.read_count, 2)
}
