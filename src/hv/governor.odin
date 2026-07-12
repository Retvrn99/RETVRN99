// SPDX-License-Identifier: GPL-3.0-only
package hv

import "core:time"
import hosttime "../hosttime"
import config "../vmconfig"

GOVERNOR_MAX_HOST_HZ :: u64(20_000_000_000)
GOVERNOR_MAX_CREDIT_NS :: i64(1_000_000)
GOVERNOR_MAX_SLEEP_NS :: i64(100_000_000)

Governor :: struct {
	mode:          config.Cpu_Mode,
	host_hz:       u64,
	last_guest_ns: u64,
	last_wall:     time.Tick,
	balance_ns:    i64,
	primed:        bool,
	waiter:        hosttime.Waiter,
}

governor_init :: proc(g: ^Governor, vm: ^Vm, mode: config.Cpu_Mode) -> bool {
	g^ = {}
	g.host_hz = min(host_clock_hz(), GOVERNOR_MAX_HOST_HZ)
	_, counters_ok := guest_runtime_ns(vm)
	if g.host_hz == 0 || !counters_ok {
		g^ = {}
		return false
	}
	hosttime.waiter_init(&g.waiter)
	governor_set_mode(g, vm, mode)
	return true
}

governor_destroy :: proc(g: ^Governor) {
	hosttime.waiter_destroy(&g.waiter)
	g^ = {}
}

governor_set_mode :: proc(g: ^Governor, vm: ^Vm, mode: config.Cpu_Mode) {
	g.mode = mode
	g.balance_ns = 0
	g.primed = false
	if mode == .GSW_886 {
		governor_rebase(g, vm)
	}
}

governor_rebase :: proc(g: ^Governor, vm: ^Vm) {
	g.last_wall = time.tick_now()
	g.last_guest_ns, g.primed = guest_runtime_ns(vm)
	g.balance_ns = 0
}

governor_on_cancel :: proc(g: ^Governor, vm: ^Vm) -> bool {
	if g.mode != .GSW_886 || g.host_hz <= GSW_886_TSC_HZ { return true }
	now := time.tick_now()
	guest_ns, ok := guest_runtime_ns(vm)
	if !ok { return false }
	if !g.primed || guest_ns < g.last_guest_ns {
		g.last_guest_ns = guest_ns
		g.last_wall = now
		g.balance_ns = 0
		g.primed = true
		return true
	}
	wall_ns := u64(max(i64(0), i64(time.tick_diff(g.last_wall, now))))
	guest_delta := guest_ns - g.last_guest_ns
	g.last_guest_ns = guest_ns
	g.last_wall = now
	wait_ns := governor_charge(g, guest_delta, wall_ns)
	if wait_ns <= 0 { return true }
	wait_start := time.tick_now()
	hosttime.waiter_sleep(&g.waiter, time.Duration(wait_ns))
	waited_ns := i64(time.tick_since(wait_start))
	governor_record_wait(g, waited_ns)
	g.last_wall = time.tick_now()
	return true
}

governor_charge :: proc(g: ^Governor, guest_ns, wall_ns: u64) -> i64 {
	if g.mode != .GSW_886 || g.host_hz <= GSW_886_TSC_HZ { return 0 }
	required_wall_ns := i128(guest_ns) * i128(g.host_hz) / i128(GSW_886_TSC_HZ)
	balance := i128(g.balance_ns) + required_wall_ns - i128(wall_ns)
	balance = clamp(balance, -i128(GOVERNOR_MAX_CREDIT_NS), i128(0x7FFFFFFFFFFFFFFF))
	g.balance_ns = i64(balance)
	return min(max(i64(0), g.balance_ns), GOVERNOR_MAX_SLEEP_NS)
}

governor_record_wait :: proc(g: ^Governor, waited_ns: i64) {
	balance := i128(g.balance_ns) - i128(max(i64(0), waited_ns))
	g.balance_ns = i64(
		clamp(balance, -i128(GOVERNOR_MAX_CREDIT_NS), i128(0x7FFFFFFFFFFFFFFF)),
	)
}
