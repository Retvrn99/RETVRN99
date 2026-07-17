// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:sync"
import "core:testing"
import "core:time"

Gsw3d_Async_Test_Backend :: struct {
	mu:                sync.Mutex,
	executed:          sync.Sema,
	execution_entered: sync.Sema,
	release_execution: sync.Sema,
	reset_executed:    sync.Sema,
	next_token:        u64,
	execute_count:     int,
	reset_count:       int,
	cancel_count:      int,
	cancel_generation: u64,
	cancel_stopping:   bool,
	states:            [8]Gsw3d_Backend_Completion_State,
	completion_calls:  [8]int,
	zero_token_mask:   u32,
	block_execution:   int,
}

gsw3d_async_test_validate :: proc(ctx: rawptr, batch: []u8) -> bool {
	return true
}

gsw3d_async_test_execute :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Async_Test_Backend)(ctx)
	if backend == nil || work == nil {return false}
	sync.lock(&backend.mu)
	backend.next_token += 1
	execution_index := backend.execute_count
	if backend.zero_token_mask & (u32(1) << u32(execution_index)) == 0 {
		work.backend_token = backend.next_token
	}
	backend.execute_count += 1
	block := backend.block_execution == execution_index + 1
	sync.unlock(&backend.mu)
	if block {
		sync.sema_post(&backend.execution_entered)
		sync.sema_wait(&backend.release_execution)
	}
	sync.sema_post(&backend.executed)
	return true
}

gsw3d_async_test_reset :: proc(ctx: rawptr, generation: u64) -> bool {
	backend := (^Gsw3d_Async_Test_Backend)(ctx)
	if backend == nil {return false}
	sync.lock(&backend.mu)
	backend.reset_count += 1
	sync.unlock(&backend.mu)
	sync.sema_post(&backend.reset_executed)
	return true
}

gsw3d_async_test_cancel :: proc(ctx: rawptr, generation: u64, stopping: bool) {
	backend := (^Gsw3d_Async_Test_Backend)(ctx)
	if backend == nil {return}
	sync.lock(&backend.mu)
	backend.cancel_count += 1
	backend.cancel_generation = generation
	backend.cancel_stopping = stopping
	release_execution := backend.block_execution != 0
	sync.unlock(&backend.mu)
	if release_execution {sync.sema_post(&backend.release_execution)}
}

gsw3d_async_test_completion :: proc(
	ctx: rawptr,
	backend_token: u64,
) -> Gsw3d_Backend_Completion_State {
	backend := (^Gsw3d_Async_Test_Backend)(ctx)
	if backend == nil || backend_token == 0 || backend_token >= u64(len(backend.states)) {
		return .Failed
	}
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	backend.completion_calls[int(backend_token)] += 1
	return backend.states[int(backend_token)]
}

gsw3d_async_test_descriptor :: proc(
	backend: ^Gsw3d_Async_Test_Backend,
	async_cap: bool = true,
	completion_callback: bool = true,
) -> Gsw3d_Backend {
	result := Gsw3d_Backend {
		ctx            = backend,
		capabilities   = GSW3D_BACKEND_SVGA9,
		validate_svga9 = gsw3d_async_test_validate,
		execute        = gsw3d_async_test_execute,
		reset          = gsw3d_async_test_reset,
		cancel         = gsw3d_async_test_cancel,
	}
	if async_cap {result.capabilities |= GSW3D_BACKEND_ASYNC_COMPLETION}
	if completion_callback {result.completion = gsw3d_async_test_completion}
	return result
}

gsw3d_async_test_build_creates :: proc(g: ^Gsw_Vga, ram: []u8, count: int) {
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	for index in 0 ..< count {
		start := 128 + index * 24
		command := ram[start:start + 24]
		gsw3d_test_header(command, .Create_Context, u64(index + 1))
		gsw_test_wr32(command, 16, u32(index + 1))
	}
	g.three_d.ring_tail = u32(count * 24)
}

gsw3d_async_test_build_draw_between_cpu_work :: proc(g: ^Gsw_Vga, ram: []u8) {
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	render := gsw3d_triangle_fixture_render()
	copy(ram[1024:1024 + len(render)], render[:])

	region := ram[128:168]
	gsw3d_test_header(region, .Register_Region, 1)
	gsw_test_wr32(region, 16, 1)
	gsw_test_wr64(region, 24, 1024)
	gsw_test_wr64(region, 32, 512)

	create := ram[168:192]
	gsw3d_test_header(create, .Create_Context, 2)
	gsw_test_wr32(create, 16, 1)

	submit := ram[192:232]
	gsw3d_test_header(submit, .Submit, 3)
	gsw_test_wr32(submit, 16, 1)
	gsw_test_wr32(submit, 20, 1)
	gsw_test_wr64(submit, 24, 0)
	gsw_test_wr32(submit, 32, u32(len(render)))
	gsw_test_wr32(submit, 36, GSW3D_PACKET_SVGA9)

	destroy := ram[232:256]
	gsw3d_test_header(destroy, .Destroy_Context, 4)
	gsw_test_wr32(destroy, 16, 1)
	g.three_d.ring_tail = 128
}

gsw3d_async_test_wait_executed :: proc(
	t: ^testing.T,
	backend: ^Gsw3d_Async_Test_Backend,
	count: int,
) -> bool {
	for _ in 0 ..< count {
		if !testing.expect(t, sync.sema_wait_with_timeout(&backend.executed, time.Second)) {
			return false
		}
	}
	return true
}

gsw3d_async_test_wait_completion_count :: proc(t: ^testing.T, d: ^Gsw3d, expected: int) -> bool {
	for _ in 0 ..< 1000 {
		sync.lock(&d.mu)
		count := d.completion_count
		sync.unlock(&d.mu)
		if count == expected {return true}
		time.sleep(time.Millisecond)
	}
	return testing.expect(t, false, "GSW3D completion FIFO did not reach the expected count")
}

gsw3d_async_test_set_state :: proc(
	backend: ^Gsw3d_Async_Test_Backend,
	token: u64,
	state: Gsw3d_Backend_Completion_State,
) {
	if token == 0 || token >= u64(len(backend.states)) {return}
	sync.lock(&backend.mu)
	backend.states[int(token)] = state
	sync.unlock(&backend.mu)
}

gsw3d_async_test_execute_count :: proc(backend: ^Gsw3d_Async_Test_Backend) -> int {
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	return backend.execute_count
}

gsw3d_async_test_completion_calls :: proc(backend: ^Gsw3d_Async_Test_Backend, token: u64) -> int {
	if token == 0 || token >= u64(len(backend.completion_calls)) {return 0}
	sync.lock(&backend.mu)
	defer sync.unlock(&backend.mu)
	return backend.completion_calls[int(token)]
}

@(test)
gsw3d_async_test_capability_requires_completion_contract :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	backend: Gsw3d_Async_Test_Backend

	missing_callback: Gsw_Vga
	gsw_vga_init(&missing_callback, framebuffer[:])
	testing.expect(
		t,
		!gsw_vga_set_3d_backend(
			&missing_callback,
			gsw3d_async_test_descriptor(&backend, true, false),
		),
	)
	gsw_vga_destroy(&missing_callback)

	missing_capability: Gsw_Vga
	gsw_vga_init(&missing_capability, framebuffer[:])
	testing.expect(
		t,
		!gsw_vga_set_3d_backend(
			&missing_capability,
			gsw3d_async_test_descriptor(&backend, false, true),
		),
	)
	gsw_vga_destroy(&missing_capability)

	valid: Gsw_Vga
	gsw_vga_init(&valid, framebuffer[:])
	if testing.expect(t, gsw_vga_set_3d_backend(&valid, gsw3d_async_test_descriptor(&backend))) {
		testing.expect(t, valid.capabilities & GSW_CAP_ASYNC_FENCES != 0)
	}
	gsw_vga_destroy(&valid)
}

@(test)
gsw3d_async_test_out_of_order_completion_cannot_overtake :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Async_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	gsw3d_async_test_build_creates(&g, ram[:], 2)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	if !gsw3d_async_test_wait_executed(t, &backend, 2) ||
	   !gsw3d_async_test_wait_completion_count(t, &g.three_d, 2) {return}

	gsw3d_poll(&g.three_d)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_BUSY != 0)
	testing.expect(t, !gsw3d_wait_idle(&g.three_d, time.Millisecond))
	gsw3d_async_test_set_state(&backend, 2, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect(t, g.three_d.status & GSW3D_STATUS_BUSY != 0)

	gsw3d_async_test_set_state(&backend, 1, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(2))
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
	testing.expect(t, g.three_d.status & GSW3D_STATUS_BUSY == 0)
}

@(test)
gsw3d_async_test_zero_token_cpu_work_orders_around_pending_gpu_work :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 2048)
	defer delete(ram)
	backend := Gsw3d_Async_Test_Backend {
		zero_token_mask = (1 << 0) | (1 << 2),
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	gsw3d_async_test_build_draw_between_cpu_work(&g, ram)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !gsw3d_async_test_wait_executed(t, &backend, 3) ||
	   !gsw3d_async_test_wait_completion_count(t, &g.three_d, 4) {return}

	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(2))
	testing.expect(t, !g.three_d.poisoned)

	gsw3d_async_test_set_state(&backend, 2, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(4))
	testing.expect(t, !g.three_d.poisoned)
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
}

@(test)
gsw3d_async_test_full_completion_fifo_backpressures_without_poison :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Async_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	sync.lock(&g.three_d.mu)
	g.three_d.completion_count = GSW3D_COMPLETION_FIFO_CAPACITY
	g.three_d.completion_tail = 0
	sync.unlock(&g.three_d.mu)

	gsw3d_async_test_build_creates(&g, ram[:], 1)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	testing.expect(t, !sync.sema_wait_with_timeout(&backend.executed, 10 * time.Millisecond))
	testing.expect_value(t, gsw3d_async_test_execute_count(&backend), 0)
	testing.expect(t, !g.three_d.poisoned)

	sync.lock(&g.three_d.mu)
	g.three_d.completion_count = GSW3D_COMPLETION_FIFO_CAPACITY - 1
	g.three_d.completion_tail = GSW3D_COMPLETION_FIFO_CAPACITY - 1
	sync.unlock(&g.three_d.mu)
	sync.cond_broadcast(&g.three_d.work_ready)
	if !gsw3d_async_test_wait_executed(t, &backend, 1) {return}
	if !gsw3d_async_test_wait_completion_count(
		t,
		&g.three_d,
		GSW3D_COMPLETION_FIFO_CAPACITY,
	) {return}
	testing.expect_value(t, gsw3d_async_test_execute_count(&backend), 1)
	testing.expect(t, !g.three_d.poisoned)
}

@(test)
gsw3d_async_test_reset_discards_stale_completion :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Async_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	gsw3d_async_test_build_creates(&g, ram[:], 1)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	if !gsw3d_async_test_wait_executed(t, &backend, 1) ||
	   !gsw3d_async_test_wait_completion_count(t, &g.three_d, 1) {return}

	gsw3d_reset(&g.three_d)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.reset_executed, time.Second)) ||
	   !gsw3d_async_test_wait_completion_count(t, &g.three_d, 1) {return}
	gsw3d_async_test_set_state(&backend, 1, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, gsw3d_async_test_completion_calls(&backend, 1), 0)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect(t, !g.three_d.reset_pending)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_READY != 0)
	testing.expect_value(t, backend.cancel_generation, u64(1))
}

@(test)
gsw3d_async_test_failure_waits_for_fifo_head_and_suppresses_later_fences :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Async_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	gsw3d_async_test_build_creates(&g, ram[:], 3)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	if !gsw3d_async_test_wait_executed(t, &backend, 3) ||
	   !gsw3d_async_test_wait_completion_count(t, &g.three_d, 3) {return}

	gsw3d_async_test_set_state(&backend, 2, .Failed)
	gsw3d_poll(&g.three_d)
	testing.expect(t, !g.three_d.poisoned)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect_value(t, gsw3d_async_test_execute_count(&backend), 3)

	gsw3d_async_test_set_state(&backend, 1, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect(t, g.three_d.poisoned)
	testing.expect_value(t, g.three_d.completed_fence, u64(1))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Backend_Failure)
	testing.expect_value(t, g.three_d.metrics.backend_failures, u64(1))
	testing.expect_value(t, gsw3d_async_test_execute_count(&backend), 3)
	testing.expect_value(t, g.three_d.queue_count, 0)

	gsw3d_async_test_set_state(&backend, 3, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(1))
}

@(test)
gsw3d_async_test_failure_discards_active_later_work_completion :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend := Gsw3d_Async_Test_Backend {
		block_execution = 3,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_async_test_descriptor(&backend))) {
		return
	}
	gsw3d_async_test_build_creates(&g, ram[:], 3)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	if !gsw3d_async_test_wait_executed(t, &backend, 2) ||
	   !testing.expect(t, sync.sema_wait_with_timeout(&backend.execution_entered, time.Second)) {
		return
	}

	gsw3d_async_test_set_state(&backend, 1, .Failed)
	gsw3d_poll(&g.three_d)
	testing.expect(t, g.three_d.poisoned)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect_value(t, g.three_d.completion_count, 0)

	sync.sema_post(&backend.release_execution)
	if !gsw3d_async_test_wait_executed(t, &backend, 1) {return}
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
	gsw3d_async_test_set_state(&backend, 3, .Complete)
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect_value(t, g.three_d.completion_count, 0)
}
