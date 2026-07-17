// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:sync"
import "core:time"

Gsw3d_Bridge_Request_Kind :: enum u8 {
	Invalid,
	Execute,
	Upload,
	Reset,
}

Gsw3d_Bridge_State :: enum u8 {
	Idle,
	Pending,
	Executing,
	Completed,
	Cancelled,
}

Gsw3d_Bridge_Request :: struct {
	kind:        Gsw3d_Bridge_Request_Kind,
	generation:  u64,
	budget_cost: u64,
	payload:     rawptr,
}

Gsw3d_Bridge_Notify_Proc :: proc(ctx: rawptr, generation: u64)
Gsw3d_Bridge_Execute_Proc :: proc(ctx: rawptr, request: Gsw3d_Bridge_Request) -> bool

Gsw3d_Bridge_Drain_Limits :: struct {
	max_requests:  int,
	max_budget:    u64,
	followup_wait: time.Duration,
}

Gsw3d_Bridge_Drain_Result :: struct {
	executed:    int,
	succeeded:   int,
	failed:      int,
	discarded:   int,
	budget_used: u64,
}

Gsw3d_Bridge_Snapshot :: struct {
	state:      Gsw3d_Bridge_State,
	generation: u64,
	sequence:   u64,
	accepting:  bool,
	shutdown:   bool,
	discard:    bool,
}

Gsw3d_Bridge :: struct {
	mu:            sync.Mutex,
	completed:     sync.Cond,
	pending:       sync.Cond,
	request:       Gsw3d_Bridge_Request,
	notify:        Gsw3d_Bridge_Notify_Proc,
	notify_ctx:    rawptr,
	state:         Gsw3d_Bridge_State,
	generation:    u64,
	sequence:      u64,
	completion_ok: bool,
	accepting:     bool,
	shutdown:      bool,
	discard:       bool,
}

gsw3d_bridge_init :: proc(
	bridge: ^Gsw3d_Bridge,
	notify: Gsw3d_Bridge_Notify_Proc = nil,
	notify_ctx: rawptr = nil,
) {
	if bridge == nil {return}
	bridge^ = {
		notify     = notify,
		notify_ctx = notify_ctx,
	}
}

@(private = "file")
gsw3d_bridge_next_generation :: proc(generation: u64) -> u64 {
	next := generation + 1
	return next != 0 ? next : 1
}

@(private = "file")
gsw3d_bridge_cancel_active_locked :: proc(bridge: ^Gsw3d_Bridge) {
	switch bridge.state {
	case .Pending, .Completed:
		bridge.state = .Cancelled
		bridge.completion_ok = false
		sync.cond_broadcast(&bridge.completed)
	case .Executing:
		bridge.discard = true
	case .Idle, .Cancelled:
	}
}

gsw3d_bridge_begin_session :: proc(bridge: ^Gsw3d_Bridge) -> u64 {
	if bridge == nil {return 0}
	sync.lock(&bridge.mu)
	defer sync.unlock(&bridge.mu)
	if bridge.shutdown {return 0}
	bridge.accepting = false
	gsw3d_bridge_cancel_active_locked(bridge)
	bridge.generation = gsw3d_bridge_next_generation(bridge.generation)
	bridge.accepting = true
	return bridge.generation
}

gsw3d_bridge_cancel_session :: proc(bridge: ^Gsw3d_Bridge, generation: u64) -> bool {
	if bridge == nil || generation == 0 {return false}
	sync.lock(&bridge.mu)
	defer sync.unlock(&bridge.mu)
	if bridge.shutdown || generation != bridge.generation {return false}
	bridge.accepting = false
	gsw3d_bridge_cancel_active_locked(bridge)
	return true
}

gsw3d_bridge_shutdown :: proc(bridge: ^Gsw3d_Bridge) {
	if bridge == nil {return}
	sync.lock(&bridge.mu)
	if !bridge.shutdown {
		bridge.accepting = false
		bridge.shutdown = true
		gsw3d_bridge_cancel_active_locked(bridge)
		bridge.generation = gsw3d_bridge_next_generation(bridge.generation)
	}
	sync.unlock(&bridge.mu)
}

@(private = "file")
gsw3d_bridge_request_cost :: proc(request: Gsw3d_Bridge_Request) -> u64 {
	return max(request.budget_cost, u64(1))
}

// payload is borrowed and must remain immutable until this synchronous call returns.
gsw3d_bridge_submit :: proc(bridge: ^Gsw3d_Bridge, request: Gsw3d_Bridge_Request) -> bool {
	if bridge == nil || request.kind == .Invalid || request.generation == 0 {return false}
	sync.lock(&bridge.mu)
	if bridge.shutdown ||
	   !bridge.accepting ||
	   request.generation != bridge.generation ||
	   bridge.state != .Idle {
		sync.unlock(&bridge.mu)
		return false
	}
	bridge.sequence += 1
	if bridge.sequence == 0 {bridge.sequence = 1}
	bridge.request = request
	bridge.completion_ok = false
	bridge.discard = false
	bridge.state = .Pending
	notify, notify_ctx := bridge.notify, bridge.notify_ctx
	sync.unlock(&bridge.mu)
	sync.cond_signal(&bridge.pending)

	if notify != nil {notify(notify_ctx, request.generation)}

	sync.lock(&bridge.mu)
	for bridge.state == .Pending || bridge.state == .Executing {
		sync.cond_wait(&bridge.completed, &bridge.mu)
	}
	ok := bridge.state == .Completed && bridge.completion_ok
	bridge.request = {}
	bridge.completion_ok = false
	bridge.discard = false
	bridge.state = .Idle
	sync.unlock(&bridge.mu)
	return ok
}

gsw3d_bridge_drain :: proc(
	bridge: ^Gsw3d_Bridge,
	limits: Gsw3d_Bridge_Drain_Limits,
	execute: Gsw3d_Bridge_Execute_Proc,
	execute_ctx: rawptr = nil,
) -> Gsw3d_Bridge_Drain_Result {
	result: Gsw3d_Bridge_Drain_Result
	if bridge == nil || execute == nil || limits.max_requests <= 0 {return result}
	followup_waits := 0

	for result.executed < limits.max_requests {
		sync.lock(&bridge.mu)
		if bridge.state != .Pending {
			can_wait :=
				result.executed > 0 &&
				limits.followup_wait > 0 &&
				followup_waits < limits.max_requests - result.executed
			if can_wait {
				followup_waits += 1
				_ = sync.cond_wait_with_timeout(&bridge.pending, &bridge.mu, limits.followup_wait)
				if bridge.state == .Pending {
					sync.unlock(&bridge.mu)
					continue
				}
			}
			sync.unlock(&bridge.mu)
			break
		}
		request := bridge.request
		sequence := bridge.sequence
		cost := gsw3d_bridge_request_cost(request)
		if cost > limits.max_budget {
			bridge.state = .Cancelled
			bridge.completion_ok = false
			sync.unlock(&bridge.mu)
			sync.cond_broadcast(&bridge.completed)
			result.executed += 1
			result.failed += 1
			result.discarded += 1
			continue
		}
		if cost > limits.max_budget - min(limits.max_budget, result.budget_used) {
			sync.unlock(&bridge.mu)
			break
		}
		if bridge.shutdown || !bridge.accepting || request.generation != bridge.generation {
			bridge.state = .Cancelled
			bridge.completion_ok = false
			sync.unlock(&bridge.mu)
			sync.cond_broadcast(&bridge.completed)
			break
		}
		bridge.state = .Executing
		sync.unlock(&bridge.mu)

		ok := execute(execute_ctx, request)

		discarded := true
		sync.lock(&bridge.mu)
		if bridge.state == .Executing && bridge.sequence == sequence {
			cancelled :=
				bridge.discard ||
				bridge.shutdown ||
				!bridge.accepting ||
				request.generation != bridge.generation
			if cancelled {
				bridge.state = .Cancelled
				bridge.completion_ok = false
			} else {
				bridge.state = .Completed
				bridge.completion_ok = ok
				discarded = false
			}
		}
		sync.unlock(&bridge.mu)
		sync.cond_broadcast(&bridge.completed)

		result.executed += 1
		result.budget_used += cost
		if ok {
			result.succeeded += 1
		} else {
			result.failed += 1
		}
		if discarded {result.discarded += 1}
	}
	return result
}

gsw3d_bridge_snapshot :: proc(bridge: ^Gsw3d_Bridge) -> Gsw3d_Bridge_Snapshot {
	if bridge == nil {return {shutdown = true}}
	sync.lock(&bridge.mu)
	defer sync.unlock(&bridge.mu)
	return {
		state = bridge.state,
		generation = bridge.generation,
		sequence = bridge.sequence,
		accepting = bridge.accepting,
		shutdown = bridge.shutdown,
		discard = bridge.discard,
	}
}
