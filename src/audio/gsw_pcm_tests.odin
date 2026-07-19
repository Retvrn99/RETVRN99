// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

gsw_pcm_test_write32 :: proc(g: ^Gsw_Pcm, ram: []u8, offset, value: u32) {
	data := [4]u8 {
		u8(value),
		u8(value >> 8),
		u8(value >> 16),
		u8(value >> 24),
	}
	gsw_pcm_mmio_write(g, offset, data[:], ram)
}

gsw_pcm_test_read32 :: proc(g: ^Gsw_Pcm, offset: u32) -> u32 {
	data: [4]u8
	gsw_pcm_mmio_read(g, offset, data[:])
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

gsw_pcm_test_write_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

gsw_pcm_test_configure :: proc(
	g: ^Gsw_Pcm,
	ram: []u8,
	ring_gpa, ring_size, period_bytes: u32,
	format := GSW_PCM_FORMAT_STEREO_S16,
) {
	gsw_pcm_test_write32(g, ram, GSW_PCM_REG_FORMAT, format)
	gsw_pcm_test_write32(g, ram, GSW_PCM_REG_RING_GPA_LOW, ring_gpa)
	gsw_pcm_test_write32(g, ram, GSW_PCM_REG_RING_GPA_HIGH, 0)
	gsw_pcm_test_write32(g, ram, GSW_PCM_REG_RING_SIZE, ring_size)
	gsw_pcm_test_write32(g, ram, GSW_PCM_REG_PERIOD_BYTES, period_bytes)
}

Gsw_Pcm_Test_Publisher :: struct {
	calls:       int,
	frames:      int,
	at_tick:     u64,
	sample_rate: u32,
	last:        Audio_Frame,
}

gsw_pcm_test_publish :: proc(
	ctx: rawptr,
	at_tick: u64,
	sample_rate: u32,
	frames: []Audio_Frame,
) {
	publisher := (^Gsw_Pcm_Test_Publisher)(ctx)
	publisher.calls += 1
	publisher.frames += len(frames)
	publisher.at_tick = at_tick
	publisher.sample_rate = sample_rate
	if len(frames) > 0 {publisher.last = frames[len(frames) - 1]}
}

@(test)
gsw_pcm_test_identity_decode_and_read_widths :: proc(t: ^testing.T) {
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	testing.expect_value(t, gsw_pcm_test_read32(&g, GSW_PCM_REG_ID), GSW_PCM_ID)
	testing.expect_value(t, gsw_pcm_test_read32(&g, GSW_PCM_REG_VERSION), GSW_PCM_INTERFACE_VERSION)
	testing.expect_value(t, gsw_pcm_test_read32(&g, GSW_PCM_REG_CAPABILITIES), GSW_PCM_CAPABILITIES)
	testing.expect_value(t, gsw_pcm_test_read32(&g, GSW_PCM_REG_STATUS), GSW_PCM_STATUS_READY)
	testing.expect_value(t, gsw_pcm_test_read32(&g, GSW_PCM_REG_MASTER_GAIN), AUDIO_GAIN_UNITY)

	bytes: [2]u8
	gsw_pcm_mmio_read(&g, GSW_PCM_REG_ID + 1, bytes[:])
	testing.expect_value(t, bytes, [2]u8{'S', 'W'})
	offset, decoded := gsw_pcm_control_offset(&g, GSW_PCM_DEFAULT_CONTROL_BASE + 0x48, 4)
	testing.expect_value(t, offset, GSW_PCM_REG_INVALID_COUNT)
	testing.expect(t, decoded)
	_, decoded = gsw_pcm_control_offset(&g, GSW_PCM_DEFAULT_CONTROL_BASE + GSW_PCM_CONTROL_SIZE - 2, 4)
	testing.expect(t, !decoded)
	gsw_pcm_set_pci_decode(&g, false, true, 0xF200_0000)
	_, decoded = gsw_pcm_control_offset(&g, 0xF200_0000, 4)
	testing.expect(t, !decoded)
	gsw_pcm_set_pci_decode(&g, true, true, 0xF200_0000)
	offset, decoded = gsw_pcm_control_offset(&g, 0xF200_0000, 4)
	testing.expect_value(t, offset, u32(0))
	testing.expect(t, decoded)
}

@(test)
gsw_pcm_test_pull_stereo_s16_period_and_underrun_irqs :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	asserted := false
	gsw_pcm_set_irq(&g, &asserted, proc(ctx: rawptr, level: bool) {(^bool)(ctx)^ = level})
	gsw_pcm_test_configure(&g, ram[:], 4096, 4096, 8)
	gsw_pcm_test_write_u16(ram[:], 4096, 0x0001)
	gsw_pcm_test_write_u16(ram[:], 4098, 0xFFFF)
	gsw_pcm_test_write_u16(ram[:], 4100, 0x8000)
	gsw_pcm_test_write_u16(ram[:], 4102, 0x7FFF)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 8)
	gsw_pcm_test_write32(
		&g,
		ram[:],
		GSW_PCM_REG_IRQ_ENABLE,
		GSW_PCM_IRQ_PERIOD | GSW_PCM_IRQ_UNDERRUN | GSW_PCM_IRQ_INVALID,
	)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	testing.expect(t, gsw_pcm_running(&g))

	frames: [2]Audio_Frame
	consumed := gsw_pcm_pull(&g, ram[:], frames[:])
	testing.expect_value(t, consumed, 2)
	testing.expect_value(t, frames[0], Audio_Frame{left = 1, right = -1})
	testing.expect_value(t, frames[1], Audio_Frame{left = -32_768, right = 32_767})
	testing.expect_value(t, g.ring_head, u32(8))
	testing.expect_value(t, g.position_bytes, u64(8))
	testing.expect_value(t, g.irq_status, GSW_PCM_IRQ_PERIOD)
	testing.expect_value(t, g.period_irq_events, u64(1))
	testing.expect(t, asserted)

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_PERIOD)
	testing.expect(t, !asserted)
	gsw_pcm_test_write_u16(ram[:], 4104, 0x1234)
	gsw_pcm_test_write_u16(ram[:], 4106, 0xFEDC)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 12)
	consumed = gsw_pcm_pull(&g, ram[:], frames[:])
	testing.expect_value(t, consumed, 1)
	testing.expect_value(t, frames[0], Audio_Frame{left = 0x1234, right = -292})
	testing.expect_value(t, frames[1], Audio_Frame{})
	testing.expect_value(t, g.xrun_count, u32(1))
	testing.expect_value(t, g.starvation_frames, u64(1))
	testing.expect(t, g.status & GSW_PCM_STATUS_UNDERRUN != 0)
	testing.expect_value(t, g.irq_status, GSW_PCM_IRQ_UNDERRUN)
	testing.expect_value(t, g.underrun_irq_events, u64(1))
	testing.expect(t, asserted)
}

@(test)
gsw_pcm_test_underrun_w1c_rearms_a_later_episode :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	gsw_pcm_test_configure(&g, ram[:], 4096, 4096, 4)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 4)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	frames: [2]Audio_Frame
	testing.expect_value(t, gsw_pcm_pull(&g, ram[:], frames[:]), 1)
	testing.expect_value(t, g.xrun_count, u32(1))
	testing.expect_value(t, g.underrun_irq_events, u64(1))

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_UNDERRUN)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_STATUS, GSW_PCM_STATUS_UNDERRUN)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 8)
	testing.expect_value(t, gsw_pcm_pull(&g, ram[:], frames[:]), 1)
	testing.expect_value(t, g.xrun_count, u32(2))
	testing.expect_value(t, g.underrun_irq_events, u64(2))
	testing.expect_value(t, g.starvation_frames, u64(2))
}

@(test)
gsw_pcm_test_stop_start_preserves_partial_period_accounting :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	gsw_pcm_test_configure(&g, ram[:], 4096, 4096, 16)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 16)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	frames: [2]Audio_Frame
	testing.expect_value(t, gsw_pcm_pull(&g, ram[:], frames[:]), 2)
	testing.expect_value(t, g.bytes_since_period, u32(8))
	testing.expect_value(t, g.period_irq_events, u64(0))

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_STOP)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	testing.expect_value(t, gsw_pcm_pull(&g, ram[:], frames[:]), 2)
	testing.expect_value(t, g.bytes_since_period, u32(0))
	testing.expect_value(t, g.period_irq_events, u64(1))
	testing.expect_value(t, g.irq_status & GSW_PCM_IRQ_PERIOD, GSW_PCM_IRQ_PERIOD)
}

@(test)
gsw_pcm_test_ring_wrap_and_mono_u8_conversion :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	format := u32(1 | 8 << GSW_PCM_FORMAT_BITS_SHIFT)
	gsw_pcm_test_configure(&g, ram[:], 4096, 4096, 2, format)
	g.ring_head = 4094
	ram[4096 + 4094] = 0
	ram[4096 + 4095] = 128
	ram[4096] = 255
	g.ring_tail = 1
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)

	frames: [3]Audio_Frame
	consumed := gsw_pcm_pull(&g, ram[:], frames[:])
	testing.expect_value(t, consumed, 3)
	testing.expect_value(t, frames[0], Audio_Frame{left = -32_768, right = -32_768})
	testing.expect_value(t, frames[1], Audio_Frame{})
	testing.expect_value(t, frames[2], Audio_Frame{left = 32_512, right = 32_512})
	testing.expect_value(t, g.ring_head, u32(1))
	testing.expect_value(t, g.irq_status & GSW_PCM_IRQ_PERIOD, GSW_PCM_IRQ_PERIOD)
}

@(test)
gsw_pcm_test_invalid_config_and_running_register_lock_fail_closed :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	asserted := false
	gsw_pcm_set_irq(&g, &asserted, proc(ctx: rawptr, level: bool) {(^bool)(ctx)^ = level})
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_ENABLE, GSW_PCM_IRQ_INVALID)
	gsw_pcm_test_configure(&g, ram[:], 4097, 4096, 64)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	testing.expect(t, !gsw_pcm_running(&g))
	testing.expect(t, g.status & GSW_PCM_STATUS_ERROR != 0)
	testing.expect_value(t, g.invalid_count, u32(1))
	testing.expect_value(t, g.irq_status, GSW_PCM_IRQ_INVALID)
	testing.expect(t, asserted)

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_INVALID)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_GPA_LOW, 4096)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	testing.expect(t, gsw_pcm_running(&g))
	testing.expect(t, !asserted)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_SAMPLE_RATE, 44_100)
	testing.expect_value(t, g.sample_rate, u32(48_000))
	testing.expect(t, gsw_pcm_running(&g))
	testing.expect_value(t, g.invalid_count, u32(2))
	testing.expect(t, asserted)

	gsw_pcm_set_pci_decode(&g, true, false, GSW_PCM_DEFAULT_CONTROL_BASE)
	testing.expect(t, !gsw_pcm_running(&g))
	testing.expect_value(t, g.invalid_count, u32(3))
	testing.expect_value(t, g.invalid_irq_events, u64(3))
	testing.expect(t, g.irq_status & GSW_PCM_IRQ_INVALID != 0)
}

@(test)
gsw_pcm_test_reset_preserves_pci_and_irq_wiring :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	asserted := false
	gsw_pcm_set_irq(&g, &asserted, proc(ctx: rawptr, level: bool) {(^bool)(ctx)^ = level})
	gsw_pcm_set_pci_decode(&g, true, true, 0xF200_0000)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_ENABLE, GSW_PCM_IRQ_INVALID)
	bad: [1]u8
	gsw_pcm_mmio_write(&g, GSW_PCM_REG_FORMAT, bad[:], ram[:])
	testing.expect(t, asserted)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET)
	testing.expect(t, !asserted)
	testing.expect_value(t, g.control_base, u64(0xF200_0000))
	testing.expect(t, g.memory_space_enabled)
	testing.expect(t, g.bus_master_enabled)
	testing.expect_value(t, g.status, GSW_PCM_STATUS_READY)
	testing.expect_value(t, g.invalid_count, u32(0))
	testing.expect_value(t, g.invalid_irq_events, u64(1))
}

@(test)
gsw_pcm_test_vm_timing_publishes_native_frames_and_exact_irqs :: proc(t: ^testing.T) {
	ram: [8192]u8
	g: Gsw_Pcm
	gsw_pcm_init(&g)
	publisher: Gsw_Pcm_Test_Publisher
	gsw_pcm_set_publisher(&g, &publisher, gsw_pcm_test_publish)

	start_tick := u64(1_234)
	testing.expect_value(t, gsw_pcm_advance_to(&g, start_tick, ram[:]), u64(0))
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_SAMPLE_RATE, 44_100)
	gsw_pcm_test_configure(&g, ram[:], 4096, 4096, 16)
	for index in 0 ..< 4 {
		value := i16((index + 1) * 100)
		gsw_pcm_test_write_u16(ram[:], 4096 + index * 4, u16(value))
		gsw_pcm_test_write_u16(ram[:], 4098 + index * 4, u16(-value))
	}
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_RING_TAIL, 16)
	gsw_pcm_test_write32(
		&g,
		ram[:],
		GSW_PCM_REG_IRQ_ENABLE,
		GSW_PCM_IRQ_PERIOD | GSW_PCM_IRQ_UNDERRUN,
	)
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)

	period_deadline, pending := gsw_pcm_next_period_deadline_tick(&g)
	testing.expect(t, pending)
	expected_delta := u64(
		(u128(4) * u128(AUDIO_MASTER_CLOCK_HZ) + u128(44_100 - 1)) / u128(44_100),
	)
	testing.expect_value(t, period_deadline, start_tick + expected_delta)
	deadline: u64
	deadline, pending = gsw_pcm_next_deadline_tick(&g)
	testing.expect(t, pending)
	testing.expect_value(t, deadline, period_deadline)

	sample_deadline, sample_pending := gsw_pcm_next_sample_deadline_tick(&g)
	testing.expect(t, sample_pending)
	first, produced := gsw_pcm_render_sample(&g, sample_deadline - 1, ram[:])
	testing.expect(t, !produced)
	testing.expect_value(t, first, Audio_Frame{})
	first, produced = gsw_pcm_render_sample(&g, sample_deadline, ram[:])
	testing.expect(t, produced)
	testing.expect_value(t, first, Audio_Frame{left = 100, right = -100})

	testing.expect_value(t, gsw_pcm_advance_to(&g, period_deadline - 1, ram[:]), u64(2))
	testing.expect_value(t, publisher.frames, 3)
	testing.expect_value(t, gsw_pcm_current_frame(&g), Audio_Frame{left = 300, right = -300})
	testing.expect_value(t, g.irq_status, u32(0))
	period_deadline_after_split: u64
	period_deadline_after_split, pending = gsw_pcm_next_period_deadline_tick(&g)
	testing.expect(t, pending)
	testing.expect_value(t, period_deadline_after_split, period_deadline)

	testing.expect_value(t, gsw_pcm_advance_to(&g, period_deadline, ram[:]), u64(1))
	testing.expect_value(t, publisher.frames, 4)
	testing.expect_value(t, publisher.at_tick, period_deadline)
	testing.expect_value(t, publisher.sample_rate, u32(44_100))
	testing.expect_value(t, publisher.last, Audio_Frame{left = 400, right = -400})
	testing.expect_value(t, gsw_pcm_current_frame(&g), publisher.last)
	testing.expect_value(t, g.irq_status, GSW_PCM_IRQ_PERIOD)
	testing.expect_value(t, g.period_irq_events, u64(1))

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_PERIOD)
	underrun_deadline: u64
	underrun_deadline, pending = gsw_pcm_next_deadline_tick(&g)
	testing.expect(t, pending)
	testing.expect(t, underrun_deadline > period_deadline)
	testing.expect_value(t, gsw_pcm_advance_to(&g, underrun_deadline, ram[:]), u64(1))
	testing.expect_value(t, publisher.frames, 5)
	testing.expect_value(t, publisher.last, Audio_Frame{})
	testing.expect_value(t, gsw_pcm_current_frame(&g), Audio_Frame{})
	testing.expect_value(t, g.xrun_count, u32(1))
	testing.expect_value(t, g.irq_status, GSW_PCM_IRQ_UNDERRUN)
	testing.expect_value(t, g.underrun_irq_events, u64(1))
	testing.expect_value(t, g.starvation_frames, u64(1))

	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_STOP)
	_, pending = gsw_pcm_next_deadline_tick(&g)
	testing.expect(t, !pending)
	reset_tick := g.now_ticks
	gsw_pcm_test_write32(&g, ram[:], GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_RESET)
	testing.expect_value(t, g.now_ticks, reset_tick)
	testing.expect(t, g.publish != nil)
	testing.expect_value(t, g.period_irq_events, u64(1))
	testing.expect_value(t, g.underrun_irq_events, u64(1))
	testing.expect_value(t, g.starvation_frames, u64(1))
}
