// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:sync"
import "core:time"
import "hosttime"
import "hv"

Vm_Guard_Cancel_Proc :: #type proc(ctx: rawptr, vm: ^hv.Vm)

Vm_Guard :: struct {
	mu:             sync.Mutex,
	vm:             ^hv.Vm,
	wake:           hosttime.Armable_Wake,
	valid:          bool,
	cancel:         Vm_Guard_Cancel_Proc,
	cancel_ctx:     rawptr,
	deadline_count: u64,
	arm_failures:   u64,
}

Vm_Guard_Stats :: struct {
	deadline_count: u64,
	arm_failures:   u64,
	valid:          bool,
}

vm_guard_hv_cancel :: proc(_: rawptr, vm: ^hv.Vm) {
	if vm != nil {hv.cancel(vm)}
}

vm_guard_deadline :: proc(ctx: rawptr) {
	guard := (^Vm_Guard)(ctx)
	if guard == nil {return}
	sync.lock(&guard.mu)
	if guard.valid && guard.vm != nil && guard.cancel != nil {
		guard.deadline_count += 1
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
	if hosttime.armable_wake_init(&guard.wake, guard, vm_guard_deadline) {return true}
	guard^ = {}
	return false
}

vm_guard_destroy :: proc(guard: ^Vm_Guard) {
	if guard == nil {return}
	hosttime.armable_wake_destroy(&guard.wake)
	guard^ = {}
}

vm_guard_bind :: proc(guard: ^Vm_Guard, vm: ^hv.Vm) {
	if guard == nil {return}
	sync.lock(&guard.mu)
	guard.vm = vm
	guard.valid = vm != nil
	sync.unlock(&guard.mu)
}

vm_guard_unbind :: proc(guard: ^Vm_Guard) {
	if guard == nil {return}
	sync.lock(&guard.mu)
	guard.valid = false
	guard.vm = nil
	sync.unlock(&guard.mu)
}

vm_guard_rearm :: proc(ctx: rawptr, delay_ns: u64) {
	guard := (^Vm_Guard)(ctx)
	if guard == nil {return}
	if hosttime.armable_wake_arm(
		&guard.wake,
		time.Duration(max(delay_ns, u64(1))),
	) {
		return
	}
	sync.lock(&guard.mu)
	guard.arm_failures += 1
	if guard.valid && guard.vm != nil && guard.cancel != nil {
		guard.cancel(guard.cancel_ctx, guard.vm)
	}
	sync.unlock(&guard.mu)
}

vm_guard_stats :: proc(guard: ^Vm_Guard) -> Vm_Guard_Stats {
	if guard == nil {return {}}
	sync.lock(&guard.mu)
	defer sync.unlock(&guard.mu)
	return {
		deadline_count = guard.deadline_count,
		arm_failures   = guard.arm_failures,
		valid          = guard.valid,
	}
}

vm_guard_failed :: proc(guard: ^Vm_Guard) -> bool {
	return vm_guard_stats(guard).arm_failures > 0
}
