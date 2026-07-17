// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:sync"
import "core:testing"
import "core:time"

Gsw3d_Test_Backend :: struct {
	submit_entered:  sync.Sema,
	release_submit:  sync.Sema,
	create_entered:  sync.Sema,
	release_create:  sync.Sema,
	block_create:    bool,
	submitted:       [32]u8,
	submitted_bytes: int,
	work_count:      int,
	reset_count:     int,
}

gsw3d_test_backend_validate :: proc(ctx: rawptr, batch: []u8) -> bool {
	return true
}

gsw3d_test_backend_reset :: proc(ctx: rawptr) -> bool {
	backend := (^Gsw3d_Test_Backend)(ctx)
	backend.reset_count += 1
	return true
}

gsw3d_test_backend_execute :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Test_Backend)(ctx)
	backend.work_count += 1
	if work.kind == .Create_Context && backend.block_create {
		sync.sema_post(&backend.create_entered)
		sync.sema_wait(&backend.release_create)
	}
	if work.kind == .Submit_Svga9 {
		sync.sema_post(&backend.submit_entered)
		sync.sema_wait(&backend.release_submit)
		backend.submitted_bytes = min(len(work.batch), len(backend.submitted))
		copy(backend.submitted[:backend.submitted_bytes], work.batch[:backend.submitted_bytes])
	}
	return true
}

@(test)
gsw3d_test_transport_fence_cannot_overtake_queued_backend_work :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend := Gsw3d_Test_Backend {
		block_create = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(
		t,
		gsw_vga_set_3d_backend(
			&g,
			{
				ctx = &backend,
				capabilities = GSW3D_BACKEND_SVGA9,
				validate_svga9 = gsw3d_test_backend_validate,
				execute = gsw3d_test_backend_execute,
				reset = gsw3d_test_backend_reset,
			},
		),
	) {return}
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	create := ram[128:152]
	gsw3d_test_header(create, .Create_Context, 10)
	gsw_test_wr32(create, 16, 1)
	region := ram[152:192]
	gsw3d_test_header(region, .Register_Region, 11)
	gsw_test_wr32(region, 16, 1)
	gsw_test_wr64(region, 24, 1024)
	gsw_test_wr64(region, 32, 64)
	g.three_d.ring_tail = 64
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.create_entered, time.Second)) {
		sync.sema_post(&backend.release_create)
		return
	}
	gsw_vga_poll(&g)
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	sync.sema_post(&backend.release_create)
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
	gsw_vga_poll(&g)
	testing.expect_value(t, g.three_d.completed_fence, u64(11))
}

gsw3d_test_header :: proc(data: []u8, opcode: Gsw3d_Opcode, fence: u64) {
	gsw_test_wr16(data, 0, u16(opcode))
	gsw_test_wr16(data, 2, GSW3D_COMMAND_VERSION)
	gsw_test_wr32(data, 4, u32(len(data)))
	gsw_test_wr64(data, 8, fence)
}

gsw3d_test_wait_for_submit :: proc(t: ^testing.T, backend: ^Gsw3d_Test_Backend) -> bool {
	return testing.expect(
		t,
		sync.sema_wait_with_timeout(&backend.submit_entered, time.Second),
		"GSW3D worker did not reach the submitted batch",
	)
}

gsw3d_test_release_submit :: proc(backend: ^Gsw3d_Test_Backend) {
	sync.sema_post(&backend.release_submit)
}

gsw3d_test_build_submission :: proc(g: ^Gsw_Vga, ram: []u8) {
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	batch := ram[1024:1044]
	gsw_test_wr32(batch, 0, 1061)
	gsw_test_wr32(batch, 4, 12)
	gsw_test_wr32(batch, 8, 1)
	gsw_test_wr32(batch, 12, 1)
	gsw_test_wr32(batch, 16, 7)

	region := ram[128:168]
	gsw3d_test_header(region, .Register_Region, 1)
	gsw_test_wr32(region, 16, 1)
	gsw_test_wr64(region, 24, 1024)
	gsw_test_wr64(region, 32, 256)
	context_command := ram[168:192]
	gsw3d_test_header(context_command, .Create_Context, 2)
	gsw_test_wr32(context_command, 16, 1)
	submit := ram[192:232]
	gsw3d_test_header(submit, .Submit, 3)
	gsw_test_wr32(submit, 16, 1)
	gsw_test_wr32(submit, 20, 1)
	gsw_test_wr64(submit, 24, 0)
	gsw_test_wr32(submit, 32, 20)
	gsw_test_wr32(submit, 36, GSW3D_PACKET_SVGA9)
	g.three_d.ring_tail = 104
}

@(test)
gsw3d_test_svga9_whitelist_rejects_unadvertised_commands :: proc(t: ^testing.T) {
	allowed: [20]u8
	gsw_test_wr32(allowed[:], 0, 1061)
	gsw_test_wr32(allowed[:], 4, 12)
	gsw_test_wr32(allowed[:], 8, 1)
	testing.expect(t, gsw3d_validate_svga9_batch(allowed[:]))

	query := allowed
	gsw_test_wr32(query[:], 0, 1065)
	testing.expect(t, !gsw3d_validate_svga9_batch(query[:]))
	present := allowed
	gsw_test_wr32(present[:], 0, 1058)
	testing.expect(t, !gsw3d_validate_svga9_batch(present[:]))
	dma := allowed
	gsw_test_wr32(dma[:], 0, 1044)
	testing.expect(t, !gsw3d_validate_svga9_batch(dma[:]))
	truncated := allowed
	gsw_test_wr32(truncated[:], 4, 16)
	testing.expect(t, !gsw3d_validate_svga9_batch(truncated[:]))
	undersized_draw := allowed
	gsw_test_wr32(undersized_draw[:], 0, 1063)
	testing.expect(t, !gsw3d_validate_svga9_batch(undersized_draw[:]))
}

@(test)
gsw3d_test_submission_is_copied_before_worker_parse :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend: Gsw3d_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	testing.expect(
		t,
		gsw_vga_set_3d_backend(
			&g,
			{
				ctx = &backend,
				capabilities = GSW3D_BACKEND_SVGA9 | GSW3D_BACKEND_DIRECT_PRESENT,
				present_intervals = GSW3D_PRESENT_INTERVAL_MASK,
				validate_svga9 = gsw3d_test_backend_validate,
				execute = gsw3d_test_backend_execute,
				reset = gsw3d_test_backend_reset,
			},
		),
	)
	testing.expect(t, g.capabilities & GSW_CAP_3D_SVGA9 != 0)
	testing.expect(t, g.capabilities & GSW_CAP_DIRECT_PRESENT != 0)
	testing.expect(t, g.capabilities & GSW_CAP_ASYNC_FENCES == 0)
	gsw3d_test_build_submission(&g, ram)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect_value(t, g.three_d.error, Gsw3d_Error.None) {return}
	if !testing.expect_value(t, g.three_d.ring_head, u32(104)) {return}
	if !gsw3d_test_wait_for_submit(t, &backend) {gsw3d_test_release_submit(&backend); return}
	gsw_test_wr32(ram[1024:1044], 0, 0xFFFF_FFFF)
	gsw3d_test_release_submit(&backend)
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
	gsw_vga_poll(&g)

	testing.expect_value(t, gsw_rd32(backend.submitted[:], 0), u32(1061))
	testing.expect_value(t, backend.submitted_bytes, 20)
	testing.expect_value(t, g.three_d.completed_fence, u64(3))
	testing.expect_value(t, g.three_d.metrics.batch_bytes, u64(20))
}

@(test)
gsw3d_test_reset_ignores_in_flight_completion :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend: Gsw3d_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(
		t,
		gsw_vga_set_3d_backend(
			&g,
			{
				ctx = &backend,
				capabilities = GSW3D_BACKEND_SVGA9,
				validate_svga9 = gsw3d_test_backend_validate,
				execute = gsw3d_test_backend_execute,
				reset = gsw3d_test_backend_reset,
			},
		),
	) {return}
	gsw3d_test_build_submission(&g, ram)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect_value(t, g.three_d.error, Gsw3d_Error.None) {return}
	if !testing.expect_value(t, g.three_d.ring_head, u32(104)) {return}
	if !gsw3d_test_wait_for_submit(t, &backend) {gsw3d_test_release_submit(&backend); return}
	gsw3d_reset(&g.three_d)
	gsw3d_test_release_submit(&backend)
	testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second))
	testing.expect(t, !gsw3d_poll(&g.three_d))
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect(t, gsw3d_find_context(&g.three_d, 1) == nil)
	testing.expect_value(t, g.three_d.ring_head, g.three_d.ring_tail)
	testing.expect_value(t, backend.reset_count, 1)
}
