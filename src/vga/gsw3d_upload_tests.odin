// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:bytes"
import "core:sync"
import "core:testing"
import "core:time"

Gsw3d_Upload_Test_Backend :: struct {
	submit_entered:     sync.Sema,
	release_submit:     sync.Sema,
	create_entered:     sync.Sema,
	release_create:     sync.Sema,
	block_submit:       bool,
	block_create:       bool,
	fail_submit:        bool,
	fail_reset:         bool,
	work_kinds:         [16]Gsw3d_Work_Kind,
	work_count:         int,
	upload_count:       int,
	reset_count:        int,
	resource_id:        u32,
	region_id:          u32,
	source_offset:      u64,
	destination_offset: u64,
	uploaded:           [64]u8,
	uploaded_bytes:     int,
}

gsw3d_upload_test_validate :: proc(ctx: rawptr, batch: []u8) -> bool {
	return true
}

gsw3d_upload_test_resource_size :: proc(
	ctx: rawptr,
	format, width, height, depth: u32,
) -> (
	u64,
	bool,
) {
	bytes_per_element: u64
	switch format {
	case 1:
		bytes_per_element = 4
	case 37:
		bytes_per_element = 1
	case:
		return 0, false
	}
	size := u128(width) * u128(height) * u128(depth) * u128(bytes_per_element)
	if width == 0 || height == 0 || depth == 0 || size > u128(~u64(0)) {return 0, false}
	return u64(size), true
}

gsw3d_upload_test_record :: proc(backend: ^Gsw3d_Upload_Test_Backend, kind: Gsw3d_Work_Kind) {
	if backend.work_count < len(backend.work_kinds) {
		backend.work_kinds[backend.work_count] = kind
	}
	backend.work_count += 1
}

gsw3d_upload_test_execute :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Upload_Test_Backend)(ctx)
	gsw3d_upload_test_record(backend, work.kind)
	if work.kind == .Create_Context && backend.block_create {
		sync.sema_post(&backend.create_entered)
		sync.sema_wait(&backend.release_create)
	}
	if work.kind == .Submit_Svga9 && backend.block_submit {
		sync.sema_post(&backend.submit_entered)
		sync.sema_wait(&backend.release_submit)
	}
	if work.kind == .Submit_Svga9 && backend.fail_submit {return false}
	return true
}

gsw3d_upload_test_upload :: proc(ctx: rawptr, work: ^Gsw3d_Work) -> bool {
	backend := (^Gsw3d_Upload_Test_Backend)(ctx)
	gsw3d_upload_test_record(backend, work.kind)
	backend.upload_count += 1
	backend.resource_id = work.resource_id
	backend.region_id = work.region_id
	backend.source_offset = work.source_offset
	backend.destination_offset = work.destination_offset
	backend.uploaded_bytes = min(len(work.upload), len(backend.uploaded))
	copy(backend.uploaded[:backend.uploaded_bytes], work.upload[:backend.uploaded_bytes])
	return true
}

gsw3d_upload_test_reset :: proc(ctx: rawptr) -> bool {
	backend := (^Gsw3d_Upload_Test_Backend)(ctx)
	backend.reset_count += 1
	return !backend.fail_reset
}

gsw3d_upload_test_backend :: proc(
	backend: ^Gsw3d_Upload_Test_Backend,
	with_upload: bool = true,
) -> Gsw3d_Backend {
	result := Gsw3d_Backend {
		ctx            = backend,
		capabilities   = GSW3D_BACKEND_SVGA9,
		validate_svga9 = gsw3d_upload_test_validate,
		execute        = gsw3d_upload_test_execute,
		reset          = gsw3d_upload_test_reset,
	}
	if with_upload {
		result.capabilities |= GSW3D_BACKEND_RESOURCE_UPLOAD
		result.upload = gsw3d_upload_test_upload
		result.resource_size = gsw3d_upload_test_resource_size
	}
	return result
}

gsw3d_upload_test_descriptor :: proc(
	data: []u8,
	fence: u64,
	resource_id, region_id: u32,
	source_offset, destination_offset: u64,
	length: u32,
) {
	gsw3d_test_header(data, .Resource_Upload, fence)
	gsw_test_wr32(data, 16, resource_id)
	gsw_test_wr32(data, 20, region_id)
	gsw_test_wr64(data, 24, source_offset)
	gsw_test_wr64(data, 32, destination_offset)
	gsw_test_wr32(data, 40, length)
}

gsw3d_upload_test_define_surface :: proc(batch: []u8, resource_id: u32) {
	gsw_test_wr32(batch, 0, 1070)
	gsw_test_wr32(batch, 4, 56)
	gsw_test_wr32(batch, 8, resource_id)
	gsw_test_wr32(batch, 16, 1)
	gsw_test_wr32(batch, 20, 1)
	gsw_test_wr32(batch, 52, 128)
	gsw_test_wr32(batch, 56, 1)
	gsw_test_wr32(batch, 60, 1)
}

gsw3d_upload_test_build_define_and_upload :: proc(g: ^Gsw_Vga, ram: []u8, payload: []u8) {
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	gsw3d_upload_test_define_surface(ram[1024:1088], 9)
	copy(ram[1152:1152 + len(payload)], payload)

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
	gsw_test_wr32(submit, 32, 64)
	gsw_test_wr32(submit, 36, GSW3D_PACKET_SVGA9)
	gsw3d_upload_test_descriptor(ram[232:280], 4, 9, 1, 128, 256, u32(len(payload)))
	g.three_d.ring_tail = 152
}

gsw3d_upload_test_ring_write :: proc(
	ram: []u8,
	ring_gpa: u64,
	ring_size, offset: u32,
	data: []u8,
) {
	first := min(len(data), int(ring_size - offset))
	start := int(ring_gpa + u64(offset))
	copy(ram[start:start + first], data[:first])
	if first < len(data) {
		base := int(ring_gpa)
		copy(ram[base:base + len(data) - first], data[first:])
	}
}

gsw3d_upload_test_process_descriptor :: proc(g: ^Gsw_Vga, ram, descriptor: []u8) {
	for &value in ram[:256] {value = 0}
	copy(ram[:len(descriptor)], descriptor)
	g.three_d.ring_gpa = 0
	g.three_d.ring_size = 256
	g.three_d.ring_head = 0
	g.three_d.ring_tail = u32(len(descriptor))
	g.three_d.error = .None
	g.three_d.status &~= GSW3D_STATUS_ERROR | GSW3D_STATUS_QUEUE_FULL
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
}

@(test)
gsw3d_upload_test_new_error_preserves_v1_error_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(Gsw3d_Error.Invalid_Batch), u32(5))
	testing.expect_value(t, u32(Gsw3d_Error.Backend_Failure), u32(9))
	testing.expect_value(t, u32(Gsw3d_Error.Invalid_Resource), u32(10))
}

@(test)
gsw3d_upload_test_capability_requires_callback_and_bit :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	backend: Gsw3d_Upload_Test_Backend

	missing_callback: Gsw_Vga
	gsw_vga_init(&missing_callback, framebuffer[:])
	defer gsw_vga_destroy(&missing_callback)
	without_callback := gsw3d_upload_test_backend(&backend, false)
	without_callback.capabilities |= GSW3D_BACKEND_RESOURCE_UPLOAD
	testing.expect(t, !gsw_vga_set_3d_backend(&missing_callback, without_callback))
	testing.expect(t, missing_callback.capabilities & GSW_CAP_RESOURCE_UPLOAD == 0)

	missing_size_callback: Gsw_Vga
	gsw_vga_init(&missing_size_callback, framebuffer[:])
	defer gsw_vga_destroy(&missing_size_callback)
	without_size := gsw3d_upload_test_backend(&backend)
	without_size.resource_size = nil
	testing.expect(t, !gsw_vga_set_3d_backend(&missing_size_callback, without_size))
	testing.expect(t, missing_size_callback.capabilities & GSW_CAP_RESOURCE_UPLOAD == 0)

	missing_bit: Gsw_Vga
	gsw_vga_init(&missing_bit, framebuffer[:])
	defer gsw_vga_destroy(&missing_bit)
	without_bit := gsw3d_upload_test_backend(&backend)
	without_bit.capabilities &~= GSW3D_BACKEND_RESOURCE_UPLOAD
	testing.expect(t, !gsw_vga_set_3d_backend(&missing_bit, without_bit))
	testing.expect(t, missing_bit.capabilities & GSW_CAP_RESOURCE_UPLOAD == 0)

	base_only: Gsw_Vga
	gsw_vga_init(&base_only, framebuffer[:])
	defer gsw_vga_destroy(&base_only)
	testing.expect(
		t,
		gsw_vga_set_3d_backend(&base_only, gsw3d_upload_test_backend(&backend, false)),
	)
	testing.expect(t, base_only.capabilities & GSW_CAP_RESOURCE_UPLOAD == 0)
	capabilities, _ := gsw3d_register_read(&base_only.three_d, GSW3D_REG_CAPABILITIES)
	testing.expect(t, capabilities & GSW3D_BACKEND_RESOURCE_UPLOAD == 0)

	ram: [256]u8
	base_only.three_d.resources[0] = {
		live = true,
		id   = 9,
	}
	base_only.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 128,
		size = 8,
	}
	descriptor: [48]u8
	gsw3d_upload_test_descriptor(descriptor[:], 1, 9, 1, 0, 0, 8)
	copy(ram[:len(descriptor)], descriptor[:])
	base_only.three_d.ring_gpa = 0
	base_only.three_d.ring_size = 256
	base_only.three_d.ring_tail = u32(len(descriptor))
	_ = gsw3d_register_write(&base_only.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	testing.expect_value(t, base_only.three_d.ring_head, u32(0))
	testing.expect_value(t, base_only.three_d.error, Gsw3d_Error.Backend_Unavailable)
}

@(test)
gsw3d_upload_test_snapshots_payload_and_orders_resource_lifetime :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend := Gsw3d_Upload_Test_Backend {
		block_submit = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	testing.expect(t, g.capabilities & GSW_CAP_RESOURCE_UPLOAD != 0)
	capabilities, _ := gsw3d_register_read(&g.three_d, GSW3D_REG_CAPABILITIES)
	testing.expect(t, capabilities & GSW3D_BACKEND_RESOURCE_UPLOAD != 0)

	payload := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	gsw3d_upload_test_build_define_and_upload(&g, ram, payload[:])
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.submit_entered, time.Second)) {
		sync.sema_post(&backend.release_submit)
		return
	}
	for &value in ram[1152:1160] {value = 0xFF}
	sync.sema_post(&backend.release_submit)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	testing.expect_value(t, backend.upload_count, 1)
	testing.expect_value(t, backend.resource_id, u32(9))
	testing.expect_value(t, backend.region_id, u32(1))
	testing.expect_value(t, backend.source_offset, u64(128))
	testing.expect_value(t, backend.destination_offset, u64(256))
	testing.expect_value(t, backend.uploaded_bytes, len(payload))
	testing.expect(t, bytes.equal(backend.uploaded[:len(payload)], payload[:]))
	testing.expect_value(t, backend.work_kinds[0], Gsw3d_Work_Kind.Create_Context)
	testing.expect_value(t, backend.work_kinds[1], Gsw3d_Work_Kind.Submit_Svga9)
	testing.expect_value(t, backend.work_kinds[2], Gsw3d_Work_Kind.Resource_Upload)
	resource := gsw3d_find_resource(&g.three_d, 9)
	testing.expect(t, resource != nil)
	if resource != nil {testing.expect_value(t, resource.size, u64(512))}
	testing.expect_value(t, g.three_d.completed_fence, u64(4))
	testing.expect_value(t, g.three_d.metrics.uploads, u64(1))
	testing.expect_value(t, g.three_d.metrics.upload_bytes, u64(len(payload)))
	testing.expect_value(t, g.three_d.owned_work_bytes, u64(0))
}

@(test)
gsw3d_upload_test_rejects_malformed_and_out_of_range_descriptors :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
		size = 64,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 256,
		size = 16,
	}

	truncated: [44]u8
	gsw3d_upload_test_descriptor(truncated[:], 1, 9, 1, 0, 0, 8)
	gsw3d_upload_test_process_descriptor(&g, ram[:], truncated[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Malformed_Descriptor)

	base: [48]u8
	gsw3d_upload_test_descriptor(base[:], 1, 9, 1, 0, 0, 8)
	reserved := base
	gsw_test_wr32(reserved[:], 44, 1)
	gsw3d_upload_test_process_descriptor(&g, ram[:], reserved[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Malformed_Descriptor)

	zero_resource := base
	gsw_test_wr32(zero_resource[:], 16, 0)
	gsw3d_upload_test_process_descriptor(&g, ram[:], zero_resource[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)

	stale_resource := base
	gsw_test_wr32(stale_resource[:], 16, 10)
	gsw3d_upload_test_process_descriptor(&g, ram[:], stale_resource[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)

	stale_region := base
	gsw_test_wr32(stale_region[:], 20, 2)
	gsw3d_upload_test_process_descriptor(&g, ram[:], stale_region[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Region)

	zero_length := base
	gsw_test_wr32(zero_length[:], 40, 0)
	gsw3d_upload_test_process_descriptor(&g, ram[:], zero_length[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Region)

	oversized := base
	gsw_test_wr32(oversized[:], 40, GSW3D_MAX_RESOURCE_UPLOAD_BYTES + 1)
	gsw3d_upload_test_process_descriptor(&g, ram[:], oversized[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Region)

	bad_source := base
	gsw_test_wr64(bad_source[:], 24, 15)
	gsw_test_wr32(bad_source[:], 40, 2)
	gsw3d_upload_test_process_descriptor(&g, ram[:], bad_source[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Region)

	bad_destination := base
	gsw_test_wr64(bad_destination[:], 32, ~u64(0))
	gsw3d_upload_test_process_descriptor(&g, ram[:], bad_destination[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)

	out_of_resource := base
	gsw_test_wr64(out_of_resource[:], 32, 60)
	gsw3d_upload_test_process_descriptor(&g, ram[:], out_of_resource[:])
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)
	testing.expect_value(t, backend.upload_count, 0)
}

@(test)
gsw3d_upload_test_surface_extent_must_match_backend_format :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	payload := [?]u8{1, 2, 3, 4}
	gsw3d_upload_test_build_define_and_upload(&g, ram, payload[:])
	gsw_test_wr32(ram[1024:1088], 16, 99)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	testing.expect_value(t, g.three_d.ring_head, u32(64))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)
	testing.expect(t, gsw3d_find_resource(&g.three_d, 9) == nil)
	testing.expect_value(t, backend.work_count, 1)
	testing.expect_value(t, backend.work_kinds[0], Gsw3d_Work_Kind.Create_Context)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, g.three_d.completed_fence, u64(2))
}

@(test)
gsw3d_upload_test_descriptor_wraps_and_preserves_numeric_fields :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 2048)
	defer delete(ram)
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.resources[0] = {
		live = true,
		id   = 17,
		size = 0x1234_5680,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 5,
		gpa  = 1024,
		size = 16,
	}
	payload := [?]u8{9, 8, 7, 6, 5, 4}
	copy(ram[1027:1033], payload[:])

	descriptor: [48]u8
	gsw3d_upload_test_descriptor(descriptor[:], 7, 17, 5, 3, 0x1234_5678, u32(len(payload)))
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256
	g.three_d.ring_head = 240
	g.three_d.ring_tail = 32
	gsw3d_upload_test_ring_write(ram, 128, 256, 240, descriptor[:])
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	testing.expect_value(t, g.three_d.error, Gsw3d_Error.None)
	testing.expect_value(t, g.three_d.ring_head, u32(32))
	testing.expect_value(t, g.three_d.completed_fence, u64(7))
	testing.expect_value(t, backend.upload_count, 1)
	testing.expect_value(t, backend.resource_id, u32(17))
	testing.expect_value(t, backend.region_id, u32(5))
	testing.expect_value(t, backend.source_offset, u64(3))
	testing.expect_value(t, backend.destination_offset, u64(0x1234_5678))
	testing.expect(t, bytes.equal(backend.uploaded[:len(payload)], payload[:]))
}

@(test)
gsw3d_upload_test_stale_region_rejected_after_zero_fence_lifetime_barrier :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 2048)
	defer delete(ram)
	backend := Gsw3d_Upload_Test_Backend {
		block_create = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
		size = 16,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 1024,
		size = 16,
	}
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256

	create := ram[128:152]
	gsw3d_test_header(create, .Create_Context, 1)
	gsw_test_wr32(create, 16, 1)
	unregister := ram[152:176]
	gsw3d_test_header(unregister, .Unregister_Region, 0)
	gsw_test_wr32(unregister, 16, 1)
	gsw3d_upload_test_descriptor(ram[176:224], 2, 9, 1, 0, 0, 4)
	g.three_d.ring_tail = 96
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.create_entered, time.Second)) {
		sync.sema_post(&backend.release_create)
		return
	}

	sync.lock(&g.three_d.mu)
	queued := g.three_d.queue_count
	queued_kind := g.three_d.queue[g.three_d.queue_head].kind
	sync.unlock(&g.three_d.mu)
	testing.expect_value(t, queued, 1)
	testing.expect_value(t, queued_kind, Gsw3d_Work_Kind.Transport_Barrier)
	testing.expect_value(t, g.three_d.ring_head, u32(48))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Region)
	testing.expect(t, !g.three_d.regions[0].live)

	sync.sema_post(&backend.release_create)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, g.three_d.completed_fence, u64(1))
}

@(test)
gsw3d_upload_test_stale_resource_rejected_after_ordered_destroy :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 2048)
	defer delete(ram)
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.contexts[0] = {
		live = true,
		id   = 1,
	}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
		size = 64,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 1024,
		size = 64,
	}
	g.three_d.ring_gpa = 128
	g.three_d.ring_size = 256

	gsw_test_wr32(ram[1024:1036], 0, 1041)
	gsw_test_wr32(ram[1024:1036], 4, 4)
	gsw_test_wr32(ram[1024:1036], 8, 9)
	submit := ram[128:168]
	gsw3d_test_header(submit, .Submit, 1)
	gsw_test_wr32(submit, 16, 1)
	gsw_test_wr32(submit, 20, 1)
	gsw_test_wr64(submit, 24, 0)
	gsw_test_wr32(submit, 32, 12)
	gsw_test_wr32(submit, 36, GSW3D_PACKET_SVGA9)
	gsw3d_upload_test_descriptor(ram[168:216], 2, 9, 1, 16, 0, 4)
	g.three_d.ring_tail = 88
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	testing.expect_value(t, g.three_d.ring_head, u32(40))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Invalid_Resource)
	testing.expect(t, gsw3d_find_resource(&g.three_d, 9) == nil)
	testing.expect_value(t, backend.work_count, 1)
	testing.expect_value(t, backend.work_kinds[0], Gsw3d_Work_Kind.Submit_Svga9)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, g.three_d.owned_work_bytes, u64(0))
}

@(test)
gsw3d_upload_test_reset_cancels_queued_snapshot_and_clears_lifetimes :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend := Gsw3d_Upload_Test_Backend {
		block_submit = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	payload := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	gsw3d_upload_test_build_define_and_upload(&g, ram, payload[:])
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.submit_entered, time.Second)) {
		sync.sema_post(&backend.release_submit)
		return
	}

	sync.lock(&g.three_d.mu)
	owned_before_reset := g.three_d.owned_work_bytes
	queued_before_reset := g.three_d.queue_count
	queued_kind := g.three_d.queue[g.three_d.queue_head].kind
	sync.unlock(&g.three_d.mu)
	testing.expect_value(t, owned_before_reset, u64(64 + len(payload)))
	testing.expect_value(t, queued_before_reset, 1)
	testing.expect_value(t, queued_kind, Gsw3d_Work_Kind.Resource_Upload)

	gsw3d_reset(&g.three_d)
	sync.lock(&g.three_d.mu)
	owned_after_cancel := g.three_d.owned_work_bytes
	queued_after_reset := g.three_d.queue_count
	reset_kind := g.three_d.queue[g.three_d.queue_head].kind
	sync.unlock(&g.three_d.mu)
	testing.expect_value(t, owned_after_cancel, u64(64))
	testing.expect_value(t, queued_after_reset, 1)
	testing.expect_value(t, reset_kind, Gsw3d_Work_Kind.Reset)
	testing.expect(t, gsw3d_find_resource(&g.three_d, 9) == nil)
	testing.expect(t, !g.three_d.regions[0].live)
	testing.expect(t, gsw3d_find_context(&g.three_d, 1) == nil)

	sync.sema_post(&backend.release_submit)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, backend.reset_count, 1)
	testing.expect_value(t, g.three_d.owned_work_bytes, u64(0))
	testing.expect_value(t, g.three_d.completed_fence, u64(0))
	testing.expect_value(t, g.three_d.ring_head, g.three_d.ring_tail)
}

@(test)
gsw3d_upload_test_snapshot_counts_toward_owned_memory_cap :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
		size = 4,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 256,
		size = 4,
	}
	descriptor: [48]u8
	gsw3d_upload_test_descriptor(descriptor[:], 1, 9, 1, 0, 0, 4)
	g.three_d.owned_work_bytes = GSW3D_MAX_QUEUED_OWNED_BYTES - 3
	gsw3d_upload_test_process_descriptor(&g, ram[:], descriptor[:])

	testing.expect_value(t, g.three_d.ring_head, u32(0))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Queue_Full)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_QUEUE_FULL != 0)
	testing.expect_value(t, g.three_d.queue_count, 0)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, g.three_d.metrics.uploads, u64(0))
	testing.expect_value(t, g.three_d.owned_work_bytes, GSW3D_MAX_QUEUED_OWNED_BYTES - 3)
	g.three_d.owned_work_bytes = 0
}

@(test)
gsw3d_upload_test_queue_full_error_clears_before_retry_and_validation :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [512]u8
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
		size = 4,
	}
	g.three_d.regions[0] = {
		live = true,
		id   = 1,
		gpa  = 256,
		size = 4,
	}
	payload := [4]u8{1, 2, 3, 4}
	copy(ram[256:260], payload[:])
	gsw3d_upload_test_descriptor(ram[:48], 1, 9, 1, 0, 0, 4)
	g.three_d.ring_gpa = 0
	g.three_d.ring_size = 256
	g.three_d.ring_tail = 48
	g.three_d.owned_work_bytes = GSW3D_MAX_QUEUED_OWNED_BYTES - 3

	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	testing.expect_value(t, g.three_d.ring_head, u32(0))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Queue_Full)

	g.three_d.owned_work_bytes = 0
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.ring_head, u32(48))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.None)
	testing.expect_value(t, backend.upload_count, 1)

	malformed := ram[48:64]
	for &value in malformed {value = 0}
	gsw3d_test_header(malformed, .Resource_Upload, 2)
	g.three_d.ring_tail = 64
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram[:])
	testing.expect_value(t, g.three_d.ring_head, u32(48))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Malformed_Descriptor)
}

@(test)
gsw3d_upload_test_backend_failure_poison_requires_successful_reset :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram := make([]u8, 4096)
	defer delete(ram)
	backend := Gsw3d_Upload_Test_Backend {
		block_submit = true,
		fail_submit  = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}
	payload := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	gsw3d_upload_test_build_define_and_upload(&g, ram, payload[:])
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	if !testing.expect(t, sync.sema_wait_with_timeout(&backend.submit_entered, time.Second)) {
		sync.sema_post(&backend.release_submit)
		return
	}
	sync.sema_post(&backend.release_submit)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)

	testing.expect_value(t, backend.work_count, 2)
	testing.expect_value(t, backend.work_kinds[0], Gsw3d_Work_Kind.Create_Context)
	testing.expect_value(t, backend.work_kinds[1], Gsw3d_Work_Kind.Submit_Svga9)
	testing.expect_value(t, backend.upload_count, 0)
	testing.expect_value(t, g.three_d.owned_work_bytes, u64(0))
	testing.expect_value(t, g.three_d.completed_fence, u64(2))
	testing.expect_value(t, g.three_d.metrics.backend_failures, u64(1))
	testing.expect(t, g.three_d.poisoned)
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Backend_Failure)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_ERROR != 0)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_READY == 0)

	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_STATUS, GSW3D_STATUS_ERROR, ram)
	testing.expect(t, g.three_d.poisoned)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_ERROR != 0)

	head_before := g.three_d.ring_head
	create: [24]u8
	gsw3d_test_header(create[:], .Create_Context, 5)
	gsw_test_wr32(create[:], 16, 2)
	gsw3d_upload_test_ring_write(
		ram,
		g.three_d.ring_gpa,
		g.three_d.ring_size,
		head_before,
		create[:],
	)
	g.three_d.ring_tail = (head_before + u32(len(create))) & (g.three_d.ring_size - 1)
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_DOORBELL, 1, ram)
	testing.expect_value(t, g.three_d.ring_head, head_before)
	testing.expect(t, gsw3d_find_context(&g.three_d, 2) == nil)

	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_STATUS, GSW3D_STATUS_RESET, ram)
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, backend.reset_count, 1)
	testing.expect(t, !g.three_d.poisoned)
	testing.expect(t, !g.three_d.reset_pending)
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.None)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_READY != 0)
	testing.expect(t, g.three_d.status & (GSW3D_STATUS_ERROR | GSW3D_STATUS_RESET) == 0)
	testing.expect(t, gsw3d_find_context(&g.three_d, 1) == nil)
	testing.expect(t, gsw3d_find_resource(&g.three_d, 9) == nil)
	testing.expect(t, !g.three_d.regions[0].live)
}

@(test)
gsw3d_upload_test_failed_reset_stays_poisoned_until_retry_succeeds :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [256]u8
	backend := Gsw3d_Upload_Test_Backend {
		fail_reset = true,
	}
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, gsw3d_upload_test_backend(&backend))) {return}

	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_STATUS, GSW3D_STATUS_RESET, ram[:])
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, backend.reset_count, 1)
	testing.expect(t, g.three_d.poisoned)
	testing.expect(t, g.three_d.reset_pending)
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.Backend_Failure)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_ERROR != 0)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_RESET != 0)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_READY == 0)

	backend.fail_reset = false
	_ = gsw3d_register_write(&g.three_d, GSW3D_REG_STATUS, GSW3D_STATUS_RESET, ram[:])
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, backend.reset_count, 2)
	testing.expect(t, !g.three_d.poisoned)
	testing.expect(t, !g.three_d.reset_pending)
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.None)
	testing.expect(t, g.three_d.status & GSW3D_STATUS_READY != 0)
	testing.expect(t, g.three_d.status & (GSW3D_STATUS_ERROR | GSW3D_STATUS_RESET) == 0)
}

@(test)
gsw3d_upload_test_direct_present_honors_backend_interval_mask :: proc(t: ^testing.T) {
	framebuffer: [4096]u8
	ram: [256]u8
	backend: Gsw3d_Upload_Test_Backend
	g: Gsw_Vga
	gsw_vga_init(&g, framebuffer[:])
	defer gsw_vga_destroy(&g)
	backend_config := gsw3d_upload_test_backend(&backend)
	backend_config.capabilities |= GSW3D_BACKEND_DIRECT_PRESENT
	backend_config.present_intervals = u32(1) << 1
	if !testing.expect(t, gsw_vga_set_3d_backend(&g, backend_config)) {return}
	intervals, _ := gsw3d_register_read(&g.three_d, GSW3D_REG_PRESENT_INTERVALS)
	testing.expect_value(t, intervals, u32(1) << 1)
	g.three_d.contexts[0] = {
		live = true,
		id   = 1,
	}
	g.three_d.resources[0] = {
		live = true,
		id   = 9,
	}

	descriptor: [64]u8
	gsw3d_test_header(descriptor[:], .Direct_Present, 1)
	gsw_test_wr32(descriptor[:], 16, 1)
	gsw_test_wr32(descriptor[:], 20, 9)
	gsw_test_wr32(descriptor[:], 32, 640)
	gsw_test_wr32(descriptor[:], 36, 480)
	gsw_test_wr32(descriptor[:], 48, 640)
	gsw_test_wr32(descriptor[:], 52, 480)

	invalid_intervals := [?]u32{0, 2, 4}
	for invalid_interval in invalid_intervals {
		gsw_test_wr32(descriptor[:], 56, invalid_interval)
		gsw3d_upload_test_process_descriptor(&g, ram[:], descriptor[:])
		testing.expect_value(t, g.three_d.ring_head, u32(0))
		testing.expect_value(t, g.three_d.error, Gsw3d_Error.Malformed_Descriptor)
	}

	gsw_test_wr32(descriptor[:], 56, 1)
	gsw3d_upload_test_process_descriptor(&g, ram[:], descriptor[:])
	if !testing.expect(t, gsw3d_wait_idle(&g.three_d, time.Second)) {return}
	gsw3d_poll(&g.three_d)
	testing.expect_value(t, g.three_d.ring_head, u32(len(descriptor)))
	testing.expect_value(t, g.three_d.error, Gsw3d_Error.None)
	testing.expect_value(t, backend.work_count, 1)
	testing.expect_value(t, backend.work_kinds[0], Gsw3d_Work_Kind.Direct_Present)
}
