// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:sync"
import "core:time"
import "hosttime"
import "hv"
import "machine"

VM_GUARD_RETRY_PERIOD :: time.Millisecond
VM_GUARD_EVIDENCE_CAPACITY :: 4096

Vm_Guard_Cancel_Proc :: #type proc(ctx: rawptr, vm: ^hv.Vm)

Vm_Guard_Wake_Evidence :: struct {
	host_generation:    u64,
	machine_generation: u64,
	host_elapsed_ns:    u64,
}

Vm_Guard :: struct {
	mu:                 sync.Mutex,
	vm:                 ^hv.Vm,
	wake:               hosttime.Armable_Wake,
	valid:              bool,
	cancel:             Vm_Guard_Cancel_Proc,
	cancel_ctx:         rawptr,
	deadline_count:     u64,
	external_wakes:     u64,
	arm_failures:       u64,
	stale_callbacks:    u64,
	cancel_calls:       u64,
	generation:         u64,
	machine_generation: u64,
	started_at:         time.Tick,
	evidence:           [VM_GUARD_EVIDENCE_CAPACITY]Vm_Guard_Wake_Evidence,
	evidence_count:     u64,
	evidence_flushed:   u64,
	evidence_dropped:   u64,
}

Vm_Guard_Stats :: struct {
	deadline_count:     u64,
	external_wakes:     u64,
	arm_failures:       u64,
	callbacks:          u64,
	retry_callbacks:    u64,
	cancel_calls:       u64,
	stale_callbacks:    u64,
	generation:         u64,
	machine_generation: u64,
	evidence_dropped:   u64,
	valid:              bool,
}

vm_guard_hv_cancel :: proc(_: rawptr, vm: ^hv.Vm) {
	if vm != nil {hv.cancel(vm)}
}

vm_guard_deadline :: proc(ctx: rawptr, generation: u64) {
	guard := (^Vm_Guard)(ctx)
	if guard == nil {return}
	sync.lock(&guard.mu)
	if guard.generation != generation {
		guard.stale_callbacks += 1
	} else if guard.valid && guard.vm != nil && guard.cancel != nil {
		guard.deadline_count += 1
		guard.cancel_calls += 1
		guard.evidence[guard.evidence_count % VM_GUARD_EVIDENCE_CAPACITY] = {
			host_generation    = generation,
			machine_generation = guard.machine_generation,
			host_elapsed_ns    = u64(max(time.Duration(0), time.tick_since(guard.started_at))),
		}
		guard.evidence_count += 1
		guard.cancel(guard.cancel_ctx, guard.vm)
	}
	sync.unlock(&guard.mu)
}

vm_guard_init :: proc(
	guard: ^Vm_Guard,
	cancel: Vm_Guard_Cancel_Proc = vm_guard_hv_cancel,
	cancel_ctx: rawptr = nil,
) -> bool {
	if guard == nil || cancel == nil {return false}
	guard^ = {}
	guard.cancel = cancel
	guard.cancel_ctx = cancel_ctx
	guard.started_at = time.tick_now()
	if hosttime.armable_wake_init(&guard.wake, guard, vm_guard_deadline) {return true}
	guard^ = {}
	return false
}

vm_guard_destroy :: proc(guard: ^Vm_Guard) -> bool {
	if guard == nil {return false}
	if !vm_guard_quiesce(guard) {return false}
	if !hosttime.armable_wake_destroy(&guard.wake) {return false}
	guard^ = {}
	return true
}

vm_guard_quiesce :: proc(guard: ^Vm_Guard) -> bool {
	if guard == nil {return false}
	sync.lock(&guard.mu)
	guard.valid = false
	guard.vm = nil
	guard.generation += 1
	sync.unlock(&guard.mu)
	return hosttime.armable_wake_quiesce(&guard.wake)
}

vm_guard_bind :: proc(guard: ^Vm_Guard, vm: ^hv.Vm) {
	if guard == nil {return}
	sync.lock(&guard.mu)
	guard.generation += 1
	guard.machine_generation = 0
	guard.vm = nil
	guard.valid = false
	sync.unlock(&guard.mu)
	_ = hosttime.armable_wake_disarm(&guard.wake)
	sync.lock(&guard.mu)
	guard.vm = vm
	guard.valid = vm != nil
	sync.unlock(&guard.mu)
}

vm_guard_unbind :: proc(guard: ^Vm_Guard) {
	if guard == nil {return}
	sync.lock(&guard.mu)
	guard.generation += 1
	guard.machine_generation = 0
	guard.valid = false
	guard.vm = nil
	sync.unlock(&guard.mu)
	_ = hosttime.armable_wake_disarm(&guard.wake)
}

vm_guard_arm :: proc(
	guard: ^Vm_Guard,
	delay_ns: u64,
	mode: machine.Wake_Schedule_Mode,
	machine_generation: u64,
) -> bool {
	if guard == nil {return false}
	sync.lock(&guard.mu)
	guard.generation += 1
	generation := guard.generation
	guard.machine_generation = machine_generation
	sync.unlock(&guard.mu)
	if mode == .Disarm {
		_ = hosttime.armable_wake_disarm(&guard.wake)
		return true
	}
	retry := mode == .Run_Guard ? VM_GUARD_RETRY_PERIOD : time.Duration(0)
	if hosttime.armable_wake_arm(
		&guard.wake,
		time.Duration(max(delay_ns, u64(1))),
		generation,
		retry,
	) {
		return true
	}
	sync.lock(&guard.mu)
	guard.arm_failures += 1
	sync.unlock(&guard.mu)
	return false
}

vm_guard_kick :: proc(guard: ^Vm_Guard) {
	if guard == nil {return}
	sync.lock(&guard.mu)
	if guard.valid && guard.vm != nil && guard.cancel != nil {
		guard.external_wakes += 1
		guard.cancel_calls += 1
		guard.cancel(guard.cancel_ctx, guard.vm)
	}
	sync.unlock(&guard.mu)
}

vm_guard_flush_wake_evidence :: proc(guard: ^Vm_Guard, m: ^machine.Machine) {
	if guard == nil || m == nil {return}
	batch: [64]Vm_Guard_Wake_Evidence
	for {
		count := 0
		sync.lock(&guard.mu)
		oldest: u64
		if guard.evidence_count > VM_GUARD_EVIDENCE_CAPACITY {
			oldest = guard.evidence_count - VM_GUARD_EVIDENCE_CAPACITY
		}
		if guard.evidence_flushed < oldest {
			guard.evidence_dropped += oldest - guard.evidence_flushed
			guard.evidence_flushed = oldest
		}
		available := guard.evidence_count - guard.evidence_flushed
		count = int(min(available, u64(len(batch))))
		for index in 0 ..< count {
			sequence := guard.evidence_flushed + u64(index)
			batch[index] = guard.evidence[sequence % VM_GUARD_EVIDENCE_CAPACITY]
		}
		guard.evidence_flushed += u64(count)
		sync.unlock(&guard.mu)
		for event in batch[:count] {
			machine.machine_trace_record(
				m,
				.Wake_Fire,
				event.machine_generation,
				event.host_generation,
				event.host_elapsed_ns,
			)
		}
		if count < len(batch) {break}
	}
}

vm_guard_schedule :: proc(
	ctx: rawptr,
	delay_ns: u64,
	mode: machine.Wake_Schedule_Mode,
	generation: u64,
) -> bool {
	guard := (^Vm_Guard)(ctx)
	if guard == nil {return false}
	return vm_guard_arm(guard, delay_ns, mode, generation)
}

vm_guard_stats :: proc(guard: ^Vm_Guard) -> Vm_Guard_Stats {
	if guard == nil {return {}}
	sync.lock(&guard.mu)
	stats := Vm_Guard_Stats {
		deadline_count     = guard.deadline_count,
		external_wakes     = guard.external_wakes,
		arm_failures       = guard.arm_failures,
		cancel_calls       = guard.cancel_calls,
		stale_callbacks    = guard.stale_callbacks,
		generation         = guard.generation,
		machine_generation = guard.machine_generation,
		evidence_dropped   = guard.evidence_dropped,
		valid              = guard.valid,
	}
	sync.unlock(&guard.mu)
	wake_stats := hosttime.armable_wake_stats(&guard.wake)
	stats.callbacks = wake_stats.callbacks
	stats.retry_callbacks = wake_stats.retry_callbacks
	stats.stale_callbacks += wake_stats.ignored
	return stats
}

vm_guard_failed :: proc(guard: ^Vm_Guard) -> bool {
	return vm_guard_stats(guard).arm_failures > 0
}
