// SPDX-License-Identifier: GPL-3.0-only
package hosttime

import "core:sync"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"

Armable_Wake_Test_Context :: struct {
	mu:         sync.Mutex,
	count:      int,
	generation: u64,
}

armable_wake_test_callback :: proc(ctx: rawptr, generation: u64) {
	test_ctx := (^Armable_Wake_Test_Context)(ctx)
	sync.lock(&test_ctx.mu)
	test_ctx.count += 1
	test_ctx.generation = generation
	sync.unlock(&test_ctx.mu)
}

armable_wake_test_snapshot :: proc(ctx: ^Armable_Wake_Test_Context) -> (int, u64) {
	sync.lock(&ctx.mu)
	defer sync.unlock(&ctx.mu)
	return ctx.count, ctx.generation
}

armable_wake_test_wait_count :: proc(
	ctx: ^Armable_Wake_Test_Context,
	wanted: int,
	timeout: time.Duration = 250 * time.Millisecond,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if count, _ := armable_wake_test_snapshot(ctx); count >= wanted {return true}
		time.sleep(time.Millisecond)
	}
	return false
}

@(test)
test_armable_wake_registered_callback_rearms_before_deadline :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	defer armable_wake_destroy(&wake)
	if !testing.expect(t, armable_wake_arm(&wake, 100 * time.Millisecond, 1)) {return}
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond, 2)) {return}
	testing.expect(t, armable_wake_test_wait_count(&ctx, 1))
	time.sleep(110 * time.Millisecond)
	count, generation := armable_wake_test_snapshot(&ctx)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, generation, u64(2))
	testing.expect_value(t, armable_wake_stats(&wake).generation, u64(2))
}

@(test)
test_armable_wake_destroy_quiesces_registered_callback :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond)) {return}
	testing.expect(t, armable_wake_test_wait_count(&ctx, 1))
	armable_wake_destroy(&wake)
	count, _ := armable_wake_test_snapshot(&ctx)
	time.sleep(10 * time.Millisecond)
	after, _ := armable_wake_test_snapshot(&ctx)
	testing.expect_value(t, after, count)
	testing.expect(t, !armable_wake_arm(&wake, time.Millisecond))
}

armable_wake_test_unregister_failure :: proc(_: win32.HANDLE, _: win32.HANDLE) -> bool {
	return false
}

@(test)
test_armable_wake_destroy_retains_state_when_unregister_fails :: proc(t: ^testing.T) {
	wake := Armable_Wake {
		registration = win32.HANDLE(uintptr(1)),
		generation   = 73,
		unregister   = armable_wake_test_unregister_failure,
	}
	testing.expect(t, !armable_wake_destroy(&wake))
	testing.expect_value(t, wake.registration, win32.HANDLE(uintptr(1)))
	testing.expect_value(t, wake.generation, u64(73))
	wake.registration = nil
	wake = {}
}

@(test)
test_armable_wake_quiesce_preserves_final_stable_stats :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	defer armable_wake_destroy(&wake)
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond, 17, time.Millisecond)) {return}
	if !testing.expect(t, armable_wake_test_wait_count(&ctx, 2)) {return}
	if !testing.expect(t, armable_wake_quiesce(&wake)) {return}
	count, generation := armable_wake_test_snapshot(&ctx)
	stats := armable_wake_stats(&wake)
	testing.expect_value(t, generation, u64(17))
	testing.expect_value(t, stats.generation, u64(17))
	time.sleep(10 * time.Millisecond)
	after, _ := armable_wake_test_snapshot(&ctx)
	after_stats := armable_wake_stats(&wake)
	testing.expect_value(t, after, count)
	testing.expect_value(t, after_stats.callbacks, stats.callbacks)
	testing.expect_value(t, after_stats.retry_callbacks, stats.retry_callbacks)
	testing.expect(t, !armable_wake_arm(&wake, time.Millisecond))
}

@(test)
test_armable_wake_periodic_retry_stops_on_disarm :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	defer armable_wake_destroy(&wake)
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond, 41, time.Millisecond)) {return}
	if !testing.expect(t, armable_wake_test_wait_count(&ctx, 2)) {return}
	stats := armable_wake_stats(&wake)
	testing.expect(t, stats.callbacks >= 2)
	testing.expect(t, stats.retry_callbacks >= 1)
	_ = armable_wake_disarm(&wake)
	time.sleep(5 * time.Millisecond)
	count, generation := armable_wake_test_snapshot(&ctx)
	testing.expect_value(t, generation, u64(41))
	time.sleep(10 * time.Millisecond)
	after, _ := armable_wake_test_snapshot(&ctx)
	testing.expect_value(t, after, count)
}

@(test)
test_armable_wake_ignores_queued_callback_before_new_deadline :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	defer armable_wake_destroy(&wake)
	if !testing.expect(t, armable_wake_arm(&wake, 100 * time.Millisecond, 9)) {return}
	armable_wake_dispatch(&wake, win32.BOOLEAN(false))
	time.sleep(time.Millisecond)
	count, _ := armable_wake_test_snapshot(&ctx)
	testing.expect_value(t, count, 0)
	stats := armable_wake_stats(&wake)
	testing.expect_value(t, stats.callbacks, u64(1))
	testing.expect_value(t, stats.ignored, u64(1))
}
