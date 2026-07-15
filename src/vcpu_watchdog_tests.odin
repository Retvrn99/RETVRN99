// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:log"
import "core:sync"
import win32 "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"
import "hosttime"
import "hv"
import "machine"

Vm_Guard_Test_Cancel :: struct {
	mu:     sync.Mutex,
	count:  int,
	target: ^hv.Vm,
}

Vm_Guard_Test_Emergency :: struct {
	mu:   sync.Mutex,
	vm:   ^hv.Vm,
	stop: bool,
}

vm_guard_test_cancel :: proc(ctx: rawptr, vm: ^hv.Vm) {
	test_ctx := (^Vm_Guard_Test_Cancel)(ctx)
	sync.lock(&test_ctx.mu)
	test_ctx.count += 1
	test_ctx.target = vm
	sync.unlock(&test_ctx.mu)
}

vm_guard_test_snapshot :: proc(ctx: ^Vm_Guard_Test_Cancel) -> (int, ^hv.Vm) {
	sync.lock(&ctx.mu)
	defer sync.unlock(&ctx.mu)
	return ctx.count, ctx.target
}

vm_guard_test_wait_count :: proc(ctx: ^Vm_Guard_Test_Cancel, wanted: int) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 250 * time.Millisecond {
		if count, _ := vm_guard_test_snapshot(ctx); count >= wanted {return true}
		time.sleep(time.Millisecond)
	}
	return false
}

vm_guard_test_emergency_proc :: proc(ctx: ^Vm_Guard_Test_Emergency) {
	time.sleep(time.Second)
	sync.lock(&ctx.mu)
	if !ctx.stop {hv.cancel(ctx.vm)}
	sync.unlock(&ctx.mu)
}

vm_guard_test_unregister_failure :: proc(_: win32.HANDLE, _: win32.HANDLE) -> bool {
	return false
}

@(test)
test_vm_guard_registered_watchdog_survives_unbind_and_rebind :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	first, second: hv.Vm

	vm_guard_bind(&guard, &first)
	vm_guard_schedule(&guard, u64(time.Millisecond), .One_Shot, 1)
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 1)) {return}
	first_generation := vm_guard_stats(&guard).generation
	count, target := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, target, &first)

	vm_guard_unbind(&guard)
	vm_guard_schedule(&guard, u64(time.Millisecond), .One_Shot, 2)
	time.sleep(10 * time.Millisecond)
	count, _ = vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)

	vm_guard_bind(&guard, &second)
	vm_guard_schedule(&guard, u64(time.Millisecond), .One_Shot, 1)
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 2)) {return}
	count, target = vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, target, &second)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.deadline_count, u64(2))
	testing.expect(t, stats.generation > first_generation)
	testing.expect(t, stats.valid)
}

@(test)
test_vm_guard_arm_failure_is_reported_before_entering_whpx :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	hosttime.armable_wake_destroy(&guard.wake)
	armed := vm_guard_schedule(&guard, u64(time.Millisecond), .Run_Guard, 1)
	testing.expect(t, !armed)
	count, _ := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 0)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.arm_failures, u64(1))
	testing.expect_value(t, stats.cancel_calls, u64(0))
	vm_guard_destroy(&guard)
}

@(test)
test_vm_guard_destroy_retains_callback_storage_when_unregister_fails :: proc(t: ^testing.T) {
	guard := Vm_Guard {
		cancel     = vm_guard_test_cancel,
		generation = 31,
	}
	guard.wake.registration = win32.HANDLE(uintptr(1))
	guard.wake.unregister = vm_guard_test_unregister_failure
	testing.expect(t, !vm_guard_destroy(&guard))
	testing.expect_value(t, guard.generation, u64(32))
	testing.expect(t, guard.cancel != nil)
	testing.expect_value(t, guard.wake.registration, win32.HANDLE(uintptr(1)))
	guard.wake.registration = nil
	guard = {}
}

@(test)
test_vm_guard_registered_watchdog_cancels_repeated_whpx_runs :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping registered watchdog integration test")
		return
	}
	testing.set_fail_timeout(t, 15 * time.Second)
	vm: hv.Vm
	if !testing.expect(t, hv.create(&vm, 64 * 1024 * 1024)) {return}
	defer hv.destroy(&vm)
	copy(vm.ram[0x7C00:], []u8{0xEB, 0xFE})
	hv.set_realmode_entry(&vm, 0, 0x7C00)

	emergency := Vm_Guard_Test_Emergency {
		vm = &vm,
	}
	emergency_thread := thread.create_and_start_with_poly_data(
		&emergency,
		vm_guard_test_emergency_proc,
	)
	defer {
		sync.lock(&emergency.mu)
		emergency.stop = true
		sync.unlock(&emergency.mu)
		thread.destroy(emergency_thread)
	}

	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard)) {return}
	defer vm_guard_destroy(&guard)
	vm_guard_bind(&guard, &vm)
	for _ in 0 ..< 2 {
		start := time.tick_now()
		before := vm_guard_stats(&guard).deadline_count
		generation := vm_guard_stats(&guard).generation + 1
		vm_guard_schedule(&guard, u64(time.Millisecond), .Run_Guard, generation)
		exit := hv.run(&vm)
		vm_guard_schedule(&guard, 0, .Disarm, generation + 1)
		elapsed := time.tick_since(start)
		if !testing.expect_value(t, exit.kind, hv.Exit_Kind.Canceled) {return}
		testing.expect(t, elapsed < 250 * time.Millisecond)
		testing.expect(t, vm_guard_stats(&guard).deadline_count > before)
	}
}

@(test)
test_vm_guard_run_guard_retries_until_disarmed :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	generation := vm_guard_stats(&guard).generation + 1
	vm_guard_schedule(&guard, u64(time.Millisecond), .Run_Guard, generation)
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 2)) {return}
	stats := vm_guard_stats(&guard)
	testing.expect(t, stats.callbacks >= 2)
	testing.expect(t, stats.retry_callbacks >= 1)
	testing.expect(t, stats.deadline_count >= 2)
	testing.expect(t, stats.cancel_calls >= 2)
	testing.expect_value(t, stats.machine_generation, generation)
	vm_guard_schedule(&guard, 0, .Disarm, generation + 1)
	count, _ := vm_guard_test_snapshot(&cancel)
	time.sleep(10 * time.Millisecond)
	after, _ := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, after, count)
}

@(test)
test_vm_guard_stale_generation_cannot_cancel_rebound_vcpu :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	machine_generation := u64(41)
	vm_guard_schedule(&guard, 100 * u64(time.Millisecond), .One_Shot, machine_generation)
	armed_generation := vm_guard_stats(&guard).generation
	vm_guard_schedule(&guard, 0, .Disarm, machine_generation + 1)
	vm_guard_deadline(&guard, armed_generation)
	count, _ := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 0)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.stale_callbacks, u64(1))
	testing.expect_value(t, stats.cancel_calls, u64(0))
}

@(test)
test_vm_guard_run_guard_rearm_rejects_stale_callback :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)

	vm_guard_schedule(&guard, u64(time.Second), .Run_Guard, 10)
	first_generation := vm_guard_stats(&guard).generation
	vm_guard_schedule(&guard, u64(time.Second), .Run_Guard, 11)
	second_generation := vm_guard_stats(&guard).generation
	if !testing.expect(t, second_generation > first_generation) {return}

	vm_guard_deadline(&guard, first_generation)
	count, _ := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 0)
	vm_guard_deadline(&guard, second_generation)
	target: ^hv.Vm
	count, target = vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, target, &vm)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.machine_generation, u64(11))
	testing.expect_value(t, stats.stale_callbacks, u64(1))
}

@(test)
test_vm_guard_host_generation_never_reuses_new_machine_tokens :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	first, second: hv.Vm

	vm_guard_bind(&guard, &first)
	vm_guard_schedule(&guard, u64(time.Second), .One_Shot, 1)
	first_arm := vm_guard_stats(&guard)
	vm_guard_unbind(&guard)
	vm_guard_bind(&guard, &second)
	vm_guard_schedule(&guard, u64(time.Second), .One_Shot, 1)
	second_arm := vm_guard_stats(&guard)

	testing.expect_value(t, first_arm.machine_generation, u64(1))
	testing.expect_value(t, second_arm.machine_generation, u64(1))
	testing.expect(t, second_arm.generation > first_arm.generation)
	vm_guard_deadline(&guard, first_arm.generation)
	count, _ := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 0)
	testing.expect(t, vm_guard_stats(&guard).stale_callbacks > 0)
}

@(test)
test_vm_guard_callback_evidence_records_between_run_fire_with_both_generations :: proc(
	t: ^testing.T,
) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	machine_generation := u64(77)
	if !testing.expect(
		t,
		vm_guard_schedule(&guard, u64(time.Millisecond), .One_Shot, machine_generation),
	) {return}
	host_generation := vm_guard_stats(&guard).generation
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 1)) {return}

	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine.machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	vm_guard_flush_wake_evidence(&guard, m)
	if !testing.expect_value(t, machine.machine_hardware_trace_count(m), u64(1)) {return}
	event := m.hardware_trace.events[0]
	testing.expect_value(t, event.kind, machine.Hardware_Event_Kind.Wake_Fire)
	testing.expect_value(t, event.a, machine_generation)
	testing.expect_value(t, event.b, host_generation)
	testing.expect(t, event.c > 0)
}

@(test)
test_vm_guard_stale_callback_does_not_create_wake_fire_evidence :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	vm_guard_schedule(&guard, u64(time.Second), .One_Shot, 1)
	stale_generation := vm_guard_stats(&guard).generation
	vm_guard_schedule(&guard, u64(time.Second), .One_Shot, 2)
	vm_guard_deadline(&guard, stale_generation)

	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine.machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	vm_guard_flush_wake_evidence(&guard, m)
	testing.expect_value(t, machine.machine_hardware_trace_count(m), u64(0))
}

@(test)
test_vm_guard_quiesce_stabilizes_final_evidence_and_stats :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	if !testing.expect(t, vm_guard_schedule(&guard, u64(time.Millisecond), .Run_Guard, 19)) {
		return
	}
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 2)) {return}
	if !testing.expect(t, vm_guard_quiesce(&guard)) {return}

	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine.machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	vm_guard_flush_wake_evidence(&guard, m)
	stats := vm_guard_stats(&guard)
	trace_count := machine.machine_hardware_trace_count(m)
	cancel_count, _ := vm_guard_test_snapshot(&cancel)
	time.sleep(10 * time.Millisecond)
	vm_guard_flush_wake_evidence(&guard, m)
	after := vm_guard_stats(&guard)
	after_cancel_count, _ := vm_guard_test_snapshot(&cancel)
	testing.expect(t, !stats.valid)
	testing.expect(t, trace_count >= 2)
	testing.expect_value(t, machine.machine_hardware_trace_count(m), trace_count)
	testing.expect_value(t, after.callbacks, stats.callbacks)
	testing.expect_value(t, after.retry_callbacks, stats.retry_callbacks)
	testing.expect_value(t, after.cancel_calls, stats.cancel_calls)
	testing.expect_value(t, after_cancel_count, cancel_count)
}

@(test)
test_vm_guard_evidence_overflow_is_counted_when_flushed :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	generation := vm_guard_stats(&guard).generation
	for _ in 0 ..< VM_GUARD_EVIDENCE_CAPACITY + 1 {
		vm_guard_deadline(&guard, generation)
	}

	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	defer {
		trace := machine.machine_hardware_trace_detach(m)
		if trace != nil {free(trace)}
	}
	vm_guard_flush_wake_evidence(&guard, m)
	testing.expect_value(t, vm_guard_stats(&guard).evidence_dropped, u64(1))
	trace_stats := machine.machine_hardware_trace_stats(m)
	full_windows := VM_GUARD_EVIDENCE_CAPACITY / machine.HARDWARE_TRACE_NOISY_WINDOW
	remainder := VM_GUARD_EVIDENCE_CAPACITY % machine.HARDWARE_TRACE_NOISY_WINDOW
	expected_retained := machine.HARDWARE_TRACE_NOISY_INITIAL_RETAIN
	if full_windows > 0 {
		expected_retained +=
			(full_windows - 1) * machine.HARDWARE_TRACE_NOISY_RETAIN +
			min(remainder, machine.HARDWARE_TRACE_NOISY_RETAIN)
	}
	testing.expect_value(t, trace_stats.observed, u64(VM_GUARD_EVIDENCE_CAPACITY))
	testing.expect_value(t, trace_stats.retained, u64(expected_retained))
	testing.expect_value(
		t,
		trace_stats.suppressed,
		u64(VM_GUARD_EVIDENCE_CAPACITY - expected_retained),
	)
}
