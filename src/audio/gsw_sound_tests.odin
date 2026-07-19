// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

@(test)
gsw_sound_test_groups_legacy_and_native_personalities :: proc(t: ^testing.T) {
	g: Gsw_Sound
	gsw_sound_init(&g)
	testing.expect_value(t, g.sb16.rate_hz, u32(22_050))
	testing.expect_value(t, g.opl3.timer1.step_ticks, OPL3_TIMER1_TICKS)
	testing.expect_value(t, g.gsw_pcm.status, GSW_PCM_STATUS_READY)

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
gsw_sound_test_pending_events_keep_irq_sources_separate :: proc(t: ^testing.T) {
	g: Gsw_Sound
	gsw_sound_init(&g)
	sb16_raise_dma_irq(&g.sb16, false)
	sb16_raise_dma_irq(&g.sb16, true)
	sb16_raise_midi_irq(&g.sb16)
	g.gsw_pcm.irq_status = GSW_PCM_IRQ_PERIOD | GSW_PCM_IRQ_UNDERRUN
	events := gsw_sound_pending_events(&g)
	testing.expect(t, events.dma8_irq)
	testing.expect(t, events.dma16_irq)
	testing.expect(t, events.midi_irq)
	testing.expect_value(t, events.native_irq_status, GSW_PCM_IRQ_PERIOD | GSW_PCM_IRQ_UNDERRUN)
}
