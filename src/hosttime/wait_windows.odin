// SPDX-License-Identifier: GPL-3.0-only
package hosttime

import "core:time"
import win32 "core:sys/windows"

Waiter :: struct {
	handle: win32.HANDLE,
}

waiter_init :: proc(w: ^Waiter) {
	w.handle = win32.CreateWaitableTimerExW(
		nil,
		nil,
		win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
		win32.TIMER_ALL_ACCESS,
	)
	if w.handle == nil {
		w.handle = win32.CreateWaitableTimerW(nil, win32.FALSE, nil)
	}
}

waiter_destroy :: proc(w: ^Waiter) {
	if w.handle != nil {
		win32.CloseHandle(w.handle)
		w.handle = nil
	}
}

waiter_sleep :: proc(w: ^Waiter, duration: time.Duration) {
	if duration <= 0 { return }
	if w.handle != nil {
		ticks_100ns := max(i64(1), (i64(duration) + 99) / 100)
		due := win32.LARGE_INTEGER(-ticks_100ns)
		if bool(win32.SetWaitableTimerEx(w.handle, &due, 0, nil, nil, nil, 0)) {
			_ = win32.WaitForSingleObject(w.handle, win32.INFINITE)
			return
		}
	}
	rounded := (duration + time.Millisecond - 1) / time.Millisecond * time.Millisecond
	time.sleep(rounded)
}
