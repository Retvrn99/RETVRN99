// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

Gsw_Sound_Test_Dreq_Event :: struct {
	channel:  int,
	asserted: bool,
}

Gsw_Sound_Test_Probe :: struct {
	ram:                [8_192]u8,
	dma:                [8]Gsw_Sound_Dma_Channel_Snapshot,
	dma_valid:          [8]bool,
	dreq_events:        [8]Gsw_Sound_Test_Dreq_Event,
	dreq_count:         int,
	legacy_irqs:        [8]u8,
	legacy_irq_count:   int,
	native_levels:      [8]bool,
	native_level_count: int,
	publish_count:      int,
	last_source:        Gsw_Sound_Source,
	last_frame:         Audio_Frame,
	release_count:      int,
}

gsw_sound_test_guest_memory :: proc(ctx: rawptr) -> []u8 {
	return (^Gsw_Sound_Test_Probe)(ctx).ram[:]
}

gsw_sound_test_dma_snapshot :: proc(
	ctx: rawptr,
	channel: int,
) -> (
	Gsw_Sound_Dma_Channel_Snapshot,
	bool,
) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	if channel < 0 || channel >= len(probe.dma) || !probe.dma_valid[channel] {
		return {}, false
	}
	return probe.dma[channel], true
}

gsw_sound_test_dreq :: proc(ctx: rawptr, channel: int, asserted: bool) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	if probe.dreq_count < len(probe.dreq_events) {
		probe.dreq_events[probe.dreq_count] = {
			channel  = channel,
			asserted = asserted,
		}
		probe.dreq_count += 1
	}
	if channel >= 0 && channel < len(probe.dma) {probe.dma[channel].dreq = asserted}
}

gsw_sound_test_legacy_irq :: proc(ctx: rawptr, irq: u8) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	if probe.legacy_irq_count < len(probe.legacy_irqs) {
		probe.legacy_irqs[probe.legacy_irq_count] = irq
		probe.legacy_irq_count += 1
	}
}

gsw_sound_test_native_irq :: proc(ctx: rawptr, asserted: bool) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	if probe.native_level_count < len(probe.native_levels) {
		probe.native_levels[probe.native_level_count] = asserted
		probe.native_level_count += 1
	}
}

gsw_sound_test_publish :: proc(
	ctx: rawptr,
	source: Gsw_Sound_Source,
	at_tick: u64,
	frame: Audio_Frame,
) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	probe.publish_count += 1
	probe.last_source = source
	probe.last_frame = frame
}

gsw_sound_test_release :: proc(ctx: rawptr, source: Gsw_Sound_Source, at_tick: u64) {
	probe := (^Gsw_Sound_Test_Probe)(ctx)
	probe.release_count += 1
}

gsw_sound_test_adapters :: proc(probe: ^Gsw_Sound_Test_Probe) -> Gsw_Sound_Adapters {
	return {
		ctx = probe,
		guest_memory = gsw_sound_test_guest_memory,
		dma_snapshot = gsw_sound_test_dma_snapshot,
		dreq = gsw_sound_test_dreq,
		legacy_irq = gsw_sound_test_legacy_irq,
		native_irq = gsw_sound_test_native_irq,
		publish_completed = gsw_sound_test_publish,
		release_completed = gsw_sound_test_release,
	}
}

gsw_sound_test_write32 :: proc(
	g: ^Gsw_Sound,
	adapter: Gsw_Sound_Adapters,
	offset, value: u32,
	at_tick := u64(0),
) {
	data := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	gsw_sound_pci_mmio_write(g, offset, data[:], at_tick, adapter)
}

@(test)
gsw_sound_test_groups_legacy_and_native_personalities :: proc(t: ^testing.T) {
	g: Gsw_Sound
	gsw_sound_init(&g)
	observation := gsw_sound_observation(&g)
	testing.expect_value(t, observation.selected_dma8, 1)
	testing.expect_value(t, observation.selected_dma16, 5)
	testing.expect_value(t, observation.selected_irq, u8(5))
	native_id: [4]u8
	gsw_sound_pci_mmio_read(&g, GSW_PCM_REG_ID, native_id[:])
	testing.expect_value(
		t,
		u32(native_id[0]) |
		u32(native_id[1]) << 8 |
		u32(native_id[2]) << 16 |
		u32(native_id[3]) << 24,
		GSW_PCM_ID,
	)

	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT, 0x02)
	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT + 1, 0xF0)
	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT, 0x04)
	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT + 1, 0x01)
	deadline, pending := gsw_sound_next_observable_deadline(&g, {})
	testing.expect(t, pending)
	testing.expect(t, deadline > 0)

	gsw_sound_advance_to(&g, deadline, {})
	status, handled := gsw_sound_legacy_read(&g, OPL3_BASE_PORT)
	testing.expect(t, handled)
	testing.expect_value(t, status & 0xC0, u8(0xC0))
}

@(test)
gsw_sound_test_owns_dreq_selection_and_transition_order :: proc(t: ^testing.T) {
	g: Gsw_Sound
	probe: Gsw_Sound_Test_Probe
	gsw_sound_init(&g)
	adapter := gsw_sound_test_adapters(&probe)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0x14, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	testing.expect_value(t, probe.dreq_count, 1)
	testing.expect_value(
		t,
		probe.dreq_events[0],
		Gsw_Sound_Test_Dreq_Event{channel = 1, asserted = true},
	)

	_ = gsw_sound_legacy_write(&g, CT1745_INDEX_PORT, 0x81, 0, adapter)
	_ = gsw_sound_legacy_write(&g, CT1745_DATA_PORT, 0x28, 0, adapter)
	testing.expect_value(t, probe.dreq_count, 3)
	testing.expect_value(t, probe.dreq_events[1], Gsw_Sound_Test_Dreq_Event{channel = 1})
	testing.expect_value(
		t,
		probe.dreq_events[2],
		Gsw_Sound_Test_Dreq_Event{channel = 3, asserted = true},
	)

	_ = gsw_sound_legacy_write(&g, 0x22C, 0xD0, 0, adapter)
	testing.expect_value(t, probe.dreq_count, 4)
	testing.expect_value(t, probe.dreq_events[3], Gsw_Sound_Test_Dreq_Event{channel = 3})
	observation := gsw_sound_observation(&g)
	testing.expect(t, !observation.dreq_active)
	testing.expect_value(t, observation.selected_dma8, 3)
	testing.expect_value(t, observation.selected_dma16, 5)
}

@(test)
gsw_sound_test_owns_dma_feasibility_and_block_deadline :: proc(t: ^testing.T) {
	g: Gsw_Sound
	probe: Gsw_Sound_Test_Probe
	gsw_sound_init(&g)
	probe.dma_valid[1] = true
	probe.dma[1] = {
		mode  = 0x08,
		count = 2,
	}
	probe.dma_valid[4] = true
	probe.dma[4] = {
		mode = 0xC0,
	}
	adapter := gsw_sound_test_adapters(&probe)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0x75, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 3, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	_, pending := gsw_sound_next_observable_deadline(&g, adapter)
	testing.expect(t, !pending)

	probe.dma[1].count = 3
	deadline: u64
	deadline, pending = gsw_sound_next_observable_deadline(&g, adapter)
	observation := gsw_sound_observation(&g)
	testing.expect(t, pending)
	testing.expect(t, deadline > observation.sb16_sample_deadline)
	probe.dma[4].masked = true
	_, pending = gsw_sound_next_observable_deadline(&g, adapter)
	testing.expect(t, !pending)
}

@(test)
gsw_sound_test_owns_legacy_irq_selection :: proc(t: ^testing.T) {
	g: Gsw_Sound
	probe: Gsw_Sound_Test_Probe
	gsw_sound_init(&g)
	adapter := gsw_sound_test_adapters(&probe)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0x80, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	gsw_sound_advance_to(&g, gsw_sound_observation(&g).sb16_sample_deadline, adapter)
	testing.expect_value(t, probe.legacy_irqs[0], u8(5))

	_ = gsw_sound_legacy_write(&g, CT1745_INDEX_PORT, 0x80, 0, adapter)
	_ = gsw_sound_legacy_write(&g, CT1745_DATA_PORT, 0x04, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0x80, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	_ = gsw_sound_legacy_write(&g, 0x22C, 0, 0, adapter)
	gsw_sound_advance_to(&g, gsw_sound_observation(&g).sb16_sample_deadline, adapter)
	testing.expect_value(t, probe.legacy_irq_count, 2)
	testing.expect_value(t, probe.legacy_irqs[1], u8(7))
	testing.expect_value(t, gsw_sound_observation(&g).selected_irq, u8(7))
}

@(test)
gsw_sound_test_native_transition_publishes_releases_and_drives_irq :: proc(t: ^testing.T) {
	g: Gsw_Sound
	probe: Gsw_Sound_Test_Probe
	gsw_sound_init(&g)
	probe.ram[4_096] = 0x34
	probe.ram[4_097] = 0x12
	probe.ram[4_098] = 0xDC
	probe.ram[4_099] = 0xFE
	adapter := gsw_sound_test_adapters(&probe)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_RING_GPA_LOW, 4_096)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_RING_SIZE, 4_096)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_PERIOD_BYTES, 4)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_RING_TAIL, 4)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_IRQ_ENABLE, GSW_PCM_IRQ_PERIOD)
	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_CONTROL, GSW_PCM_CONTROL_START)
	testing.expect(t, gsw_sound_observation(&g).native_active)

	deadline := gsw_sound_observation(&g).native_sample_deadline
	gsw_sound_advance_to(&g, deadline, adapter)
	testing.expect_value(t, probe.last_source, Gsw_Sound_Source.Native_PCM)
	testing.expect_value(t, probe.last_frame, Audio_Frame{left = 0x1234, right = -292})
	testing.expect_value(t, probe.native_level_count, 1)
	testing.expect(t, probe.native_levels[0])

	gsw_sound_test_write32(&g, adapter, GSW_PCM_REG_IRQ_STATUS, GSW_PCM_IRQ_PERIOD, deadline)
	testing.expect_value(t, probe.native_level_count, 2)
	testing.expect(t, !probe.native_levels[1])
	deadline = gsw_sound_observation(&g).native_sample_deadline
	gsw_sound_advance_to(&g, deadline, adapter)
	testing.expect_value(t, probe.release_count, 1)
	testing.expect(t, !gsw_sound_observation(&g).native_active)
}

@(test)
gsw_sound_test_observation_is_a_value_snapshot :: proc(t: ^testing.T) {
	g: Gsw_Sound
	gsw_sound_init(&g)
	before := gsw_sound_observation(&g)
	_ = gsw_sound_legacy_write(&g, CT1745_INDEX_PORT, 0x3B)
	_ = gsw_sound_legacy_write(&g, CT1745_DATA_PORT, 0)
	_ = gsw_sound_legacy_write(&g, CT1745_INDEX_PORT, 0x36)
	_ = gsw_sound_legacy_write(&g, CT1745_DATA_PORT, 0)
	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT, 0xB0)
	_ = gsw_sound_legacy_write(&g, OPL3_BASE_PORT + 1, 0x20)
	after := gsw_sound_observation(&g)
	testing.expect(t, after.speaker_gain_left < before.speaker_gain_left)
	testing.expect_value(t, after.cdda_gain_left, u32(0))
	testing.expect(t, after.opl3_active)
	testing.expect(t, before.speaker_gain_left > 0)
	testing.expect(t, before.cdda_gain_left > 0)
	testing.expect(t, !before.opl3_active)
	testing.expect_value(t, before.selected_irq, u8(5))
}
