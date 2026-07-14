// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:log"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "hosttime"
import "hv"

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

@(test)
test_vm_guard_registered_watchdog_survives_unbind_and_rebind :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	defer vm_guard_destroy(&guard)
	first, second: hv.Vm

	vm_guard_bind(&guard, &first)
	vm_guard_rearm(&guard, u64(time.Millisecond))
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 1)) {return}
	count, target := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, target, &first)

	vm_guard_unbind(&guard)
	vm_guard_rearm(&guard, u64(time.Millisecond))
	time.sleep(10 * time.Millisecond)
	count, _ = vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)

	vm_guard_bind(&guard, &second)
	vm_guard_rearm(&guard, u64(time.Millisecond))
	if !testing.expect(t, vm_guard_test_wait_count(&cancel, 2)) {return}
	count, target = vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, target, &second)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.deadline_count, u64(2))
	testing.expect(t, stats.valid)
}

@(test)
test_vm_guard_arm_failure_cancels_bound_vcpu_immediately :: proc(t: ^testing.T) {
	cancel: Vm_Guard_Test_Cancel
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard, vm_guard_test_cancel, &cancel)) {return}
	vm: hv.Vm
	vm_guard_bind(&guard, &vm)
	hosttime.armable_wake_destroy(&guard.wake)
	vm_guard_rearm(&guard, u64(time.Millisecond))
	count, target := vm_guard_test_snapshot(&cancel)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, target, &vm)
	stats := vm_guard_stats(&guard)
	testing.expect_value(t, stats.arm_failures, u64(1))
	vm_guard_destroy(&guard)
}

@(test)
test_vm_guard_registered_watchdog_cancels_repeated_whpx_runs :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available; skipping registered watchdog integration test")
		return
	}
	testing.set_fail_timeout(t, 5 * time.Second)
	vm: hv.Vm
	if !testing.expect(t, hv.create(&vm, 64 * 1024 * 1024)) {return}
	defer hv.destroy(&vm)
	copy(vm.ram[0x7C00:], []u8{0xEB, 0xFE})
	hv.set_realmode_entry(&vm, 0, 0x7C00)

	emergency := Vm_Guard_Test_Emergency{vm = &vm}
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
	for expected in u64(1) ..= u64(2) {
		start := time.tick_now()
		vm_guard_rearm(&guard, u64(time.Millisecond))
		exit := hv.run(&vm)
		elapsed := time.tick_since(start)
		if !testing.expect_value(t, exit.kind, hv.Exit_Kind.Canceled) {return}
		testing.expect(t, elapsed < 250 * time.Millisecond)
		testing.expect_value(t, vm_guard_stats(&guard).deadline_count, expected)
	}
}
