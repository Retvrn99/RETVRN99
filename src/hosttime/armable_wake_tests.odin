// SPDX-License-Identifier: GPL-3.0-only
package hosttime

import "core:sync"
import "core:testing"
import "core:time"

Armable_Wake_Test_Context :: struct {
	mu:    sync.Mutex,
	count: int,
}

armable_wake_test_callback :: proc(ctx: rawptr) {
	test_ctx := (^Armable_Wake_Test_Context)(ctx)
	sync.lock(&test_ctx.mu)
	test_ctx.count += 1
	sync.unlock(&test_ctx.mu)
}

armable_wake_test_count :: proc(ctx: ^Armable_Wake_Test_Context) -> int {
	sync.lock(&ctx.mu)
	defer sync.unlock(&ctx.mu)
	return ctx.count
}

armable_wake_test_wait_count :: proc(
	ctx: ^Armable_Wake_Test_Context,
	wanted: int,
	timeout: time.Duration = 250 * time.Millisecond,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if armable_wake_test_count(ctx) >= wanted {return true}
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
	if !testing.expect(t, armable_wake_arm(&wake, 100 * time.Millisecond)) {return}
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond)) {return}
	testing.expect(t, armable_wake_test_wait_count(&ctx, 1))
	time.sleep(110 * time.Millisecond)
	testing.expect_value(t, armable_wake_test_count(&ctx), 1)
}

@(test)
test_armable_wake_destroy_quiesces_registered_callback :: proc(t: ^testing.T) {
	ctx: Armable_Wake_Test_Context
	wake: Armable_Wake
	if !testing.expect(t, armable_wake_init(&wake, &ctx, armable_wake_test_callback)) {return}
	if !testing.expect(t, armable_wake_arm(&wake, time.Millisecond)) {return}
	testing.expect(t, armable_wake_test_wait_count(&ctx, 1))
	armable_wake_destroy(&wake)
	count := armable_wake_test_count(&ctx)
	time.sleep(10 * time.Millisecond)
	testing.expect_value(t, armable_wake_test_count(&ctx), count)
	testing.expect(t, !armable_wake_arm(&wake, time.Millisecond))
}
