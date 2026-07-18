// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

mechanical_test_start_frames: [2]Audio_Frame = {
	{left = 1_000, right = 1_000},
	{left = 900, right = 900},
}
mechanical_test_loop_frames: [2]Audio_Frame = {
	{left = 200, right = 200},
	{left = -200, right = -200},
}
mechanical_test_stop_frames: [2]Audio_Frame = {
	{left = 700, right = 700},
	{left = 300, right = 300},
}
mechanical_test_seek_up_frames: [2]Audio_Frame = {
	{left = 2_000, right = 2_000},
	{left = -1_000, right = -1_000},
}
mechanical_test_seek_down_frames: [2]Audio_Frame = {
	{left = 3_000, right = 3_000},
	{left = -1_500, right = -1_500},
}

mechanical_test_sample_set :: proc() -> Mechanical_Sample_Set {
	set := Mechanical_Sample_Set {
		hdd_spin_up   = {frames = mechanical_test_start_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		hdd_running   = {frames = mechanical_test_loop_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		hdd_spin_down = {frames = mechanical_test_stop_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		hdd_seek      = {frames = mechanical_test_seek_up_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		fdd_motor_start = {frames = mechanical_test_start_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		fdd_motor_loop  = {frames = mechanical_test_loop_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		fdd_motor_stop  = {frames = mechanical_test_stop_frames[:], gain = MECHANICAL_SAMPLE_GAIN_ONE},
		hdd_available = true,
		fdd_available = true,
	}
	for index in 0 ..< MECHANICAL_FDD_SEEK_SAMPLE_COUNT {
		set.fdd_seek_up[index] = {
			frames = mechanical_test_seek_up_frames[:],
			gain = MECHANICAL_SAMPLE_GAIN_ONE,
		}
		set.fdd_seek_down[index] = {
			frames = mechanical_test_seek_down_frames[:],
			gain = MECHANICAL_SAMPLE_GAIN_ONE,
		}
	}
	return set
}

mechanical_test_has_signal :: proc(frames: []Audio_Frame) -> bool {
	for frame in frames {
		if frame.left != 0 || frame.right != 0 {return true}
	}
	return false
}

@(test)
test_mechanical_synth_is_deterministic_and_bounded :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	first, second: Mechanical_Synth
	mechanical_synth_reset(&first, &samples)
	mechanical_synth_reset(&second, &samples)
	events := [?]Mechanical_Event {
		{kind = .Test_Hard_Drive},
		{kind = .Hard_Drive_Access, position = 100, amount = 8},
		{kind = .Hard_Drive_Access, position = 90_000, amount = 32, write = true},
		{kind = .Floppy_Motor, amount = 1},
		{kind = .Floppy_Seek, amount = 17},
	}
	for event in events {
		mechanical_synth_event(&first, event)
		mechanical_synth_event(&second, event)
	}
	left, right: [4_096]Audio_Frame
	mechanical_synth_render(&first, left[:])
	mechanical_synth_render(&second, right[:])
	testing.expect_value(t, left, right)
	testing.expect(t, mechanical_test_has_signal(left[:]))
	for frame in left {
		testing.expect(t, frame.left >= -32_768 && frame.left <= 32_767)
		testing.expect_value(t, frame.left, frame.right)
	}
}

@(test)
test_mechanical_event_queue_is_bounded :: proc(t: ^testing.T) {
	queue: Mechanical_Event_Queue
	mechanical_event_queue_init(&queue)
	for index in 0 ..< MECHANICAL_EVENT_CAPACITY {
		testing.expect(t, mechanical_event_queue_push(
			&queue,
			{kind = .Hard_Drive_Access, position = u32(index)},
		))
	}
	testing.expect(t, !mechanical_event_queue_push(&queue, {kind = .Test_Hard_Drive}))
	testing.expect_value(t, mechanical_event_queue_dropped(&queue), u64(1))
	for index in 0 ..< MECHANICAL_EVENT_CAPACITY {
		event, available := mechanical_event_queue_pop(&queue)
		testing.expect(t, available)
		testing.expect_value(t, event.position, u32(index))
	}
	_, available := mechanical_event_queue_pop(&queue)
	testing.expect(t, !available)
}

@(test)
test_mechanical_engine_rejects_paused_and_old_session_events :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_hdd_attached(&engine, true)
	sink := mechanical_engine_sink(&engine)
	mechanical_engine_set_machine_state(&engine, true, false)
	mechanical_event_sink_emit(sink, {
		kind = .Hard_Drive_Access,
		position = 1_000,
		amount = 4,
	})
	mechanical_engine_set_machine_state(&engine, true, true)
	paused: [512]Audio_Frame
	mechanical_engine_render(&engine, paused[:])
	testing.expect(t, !mechanical_test_has_signal(paused[:]))

	mechanical_engine_set_machine_state(&engine, true, false)
	mechanical_event_sink_emit(sink, {
		kind = .Hard_Drive_Access,
		position = 1_000,
		amount = 4,
	})
	running: [512]Audio_Frame
	mechanical_engine_render(&engine, running[:])
	testing.expect(t, mechanical_test_has_signal(running[:]))
}

@(test)
test_mechanical_previews_work_while_machine_stopped :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_machine_state(&engine, false, false)
	testing.expect(t, mechanical_engine_test_hard_drive(&engine))
	hdd: [512]Audio_Frame
	mechanical_engine_render(&engine, hdd[:])
	testing.expect(t, mechanical_test_has_signal(hdd[:]))

	mechanical_engine_set_machine_state(&engine, false, false)
	testing.expect(t, mechanical_engine_test_floppy(&engine))
	floppy: [4_096]Audio_Frame
	mechanical_engine_render(&engine, floppy[:])
	testing.expect(t, mechanical_test_has_signal(floppy[:]))
}

@(test)
test_mechanical_disabled_machine_sounds_are_silent :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_hdd_attached(&engine, true)
	mechanical_engine_set_enabled(&engine, false, false)
	mechanical_engine_set_machine_state(&engine, true, false)
	sink := mechanical_engine_sink(&engine)
	mechanical_event_sink_emit(sink, {
		kind = .Hard_Drive_Access,
		position = 10,
		amount = 1,
	})
	mechanical_event_sink_emit(sink, {kind = .Floppy_Motor, amount = 1})
	frames: [1_024]Audio_Frame
	mechanical_engine_render(&engine, frames[:])
	testing.expect(t, !mechanical_test_has_signal(frames[:]))
}

mechanical_test_render_frames :: proc(synth: ^Mechanical_Synth, count: int) {
	chunk: [256]Audio_Frame
	remaining := count
	for remaining > 0 {
		batch := min(remaining, len(chunk))
		mechanical_synth_render(synth, chunk[:batch])
		remaining -= batch
	}
}

@(test)
test_mechanical_missing_samples_reject_previews :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	testing.expect(t, !mechanical_engine_test_hard_drive(&engine))
	testing.expect(t, !mechanical_engine_test_floppy(&engine))
}

@(test)
test_mechanical_machine_without_attached_hdd_has_no_live_spindle_or_seek :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_machine_state(&engine, true, false)
	sink := mechanical_engine_sink(&engine)
	mechanical_event_sink_emit(sink, {kind = .Hard_Drive_Access, position = 100, amount = 1})
	_, queued := mechanical_event_queue_pop(&engine.queue)
	testing.expect(t, !queued)
	live: [16]Audio_Frame
	mechanical_engine_render(&engine, live[:])
	testing.expect(t, !mechanical_test_has_signal(live[:]))
	testing.expect_value(t, engine.synth.hdd_state, Mechanical_Spindle_State.Stopped)

	mechanical_engine_set_machine_state(&engine, false, false)
	testing.expect(t, mechanical_engine_test_hard_drive(&engine))
	preview: [16]Audio_Frame
	mechanical_engine_render(&engine, preview[:])
	testing.expect(t, mechanical_test_has_signal(preview[:]))
}

@(test)
test_mechanical_hdd_runs_start_loop_stop_state_machine :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_hdd_attached(&engine, true)
	mechanical_engine_set_machine_state(&engine, true, false)
	start: [2]Audio_Frame
	mechanical_engine_render(&engine, start[:])
	testing.expect_value(t, start, mechanical_test_start_frames)
	loop: [2]Audio_Frame
	mechanical_engine_render(&engine, loop[:])
	testing.expect_value(t, loop, mechanical_test_loop_frames)
	mechanical_engine_set_machine_state(&engine, false, false)
	stop: [2]Audio_Frame
	mechanical_engine_render(&engine, stop[:])
	testing.expect_value(t, stop, mechanical_test_stop_frames)
}

@(test)
test_mechanical_hdd_seeks_only_while_spindle_running :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	synth: Mechanical_Synth
	mechanical_synth_reset(&synth, &samples)
	mechanical_synth_event(&synth, {kind = .Hard_Drive_Access})
	testing.expect(t, !synth.hdd_seek_voices[0].active)
	synth.hdd_state = .Starting
	mechanical_synth_event(&synth, {kind = .Hard_Drive_Access})
	testing.expect(t, !synth.hdd_seek_voices[0].active)
	synth.hdd_state = .Running
	mechanical_synth_event(&synth, {kind = .Hard_Drive_Access})
	testing.expect(t, synth.hdd_seek_voices[0].active)
}

@(test)
test_mechanical_fdd_selects_direction_and_distance_sample :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	synth: Mechanical_Synth
	mechanical_synth_reset(&synth, &samples)
	synth.fdd_state = .Running
	synth.fdd_last_track = 10
	mechanical_synth_event(&synth, {kind = .Floppy_Seek, position = 20, amount = 10})
	testing.expect_value(t, synth.fdd_seek_voices[0].sample, &samples.fdd_seek_up[9])
	mechanical_synth_event(&synth, {kind = .Floppy_Seek, position = 5, amount = 15})
	testing.expect_value(t, synth.fdd_seek_voices[1].sample, &samples.fdd_seek_down[14])
}

@(test)
test_mechanical_fdd_motor_event_seeds_first_seek_direction :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	synth: Mechanical_Synth
	mechanical_synth_reset(&synth, &samples)
	mechanical_synth_event(&synth, {kind = .Floppy_Motor, position = 50, amount = 1})
	mechanical_synth_event(&synth, {kind = .Floppy_Seek, position = 40, amount = 10})
	testing.expect_value(t, synth.fdd_seek_voices[0].sample, &samples.fdd_seek_down[9])
	mechanical_synth_event(&synth, {kind = .Floppy_Motor, position = 17, amount = 0})
	testing.expect_value(t, synth.fdd_last_track, u32(17))
}

@(test)
test_mechanical_saturated_hdd_drops_while_fdd_reuses :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	hdd, fdd: Mechanical_Synth
	mechanical_synth_reset(&hdd, &samples)
	mechanical_synth_reset(&fdd, &samples)
	hdd.hdd_state = .Running
	fdd.fdd_state = .Running
	for index in 0 ..< MECHANICAL_MAX_SAMPLE_VOICES {
		hdd.hdd_cooldown = 0
		mechanical_synth_event(&hdd, {kind = .Hard_Drive_Access})
		mechanical_synth_event(&fdd, {
			kind = .Floppy_Seek,
			position = u32(index + 1),
			amount = 1,
		})
	}
	hdd.hdd_seek_voices[0].position = 1
	fdd.fdd_seek_voices[0].position = 1
	hdd.hdd_cooldown = 0
	mechanical_synth_event(&hdd, {kind = .Hard_Drive_Access})
	mechanical_synth_event(&fdd, {
		kind = .Floppy_Seek,
		position = u32(MECHANICAL_MAX_SAMPLE_VOICES + 1),
		amount = 1,
	})
	testing.expect_value(t, hdd.hdd_seek_voices[0].position, 1)
	testing.expect_value(t, fdd.fdd_seek_voices[0].position, 0)
	fdd.fdd_seek_voices[0].position = 1
	fdd.fdd_seek_voices[1].position = 1
	mechanical_synth_event(&fdd, {
		kind = .Floppy_Seek,
		position = u32(MECHANICAL_MAX_SAMPLE_VOICES + 2),
		amount = 1,
	})
	testing.expect_value(t, fdd.fdd_seek_voices[0].position, 0)
	testing.expect_value(t, fdd.fdd_seek_voices[1].position, 1)
}

@(test)
test_mechanical_hdd_quick_restart_interrupts_spin_down :: proc(t: ^testing.T) {
	engine: Mechanical_Engine
	mechanical_engine_init(&engine)
	mechanical_engine_set_samples(&engine, mechanical_test_sample_set())
	mechanical_engine_set_hdd_attached(&engine, true)
	mechanical_engine_set_machine_state(&engine, true, false)
	started: [1]Audio_Frame
	mechanical_engine_render(&engine, started[:])
	mechanical_engine_set_machine_state(&engine, false, false)
	stopping: [1]Audio_Frame
	mechanical_engine_render(&engine, stopping[:])
	testing.expect_value(t, engine.synth.hdd_state, Mechanical_Spindle_State.Stopping)
	mechanical_engine_set_machine_state(&engine, true, false)
	restarted: [1]Audio_Frame
	mechanical_engine_render(&engine, restarted[:])
	testing.expect_value(t, engine.synth.hdd_state, Mechanical_Spindle_State.Starting)
	testing.expect_value(t, restarted[0], mechanical_test_start_frames[0])
}

@(test)
test_mechanical_previews_do_not_stop_live_motors :: proc(t: ^testing.T) {
	samples := mechanical_test_sample_set()
	synth: Mechanical_Synth
	mechanical_synth_reset(&synth, &samples)
	synth.hdd_state = .Running
	synth.fdd_state = .Running
	synth.fdd_motor_requested = true
	mechanical_synth_event(&synth, {kind = .Test_Hard_Drive})
	mechanical_synth_event(&synth, {kind = .Test_Floppy})
	mechanical_test_render_frames(&synth, MECHANICAL_FLOPPY_TEST_FRAMES + 1)
	testing.expect_value(t, synth.hdd_state, Mechanical_Spindle_State.Running)
	testing.expect_value(t, synth.fdd_state, Mechanical_Spindle_State.Running)
	testing.expect(t, synth.fdd_motor_requested)
}
