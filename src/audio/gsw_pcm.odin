// SPDX-License-Identifier: GPL-3.0-only
package audio

GSW_PCM_DEFAULT_CONTROL_BASE :: u64(0xF100_1000)
GSW_PCM_CONTROL_SIZE :: u64(0x1000)
GSW_PCM_INTERFACE_VERSION :: u32(1)
GSW_PCM_RING_MIN_SIZE :: u32(4 * 1024)
GSW_PCM_RING_MAX_SIZE :: u32(256 * 1024)

GSW_PCM_REG_ID :: u32(0x00)
GSW_PCM_REG_VERSION :: u32(0x04)
GSW_PCM_REG_CAPABILITIES :: u32(0x08)
GSW_PCM_REG_STATUS :: u32(0x0C)
GSW_PCM_REG_CONTROL :: u32(0x10)
GSW_PCM_REG_SAMPLE_RATE :: u32(0x14)
GSW_PCM_REG_FORMAT :: u32(0x18)
GSW_PCM_REG_RING_GPA_LOW :: u32(0x1C)
GSW_PCM_REG_RING_GPA_HIGH :: u32(0x20)
GSW_PCM_REG_RING_SIZE :: u32(0x24)
GSW_PCM_REG_RING_HEAD :: u32(0x28)
GSW_PCM_REG_RING_TAIL :: u32(0x2C)
GSW_PCM_REG_PERIOD_BYTES :: u32(0x30)
GSW_PCM_REG_IRQ_ENABLE :: u32(0x34)
GSW_PCM_REG_IRQ_STATUS :: u32(0x38)
GSW_PCM_REG_POSITION_LOW :: u32(0x3C)
GSW_PCM_REG_POSITION_HIGH :: u32(0x40)
GSW_PCM_REG_XRUN_COUNT :: u32(0x44)
GSW_PCM_REG_INVALID_COUNT :: u32(0x48)
GSW_PCM_REG_AVAILABLE_BYTES :: u32(0x4C)
GSW_PCM_REG_MASTER_GAIN :: u32(0x50)

GSW_PCM_ID :: u32(0x3157_5347) // "GSW1"
GSW_PCM_CAP_PLAYBACK :: u32(1 << 0)
GSW_PCM_CAP_PCM_U8 :: u32(1 << 1)
GSW_PCM_CAP_PCM_S16 :: u32(1 << 2)
GSW_PCM_CAP_MONO :: u32(1 << 3)
GSW_PCM_CAP_STEREO :: u32(1 << 4)
GSW_PCM_CAP_PERIOD_IRQ :: u32(1 << 5)
GSW_PCM_CAP_MASTER_GAIN :: u32(1 << 6)
GSW_PCM_CAPABILITIES ::
	GSW_PCM_CAP_PLAYBACK |
	GSW_PCM_CAP_PCM_U8 |
	GSW_PCM_CAP_PCM_S16 |
	GSW_PCM_CAP_MONO |
	GSW_PCM_CAP_STEREO |
	GSW_PCM_CAP_PERIOD_IRQ |
	GSW_PCM_CAP_MASTER_GAIN

GSW_PCM_STATUS_READY :: u32(1 << 0)
GSW_PCM_STATUS_RUNNING :: u32(1 << 1)
GSW_PCM_STATUS_BAD_CONFIG :: u32(1 << 2)
GSW_PCM_STATUS_ERROR :: GSW_PCM_STATUS_BAD_CONFIG
GSW_PCM_STATUS_UNDERRUN :: u32(1 << 3)

GSW_PCM_CONTROL_START :: u32(1 << 0)
GSW_PCM_CONTROL_STOP :: u32(1 << 1)
GSW_PCM_CONTROL_RESET :: u32(1 << 2)
GSW_PCM_CONTROL_MASK :: GSW_PCM_CONTROL_START | GSW_PCM_CONTROL_STOP | GSW_PCM_CONTROL_RESET

GSW_PCM_IRQ_PERIOD :: u32(1 << 0)
GSW_PCM_IRQ_UNDERRUN :: u32(1 << 1)
GSW_PCM_IRQ_INVALID :: u32(1 << 2)
GSW_PCM_IRQ_MASK :: GSW_PCM_IRQ_PERIOD | GSW_PCM_IRQ_UNDERRUN | GSW_PCM_IRQ_INVALID

GSW_PCM_FORMAT_CHANNELS_MASK :: u32(0xFF)
GSW_PCM_FORMAT_BITS_SHIFT :: 8
GSW_PCM_FORMAT_BITS_MASK :: u32(0xFF << GSW_PCM_FORMAT_BITS_SHIFT)
GSW_PCM_FORMAT_MASK :: GSW_PCM_FORMAT_CHANNELS_MASK | GSW_PCM_FORMAT_BITS_MASK
GSW_PCM_FORMAT_STEREO_S16 :: u32(2 | 16 << GSW_PCM_FORMAT_BITS_SHIFT)
GSW_PCM_ADVANCE_BATCH :: 256

// Published frames are native-rate device frames. The callback runs
// synchronously on the machine thread; the slice is valid only for the call.
// A host mixer may queue/resample it, but must never use this hook to read RAM.
Gsw_Pcm_Publish_Proc :: proc(
	ctx: rawptr,
	at_tick: u64,
	sample_rate: u32,
	frames: []Audio_Frame,
)

Gsw_Pcm :: struct {
	memory_space_enabled: bool,
	bus_master_enabled:   bool,
	control_base:         u64,
	sample_rate:          u32,
	format:               u32,
	ring_gpa:              u64,
	ring_size:             u32,
	ring_head:             u32,
	ring_tail:             u32,
	period_bytes:          u32,
	bytes_since_period:    u32,
	position_bytes:        u64,
	status:                u32,
	irq_enable:            u32,
	irq_status:            u32,
	xrun_count:            u32,
	invalid_count:         u32,
	period_irq_events:     u64,
	underrun_irq_events:   u64,
	invalid_irq_events:    u64,
	starvation_frames:     u64,
	master_gain:           u32,
	now_ticks:             u64,
	sample_phase:          u64,
	current_frame:         Audio_Frame,
	irq_ctx:               rawptr,
	irq:                   proc(ctx: rawptr, asserted: bool),
	publish_ctx:           rawptr,
	publish:               Gsw_Pcm_Publish_Proc,
}

@(private = "file")
gsw_pcm_sync_irq :: proc(g: ^Gsw_Pcm) {
	if g != nil && g.irq != nil {g.irq(g.irq_ctx, g.irq_status & g.irq_enable != 0)}
}

gsw_pcm_init :: proc(g: ^Gsw_Pcm) {
	if g == nil {return}
	g^ = {
		memory_space_enabled = true,
		bus_master_enabled   = true,
		control_base         = GSW_PCM_DEFAULT_CONTROL_BASE,
		sample_rate          = 48_000,
		format               = GSW_PCM_FORMAT_STEREO_S16,
		status               = GSW_PCM_STATUS_READY,
		master_gain          = AUDIO_GAIN_UNITY,
	}
}

gsw_pcm_reset :: proc(g: ^Gsw_Pcm) {
	if g == nil {return}
	memory_space_enabled := g.memory_space_enabled
	bus_master_enabled := g.bus_master_enabled
	control_base := g.control_base
	irq_ctx := g.irq_ctx
	irq := g.irq
	now_ticks := g.now_ticks
	publish_ctx := g.publish_ctx
	publish := g.publish
	period_irq_events := g.period_irq_events
	underrun_irq_events := g.underrun_irq_events
	invalid_irq_events := g.invalid_irq_events
	starvation_frames := g.starvation_frames
	if irq != nil {irq(irq_ctx, false)}
	gsw_pcm_init(g)
	g.memory_space_enabled = memory_space_enabled
	g.bus_master_enabled = bus_master_enabled
	g.control_base = control_base
	g.irq_ctx = irq_ctx
	g.irq = irq
	g.now_ticks = now_ticks
	g.publish_ctx = publish_ctx
	g.publish = publish
	g.period_irq_events = period_irq_events
	g.underrun_irq_events = underrun_irq_events
	g.invalid_irq_events = invalid_irq_events
	g.starvation_frames = starvation_frames
}

gsw_pcm_set_irq :: proc(g: ^Gsw_Pcm, ctx: rawptr, irq: proc(ctx: rawptr, asserted: bool)) {
	if g == nil {return}
	if g.irq != nil {g.irq(g.irq_ctx, false)}
	g.irq_ctx = ctx
	g.irq = irq
	gsw_pcm_sync_irq(g)
}

gsw_pcm_set_publisher :: proc(g: ^Gsw_Pcm, ctx: rawptr, publish: Gsw_Pcm_Publish_Proc) {
	if g == nil {return}
	g.publish_ctx = ctx
	g.publish = publish
}

gsw_pcm_set_pci_decode :: proc(
	g: ^Gsw_Pcm,
	memory_space_enabled, bus_master_enabled: bool,
	control_base: u64,
) {
	if g == nil {return}
	g.memory_space_enabled = memory_space_enabled
	g.control_base = control_base
	if g.bus_master_enabled && !bus_master_enabled && g.status & GSW_PCM_STATUS_RUNNING != 0 {
		g.status &~= GSW_PCM_STATUS_RUNNING
		g.sample_phase = 0
		g.current_frame = {}
		g.status |= GSW_PCM_STATUS_ERROR
		g.invalid_count += 1
		g.invalid_irq_events += 1
		g.irq_status |= GSW_PCM_IRQ_INVALID
	}
	g.bus_master_enabled = bus_master_enabled
	gsw_pcm_sync_irq(g)
}

gsw_pcm_control_offset :: proc(g: ^Gsw_Pcm, gpa: u64, size: int) -> (u32, bool) {
	if g == nil ||
	   !g.memory_space_enabled ||
	   size < 0 ||
	   gpa < g.control_base ||
	   u64(size) > GSW_PCM_CONTROL_SIZE ||
	   gpa - g.control_base > GSW_PCM_CONTROL_SIZE - u64(size) {
		return 0, false
	}
	return u32(gpa - g.control_base), true
}

@(private = "file")
gsw_pcm_rd32 :: proc(data: []u8) -> u32 {
	return u32(data[0]) | u32(data[1]) << 8 | u32(data[2]) << 16 | u32(data[3]) << 24
}

@(private = "file")
gsw_pcm_channels :: proc(g: ^Gsw_Pcm) -> u32 {
	return g.format & GSW_PCM_FORMAT_CHANNELS_MASK
}

@(private = "file")
gsw_pcm_bits_per_sample :: proc(g: ^Gsw_Pcm) -> u32 {
	return (g.format & GSW_PCM_FORMAT_BITS_MASK) >> GSW_PCM_FORMAT_BITS_SHIFT
}

gsw_pcm_frame_bytes :: proc(g: ^Gsw_Pcm) -> u32 {
	if g == nil {return 0}
	channels := gsw_pcm_channels(g)
	bits := gsw_pcm_bits_per_sample(g)
	if (channels != 1 && channels != 2) || (bits != 8 && bits != 16) {return 0}
	return channels * bits / 8
}

gsw_pcm_available_bytes :: proc(g: ^Gsw_Pcm) -> u32 {
	if g == nil || g.ring_size == 0 || g.ring_head >= g.ring_size || g.ring_tail >= g.ring_size {
		return 0
	}
	if g.ring_tail >= g.ring_head {return g.ring_tail - g.ring_head}
	return g.ring_size - g.ring_head + g.ring_tail
}

gsw_pcm_available_frames :: proc(g: ^Gsw_Pcm) -> u32 {
	frame_bytes := gsw_pcm_frame_bytes(g)
	return frame_bytes == 0 ? 0 : gsw_pcm_available_bytes(g) / frame_bytes
}

gsw_pcm_running :: proc(g: ^Gsw_Pcm) -> bool {
	return g != nil && g.status & GSW_PCM_STATUS_RUNNING != 0
}

gsw_pcm_sample_rate :: proc(g: ^Gsw_Pcm) -> u32 {
	return g != nil ? g.sample_rate : 0
}

gsw_pcm_current_frame :: proc(g: ^Gsw_Pcm) -> Audio_Frame {
	return g != nil ? g.current_frame : Audio_Frame{}
}

@(private = "file")
gsw_pcm_config_valid :: proc(g: ^Gsw_Pcm, ram: []u8) -> bool {
	if g == nil || !g.bus_master_enabled {return false}
	frame_bytes := gsw_pcm_frame_bytes(g)
	sample_rate_valid :=
		g.sample_rate == 11_025 ||
		g.sample_rate == 22_050 ||
		g.sample_rate == 44_100 ||
		g.sample_rate == 48_000
	return(
		sample_rate_valid &&
		g.format &~ GSW_PCM_FORMAT_MASK == 0 &&
		frame_bytes != 0 &&
		g.ring_size >= GSW_PCM_RING_MIN_SIZE &&
		g.ring_size <= GSW_PCM_RING_MAX_SIZE &&
		g.ring_size & (g.ring_size - 1) == 0 &&
		g.ring_size % frame_bytes == 0 &&
		g.ring_gpa & 0xF == 0 &&
		g.ring_gpa <= u64(len(ram)) &&
		u64(g.ring_size) <= u64(len(ram)) - g.ring_gpa &&
		g.ring_head < g.ring_size &&
		g.ring_tail < g.ring_size &&
		g.ring_head % frame_bytes == 0 &&
		g.ring_tail % frame_bytes == 0 &&
		g.period_bytes >= frame_bytes &&
		g.period_bytes <= g.ring_size / 2 &&
		g.period_bytes % frame_bytes == 0 &&
		g.ring_size % g.period_bytes == 0 \
	)
}

@(private = "file")
gsw_pcm_note_invalid :: proc(g: ^Gsw_Pcm) {
	if g == nil {return}
	g.status |= GSW_PCM_STATUS_ERROR
	g.invalid_count += 1
	g.invalid_irq_events += 1
	g.irq_status |= GSW_PCM_IRQ_INVALID
	gsw_pcm_sync_irq(g)
}

@(private = "file")
gsw_pcm_note_underrun :: proc(g: ^Gsw_Pcm) {
	if g.status & GSW_PCM_STATUS_UNDERRUN != 0 {return}
	g.status |= GSW_PCM_STATUS_UNDERRUN
	g.xrun_count += 1
	g.underrun_irq_events += 1
	g.irq_status |= GSW_PCM_IRQ_UNDERRUN
	gsw_pcm_sync_irq(g)
}

@(private = "file")
gsw_pcm_start :: proc(g: ^Gsw_Pcm, ram: []u8) {
	if !gsw_pcm_config_valid(g, ram) {
		gsw_pcm_note_invalid(g)
		return
	}
	g.status &~= GSW_PCM_STATUS_ERROR | GSW_PCM_STATUS_UNDERRUN
	g.status |= GSW_PCM_STATUS_READY | GSW_PCM_STATUS_RUNNING
	g.sample_phase = 0
	g.current_frame = {}
}

@(private = "file")
gsw_pcm_register_read :: proc(g: ^Gsw_Pcm, offset: u32) -> u32 {
	switch offset {
	case GSW_PCM_REG_ID:
		return GSW_PCM_ID
	case GSW_PCM_REG_VERSION:
		return GSW_PCM_INTERFACE_VERSION
	case GSW_PCM_REG_CAPABILITIES:
		return GSW_PCM_CAPABILITIES
	case GSW_PCM_REG_STATUS:
		return g.status
	case GSW_PCM_REG_SAMPLE_RATE:
		return g.sample_rate
	case GSW_PCM_REG_FORMAT:
		return g.format
	case GSW_PCM_REG_RING_GPA_LOW:
		return u32(g.ring_gpa)
	case GSW_PCM_REG_RING_GPA_HIGH:
		return u32(g.ring_gpa >> 32)
	case GSW_PCM_REG_RING_SIZE:
		return g.ring_size
	case GSW_PCM_REG_RING_HEAD:
		return g.ring_head
	case GSW_PCM_REG_RING_TAIL:
		return g.ring_tail
	case GSW_PCM_REG_PERIOD_BYTES:
		return g.period_bytes
	case GSW_PCM_REG_IRQ_ENABLE:
		return g.irq_enable
	case GSW_PCM_REG_IRQ_STATUS:
		return g.irq_status
	case GSW_PCM_REG_POSITION_LOW:
		return u32(g.position_bytes)
	case GSW_PCM_REG_POSITION_HIGH:
		return u32(g.position_bytes >> 32)
	case GSW_PCM_REG_XRUN_COUNT:
		return g.xrun_count
	case GSW_PCM_REG_INVALID_COUNT:
		return g.invalid_count
	case GSW_PCM_REG_AVAILABLE_BYTES:
		return gsw_pcm_available_bytes(g)
	case GSW_PCM_REG_MASTER_GAIN:
		return g.master_gain
	}
	return 0
}

gsw_pcm_mmio_read :: proc(g: ^Gsw_Pcm, offset: u32, data: []u8) {
	if g == nil {return}
	for &byte, i in data {
		register := (offset + u32(i)) &~ u32(3)
		shift := ((offset + u32(i)) & 3) * 8
		byte = u8(gsw_pcm_register_read(g, register) >> shift)
	}
}

gsw_pcm_mmio_write :: proc(g: ^Gsw_Pcm, offset: u32, data, ram: []u8) {
	if g == nil {return}
	if len(data) != 4 || offset & 3 != 0 {
		gsw_pcm_note_invalid(g)
		return
	}
	value := gsw_pcm_rd32(data)
	configuration_locked := gsw_pcm_running(g)
	switch offset {
	case GSW_PCM_REG_CONTROL:
		command := value & GSW_PCM_CONTROL_MASK
		if value &~ GSW_PCM_CONTROL_MASK != 0 || command == 0 || command & (command - 1) != 0 {
			gsw_pcm_note_invalid(g)
			return
		}
		switch command {
		case GSW_PCM_CONTROL_RESET:
			gsw_pcm_reset(g)
		case GSW_PCM_CONTROL_STOP:
			g.status &~= GSW_PCM_STATUS_RUNNING
			g.sample_phase = 0
			g.current_frame = {}
		case GSW_PCM_CONTROL_START:
			gsw_pcm_start(g, ram)
		}
	case GSW_PCM_REG_SAMPLE_RATE:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.sample_rate = value
	case GSW_PCM_REG_FORMAT:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.format = value
	case GSW_PCM_REG_RING_GPA_LOW:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.ring_gpa = g.ring_gpa & 0xFFFF_FFFF_0000_0000 | u64(value)
		g.ring_head, g.ring_tail = 0, 0
		g.position_bytes, g.bytes_since_period = 0, 0
	case GSW_PCM_REG_RING_GPA_HIGH:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.ring_gpa = g.ring_gpa & 0x0000_0000_FFFF_FFFF | u64(value) << 32
		g.ring_head, g.ring_tail = 0, 0
		g.position_bytes, g.bytes_since_period = 0, 0
	case GSW_PCM_REG_RING_SIZE:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.ring_size = value
		g.ring_head, g.ring_tail = 0, 0
		g.position_bytes, g.bytes_since_period = 0, 0
	case GSW_PCM_REG_RING_TAIL:
		frame_bytes := gsw_pcm_frame_bytes(g)
		if g.ring_size == 0 || value >= g.ring_size || frame_bytes == 0 || value % frame_bytes != 0 {
			gsw_pcm_note_invalid(g)
			return
		}
		available := gsw_pcm_available_bytes(g)
		free := g.ring_size - min(g.ring_size, available) - frame_bytes
		committed := value - g.ring_tail
		if value < g.ring_tail {committed = g.ring_size - g.ring_tail + value}
		if committed > free {
			gsw_pcm_note_invalid(g)
			return
		}
		g.ring_tail = value
	case GSW_PCM_REG_PERIOD_BYTES:
		if configuration_locked {gsw_pcm_note_invalid(g); return}
		g.period_bytes = value
	case GSW_PCM_REG_IRQ_ENABLE:
		g.irq_enable = value & GSW_PCM_IRQ_MASK
		gsw_pcm_sync_irq(g)
	case GSW_PCM_REG_IRQ_STATUS:
		g.irq_status &~= value & GSW_PCM_IRQ_MASK
		gsw_pcm_sync_irq(g)
	case GSW_PCM_REG_STATUS:
		g.status &~= value & (GSW_PCM_STATUS_ERROR | GSW_PCM_STATUS_UNDERRUN)
	case GSW_PCM_REG_MASTER_GAIN:
		g.master_gain = min(value, AUDIO_GAIN_UNITY)
	case:
		gsw_pcm_note_invalid(g)
	}
}

@(private = "file")
gsw_pcm_ring_byte :: proc(g: ^Gsw_Pcm, ram: []u8, offset: u32) -> u8 {
	ring_offset := offset & (g.ring_size - 1)
	return ram[int(g.ring_gpa + u64(ring_offset))]
}

@(private = "file")
gsw_pcm_ring_i16 :: proc(g: ^Gsw_Pcm, ram: []u8, offset: u32) -> i16 {
	low := u16(gsw_pcm_ring_byte(g, ram, offset))
	high := u16(gsw_pcm_ring_byte(g, ram, offset + 1))
	return audio_pcm_i16(low | high << 8)
}

// Pulls device-rate frames synchronously from guest RAM. Callers own scheduling;
// this routine deliberately has no worker or audio-callback path to guest memory.
// Unavailable frames are returned as silence and raise the underrun latch.
gsw_pcm_pull :: proc(g: ^Gsw_Pcm, ram: []u8, out: []Audio_Frame) -> int {
	for &frame in out {frame = {}}
	if g == nil || len(out) == 0 || !gsw_pcm_running(g) {return 0}
	if !gsw_pcm_config_valid(g, ram) {
		g.status &~= GSW_PCM_STATUS_RUNNING
		gsw_pcm_note_invalid(g)
		return 0
	}
	frame_bytes := gsw_pcm_frame_bytes(g)
	available := int(gsw_pcm_available_bytes(g) / frame_bytes)
	consumed := min(len(out), available)
	channels := gsw_pcm_channels(g)
	bits := gsw_pcm_bits_per_sample(g)
	for index in 0 ..< consumed {
		offset := g.ring_head
		left, right: i16
		if bits == 8 {
			left = audio_pcm_u8(gsw_pcm_ring_byte(g, ram, offset))
			right = left
			if channels == 2 {right = audio_pcm_u8(gsw_pcm_ring_byte(g, ram, offset + 1))}
		} else {
			left = gsw_pcm_ring_i16(g, ram, offset)
			right = channels == 2 ? gsw_pcm_ring_i16(g, ram, offset + 2) : left
		}
		left = audio_clamp_i16(i64(audio_scale_q16(left, g.master_gain)))
		right = audio_clamp_i16(i64(audio_scale_q16(right, g.master_gain)))
		out[index] = {left = left, right = right}
		g.ring_head = (g.ring_head + frame_bytes) & (g.ring_size - 1)
		g.position_bytes += u64(frame_bytes)
		g.bytes_since_period += frame_bytes
		if g.bytes_since_period >= g.period_bytes {
			g.bytes_since_period %= g.period_bytes
			g.period_irq_events += 1
			g.irq_status |= GSW_PCM_IRQ_PERIOD
		}
	}
	if len(out) > 0 {g.current_frame = out[len(out) - 1]}
	if consumed < len(out) {
		g.starvation_frames += u64(len(out) - consumed)
		gsw_pcm_note_underrun(g)
	} else {
		gsw_pcm_sync_irq(g)
	}
	return consumed
}

@(private = "file")
gsw_pcm_ticks_until_frames :: proc(g: ^Gsw_Pcm, frames: u64) -> (u64, bool) {
	if g == nil || !gsw_pcm_running(g) || frames == 0 || g.sample_rate == 0 {
		return 0, false
	}
	needed := u128(frames) * u128(AUDIO_MASTER_CLOCK_HZ)
	if needed > u128(g.sample_phase) {needed -= u128(g.sample_phase)} else {needed = 1}
	delta := (needed + u128(g.sample_rate) - 1) / u128(g.sample_rate)
	if delta > u128(~u64(0) - g.now_ticks) {return ~u64(0), true}
	return g.now_ticks + max(u64(delta), u64(1)), true
}

// Returns the exact VM tick at which the next committed period can complete.
// A period cannot complete until enough guest frames have been committed.
gsw_pcm_next_period_deadline_tick :: proc(g: ^Gsw_Pcm) -> (u64, bool) {
	if g == nil || !gsw_pcm_running(g) {return 0, false}
	frame_bytes := gsw_pcm_frame_bytes(g)
	if frame_bytes == 0 || g.period_bytes < frame_bytes {return 0, false}
	remaining_bytes := g.period_bytes - min(g.bytes_since_period, g.period_bytes - frame_bytes)
	frames := u64(remaining_bytes / frame_bytes)
	if u64(gsw_pcm_available_frames(g)) < frames {return 0, false}
	return gsw_pcm_ticks_until_frames(g, frames)
}

// Returns the exact VM tick at which playback first requests a frame beyond the
// committed tail. An already-latched underrun is not repeatedly rescheduled.
gsw_pcm_next_underrun_deadline_tick :: proc(g: ^Gsw_Pcm) -> (u64, bool) {
	if g == nil || !gsw_pcm_running(g) || g.status & GSW_PCM_STATUS_UNDERRUN != 0 {
		return 0, false
	}
	return gsw_pcm_ticks_until_frames(g, u64(gsw_pcm_available_frames(g)) + 1)
}

// Next native device-rate sample boundary. Machine audio uses this to merge
// GSW-Sound samples with PIT/SB16/OPL3 events in exact VM-tick order.
gsw_pcm_next_sample_deadline_tick :: proc(g: ^Gsw_Pcm) -> (u64, bool) {
	return gsw_pcm_ticks_until_frames(g, 1)
}

// Earliest guest-observable transport completion (period or first underrun).
gsw_pcm_next_deadline_tick :: proc(g: ^Gsw_Pcm) -> (deadline: u64, pending: bool) {
	deadline, pending = gsw_pcm_next_period_deadline_tick(g)
	if underrun, ok := gsw_pcm_next_underrun_deadline_tick(g);
	   ok && (!pending || underrun < deadline) {
		deadline, pending = underrun, true
	}
	return
}

// Advances native playback against the 6.6 GHz VM timeline. Guest RAM is read
// only in this synchronous call, which must run on the machine thread.
gsw_pcm_advance_to :: proc(g: ^Gsw_Pcm, at_tick: u64, ram: []u8) -> u64 {
	if g == nil || at_tick <= g.now_ticks {return 0}
	elapsed := at_tick - g.now_ticks
	g.now_ticks = at_tick
	if !gsw_pcm_running(g) {
		g.sample_phase = 0
		return 0
	}
	total := u128(g.sample_phase) + u128(elapsed) * u128(g.sample_rate)
	frames_due_128 := total / u128(AUDIO_MASTER_CLOCK_HZ)
	g.sample_phase = u64(total % u128(AUDIO_MASTER_CLOCK_HZ))
	frames_due := frames_due_128 > u128(~u64(0)) ? ~u64(0) : u64(frames_due_128)
	if frames_due == 0 {return 0}

	remaining := frames_due
	batch: [GSW_PCM_ADVANCE_BATCH]Audio_Frame
	for remaining > 0 {
		count := int(min(remaining, u64(len(batch))))
		consumed := gsw_pcm_pull(g, ram, batch[:count])
		if g.publish != nil {g.publish(g.publish_ctx, at_tick, g.sample_rate, batch[:count])}
		remaining -= u64(count)
		// A very large paused-time jump must not create an unbounded catch-up
		// burst once the ring is empty. The callback above publishes the new
		// silent state at at_tick; normal scheduler advances remain exact.
		if consumed == 0 && remaining > 0 {
			g.current_frame = {}
			break
		}
	}
	return frames_due
}

// Renders exactly the native sample event due at at_tick. Calls at a tick
// before the next boundary are non-producing; callers should normally pass the
// value returned by gsw_pcm_next_sample_deadline_tick.
gsw_pcm_render_sample :: proc(
	g: ^Gsw_Pcm,
	at_tick: u64,
	ram: []u8,
) -> (Audio_Frame, bool) {
	deadline, pending := gsw_pcm_next_sample_deadline_tick(g)
	if !pending || at_tick < deadline {return gsw_pcm_current_frame(g), false}
	advanced := gsw_pcm_advance_to(g, at_tick, ram)
	return gsw_pcm_current_frame(g), advanced > 0
}
