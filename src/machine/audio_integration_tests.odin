// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import disk "../disk"
import "core:testing"

machine_test_audio_timing_init :: proc(m: ^Machine) -> bool {
	if !sound.audio_mixer_init(&m.audio) {return false}
	pit_init(&m.pit)
	dma_init(&m.dma)
	sound.gsw_sound_init(&m.gsw_sound)
	cmos_init(&m.cmos, 64 * 1024 * 1024)
	i8042_init(&m.kbd, nil, nil)
	uart_init_com1(&m.serial1)
	uart_init_com2(&m.serial2)
	lpt_init_lpt1(&m.parallel1)
	lpt_init_lpt2(&m.parallel2)
	disk.atapi_init(&m.atapi)
	disk.bmide_init(&m.bmide)
	m.vga.timing.elapsed_ns = ~u64(0)
	pit_out(&m.pit, 0x43, 0xB6)
	pit_out(&m.pit, 0x42, 0xA9)
	pit_out(&m.pit, 0x42, 0x04)
	pit_port61_write(&m.pit, 0x03)
	pit_clear_channel2_transitions(&m.pit)
	_ = sound.audio_mixer_set_speaker_state(&m.audio, 0, true, pit_channel_out(&m.pit, 2))
	return true
}

audio_test_count_left_zero_crossings :: proc(
	m: ^Machine,
	consumer: ^sound.Audio_Consumer,
	milliseconds: int,
) -> int {
	frames: [sound.AUDIO_RENDER_BATCH]sound.Audio_Frame
	previous_sign := 0
	zero_crossings := 0
	for _ in 0 ..< milliseconds {
		machine_advance_time_ns(m, 1_000_000)
		sound.audio_consumer_read(consumer, frames[:])
		for frame in frames {
			sign := frame.left > 0 ? 1 : (frame.left < 0 ? -1 : 0)
			if sign != 0 {
				if previous_sign != 0 && sign != previous_sign {zero_crossings += 1}
				previous_sign = sign
			}
		}
	}
	return zero_crossings
}

@(test)
test_machine_master_deadline_partition_preserves_speaker_audio :: proc(t: ^testing.T) {
	coarse := new(Machine)
	partitioned := new(Machine)
	defer free(coarse)
	defer free(partitioned)
	if !testing.expect(t, machine_test_audio_timing_init(coarse)) {return}
	if !testing.expect(t, machine_test_audio_timing_init(partitioned)) {return}

	coarse_sink, partitioned_sink: sound.Audio_Offline
	sound.audio_offline_init(&coarse_sink, machine_audio_output(coarse))
	sound.audio_offline_init(&partitioned_sink, machine_audio_output(partitioned))
	machine_advance_time_ns(coarse, 100_000_000)
	for _ in 0 ..< 100 {machine_advance_time_ns(partitioned, 1_000_000)}
	sound.audio_offline_consume(&coarse_sink, 4_800)
	sound.audio_offline_consume(&partitioned_sink, 4_800)

	coarse_result := sound.audio_offline_snapshot(&coarse_sink)
	partitioned_result := sound.audio_offline_snapshot(&partitioned_sink)
	testing.expect_value(
		t,
		master_timeline_now(coarse.timeline),
		master_timeline_now(partitioned.timeline),
	)
	testing.expect_value(t, coarse.active_ns, partitioned.active_ns)
	testing.expect_value(t, coarse_result, partitioned_result)
	testing.expect(t, coarse_result.non_silent_frames > 0)
	telemetry := sound.audio_mixer_telemetry(&coarse.audio)
	testing.expect(t, telemetry.speaker_transitions_applied > 150)
	testing.expect_value(t, telemetry.speaker_transitions_late, u64(0))
	testing.expect_value(t, telemetry.speaker_transitions_dropped, u64(0))
}

@(test)
test_machine_pc_speaker_tone_crosses_zero_without_late_edges :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	consumer: sound.Audio_Consumer
	sound.audio_consumer_init(&consumer, machine_audio_output(m))
	sound.audio_consumer_discard_queued(&consumer)
	consumer.gain = sound.AUDIO_RAMP_FRAMES
	zero_crossings := audio_test_count_left_zero_crossings(m, &consumer, 100)
	testing.expect(t, zero_crossings >= 180)
	testing.expect(t, zero_crossings <= 220)
	telemetry := sound.audio_mixer_telemetry(&m.audio)
	testing.expect_value(t, telemetry.speaker_transitions_late, u64(0))
	testing.expect_value(t, telemetry.speaker_transitions_dropped, u64(0))
}

@(test)
test_machine_pc_speaker_440_hz_tracks_pit_divisor :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	// 1,193,182 / 2,712 = 439.96 Hz.
	pit_out(&m.pit, 0x43, 0xB6)
	pit_out(&m.pit, 0x42, 0x98)
	pit_out(&m.pit, 0x42, 0x0A)
	pit_clear_channel2_transitions(&m.pit)
	_ = sound.audio_mixer_set_speaker_state(&m.audio, 0, true, pit_channel_out(&m.pit, 2))

	consumer: sound.Audio_Consumer
	sound.audio_consumer_init(&consumer, machine_audio_output(m))
	sound.audio_consumer_discard_queued(&consumer)
	consumer.gain = sound.AUDIO_RAMP_FRAMES
	zero_crossings := audio_test_count_left_zero_crossings(m, &consumer, 250)
	testing.expect(t, zero_crossings >= 210)
	testing.expect(t, zero_crossings <= 230)
	telemetry := sound.audio_mixer_telemetry(&m.audio)
	testing.expect_value(t, telemetry.speaker_transitions_late, u64(0))
	testing.expect_value(t, telemetry.speaker_transitions_dropped, u64(0))
}

@(test)
test_machine_pc_speaker_port61_bit_bang_preserves_every_edge :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	testing.expect(t, machine_io_write(m, 0x61, 1, 0x00))

	consumer: sound.Audio_Consumer
	sound.audio_consumer_init(&consumer, machine_audio_output(m))
	sound.audio_consumer_discard_queued(&consumer)
	consumer.gain = sound.AUDIO_RAMP_FRAMES
	before := sound.audio_mixer_telemetry(&m.audio).speaker_transitions_applied
	for edge in 0 ..< 40 {
		machine_advance_time_ns(m, 125_000)
		value := edge & 1 == 0 ? u32(0x02) : u32(0x00)
		testing.expect(t, machine_io_write(m, 0x61, 1, value))
	}
	machine_advance_time_ns(m, 5_000_000)
	frames: [sound.AUDIO_RENDER_BATCH * 10]sound.Audio_Frame
	sound.audio_consumer_read(&consumer, frames[:])
	nonzero := 0
	for frame in frames {
		if frame.left != 0 || frame.right != 0 {nonzero += 1}
	}
	testing.expect(t, nonzero > 100)
	telemetry := sound.audio_mixer_telemetry(&m.audio)
	testing.expect_value(t, telemetry.speaker_transitions_applied - before, u64(40))
	testing.expect_value(t, telemetry.speaker_transitions_late, u64(0))
	testing.expect_value(t, telemetry.speaker_transitions_dropped, u64(0))
	port61, handled := machine_io_read(m, 0x61, 1)
	testing.expect(t, handled)
	testing.expect_value(t, port61 & 0x03, u32(0))
}

audio_test_opl3_write_register :: proc(opl: ^sound.Opl3, index, value: u8) {
	_ = sound.opl3_write_port(opl, sound.OPL3_BASE_PORT, index)
	_ = sound.opl3_write_port(opl, sound.OPL3_BASE_PORT + 1, value)
}

@(test)
test_machine_audio_scheduler_batches_opl_samples_but_preserves_timer_deadline :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	audio_test_opl3_write_register(&m.opl3, 0xA0, 0x98)
	audio_test_opl3_write_register(&m.opl3, 0xB0, 0x31)
	sample_deadline, sample_pending := sound.opl3_sample_deadline(&m.opl3)
	deadline, pending := machine_audio_next_deadline(m)
	testing.expect(t, sample_pending)
	testing.expect(t, pending)
	testing.expect(t, deadline > sample_deadline)
	testing.expect_value(t, deadline, sound.AUDIO_MASTER_CLOCK_HZ / 1_000)

	machine_advance_time_ns(m, 100_000_000)
	testing.expect(t, m.opl3.global_sample_index >= 4_970)
	testing.expect(t, m.opl3.global_sample_index <= 4_972)
	testing.expect(t, m.device_advances[int(Scheduled_Device.Audio)] <= 102)

	timer_machine := new(Machine)
	defer free(timer_machine)
	if !testing.expect(t, machine_test_audio_timing_init(timer_machine)) {return}
	_ = sound.audio_mixer_set_speaker_state(&timer_machine.audio, 0, false, false)
	pit_port61_write(&timer_machine.pit, 0)
	audio_test_opl3_write_register(&timer_machine.opl3, 0x02, 0xFF)
	audio_test_opl3_write_register(&timer_machine.opl3, 0x04, 0x01)
	timer_deadline, timer_pending := sound.opl3_timer_deadline(
		&timer_machine.opl3,
		&timer_machine.opl3.timer1,
	)
	deadline, pending = machine_audio_next_deadline(timer_machine)
	testing.expect(t, timer_pending)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, timer_deadline)
}

@(test)
test_machine_audio_scheduler_keeps_exact_sb16_silence_block_deadline :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	sound.sb16_write_command_byte(&m.sb16, 0x80)
	sound.sb16_write_command_byte(&m.sb16, 9)
	sound.sb16_write_command_byte(&m.sb16, 0)
	first_sample, sample_pending := sound.sb16_sample_deadline(&m.sb16)
	block_deadline, block_pending := machine_audio_sb16_block_deadline(m)
	deadline, pending := machine_audio_next_deadline(m)
	testing.expect(t, sample_pending)
	testing.expect(t, block_pending)
	testing.expect(t, block_deadline > first_sample)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, block_deadline)
}

Audio_Test_Adpcm_Dma :: struct {
	bytes: [4]u8,
	at:    int,
}

audio_test_adpcm_dma_read :: proc(ctx: rawptr, channel: int) -> (u8, bool) {
	dma := (^Audio_Test_Adpcm_Dma)(ctx)
	if channel != 1 || dma.at >= len(dma.bytes) {return 0, false}
	value := dma.bytes[dma.at]
	dma.at += 1
	return value, true
}

@(test)
test_machine_audio_scheduler_keeps_exact_sb16_adpcm_block_deadline :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	// Four DMA bytes: one reference followed by three 4-bit ADPCM bytes.
	sound.sb16_write_command_byte(&m.sb16, 0x75)
	sound.sb16_write_command_byte(&m.sb16, 3)
	sound.sb16_write_command_byte(&m.sb16, 0)
	m.dma.ch[1].masked = false
	m.dma.ch[1].mode = 0x08
	m.dma.ch[1].count = 3
	m.dma.ch[1].dreq = true
	m.dma.ch[4].masked = false
	m.dma.ch[4].mode = 0xC0

	block_deadline, block_pending := machine_audio_sb16_block_deadline(m)
	if !testing.expect(t, block_pending) {return}
	dma := Audio_Test_Adpcm_Dma{bytes = {0x80, 0x11, 0x22, 0x33}}
	actual_deadline: u64
	for {
		sample_tick, pending := sound.sb16_sample_deadline(&m.sb16)
		if !testing.expect(t, pending) {return}
		sound.sb16_advance_control_to(&m.sb16, sample_tick)
		_, produced := sound.sb16_render_sample(&m.sb16, &dma, audio_test_adpcm_dma_read, nil)
		if !testing.expect(t, produced) {return}
		_, irq := sound.sb16_take_irq(&m.sb16)
		if irq {
			actual_deadline = sample_tick
			break
		}
	}
	testing.expect_value(t, actual_deadline, block_deadline)
}

audio_test_gsw_pcm_write32 :: proc(m: ^Machine, offset, value: u32) {
	data := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	sound.gsw_pcm_mmio_write(&m.gsw_pcm, offset, data[:], m.vm.ram)
}

@(test)
test_machine_audio_merges_native_pcm_and_keeps_observable_transport_deadline :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_test_audio_timing_init(m)) {return}
	ram: [8_192]u8
	m.vm.ram = ram[:]
	for offset in 0 ..< 4 {
		base := 4_096 + offset * 4
		ram[base] = 0x00
		ram[base + 1] = 0x10
		ram[base + 2] = 0x00
		ram[base + 3] = 0xF0
	}
	pit_port61_write(&m.pit, 0)
	pit_clear_channel2_transitions(&m.pit)
	_ = sound.audio_mixer_set_speaker_state(&m.audio, 0, false, false)
	audio_test_gsw_pcm_write32(m, sound.GSW_PCM_REG_RING_GPA_LOW, 4_096)
	audio_test_gsw_pcm_write32(m, sound.GSW_PCM_REG_RING_SIZE, 4_096)
	audio_test_gsw_pcm_write32(m, sound.GSW_PCM_REG_PERIOD_BYTES, 16)
	audio_test_gsw_pcm_write32(m, sound.GSW_PCM_REG_RING_TAIL, 16)
	audio_test_gsw_pcm_write32(m, sound.GSW_PCM_REG_CONTROL, sound.GSW_PCM_CONTROL_START)

	transport_deadline, transport_pending := sound.gsw_pcm_next_deadline_tick(&m.gsw_pcm)
	deadline, pending := machine_audio_next_deadline(m)
	testing.expect(t, transport_pending)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, transport_deadline)

	consumer: sound.Audio_Consumer
	sound.audio_consumer_init(&consumer, machine_audio_output(m))
	sound.audio_consumer_discard_queued(&consumer)
	consumer.gain = sound.AUDIO_RAMP_FRAMES
	machine_advance_time_ns(m, 1_000_000)
	frames: [sound.AUDIO_RENDER_BATCH]sound.Audio_Frame
	sound.audio_consumer_read(&consumer, frames[:])
	nonzero := 0
	for frame in frames {
		if frame.left != 0 || frame.right != 0 {nonzero += 1}
	}
	// Four committed device frames are followed by the bounded native-source
	// release, rather than a held sample or an abrupt step to zero.
	testing.expect_value(t, nonzero, sound.AUDIO_RENDER_BATCH - 1)
	testing.expect_value(t, frames[0], sound.Audio_Frame{})
	testing.expect_value(t, frames[1], sound.Audio_Frame{left = 4_096, right = -4_096})
	testing.expect(t, abs(i32(frames[len(frames) - 1].left)) < abs(i32(frames[4].left)))
	testing.expect_value(t, m.gsw_pcm.position_bytes, u64(16))
	testing.expect_value(t, m.gsw_pcm.starvation_frames, u64(44))
	telemetry := sound.audio_mixer_telemetry(&m.audio)
	native := telemetry.sources[int(sound.Audio_Mixer_Source.Native_PCM)]
	testing.expect_value(t, native.frames_produced, u64(sound.AUDIO_RENDER_BATCH))
	testing.expect_value(t, native.nonzero_frames, u64(sound.AUDIO_RENDER_BATCH - 1))
}
