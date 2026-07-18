// SPDX-License-Identifier: GPL-3.0-only
package audio

import "core:testing"

mechanical_test_has_signal :: proc(frames: []Audio_Frame) -> bool {
	for frame in frames {
		if frame.left != 0 || frame.right != 0 {return true}
	}
	return false
}

@(test)
test_mechanical_synth_is_deterministic_and_bounded :: proc(t: ^testing.T) {
	first, second: Mechanical_Synth
	mechanical_synth_reset(&first)
	mechanical_synth_reset(&second)
	events := [?]Mechanical_Event {
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
