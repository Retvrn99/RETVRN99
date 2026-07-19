// SPDX-License-Identifier: GPL-3.0-only
package audio

// GSW_Sound is the deep guest-facing Module. The machine owns the PIT,
// ISA-DMA, PCI-memory, IRQ, and final-mix Adapters passed through this
// Interface; the Module owns both guest audio personalities and their state.

Gsw_Sound_Source :: enum u8 {
	SB16,
	OPL3,
	Native_PCM,
}

Gsw_Sound_Publish_Proc :: proc(
	ctx: rawptr,
	source: Gsw_Sound_Source,
	at_tick: u64,
	frame: Audio_Frame,
)

Gsw_Sound_Legacy_Irq_Proc :: proc(ctx: rawptr, dma16: bool)
Gsw_Sound_Release_Proc :: proc(ctx: rawptr, source: Gsw_Sound_Source, at_tick: u64)
Gsw_Sound_Deadline_Proc :: proc(ctx: rawptr) -> (deadline: u64, pending: bool)

Gsw_Sound_Adapters :: struct {
	ctx:                   rawptr,
	ram:                   []u8,
	dma_read_byte:         Sb16_Dma_Read_Byte_Proc,
	dma_read_word:         Sb16_Dma_Read_Word_Proc,
	publish:               Gsw_Sound_Publish_Proc,
	release:               Gsw_Sound_Release_Proc,
	legacy_irq:            Gsw_Sound_Legacy_Irq_Proc,
	legacy_block_deadline: Gsw_Sound_Deadline_Proc,
}

Gsw_Sound_Pending_Events :: struct {
	dma8_irq:         bool,
	dma16_irq:        bool,
	midi_irq:         bool,
	native_irq_status: u32,
}

Gsw_Sound :: struct {
	sb16:    Sb16,
	opl3:    Opl3,
	gsw_pcm: Gsw_Pcm,
}

gsw_sound_init :: proc(g: ^Gsw_Sound) {
	if g == nil {return}
	g^ = {}
	sb16_init(&g.sb16)
	opl3_init(&g.opl3)
	gsw_pcm_init(&g.gsw_pcm)
}

@(private = "file")
gsw_sound_publish :: proc(
	g: ^Gsw_Sound,
	adapter: Gsw_Sound_Adapters,
	source: Gsw_Sound_Source,
	at_tick: u64,
	frame: Audio_Frame,
) {
	if adapter.publish != nil {adapter.publish(adapter.ctx, source, at_tick, frame)}
}

// Advances internal legacy and native samples without exposing them as machine
// scheduler events. Callers may split this at PIT channel-2 transitions so the
// separate PC-Speaker Module is integrated before the corresponding interval.
gsw_sound_advance_to :: proc(
	g: ^Gsw_Sound,
	target_tick: u64,
	adapter: Gsw_Sound_Adapters,
) {
	if g == nil {return}
	for {
		next_tick: u64
		pending := false
		if deadline, ok := sb16_sample_deadline(&g.sb16); ok && deadline <= target_tick {
			next_tick, pending = deadline, true
		}
		if deadline, ok := opl3_sample_deadline(&g.opl3);
		   ok && deadline <= target_tick && (!pending || deadline < next_tick) {
			next_tick, pending = deadline, true
		}
		if deadline, ok := gsw_pcm_next_sample_deadline_tick(&g.gsw_pcm);
		   ok && deadline <= target_tick && (!pending || deadline < next_tick) {
			next_tick, pending = deadline, true
		}
		if !pending {break}

		sb16_advance_control_to(&g.sb16, next_tick)
		opl3_advance_control_to(&g.opl3, next_tick)
		if deadline, ok := sb16_sample_deadline(&g.sb16); ok && deadline == next_tick {
			frame, produced := sb16_render_sample(
				&g.sb16,
				adapter.ctx,
				adapter.dma_read_byte,
				adapter.dma_read_word,
			)
			frame = produced ? sb16_output_frame(&g.sb16) : Audio_Frame{}
			gsw_sound_publish(g, adapter, .SB16, next_tick, frame)
			if dma16, irq := sb16_take_irq(&g.sb16); irq && adapter.legacy_irq != nil {
				adapter.legacy_irq(adapter.ctx, dma16)
			}
		}
		if deadline, ok := opl3_sample_deadline(&g.opl3); ok && deadline == next_tick {
			frame, produced := opl3_render_sample(&g.opl3)
			if produced {
				frame = ct1745_apply_gain(&g.sb16.mixer, frame, false)
				gsw_sound_publish(g, adapter, .OPL3, next_tick, frame)
			}
		}
		if deadline, ok := gsw_pcm_next_sample_deadline_tick(&g.gsw_pcm);
		   ok && deadline == next_tick {
			starvation_before := g.gsw_pcm.starvation_frames
			underrun_before := g.gsw_pcm.status & GSW_PCM_STATUS_UNDERRUN != 0
			frame, produced := gsw_pcm_render_sample(&g.gsw_pcm, next_tick, adapter.ram)
			if !underrun_before && g.gsw_pcm.status & GSW_PCM_STATUS_UNDERRUN != 0 {
				if adapter.release != nil {adapter.release(adapter.ctx, .Native_PCM, next_tick)}
			} else if produced && g.gsw_pcm.starvation_frames == starvation_before {
				gsw_sound_publish(g, adapter, .Native_PCM, next_tick, frame)
			}
		}
	}
	_ = gsw_pcm_advance_to(&g.gsw_pcm, target_tick, adapter.ram)
	sb16_advance_control_to(&g.sb16, target_tick)
	opl3_advance_control_to(&g.opl3, target_tick)
}

gsw_sound_has_internal_samples :: proc(g: ^Gsw_Sound) -> bool {
	if g == nil {return false}
	_, sb16_pending := sb16_sample_deadline(&g.sb16)
	_, opl3_pending := opl3_sample_deadline(&g.opl3)
	_, native_pending := gsw_pcm_next_sample_deadline_tick(&g.gsw_pcm)
	return sb16_pending || opl3_pending || native_pending
}

@(private = "file")
gsw_sound_consider_deadline :: proc(deadline: ^u64, pending: ^bool, candidate: u64, ok: bool) {
	if ok && (!pending^ || candidate < deadline^) {
		deadline^ = candidate
		pending^ = true
	}
}

// Only guest-observable completions belong here. Ordinary OPL3, SB16, and
// native samples remain internal to advance_to and the 1 ms mix quantum.
gsw_sound_next_observable_deadline :: proc(
	g: ^Gsw_Sound,
	adapter: Gsw_Sound_Adapters,
) -> (
	deadline: u64,
	pending: bool,
) {
	if g == nil {return 0, false}
	if g.sb16.reset_pending {
		gsw_sound_consider_deadline(&deadline, &pending, g.sb16.reset_deadline, true)
	}
	if adapter.legacy_block_deadline != nil {
		candidate, ok := adapter.legacy_block_deadline(adapter.ctx)
		gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	}
	candidate, ok := opl3_timer_deadline(&g.opl3, &g.opl3.timer1)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	candidate, ok = opl3_timer_deadline(&g.opl3, &g.opl3.timer2)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	candidate, ok = gsw_pcm_next_deadline_tick(&g.gsw_pcm)
	gsw_sound_consider_deadline(&deadline, &pending, candidate, ok)
	return
}

gsw_sound_legacy_read :: proc(g: ^Gsw_Sound, port: u16) -> (u8, bool) {
	if g == nil {return 0xFF, false}
	if port >= SB16_BASE_PORT && port <= SB16_BASE_PORT + 3 {
		return opl3_read_port(&g.opl3, OPL3_BASE_PORT + port - SB16_BASE_PORT)
	}
	if port >= OPL3_BASE_PORT && port <= OPL3_LAST_PORT {
		return opl3_read_port(&g.opl3, port)
	}
	return sb16_read_port(&g.sb16, port)
}

gsw_sound_legacy_write :: proc(g: ^Gsw_Sound, port: u16, value: u8) -> bool {
	if g == nil {return false}
	if port >= SB16_BASE_PORT && port <= SB16_BASE_PORT + 3 {
		return opl3_write_port(&g.opl3, OPL3_BASE_PORT + port - SB16_BASE_PORT, value)
	}
	if port >= OPL3_BASE_PORT && port <= OPL3_LAST_PORT {
		return opl3_write_port(&g.opl3, port, value)
	}
	return sb16_write_port(&g.sb16, port, value)
}

gsw_sound_pci_mmio_read :: proc(g: ^Gsw_Sound, offset: u32, data: []u8) {
	if g == nil {return}
	gsw_pcm_mmio_read(&g.gsw_pcm, offset, data)
}

gsw_sound_pci_mmio_write :: proc(g: ^Gsw_Sound, offset: u32, data, ram: []u8) {
	if g == nil {return}
	gsw_pcm_mmio_write(&g.gsw_pcm, offset, data, ram)
}

gsw_sound_pending_events :: proc(g: ^Gsw_Sound) -> Gsw_Sound_Pending_Events {
	if g == nil {return {}}
	return {
		dma8_irq          = g.sb16.irq_pending_dma8,
		dma16_irq         = g.sb16.irq_pending_dma16,
		midi_irq          = g.sb16.irq_pending_midi,
		native_irq_status = g.gsw_pcm.irq_status,
	}
}
