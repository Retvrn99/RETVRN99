// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

Gsw3d_Bridge_Test_Notify :: struct {
	bridge:        ^Gsw3d_Bridge,
	pending:       sync.Sema,
	state:         Gsw3d_Bridge_State,
	generation:    u64,
	notifications: int,
}

Gsw3d_Bridge_Test_Producer :: struct {
	bridge:   ^Gsw3d_Bridge,
	request:  Gsw3d_Bridge_Request,
	returned: sync.Sema,
	result:   bool,
}

Gsw3d_Bridge_Test_Sequence_Producer :: struct {
	bridge:   ^Gsw3d_Bridge,
	requests: [2]Gsw3d_Bridge_Request,
	results:  [2]bool,
	returned: sync.Sema,
}

Gsw3d_Bridge_Test_Execute :: struct {
	bridge:       ^Gsw3d_Bridge,
	entered:      sync.Sema,
	release:      sync.Sema,
	returned:     sync.Sema,
	block:        bool,
	result:       bool,
	request:      Gsw3d_Bridge_Request,
	state_inside: Gsw3d_Bridge_State,
	drain:        Gsw3d_Bridge_Drain_Result,
}

gsw3d_bridge_test_notify :: proc(ctx: rawptr, generation: u64) {
	notify := (^Gsw3d_Bridge_Test_Notify)(ctx)
	snapshot := gsw3d_bridge_snapshot(notify.bridge)
	notify.state = snapshot.state
	notify.generation = generation
	notify.notifications += 1
	sync.sema_post(&notify.pending)
}

gsw3d_bridge_test_producer :: proc(producer: ^Gsw3d_Bridge_Test_Producer) {
	producer.result = gsw3d_bridge_submit(producer.bridge, producer.request)
	sync.sema_post(&producer.returned)
}

gsw3d_bridge_test_sequence_producer :: proc(producer: ^Gsw3d_Bridge_Test_Sequence_Producer) {
	for request, index in producer.requests {
		producer.results[index] = gsw3d_bridge_submit(producer.bridge, request)
	}
	sync.sema_post(&producer.returned)
}

gsw3d_bridge_test_execute :: proc(ctx: rawptr, request: Gsw3d_Bridge_Request) -> bool {
	execute := (^Gsw3d_Bridge_Test_Execute)(ctx)
	execute.request = request
	execute.state_inside = gsw3d_bridge_snapshot(execute.bridge).state
	sync.sema_post(&execute.entered)
	if execute.block {sync.sema_wait(&execute.release)}
	return execute.result
}

gsw3d_bridge_test_drain_thread :: proc(execute: ^Gsw3d_Bridge_Test_Execute) {
	execute.drain = gsw3d_bridge_drain(
		execute.bridge,
		{max_requests = 1, max_budget = 1024},
		gsw3d_bridge_test_execute,
		execute,
	)
	sync.sema_post(&execute.returned)
}

gsw3d_bridge_test_start_producer :: proc(
	bridge: ^Gsw3d_Bridge,
	request: Gsw3d_Bridge_Request,
) -> (
	^Gsw3d_Bridge_Test_Producer,
	^thread.Thread,
) {
	producer := new(Gsw3d_Bridge_Test_Producer)
	producer.bridge = bridge
	producer.request = request
	producer_thread := thread.create_and_start_with_poly_data(producer, gsw3d_bridge_test_producer)
	return producer, producer_thread
}

gsw3d_bridge_test_finish_producer :: proc(
	t: ^testing.T,
	producer: ^Gsw3d_Bridge_Test_Producer,
	producer_thread: ^thread.Thread,
) -> bool {
	returned := testing.expect(
		t,
		sync.sema_wait_with_timeout(&producer.returned, time.Second),
		"GSW3D bridge producer did not return",
	)
	if !returned {gsw3d_bridge_shutdown(producer.bridge)}
	thread.destroy(producer_thread)
	return returned
}

@(test)
host_gsw3d_bridge_test_executes_borrowed_request_outside_mutex :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	payload := u32(0x1234_5678)
	producer, producer_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Execute, generation = generation, budget_cost = 64, payload = &payload},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	testing.expect_value(t, notify.state, Gsw3d_Bridge_State.Pending)
	testing.expect_value(t, notify.generation, generation)
	execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		result = true,
	}
	drained := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 1, max_budget = 64},
		gsw3d_bridge_test_execute,
		&execute,
	)
	finished := gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
	if finished {testing.expect(t, producer.result)}
	testing.expect_value(t, execute.state_inside, Gsw3d_Bridge_State.Executing)
	testing.expect(t, execute.request.payload == &payload)
	testing.expect_value(t, execute.request.generation, generation)
	testing.expect_value(t, drained.executed, 1)
	testing.expect_value(t, drained.succeeded, 1)
	testing.expect_value(t, drained.failed, 0)
	testing.expect_value(t, drained.discarded, 0)
	testing.expect_value(t, drained.budget_used, u64(64))
	free(producer)
}

@(test)
host_gsw3d_bridge_test_pending_cancel_wakes_producer_false :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	producer, producer_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Reset, generation = generation, budget_cost = 1},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	testing.expect(t, gsw3d_bridge_cancel_session(&bridge, generation))
	finished := gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
	if finished {testing.expect(t, !producer.result)}
	snapshot := gsw3d_bridge_snapshot(&bridge)
	testing.expect_value(t, snapshot.state, Gsw3d_Bridge_State.Idle)
	testing.expect(t, !snapshot.accepting)
	testing.expect(
		t,
		!gsw3d_bridge_submit(&bridge, {kind = .Reset, generation = generation, budget_cost = 1}),
	)
	free(producer)
}

@(test)
host_gsw3d_bridge_test_executing_cancel_waits_for_executor_and_discards_result :: proc(
	t: ^testing.T,
) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	payload := u32(7)
	producer, producer_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Execute, generation = generation, budget_cost = 8, payload = &payload},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		block  = true,
		result = true,
	}
	drain_thread := thread.create_and_start_with_poly_data(
		&execute,
		gsw3d_bridge_test_drain_thread,
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&execute.entered, time.Second)) {
		sync.sema_post(&execute.release)
		thread.destroy(drain_thread)
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	testing.expect(t, gsw3d_bridge_cancel_session(&bridge, generation))
	snapshot := gsw3d_bridge_snapshot(&bridge)
	testing.expect_value(t, snapshot.state, Gsw3d_Bridge_State.Executing)
	testing.expect(t, snapshot.discard)
	testing.expect(
		t,
		!sync.sema_wait_with_timeout(&producer.returned, 10 * time.Millisecond),
		"producer returned while the executor still borrowed its payload",
	)
	sync.sema_post(&execute.release)
	testing.expect(t, sync.sema_wait_with_timeout(&execute.returned, time.Second))
	thread.destroy(drain_thread)
	finished := gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
	if finished {testing.expect(t, !producer.result)}
	testing.expect_value(t, execute.drain.executed, 1)
	testing.expect_value(t, execute.drain.succeeded, 1)
	testing.expect_value(t, execute.drain.discarded, 1)
	free(producer)
}

@(test)
host_gsw3d_bridge_test_new_generation_isolated_from_stale_completion :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	old_generation := gsw3d_bridge_begin_session(&bridge)
	old_producer, old_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Execute, generation = old_generation, budget_cost = 1},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, old_producer, old_thread)
		free(old_producer)
		return
	}
	old_execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		block  = true,
		result = true,
	}
	drain_thread := thread.create_and_start_with_poly_data(
		&old_execute,
		gsw3d_bridge_test_drain_thread,
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&old_execute.entered, time.Second)) {
		sync.sema_post(&old_execute.release)
		thread.destroy(drain_thread)
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, old_producer, old_thread)
		free(old_producer)
		return
	}
	new_generation := gsw3d_bridge_begin_session(&bridge)
	testing.expect(t, new_generation != 0 && new_generation != old_generation)
	sync.sema_post(&old_execute.release)
	testing.expect(t, sync.sema_wait_with_timeout(&old_execute.returned, time.Second))
	thread.destroy(drain_thread)
	old_finished := gsw3d_bridge_test_finish_producer(t, old_producer, old_thread)
	if old_finished {testing.expect(t, !old_producer.result)}
	free(old_producer)

	new_producer, new_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Reset, generation = new_generation, budget_cost = 1},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, new_producer, new_thread)
		free(new_producer)
		return
	}
	new_execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		result = true,
	}
	_ = gsw3d_bridge_drain(
		&bridge,
		{max_requests = 1, max_budget = 1},
		gsw3d_bridge_test_execute,
		&new_execute,
	)
	new_finished := gsw3d_bridge_test_finish_producer(t, new_producer, new_thread)
	if new_finished {testing.expect(t, new_producer.result)}
	testing.expect_value(t, new_execute.request.generation, new_generation)
	free(new_producer)
}

@(test)
host_gsw3d_bridge_test_drain_limits_and_single_producer_are_fail_closed :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	producer, producer_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Upload, generation = generation, budget_cost = 100},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	testing.expect(
		t,
		!gsw3d_bridge_submit(&bridge, {kind = .Reset, generation = generation, budget_cost = 1}),
	)
	execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		result = false,
	}
	zero_count := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 0, max_budget = 100},
		gsw3d_bridge_test_execute,
		&execute,
	)
	low_budget := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 1, max_budget = 99},
		gsw3d_bridge_test_execute,
		&execute,
	)
	testing.expect_value(t, zero_count.executed, 0)
	testing.expect_value(t, low_budget.executed, 1)
	testing.expect_value(t, low_budget.failed, 1)
	testing.expect_value(t, low_budget.discarded, 1)
	finished := gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
	if finished {testing.expect(t, !producer.result)}
	free(producer)

	fitting, fitting_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Upload, generation = generation, budget_cost = 100},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, fitting, fitting_thread)
		free(fitting)
		return
	}
	drained := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 1, max_budget = 100},
		gsw3d_bridge_test_execute,
		&execute,
	)
	fitting_finished := gsw3d_bridge_test_finish_producer(t, fitting, fitting_thread)
	if fitting_finished {testing.expect(t, !fitting.result)}
	testing.expect_value(t, drained.executed, 1)
	testing.expect_value(t, drained.succeeded, 0)
	testing.expect_value(t, drained.failed, 1)
	testing.expect_value(t, drained.budget_used, u64(100))
	free(fitting)

	oversized, oversized_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Upload, generation = generation, budget_cost = 101},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, oversized, oversized_thread)
		free(oversized)
		return
	}
	rejected := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 1, max_budget = 100},
		gsw3d_bridge_test_execute,
		&execute,
	)
	oversized_finished := gsw3d_bridge_test_finish_producer(t, oversized, oversized_thread)
	if oversized_finished {testing.expect(t, !oversized.result)}
	testing.expect_value(t, rejected.executed, 1)
	testing.expect_value(t, rejected.failed, 1)
	testing.expect_value(t, rejected.discarded, 1)
	testing.expect_value(t, rejected.budget_used, u64(0))
	free(oversized)
}

@(test)
host_gsw3d_bridge_test_shutdown_rejects_late_sessions_and_requests :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	producer, producer_thread := gsw3d_bridge_test_start_producer(
		&bridge,
		{kind = .Reset, generation = generation, budget_cost = 1},
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		_ = gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
		free(producer)
		return
	}
	gsw3d_bridge_shutdown(&bridge)
	finished := gsw3d_bridge_test_finish_producer(t, producer, producer_thread)
	if finished {testing.expect(t, !producer.result)}
	snapshot := gsw3d_bridge_snapshot(&bridge)
	testing.expect(t, snapshot.shutdown)
	testing.expect(t, !snapshot.accepting)
	testing.expect_value(t, gsw3d_bridge_begin_session(&bridge), u64(0))
	testing.expect(t, !gsw3d_bridge_cancel_session(&bridge, generation))
	testing.expect(
		t,
		!gsw3d_bridge_submit(&bridge, {kind = .Reset, generation = generation, budget_cost = 1}),
	)
	free(producer)
}

@(test)
host_gsw3d_bridge_test_followup_wait_drains_serial_successor :: proc(t: ^testing.T) {
	bridge: Gsw3d_Bridge
	notify := Gsw3d_Bridge_Test_Notify {
		bridge = &bridge,
	}
	gsw3d_bridge_init(&bridge, gsw3d_bridge_test_notify, &notify)
	generation := gsw3d_bridge_begin_session(&bridge)
	producer := Gsw3d_Bridge_Test_Sequence_Producer {
		bridge   = &bridge,
		requests = {
			{kind = .Execute, generation = generation, budget_cost = 4},
			{kind = .Upload, generation = generation, budget_cost = 8},
		},
	}
	producer_thread := thread.create_and_start_with_poly_data(
		&producer,
		gsw3d_bridge_test_sequence_producer,
	)
	if !testing.expect(t, sync.sema_wait_with_timeout(&notify.pending, time.Second)) {
		gsw3d_bridge_shutdown(&bridge)
		thread.destroy(producer_thread)
		return
	}
	execute := Gsw3d_Bridge_Test_Execute {
		bridge = &bridge,
		result = true,
	}
	drained := gsw3d_bridge_drain(
		&bridge,
		{max_requests = 2, max_budget = 12, followup_wait = 20 * time.Millisecond},
		gsw3d_bridge_test_execute,
		&execute,
	)
	returned := testing.expect(t, sync.sema_wait_with_timeout(&producer.returned, time.Second))
	if !returned {gsw3d_bridge_shutdown(&bridge)}
	thread.destroy(producer_thread)
	testing.expect_value(t, drained.executed, 2)
	testing.expect_value(t, drained.succeeded, 2)
	testing.expect_value(t, drained.budget_used, u64(12))
	testing.expect(t, producer.results[0])
	testing.expect(t, producer.results[1])
}
