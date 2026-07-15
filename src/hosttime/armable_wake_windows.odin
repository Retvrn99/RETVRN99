// SPDX-License-Identifier: GPL-3.0-only
package hosttime

import "base:runtime"
import "core:sync"
import win32 "core:sys/windows"
import "core:time"

foreign import kernel32 "system:Kernel32.lib"

foreign kernel32 {
	CancelWaitableTimer :: proc(timer: win32.HANDLE) -> win32.BOOL ---
}

Armable_Wake_Callback :: #type proc(ctx: rawptr, generation: u64)
Armable_Wake_Unregister_Proc :: #type proc(registration, completion: win32.HANDLE) -> bool

armable_wake_unregister :: proc(registration, completion: win32.HANDLE) -> bool {
	return bool(win32.UnregisterWaitEx(registration, completion))
}

Armable_Wake :: struct {
	timer:           win32.HANDLE,
	registration:    win32.HANDLE,
	callback:        Armable_Wake_Callback,
	callback_ctx:    rawptr,
	unregister:      Armable_Wake_Unregister_Proc,
	mu:              sync.Mutex,
	generation:      u64,
	armed_at:        time.Tick,
	delay:           time.Duration,
	armed:           bool,
	periodic:        bool,
	arm_callbacks:   u64,
	callbacks:       u64,
	retry_callbacks: u64,
	ignored:         u64,
}

Armable_Wake_Stats :: struct {
	generation:      u64,
	callbacks:       u64,
	retry_callbacks: u64,
	ignored:         u64,
}

armable_wake_dispatch :: proc "system" (parameter: rawptr, _: win32.BOOLEAN) {
	context = runtime.default_context()
	wake := (^Armable_Wake)(parameter)
	if wake == nil {return}
	sync.lock(&wake.mu)
	wake.callbacks += 1
	if !wake.armed || time.tick_since(wake.armed_at) < wake.delay {
		wake.ignored += 1
		sync.unlock(&wake.mu)
		return
	}
	callback := wake.callback
	callback_ctx := wake.callback_ctx
	generation := wake.generation
	if wake.periodic && wake.arm_callbacks > 0 {wake.retry_callbacks += 1}
	wake.arm_callbacks += 1
	if !wake.periodic {wake.armed = false}
	sync.unlock(&wake.mu)
	if callback != nil {callback(callback_ctx, generation)}
}

armable_wake_init :: proc(
	wake: ^Armable_Wake,
	callback_ctx: rawptr,
	callback: Armable_Wake_Callback,
) -> bool {
	if wake == nil || callback == nil {return false}
	wake^ = {}
	wake.timer = win32.CreateWaitableTimerExW(
		nil,
		nil,
		win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
		win32.TIMER_ALL_ACCESS,
	)
	if wake.timer == nil {wake.timer = win32.CreateWaitableTimerW(nil, win32.FALSE, nil)}
	if wake.timer == nil {return false}
	wake.callback_ctx = callback_ctx
	wake.callback = callback
	wake.unregister = armable_wake_unregister
	if bool(
		win32.RegisterWaitForSingleObject(
			&wake.registration,
			wake.timer,
			armable_wake_dispatch,
			wake,
			win32.INFINITE,
			win32.WT_EXECUTEDEFAULT,
		),
	) {
		return true
	}
	_ = armable_wake_destroy(wake)
	return false
}

armable_wake_destroy :: proc(wake: ^Armable_Wake) -> bool {
	if wake == nil {return false}
	if !armable_wake_quiesce(wake) {return false}
	if wake.timer != nil {
		if !bool(win32.CloseHandle(wake.timer)) {return false}
		wake.timer = nil
	}
	wake^ = {}
	return true
}

armable_wake_quiesce :: proc(wake: ^Armable_Wake) -> bool {
	if wake == nil {return false}
	_ = armable_wake_disarm(wake)
	if wake.registration == nil {return true}
	unregister := wake.unregister
	if unregister == nil {unregister = armable_wake_unregister}
	if !unregister(wake.registration, win32.INVALID_HANDLE_VALUE) {
		return false
	}
	wake.registration = nil
	return true
}

armable_wake_arm :: proc(
	wake: ^Armable_Wake,
	duration: time.Duration,
	generation: u64 = 0,
	retry_period: time.Duration = 0,
) -> bool {
	if wake == nil || wake.timer == nil || wake.registration == nil {return false}
	delay := time.Duration(max(i64(duration), i64(1)))
	ticks_100ns := max(i64(1), (i64(delay) + 99) / 100)
	due := win32.LARGE_INTEGER(-ticks_100ns)
	period_ms := i32(0)
	if retry_period > 0 {
		period_ms = i32(
			max(i64(1), (i64(retry_period) + i64(time.Millisecond) - 1) / i64(time.Millisecond)),
		)
	}
	sync.lock(&wake.mu)
	wake.generation = generation
	wake.armed_at = time.tick_now()
	wake.delay = delay
	wake.armed = true
	wake.periodic = period_ms != 0
	wake.arm_callbacks = 0
	ok := bool(win32.SetWaitableTimerEx(wake.timer, &due, period_ms, nil, nil, nil, 0))
	if !ok {wake.armed = false}
	sync.unlock(&wake.mu)
	return ok
}

armable_wake_stats :: proc(wake: ^Armable_Wake) -> Armable_Wake_Stats {
	if wake == nil {return {}}
	sync.lock(&wake.mu)
	defer sync.unlock(&wake.mu)
	return {
		generation = wake.generation,
		callbacks = wake.callbacks,
		retry_callbacks = wake.retry_callbacks,
		ignored = wake.ignored,
	}
}

armable_wake_disarm :: proc(wake: ^Armable_Wake) -> bool {
	if wake == nil || wake.timer == nil || wake.registration == nil {return false}
	sync.lock(&wake.mu)
	wake.armed = false
	wake.periodic = false
	ok := bool(CancelWaitableTimer(wake.timer))
	sync.unlock(&wake.mu)
	return ok
}
