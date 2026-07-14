// SPDX-License-Identifier: GPL-3.0-only
package hosttime

import "base:runtime"
import "core:time"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

foreign kernel32 {
	CancelWaitableTimer :: proc(timer: win32.HANDLE) -> win32.BOOL ---
}

Armable_Wake_Callback :: #type proc(ctx: rawptr)

Armable_Wake :: struct {
	timer:        win32.HANDLE,
	registration: win32.HANDLE,
	callback:     Armable_Wake_Callback,
	callback_ctx: rawptr,
}

armable_wake_dispatch :: proc "system" (parameter: rawptr, _: win32.BOOLEAN) {
	context = runtime.default_context()
	wake := (^Armable_Wake)(parameter)
	if wake != nil && wake.callback != nil {wake.callback(wake.callback_ctx)}
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
	if bool(win32.RegisterWaitForSingleObject(
		&wake.registration,
		wake.timer,
		armable_wake_dispatch,
		wake,
		win32.INFINITE,
		win32.WT_EXECUTEDEFAULT,
	)) {
		return true
	}
	armable_wake_destroy(wake)
	return false
}

armable_wake_destroy :: proc(wake: ^Armable_Wake) {
	if wake == nil {return}
	if wake.registration != nil {
		_ = win32.UnregisterWaitEx(wake.registration, win32.INVALID_HANDLE_VALUE)
		wake.registration = nil
	}
	if wake.timer != nil {
		_ = win32.CloseHandle(wake.timer)
		wake.timer = nil
	}
	wake^ = {}
}

armable_wake_arm :: proc(wake: ^Armable_Wake, duration: time.Duration) -> bool {
	if wake == nil || wake.timer == nil || wake.registration == nil {return false}
	ticks_100ns := max(i64(1), (max(i64(duration), i64(1)) + 99) / 100)
	due := win32.LARGE_INTEGER(-ticks_100ns)
	return bool(win32.SetWaitableTimerEx(wake.timer, &due, 0, nil, nil, nil, 0))
}

armable_wake_disarm :: proc(wake: ^Armable_Wake) -> bool {
	if wake == nil || wake.timer == nil || wake.registration == nil {return false}
	return bool(CancelWaitableTimer(wake.timer))
}
