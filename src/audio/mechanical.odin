// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:sync"

MECHANICAL_EVENT_CAPACITY :: 128
MECHANICAL_HDD_COOLDOWN_FRAMES :: int(AUDIO_OUTPUT_HZ * 2 / 1_000)
MECHANICAL_HDD_TEST_INTERVAL_FRAMES :: int(AUDIO_OUTPUT_HZ * 70 / 1_000)
MECHANICAL_FLOPPY_TEST_FRAMES :: int(AUDIO_OUTPUT_HZ * 6 / 5)
MECHANICAL_FLOPPY_TEST_STEP_FRAMES :: int(AUDIO_OUTPUT_HZ / 7)
MECHANICAL_PHASE_ONE :: u64(1) << 32

Mechanical_Event_Kind :: enum u8 {
	Hard_Drive_Access,
	Floppy_Motor,
	Floppy_Seek,
	Floppy_Transfer,
	Test_Hard_Drive,
	Test_Floppy,
}

Mechanical_Event :: struct {
	kind:     Mechanical_Event_Kind,
	position: u32,
	amount:   u16,
	write:    bool,
	session:  u64,
}

Mechanical_Event_Proc :: proc(ctx: rawptr, event: Mechanical_Event)

Mechanical_Event_Sink :: struct {
	ctx:  rawptr,
	emit: Mechanical_Event_Proc,
}

mechanical_event_sink_emit :: proc(sink: Mechanical_Event_Sink, event: Mechanical_Event) {
	if sink.emit != nil {sink.emit(sink.ctx, event)}
}

Mechanical_Event_Queue :: struct {
	events:       [MECHANICAL_EVENT_CAPACITY]Mechanical_Event,
	sequence:     [MECHANICAL_EVENT_CAPACITY]u64,
	enqueue_pos:  u64,
	dequeue_pos:  u64,
	dropped:      u64,
}

mechanical_event_queue_init :: proc(queue: ^Mechanical_Event_Queue) {
	if queue == nil {return}
	queue^ = {}
	for index in 0 ..< MECHANICAL_EVENT_CAPACITY {
		sync.atomic_store_explicit(&queue.sequence[index], u64(index), .Relaxed)
	}
}

mechanical_event_queue_push :: proc(
	queue: ^Mechanical_Event_Queue,
	event: Mechanical_Event,
) -> bool {
	if queue == nil {return false}
	position := sync.atomic_load_explicit(&queue.enqueue_pos, .Relaxed)
	for {
		slot := position % u64(MECHANICAL_EVENT_CAPACITY)
		sequence := sync.atomic_load_explicit(&queue.sequence[slot], .Acquire)
		difference := i64(sequence - position)
		if difference == 0 {
			_, claimed := sync.atomic_compare_exchange_weak_explicit(
				&queue.enqueue_pos,
				position,
				position + 1,
				.Relaxed,
				.Relaxed,
			)
			if !claimed {
				position = sync.atomic_load_explicit(&queue.enqueue_pos, .Relaxed)
				continue
			}
			queue.events[slot] = event
			sync.atomic_store_explicit(&queue.sequence[slot], position + 1, .Release)
			return true
		}
		if difference < 0 {
			_ = sync.atomic_add_explicit(&queue.dropped, u64(1), .Relaxed)
			return false
		}
		position = sync.atomic_load_explicit(&queue.enqueue_pos, .Relaxed)
	}
}

mechanical_event_queue_pop :: proc(
	queue: ^Mechanical_Event_Queue,
) -> (Mechanical_Event, bool) {
	if queue == nil {return {}, false}
	position := sync.atomic_load_explicit(&queue.dequeue_pos, .Relaxed)
	slot := position % u64(MECHANICAL_EVENT_CAPACITY)
	sequence := sync.atomic_load_explicit(&queue.sequence[slot], .Acquire)
	if i64(sequence - (position + 1)) != 0 {return {}, false}
	event := queue.events[slot]
	sync.atomic_store_explicit(
		&queue.sequence[slot],
		position + u64(MECHANICAL_EVENT_CAPACITY),
		.Release,
	)
	sync.atomic_store_explicit(&queue.dequeue_pos, position + 1, .Release)
	return event, true
}

mechanical_event_queue_dropped :: proc(queue: ^Mechanical_Event_Queue) -> u64 {
	if queue == nil {return 0}
	return sync.atomic_load_explicit(&queue.dropped, .Relaxed)
}

Mechanical_Synth :: struct {
	noise:                        u32,
	hdd_envelope:                 i32,
	hdd_phase:                    u32,
	hdd_phase_step:               u32,
	hdd_cooldown:                 int,
	hdd_last_position:            u32,
	hdd_last_position_valid:      bool,
	hdd_test_clicks:              int,
	hdd_test_countdown:           int,
	floppy_machine_motor:         bool,
	floppy_motor_level:           i32,
	floppy_carrier_phase:         u32,
	floppy_wobble_phase:          u32,
	floppy_step_envelope:         i32,
	floppy_test_frames:           int,
	floppy_test_step_countdown:   int,
}

mechanical_synth_reset :: proc(synth: ^Mechanical_Synth) {
	if synth == nil {return}
	synth^ = {
		noise = 0x6D2B_79F5,
		hdd_phase_step = u32(MECHANICAL_PHASE_ONE * 2_900 / AUDIO_OUTPUT_HZ),
	}
}

@(private = "file")
mechanical_abs_difference_u32 :: proc(a, b: u32) -> u32 {
	return a >= b ? a - b : b - a
}

@(private = "file")
mechanical_hdd_intensity :: proc(synth: ^Mechanical_Synth, event: Mechanical_Event) -> i32 {
	distance: u32
	if synth.hdd_last_position_valid {
		distance = mechanical_abs_difference_u32(event.position, synth.hdd_last_position)
	}
	synth.hdd_last_position = event.position + u32(event.amount)
	synth.hdd_last_position_valid = true
	distance_weight: i32
	remaining := distance
	for remaining > 0 {
		distance_weight += 420
		remaining >>= 1
	}
	transfer_weight := min(i32(event.amount) * 18, i32(2_800))
	write_weight := event.write ? i32(700) : i32(0)
	return clamp(i32(4_800) + distance_weight + transfer_weight + write_weight, i32(4_800), i32(14_000))
}

@(private = "file")
mechanical_synth_trigger_hdd :: proc(synth: ^Mechanical_Synth, intensity: i32) {
	if synth.hdd_cooldown > 0 {
		synth.hdd_envelope = min(i32(15_000), max(synth.hdd_envelope, intensity / 3))
		return
	}
	synth.hdd_envelope = max(synth.hdd_envelope, intensity)
	synth.hdd_phase = 0
	synth.hdd_phase_step = u32(
		MECHANICAL_PHASE_ONE * u64(2_200 + intensity / 8) / AUDIO_OUTPUT_HZ,
	)
	synth.hdd_cooldown = MECHANICAL_HDD_COOLDOWN_FRAMES
}

mechanical_synth_event :: proc(synth: ^Mechanical_Synth, event: Mechanical_Event) {
	if synth == nil {return}
	switch event.kind {
	case .Hard_Drive_Access:
		mechanical_synth_trigger_hdd(synth, mechanical_hdd_intensity(synth, event))
	case .Floppy_Motor:
		synth.floppy_machine_motor = event.amount != 0
	case .Floppy_Seek:
		steps := max(i32(event.amount), i32(1))
		synth.floppy_step_envelope = max(
			synth.floppy_step_envelope,
			min(i32(11_000), i32(4_500) + steps * 350),
		)
	case .Floppy_Transfer:
		synth.floppy_step_envelope = max(synth.floppy_step_envelope, i32(2_600))
	case .Test_Hard_Drive:
		synth.hdd_test_clicks = 4
		synth.hdd_test_countdown = 0
	case .Test_Floppy:
		synth.floppy_test_frames = MECHANICAL_FLOPPY_TEST_FRAMES
		synth.floppy_test_step_countdown = 0
	}
}

@(private = "file")
mechanical_noise_next :: proc(synth: ^Mechanical_Synth) -> i32 {
	value := synth.noise
	value = value ~ (value << 13)
	value = value ~ (value >> 17)
	value = value ~ (value << 5)
	synth.noise = value
	return i32(i16(u16(value >> 16)))
}

@(private = "file")
mechanical_triangle :: proc(phase: u32) -> i32 {
	position := i32(phase >> 16)
	if position < 32_768 {return position * 2 - 32_768}
	return (65_535 - position) * 2 - 32_768
}

@(private = "file")
mechanical_synth_frame :: proc(synth: ^Mechanical_Synth) -> Audio_Frame {
	if synth.hdd_test_clicks > 0 {
		if synth.hdd_test_countdown <= 0 {
			mechanical_synth_trigger_hdd(synth, 12_000 - i32(4 - synth.hdd_test_clicks) * 900)
			synth.hdd_test_clicks -= 1
			synth.hdd_test_countdown = MECHANICAL_HDD_TEST_INTERVAL_FRAMES
		}
		synth.hdd_test_countdown -= 1
	}
	if synth.floppy_test_frames > 0 {
		synth.floppy_test_frames -= 1
		if synth.floppy_test_step_countdown <= 0 {
			synth.floppy_step_envelope = 8_500
			synth.floppy_test_step_countdown = MECHANICAL_FLOPPY_TEST_STEP_FRAMES
		}
		synth.floppy_test_step_countdown -= 1
	}

	noise := mechanical_noise_next(synth)
	hdd: i32
	if synth.hdd_envelope > 0 {
		synth.hdd_phase += synth.hdd_phase_step
		resonance := mechanical_triangle(synth.hdd_phase)
		hdd = noise * synth.hdd_envelope / 98_304 + resonance * synth.hdd_envelope / 131_072
		synth.hdd_envelope = synth.hdd_envelope * 32_500 / 32_768
		if synth.hdd_envelope < 8 {synth.hdd_envelope = 0}
	}
	synth.hdd_cooldown -= min(synth.hdd_cooldown, 1)

	motor_target := synth.floppy_machine_motor || synth.floppy_test_frames > 0
	if motor_target {
		synth.floppy_motor_level = min(i32(2_800), synth.floppy_motor_level + 7)
	} else {
		synth.floppy_motor_level = max(i32(0), synth.floppy_motor_level - 4)
	}
	floppy: i32
	if synth.floppy_motor_level > 0 {
		synth.floppy_carrier_phase += u32(MECHANICAL_PHASE_ONE * 112 / AUDIO_OUTPUT_HZ)
		synth.floppy_wobble_phase += u32(MECHANICAL_PHASE_ONE * 5 / AUDIO_OUTPUT_HZ)
		carrier := mechanical_triangle(synth.floppy_carrier_phase)
		wobble := mechanical_triangle(synth.floppy_wobble_phase)
		modulated_level := synth.floppy_motor_level * (39_000 + wobble / 4) / 49_152
		floppy = carrier * modulated_level / 65_536 + noise * modulated_level / 393_216
	}
	if synth.floppy_step_envelope > 0 {
		floppy += noise * synth.floppy_step_envelope / 65_536
		synth.floppy_step_envelope = synth.floppy_step_envelope * 32_100 / 32_768
		if synth.floppy_step_envelope < 8 {synth.floppy_step_envelope = 0}
	}

	mixed := audio_clamp_i16(i64(hdd + floppy))
	return {left = mixed, right = mixed}
}

mechanical_synth_render :: proc(synth: ^Mechanical_Synth, frames: []Audio_Frame) {
	if synth == nil {return}
	for &frame in frames {frame = mechanical_synth_frame(synth)}
}

Mechanical_Engine :: struct {
	queue:                  Mechanical_Event_Queue,
	synth:                  Mechanical_Synth,
	session:                u64,
	reset_generation:       u64,
	seen_reset_generation:  u64,
	machine_events_enabled: u64,
	hdd_enabled:            u64,
	floppy_enabled:         u64,
}

mechanical_engine_init :: proc(engine: ^Mechanical_Engine) {
	if engine == nil {return}
	engine^ = {}
	mechanical_event_queue_init(&engine.queue)
	mechanical_synth_reset(&engine.synth)
	sync.atomic_store_explicit(&engine.session, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.reset_generation, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.hdd_enabled, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.floppy_enabled, u64(1), .Relaxed)
}

@(private = "file")
mechanical_engine_emit :: proc(ctx: rawptr, event: Mechanical_Event) {
	engine := (^Mechanical_Engine)(ctx)
	if engine == nil || sync.atomic_load_explicit(&engine.machine_events_enabled, .Acquire) == 0 {
		return
	}
	queued := event
	queued.session = sync.atomic_load_explicit(&engine.session, .Acquire)
	_ = mechanical_event_queue_push(&engine.queue, queued)
}

mechanical_engine_sink :: proc(engine: ^Mechanical_Engine) -> Mechanical_Event_Sink {
	if engine == nil {return {}}
	return {ctx = engine, emit = mechanical_engine_emit}
}

mechanical_engine_set_machine_state :: proc(
	engine: ^Mechanical_Engine,
	running, paused: bool,
) {
	if engine == nil {return}
	_ = sync.atomic_add_explicit(&engine.session, u64(1), .Release)
	sync.atomic_store_explicit(
		&engine.machine_events_enabled,
		running && !paused ? u64(1) : u64(0),
		.Release,
	)
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

mechanical_engine_set_enabled :: proc(engine: ^Mechanical_Engine, hdd, floppy: bool) {
	if engine == nil {return}
	_ = sync.atomic_add_explicit(&engine.session, u64(1), .Release)
	sync.atomic_store_explicit(&engine.hdd_enabled, hdd ? u64(1) : u64(0), .Release)
	sync.atomic_store_explicit(&engine.floppy_enabled, floppy ? u64(1) : u64(0), .Release)
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

mechanical_engine_test_hard_drive :: proc(engine: ^Mechanical_Engine) -> bool {
	if engine == nil {return false}
	return mechanical_event_queue_push(&engine.queue, {kind = .Test_Hard_Drive})
}

mechanical_engine_test_floppy :: proc(engine: ^Mechanical_Engine) -> bool {
	if engine == nil {return false}
	return mechanical_event_queue_push(&engine.queue, {kind = .Test_Floppy})
}

mechanical_engine_render :: proc(engine: ^Mechanical_Engine, frames: []Audio_Frame) {
	if engine == nil {return}
	reset_generation := sync.atomic_load_explicit(&engine.reset_generation, .Acquire)
	if engine.seen_reset_generation != reset_generation {
		mechanical_synth_reset(&engine.synth)
		engine.seen_reset_generation = reset_generation
	}
	session := sync.atomic_load_explicit(&engine.session, .Acquire)
	machine_enabled := sync.atomic_load_explicit(&engine.machine_events_enabled, .Acquire) != 0
	hdd_enabled := sync.atomic_load_explicit(&engine.hdd_enabled, .Acquire) != 0
	floppy_enabled := sync.atomic_load_explicit(&engine.floppy_enabled, .Acquire) != 0
	for {
		event, available := mechanical_event_queue_pop(&engine.queue)
		if !available {break}
		switch event.kind {
		case .Test_Hard_Drive, .Test_Floppy:
			mechanical_synth_event(&engine.synth, event)
		case .Hard_Drive_Access:
			if machine_enabled && hdd_enabled && event.session == session {
				mechanical_synth_event(&engine.synth, event)
			}
		case .Floppy_Motor, .Floppy_Seek, .Floppy_Transfer:
			if machine_enabled && floppy_enabled && event.session == session {
				mechanical_synth_event(&engine.synth, event)
			}
		}
	}
	mechanical_synth_render(&engine.synth, frames)
}
