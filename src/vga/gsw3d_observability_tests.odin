// SPDX-License-Identifier: GPL-3.0-only
package vga

import "core:testing"

@(test)
gsw3d_observability_test_reasoned_admission_rejections :: proc(t: ^testing.T) {
	d: Gsw3d
	work: Gsw3d_Work

	d.poisoned = true
	testing.expect(t, !gsw3d_queue_owned(&d, &work))
	d.poisoned = false
	d.queue_count = GSW3D_MAX_QUEUED_WORK
	testing.expect(t, !gsw3d_queue_owned(&d, &work))
	d.queue_count = 0
	work.kind = .Direct_Present
	d.queued_presents = GSW3D_MAX_QUEUED_PRESENTS
	testing.expect(t, !gsw3d_queue_owned(&d, &work))
	d.queued_presents = 0
	work.kind = .Submit_Svga9
	d.owned_work_bytes = GSW3D_MAX_QUEUED_OWNED_BYTES
	work.batch = make([]u8, 1)
	defer delete(work.batch)
	testing.expect(t, !gsw3d_queue_owned(&d, &work))

	snapshot := gsw3d_queue_snapshot(&d)
	testing.expect_value(t, snapshot.admission_rejections.total, u64(4))
	testing.expect_value(t, snapshot.admission_rejections.poisoned, u64(1))
	testing.expect_value(t, snapshot.admission_rejections.queue_limit, u64(1))
	testing.expect_value(t, snapshot.admission_rejections.present_limit, u64(1))
	testing.expect_value(t, snapshot.admission_rejections.owned_bytes_limit, u64(1))
}

@(test)
gsw3d_observability_test_locked_queue_snapshot :: proc(t: ^testing.T) {
	d: Gsw3d
	d.queue_count = 3
	d.queued_presents = 2
	d.owned_work_bytes = 8192
	gsw3d_note_queue_high_water_locked(&d)
	d.queue_count = 1
	d.queued_presents = 1
	d.owned_work_bytes = 4096
	d.metrics.presents = 7
	d.metrics.batches = 4
	d.metrics.batch_bytes = 32768
	d.metrics.uploads = 2
	d.metrics.upload_bytes = 4096
	d.active = true
	d.completion_count = 2
	d.completed_fence = 11
	d.generation = 13
	d.queue_retries = 5

	snapshot := gsw3d_queue_snapshot(&d)
	testing.expect_value(t, snapshot.queue_depth_current, 1)
	testing.expect_value(t, snapshot.queue_depth_high_water, 3)
	testing.expect_value(t, snapshot.queued_presents_current, 1)
	testing.expect_value(t, snapshot.queued_presents_high_water, 2)
	testing.expect_value(t, snapshot.submitted_presents, u64(7))
	testing.expect_value(t, snapshot.metrics.batches, u64(4))
	testing.expect_value(t, snapshot.metrics.batch_bytes, u64(32768))
	testing.expect_value(t, snapshot.metrics.uploads, u64(2))
	testing.expect_value(t, snapshot.metrics.upload_bytes, u64(4096))
	testing.expect_value(t, snapshot.owned_work_bytes_current, u64(4096))
	testing.expect_value(t, snapshot.owned_work_bytes_high_water, u64(8192))
	testing.expect(t, snapshot.active)
	testing.expect_value(t, snapshot.completion_queue_depth, 2)
	testing.expect_value(t, snapshot.completed_fence, u64(11))
	testing.expect_value(t, snapshot.device_generation, u64(13))
	testing.expect_value(t, snapshot.queue_retries, u64(5))
}
