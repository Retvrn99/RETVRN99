// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:sync"

MECHANICAL_EVENT_CAPACITY :: 128
MECHANICAL_HDD_COOLDOWN_FRAMES :: int(AUDIO_OUTPUT_HZ * 2 / 1_000)
MECHANICAL_HDD_TEST_INTERVAL_FRAMES :: int(AUDIO_OUTPUT_HZ * 70 / 1_000)
MECHANICAL_HDD_TEST_FRAMES :: int(AUDIO_OUTPUT_HZ * 2 / 5)
MECHANICAL_FLOPPY_TEST_FRAMES :: int(AUDIO_OUTPUT_HZ * 6 / 5)
MECHANICAL_FLOPPY_TEST_STEP_FRAMES :: int(AUDIO_OUTPUT_HZ / 7)
MECHANICAL_FDD_STOP_FADE_FRAMES :: int(AUDIO_OUTPUT_HZ * 75 / 1_000)
MECHANICAL_SAMPLE_GAIN_ONE :: i32(65_536)
MECHANICAL_MAX_SAMPLE_VOICES :: 8
MECHANICAL_FDD_SEEK_SAMPLE_COUNT :: 79

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

// The state transitions and layered seek-voice model follow 86Box commit
// 82c0e7a3ca74da1f52682544d533b58f6665e9bd. Sample recordings are external;
// the 86Box assets repository does not grant redistribution rights.
Mechanical_Sample :: struct {
	frames: []Audio_Frame,
	gain:   i32,
}

mechanical_sample_valid :: proc(sample: ^Mechanical_Sample) -> bool {
	return sample != nil && len(sample.frames) > 0
}

Mechanical_Sample_Set :: struct {
	hdd_spin_up:     Mechanical_Sample,
	hdd_running:     Mechanical_Sample,
	hdd_spin_down:   Mechanical_Sample,
	hdd_seek:        Mechanical_Sample,
	fdd_motor_start: Mechanical_Sample,
	fdd_motor_loop:  Mechanical_Sample,
	fdd_motor_stop:  Mechanical_Sample,
	fdd_seek_up:     [MECHANICAL_FDD_SEEK_SAMPLE_COUNT]Mechanical_Sample,
	fdd_seek_down:   [MECHANICAL_FDD_SEEK_SAMPLE_COUNT]Mechanical_Sample,
	hdd_available:   bool,
	fdd_available:   bool,
}

Mechanical_Spindle_State :: enum u8 {
	Stopped,
	Starting,
	Running,
	Stopping,
}

Mechanical_Sample_Voice :: struct {
	sample:   ^Mechanical_Sample,
	position: int,
	active:   bool,
}

Mechanical_Voice_Full_Policy :: enum u8 {
	Drop,
	Reuse_First,
}

Mechanical_Synth :: struct {
	samples:                    ^Mechanical_Sample_Set,
	hdd_state:                  Mechanical_Spindle_State,
	hdd_position:               int,
	hdd_seek_voices:            [MECHANICAL_MAX_SAMPLE_VOICES]Mechanical_Sample_Voice,
	hdd_cooldown:               int,
	hdd_test_frames:            int,
	hdd_test_countdown:         int,
	hdd_test_should_stop:       bool,
	fdd_state:                  Mechanical_Spindle_State,
	fdd_motor_requested:        bool,
	fdd_motor_position:         int,
	fdd_stop_position:          int,
	fdd_stop_fade_remaining:    int,
	fdd_seek_voices:            [MECHANICAL_MAX_SAMPLE_VOICES]Mechanical_Sample_Voice,
	fdd_last_track:             u32,
	fdd_test_frames:            int,
	fdd_test_step_countdown:    int,
	fdd_test_step_index:        int,
	fdd_test_should_stop:       bool,
}

mechanical_synth_reset :: proc(
	synth: ^Mechanical_Synth,
	samples: ^Mechanical_Sample_Set = nil,
) {
	if synth == nil {return}
	synth^ = {samples = samples}
}

@(private = "file")
mechanical_sample_mix :: proc(
	sample: ^Mechanical_Sample,
	position: int,
	left, right: ^i64,
	gain_scale: i32 = MECHANICAL_SAMPLE_GAIN_ONE,
) -> bool {
	if !mechanical_sample_valid(sample) || position < 0 || position >= len(sample.frames) {
		return false
	}
	frame := sample.frames[position]
	gain := i64(sample.gain) * i64(gain_scale) / i64(MECHANICAL_SAMPLE_GAIN_ONE)
	left^ += i64(frame.left) * gain / i64(MECHANICAL_SAMPLE_GAIN_ONE)
	right^ += i64(frame.right) * gain / i64(MECHANICAL_SAMPLE_GAIN_ONE)
	return true
}

@(private = "file")
mechanical_voice_start :: proc(
	voices: []Mechanical_Sample_Voice,
	sample: ^Mechanical_Sample,
	full_policy: Mechanical_Voice_Full_Policy,
) {
	if !mechanical_sample_valid(sample) || len(voices) == 0 {return}
	index := -1
	for candidate in 0 ..< len(voices) {
		if !voices[candidate].active {index = candidate; break}
	}
	if index < 0 {
		if full_policy == .Drop {return}
		index = 0
	}
	voices[index] = {sample = sample, active = true}
}

@(private = "file")
mechanical_voices_mix :: proc(
	voices: []Mechanical_Sample_Voice,
	left, right: ^i64,
) {
	for &voice in voices {
		if !voice.active {continue}
		if mechanical_sample_mix(voice.sample, voice.position, left, right) {
			voice.position += 1
		} else {
			voice = {}
		}
	}
}

@(private = "file")
mechanical_hdd_start :: proc(synth: ^Mechanical_Synth) {
	if synth == nil || synth.samples == nil || !synth.samples.hdd_available {return}
	synth.hdd_position = 0
	if mechanical_sample_valid(&synth.samples.hdd_spin_up) {
		synth.hdd_state = .Starting
	} else {
		synth.hdd_state = .Running
	}
}

@(private = "file")
mechanical_hdd_stop :: proc(synth: ^Mechanical_Synth) {
	if synth == nil || synth.hdd_state == .Stopped || synth.hdd_state == .Stopping {return}
	synth.hdd_seek_voices = {}
	synth.hdd_position = 0
	if synth.samples != nil && mechanical_sample_valid(&synth.samples.hdd_spin_down) {
		synth.hdd_state = .Stopping
	} else {
		synth.hdd_state = .Stopped
	}
}

@(private = "file")
mechanical_hdd_seek :: proc(synth: ^Mechanical_Synth) {
	if synth == nil || synth.samples == nil || synth.hdd_state != .Running || synth.hdd_cooldown > 0 {
		return
	}
	mechanical_voice_start(
		synth.hdd_seek_voices[:],
		&synth.samples.hdd_seek,
		.Drop,
	)
	synth.hdd_cooldown = MECHANICAL_HDD_COOLDOWN_FRAMES
}

@(private = "file")
mechanical_fdd_start :: proc(synth: ^Mechanical_Synth) {
	if synth == nil || synth.samples == nil || !synth.samples.fdd_available {return}
	synth.fdd_motor_requested = true
	synth.fdd_motor_position = 0
	synth.fdd_stop_position = 0
	synth.fdd_stop_fade_remaining = 0
	if mechanical_sample_valid(&synth.samples.fdd_motor_start) {
		synth.fdd_state = .Starting
	} else {
		synth.fdd_state = .Running
	}
}

@(private = "file")
mechanical_fdd_stop :: proc(synth: ^Mechanical_Synth) {
	if synth == nil {return}
	synth.fdd_motor_requested = false
	if synth.fdd_state == .Stopped || synth.fdd_state == .Stopping {return}
	synth.fdd_stop_position = 0
	synth.fdd_stop_fade_remaining = MECHANICAL_FDD_STOP_FADE_FRAMES
	if synth.samples != nil && mechanical_sample_valid(&synth.samples.fdd_motor_stop) {
		synth.fdd_state = .Stopping
	} else {
		synth.fdd_state = .Stopped
	}
}

@(private = "file")
mechanical_fdd_seek :: proc(synth: ^Mechanical_Synth, event: Mechanical_Event) {
	if synth == nil || synth.samples == nil || synth.fdd_state == .Stopped {return}
	distance := clamp(int(event.amount), 1, MECHANICAL_FDD_SEEK_SAMPLE_COUNT)
	up := event.position >= synth.fdd_last_track
	synth.fdd_last_track = event.position
	sample := up ? &synth.samples.fdd_seek_up[distance - 1] :
	               &synth.samples.fdd_seek_down[distance - 1]
	mechanical_voice_start(
		synth.fdd_seek_voices[:],
		sample,
		.Reuse_First,
	)
}

mechanical_synth_event :: proc(synth: ^Mechanical_Synth, event: Mechanical_Event) {
	if synth == nil {return}
	switch event.kind {
	case .Hard_Drive_Access:
		mechanical_hdd_seek(synth)
	case .Floppy_Motor:
		synth.fdd_last_track = event.position
		if event.amount != 0 {mechanical_fdd_start(synth)} else {mechanical_fdd_stop(synth)}
	case .Floppy_Seek:
		mechanical_fdd_seek(synth, event)
	case .Floppy_Transfer:
		// The selected 86Box profile has no transfer sample; the motor loop remains audible.
	case .Test_Hard_Drive:
		if synth.samples != nil && synth.samples.hdd_available {
			synth.hdd_test_should_stop = synth.hdd_state == .Stopped
			if synth.hdd_test_should_stop {
				synth.hdd_state = .Running
				synth.hdd_position = 0
			}
			synth.hdd_test_frames = MECHANICAL_HDD_TEST_FRAMES
			synth.hdd_test_countdown = 0
		}
	case .Test_Floppy:
		if synth.samples != nil && synth.samples.fdd_available {
			synth.fdd_test_should_stop = synth.fdd_state == .Stopped
			if synth.fdd_test_should_stop {mechanical_fdd_start(synth)}
			synth.fdd_test_frames = MECHANICAL_FLOPPY_TEST_FRAMES
			synth.fdd_test_step_countdown = 0
			synth.fdd_test_step_index = 0
		}
	}
}

@(private = "file")
mechanical_hdd_mix :: proc(synth: ^Mechanical_Synth, left, right: ^i64) {
	if synth.samples == nil {return}
	switch synth.hdd_state {
	case .Stopped:
	case .Starting:
		if mechanical_sample_mix(&synth.samples.hdd_spin_up, synth.hdd_position, left, right) {
			synth.hdd_position += 1
		} else {
			synth.hdd_state = .Running
			synth.hdd_position = 0
			if mechanical_sample_mix(&synth.samples.hdd_running, 0, left, right) {
				synth.hdd_position = 1
			}
		}
	case .Running:
		if mechanical_sample_mix(&synth.samples.hdd_running, synth.hdd_position, left, right) {
			synth.hdd_position += 1
			if synth.hdd_position >= len(synth.samples.hdd_running.frames) {synth.hdd_position = 0}
		}
		mechanical_voices_mix(synth.hdd_seek_voices[:], left, right)
	case .Stopping:
		if mechanical_sample_mix(&synth.samples.hdd_spin_down, synth.hdd_position, left, right) {
			synth.hdd_position += 1
		} else {
			synth.hdd_state = .Stopped
			synth.hdd_position = 0
		}
	}
	synth.hdd_cooldown -= min(synth.hdd_cooldown, 1)
}

@(private = "file")
mechanical_fdd_loop_mix :: proc(
	synth: ^Mechanical_Synth,
	left, right: ^i64,
	gain_scale: i32 = MECHANICAL_SAMPLE_GAIN_ONE,
) {
	loop := &synth.samples.fdd_motor_loop
	if !mechanical_sample_valid(loop) {return}
	if synth.fdd_motor_position >= len(loop.frames) {synth.fdd_motor_position = 0}
	_ = mechanical_sample_mix(loop, synth.fdd_motor_position, left, right, gain_scale)
	synth.fdd_motor_position += 1
}

@(private = "file")
mechanical_fdd_mix :: proc(synth: ^Mechanical_Synth, left, right: ^i64) {
	if synth.samples == nil {return}
	switch synth.fdd_state {
	case .Stopped:
	case .Starting:
		if mechanical_sample_mix(&synth.samples.fdd_motor_start, synth.fdd_motor_position, left, right) {
			synth.fdd_motor_position += 1
		} else if synth.fdd_motor_requested {
			synth.fdd_state = .Running
			synth.fdd_motor_position = 0
			mechanical_fdd_loop_mix(synth, left, right)
		} else {
			mechanical_fdd_stop(synth)
		}
	case .Running:
		mechanical_fdd_loop_mix(synth, left, right)
	case .Stopping:
		if synth.fdd_stop_fade_remaining > 0 {
			loop_gain := i32(
				i64(MECHANICAL_SAMPLE_GAIN_ONE) * i64(synth.fdd_stop_fade_remaining) /
				i64(MECHANICAL_FDD_STOP_FADE_FRAMES),
			)
			mechanical_fdd_loop_mix(synth, left, right, loop_gain)
			_ = mechanical_sample_mix(
				&synth.samples.fdd_motor_stop,
				synth.fdd_stop_position,
				left,
				right,
				MECHANICAL_SAMPLE_GAIN_ONE - loop_gain,
			)
			synth.fdd_stop_position += 1
			synth.fdd_stop_fade_remaining -= 1
		} else if mechanical_sample_mix(
			&synth.samples.fdd_motor_stop,
			synth.fdd_stop_position,
			left,
			right,
		) {
			synth.fdd_stop_position += 1
		} else {
			synth.fdd_state = .Stopped
			synth.fdd_motor_position = 0
			synth.fdd_stop_position = 0
			if synth.fdd_motor_requested {mechanical_fdd_start(synth)}
		}
	}
	mechanical_voices_mix(synth.fdd_seek_voices[:], left, right)
}

@(private = "file")
mechanical_synth_frame :: proc(synth: ^Mechanical_Synth) -> Audio_Frame {
	if synth.hdd_test_frames > 0 {
		if synth.hdd_test_countdown <= 0 {
			mechanical_voice_start(
				synth.hdd_seek_voices[:],
				&synth.samples.hdd_seek,
				.Drop,
			)
			synth.hdd_test_countdown = MECHANICAL_HDD_TEST_INTERVAL_FRAMES
		}
		synth.hdd_test_countdown -= 1
		synth.hdd_test_frames -= 1
		if synth.hdd_test_frames == 0 && synth.hdd_test_should_stop {mechanical_hdd_stop(synth)}
	}
	if synth.fdd_test_frames > 0 {
		if synth.fdd_test_step_countdown <= 0 {
			distance := (synth.fdd_test_step_index % 4) + 1
			mechanical_voice_start(
				synth.fdd_seek_voices[:],
				&synth.samples.fdd_seek_up[distance - 1],
				.Reuse_First,
			)
			synth.fdd_test_step_index += 1
			synth.fdd_test_step_countdown = MECHANICAL_FLOPPY_TEST_STEP_FRAMES
		}
		synth.fdd_test_step_countdown -= 1
		synth.fdd_test_frames -= 1
		if synth.fdd_test_frames == 0 && synth.fdd_test_should_stop {mechanical_fdd_stop(synth)}
	}
	left, right: i64
	mechanical_hdd_mix(synth, &left, &right)
	mechanical_fdd_mix(synth, &left, &right)
	return {
		left  = audio_clamp_i16(left),
		right = audio_clamp_i16(right),
	}
}

mechanical_synth_render :: proc(synth: ^Mechanical_Synth, frames: []Audio_Frame) {
	if synth == nil {return}
	for &frame in frames {frame = mechanical_synth_frame(synth)}
}

Mechanical_Engine :: struct {
	queue:                  Mechanical_Event_Queue,
	samples:                Mechanical_Sample_Set,
	synth:                  Mechanical_Synth,
	session:                u64,
	reset_generation:       u64,
	seen_reset_generation:  u64,
	machine_events_enabled: u64,
	machine_running:        u64,
	machine_paused:         u64,
	hdd_enabled:            u64,
	hdd_attached:           u64,
	floppy_enabled:         u64,
}

mechanical_engine_init :: proc(engine: ^Mechanical_Engine) {
	if engine == nil {return}
	engine^ = {}
	mechanical_event_queue_init(&engine.queue)
	mechanical_synth_reset(&engine.synth, &engine.samples)
	sync.atomic_store_explicit(&engine.session, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.reset_generation, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.hdd_enabled, u64(1), .Relaxed)
	sync.atomic_store_explicit(&engine.floppy_enabled, u64(1), .Relaxed)
}

mechanical_engine_set_samples :: proc(
	engine: ^Mechanical_Engine,
	samples: Mechanical_Sample_Set,
) {
	if engine == nil {return}
	engine.samples = samples
	engine.synth.samples = &engine.samples
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

@(private = "file")
mechanical_engine_emit :: proc(ctx: rawptr, event: Mechanical_Event) {
	engine := (^Mechanical_Engine)(ctx)
	if engine == nil || sync.atomic_load_explicit(&engine.machine_events_enabled, .Acquire) == 0 {
		return
	}
	if event.kind == .Hard_Drive_Access &&
	   sync.atomic_load_explicit(&engine.hdd_attached, .Acquire) == 0 {
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
	sync.atomic_store_explicit(&engine.machine_running, running ? u64(1) : u64(0), .Release)
	sync.atomic_store_explicit(&engine.machine_paused, paused ? u64(1) : u64(0), .Release)
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

mechanical_engine_set_enabled :: proc(engine: ^Mechanical_Engine, hdd, floppy: bool) {
	if engine == nil {return}
	_ = sync.atomic_add_explicit(&engine.session, u64(1), .Release)
	sync.atomic_store_explicit(&engine.hdd_enabled, hdd ? u64(1) : u64(0), .Release)
	sync.atomic_store_explicit(&engine.floppy_enabled, floppy ? u64(1) : u64(0), .Release)
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

mechanical_engine_set_hdd_attached :: proc(engine: ^Mechanical_Engine, attached: bool) {
	if engine == nil {return}
	_ = sync.atomic_add_explicit(&engine.session, u64(1), .Release)
	sync.atomic_store_explicit(&engine.hdd_attached, attached ? u64(1) : u64(0), .Release)
	_ = sync.atomic_add_explicit(&engine.reset_generation, u64(1), .Release)
}

mechanical_engine_test_hard_drive :: proc(engine: ^Mechanical_Engine) -> bool {
	if engine == nil || !engine.samples.hdd_available {return false}
	return mechanical_event_queue_push(&engine.queue, {kind = .Test_Hard_Drive})
}

mechanical_engine_test_floppy :: proc(engine: ^Mechanical_Engine) -> bool {
	if engine == nil || !engine.samples.fdd_available {return false}
	return mechanical_event_queue_push(&engine.queue, {kind = .Test_Floppy})
}

@(private = "file")
mechanical_engine_apply_control :: proc(
	engine: ^Mechanical_Engine,
	running, paused, hdd_enabled, hdd_attached, floppy_enabled: bool,
) {
	if paused {
		mechanical_synth_reset(&engine.synth, &engine.samples)
		return
	}
	if !hdd_enabled || !hdd_attached {
		engine.synth.hdd_state = .Stopped
		engine.synth.hdd_position = 0
		engine.synth.hdd_seek_voices = {}
	} else if running {
		if engine.synth.hdd_state == .Stopped || engine.synth.hdd_state == .Stopping {
			mechanical_hdd_start(&engine.synth)
		}
	} else {
		mechanical_hdd_stop(&engine.synth)
	}
	if !floppy_enabled {
		engine.synth.fdd_state = .Stopped
		engine.synth.fdd_motor_requested = false
		engine.synth.fdd_seek_voices = {}
	} else if !running {
		mechanical_fdd_stop(&engine.synth)
	}
}

mechanical_engine_render :: proc(engine: ^Mechanical_Engine, frames: []Audio_Frame) {
	if engine == nil {return}
	reset_generation := sync.atomic_load_explicit(&engine.reset_generation, .Acquire)
	session := sync.atomic_load_explicit(&engine.session, .Acquire)
	machine_enabled := sync.atomic_load_explicit(&engine.machine_events_enabled, .Acquire) != 0
	running := sync.atomic_load_explicit(&engine.machine_running, .Acquire) != 0
	paused := sync.atomic_load_explicit(&engine.machine_paused, .Acquire) != 0
	hdd_enabled := sync.atomic_load_explicit(&engine.hdd_enabled, .Acquire) != 0
	hdd_attached := sync.atomic_load_explicit(&engine.hdd_attached, .Acquire) != 0
	floppy_enabled := sync.atomic_load_explicit(&engine.floppy_enabled, .Acquire) != 0
	if engine.seen_reset_generation != reset_generation {
		mechanical_engine_apply_control(
			engine,
			running,
			paused,
			hdd_enabled,
			hdd_attached,
			floppy_enabled,
		)
		engine.seen_reset_generation = reset_generation
	}
	for {
		event, available := mechanical_event_queue_pop(&engine.queue)
		if !available {break}
		switch event.kind {
		case .Test_Hard_Drive, .Test_Floppy:
			mechanical_synth_event(&engine.synth, event)
		case .Hard_Drive_Access:
			if machine_enabled && hdd_enabled && hdd_attached && event.session == session {
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
