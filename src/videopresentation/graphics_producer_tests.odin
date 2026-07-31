// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:strings"
import "core:testing"
import hv "../hv"
import vga "../vga"

@(test)
graphics_producer_test_interval_separates_measured_and_derived_counters :: proc(t: ^testing.T) {
	previous := Graphics_Producer_Sample {
		valid              = true,
		session_generation = 2,
	}
	previous.vm = {
		step_calls       = 10,
		step_wall_ns     = 1000,
		inactive_wait_ns = 50,
	}
	previous.machine.whpx.run_calls = 8
	previous.machine.whpx.physical_exit_count = 7
	previous.machine.whpx.physical_exit_reasons[int(hv.Whpx_Physical_Exit_Reason.Memory_Access)] = 3
	previous.machine.whpx.mmio_fallbacks = 2
	previous.machine.whpx.mmio_scalar_fallbacks = 1
	previous.machine.whpx.mmio_string_fallbacks = 1
	previous.machine.whpx.mmio_string_chunks = 2
	previous.machine.whpx.mmio_string_elements = 16
	previous.machine.whpx.mmio_fallback_by_kind[int(hv.Whpx_Mmio_Kind.Winquake_Store_Loop)] = {
		attempts  = 2,
		successes = 2,
	}
	previous.machine.lfb_dirty_page_observations = 3
	previous.machine.bank_alias_dirty_page_observations = 1
	previous.machine.mode.bank_program_count = 4
	previous.machine.mode.bank_change_count = 2
	previous.machine.mode.io_write_count = 7
	previous.machine.mode.io_write_bytes = 12
	previous.machine.gsw2d.metrics = {
		mmio_write_count           = 2,
		mmio_write_bytes           = 8,
		commands                   = 8,
		malformed                  = 1,
		presents                   = 2,
		fills                      = 3,
		copies                     = 1,
		palette_updates            = 4,
		blits                      = 2,
		software_pixels            = 100,
		fenced_command_completions = 5,
	}
	previous.machine.gsw2d.completed_fence = 9
	previous.machine.gsw3d.device_generation = 3
	previous.machine.gsw3d.metrics = {
		descriptors        = 2,
		malformed          = 1,
		batches            = 3,
		batch_bytes        = 1024,
		contexts_created   = 1,
		regions_registered = 1,
		presents           = 2,
		uploads            = 2,
		upload_bytes       = 512,
		backend_failures   = 1,
		resets             = 1,
	}
	previous.machine.gsw3d.submitted_presents = 2
	previous.machine.gsw3d.queue_retries = 1
	previous.output_underrun_frames = 4
	previous.output_underrun_events = 1
	previous.native_pcm_starvation_frames = 6

	current := previous
	current.vm = {
		step_calls       = 14,
		step_wall_ns     = 1800,
		inactive_wait_ns = 90,
	}
	current.machine.mode = {
		scanout_generation = 9,
		kind               = .Rgb_565,
		width              = 640,
		height             = 480,
		bank_program_count = 7,
		bank_change_count  = 3,
		io_write_count     = 11,
		io_write_bytes     = 21,
	}
	current.machine.whpx.run_calls = 12
	current.machine.whpx.physical_exit_count = 11
	current.machine.whpx.physical_exit_reasons[int(hv.Whpx_Physical_Exit_Reason.Memory_Access)] = 6
	current.machine.whpx.mmio_fallbacks = 5
	current.machine.whpx.mmio_scalar_fallbacks = 2
	current.machine.whpx.mmio_string_fallbacks = 3
	current.machine.whpx.mmio_string_chunks = 5
	current.machine.whpx.mmio_string_elements = 40
	current.machine.whpx.mmio_fallback_by_kind[int(hv.Whpx_Mmio_Kind.Winquake_Store_Loop)] = {
		attempts  = 5,
		successes = 4,
		failures  = 1,
	}
	current.machine.lfb_dirty_page_observations = 5
	current.machine.bank_alias_dirty_page_observations = 4
	current.machine.gsw2d.metrics = {
		mmio_write_count           = 6,
		mmio_write_bytes           = 24,
		commands                   = 13,
		malformed                  = 2,
		presents                   = 4,
		fills                      = 5,
		copies                     = 2,
		palette_updates            = 10,
		blits                      = 5,
		software_pixels            = 250,
		fenced_command_completions = 8,
	}
	current.machine.gsw2d.completed_fence = 14
	current.machine.gsw3d.metrics = {
		descriptors        = 5,
		malformed          = 2,
		batches            = 7,
		batch_bytes        = 4096,
		contexts_created   = 2,
		regions_registered = 3,
		presents           = 4,
		uploads            = 5,
		upload_bytes       = 2048,
		backend_failures   = 2,
		resets             = 2,
	}
	current.machine.gsw3d.submitted_presents = 4
	current.machine.gsw3d.queue_retries = 3
	current.machine.gsw3d.admission_rejections.queue_limit = 1
	current.machine.gsw3d.admission_rejections.total = 1
	current.machine.gsw3d.queue_depth_current = 2
	current.machine.gsw3d.queue_depth_high_water = 7
	current.machine.gsw3d.owned_work_bytes_current = 4096
	current.machine.gsw3d.owned_work_bytes_high_water = 8192
	current.output_underrun_frames = 9
	current.output_underrun_events = 3
	current.native_pcm_starvation_frames = 10

	interval := graphics_producer_interval(current, previous)
	testing.expect(t, interval.valid)
	testing.expect_value(t, interval.session_generation, u64(2))
	testing.expect_value(t, interval.device_generation, u64(3))
	testing.expect_value(t, interval.mode.kind, vga.Display_Kind.Rgb_565)
	testing.expect_value(t, interval.vm_step_calls, u64(4))
	testing.expect_value(t, interval.vm_step_wall_ns, u64(800))
	testing.expect_value(t, interval.whpx_physical_exits, u64(4))
	testing.expect_value(
		t,
		interval.whpx_physical_exit_reasons[int(hv.Whpx_Physical_Exit_Reason.Memory_Access)],
		u64(3),
	)
	testing.expect_value(t, interval.mmio_fallbacks, u64(3))
	testing.expect_value(t, interval.mmio_scalar_fallbacks, u64(1))
	testing.expect_value(t, interval.mmio_string_fallbacks, u64(2))
	testing.expect_value(t, interval.mmio_string_chunks, u64(3))
	testing.expect_value(t, interval.mmio_string_elements, u64(24))
	testing.expect_value(t, interval.winquake_fallback_attempts, u64(3))
	testing.expect_value(t, interval.winquake_fallback_successes, u64(2))
	testing.expect_value(t, interval.winquake_fallback_failures, u64(1))
	testing.expect_value(t, interval.lfb_dirty_pages, u64(2))
	testing.expect_value(t, interval.lfb_dirty_page_coverage_bytes_upper_bound, u64(8192))
	testing.expect_value(t, interval.bank_alias_dirty_pages, u64(3))
	testing.expect_value(t, interval.vga_io_writes, u64(4))
	testing.expect_value(t, interval.vga_io_write_bytes, u64(9))
	testing.expect_value(t, interval.gsw_control_writes, u64(4))
	testing.expect_value(t, interval.gsw_control_write_bytes, u64(16))
	testing.expect_value(t, interval.gsw2d_fenced_completions, u64(3))
	testing.expect_value(t, interval.gsw2d_commands, u64(5))
	testing.expect_value(t, interval.gsw2d_software_pixels, u64(150))
	testing.expect_value(t, interval.gsw2d_completed_fence, u64(14))
	testing.expect_value(t, interval.gsw3d_descriptors, u64(3))
	testing.expect_value(t, interval.gsw3d_batches, u64(4))
	testing.expect_value(t, interval.gsw3d_batch_bytes, u64(3072))
	testing.expect_value(t, interval.gsw3d_submitted_presents, u64(2))
	testing.expect_value(t, interval.gsw3d_uploads, u64(3))
	testing.expect_value(t, interval.gsw3d_upload_bytes, u64(1536))
	testing.expect_value(t, interval.gsw3d_backend_failures, u64(1))
	testing.expect_value(t, interval.gsw3d_resets, u64(1))
	testing.expect_value(t, interval.gsw3d_queue_retries, u64(2))
	testing.expect_value(t, interval.gsw3d_rejected_queue_limit, u64(1))
	testing.expect_value(t, interval.output_underrun_frames, u64(5))
	testing.expect_value(t, interval.output_underrun_events, u64(2))
	testing.expect_value(t, interval.native_pcm_starvation_frames, u64(4))
	testing.expect_value(t, interval.gsw3d_queue_depth_current, 2)
	testing.expect_value(t, interval.gsw3d_queue_depth_sampled_peak, 2)
	testing.expect_value(t, interval.gsw3d_queue_depth_high_water, 7)
	testing.expect_value(t, interval.counter_resets, u64(0))
}

@(test)
graphics_producer_test_counter_reset_is_explicit_and_interval_add_is_saturating :: proc(
	t: ^testing.T,
) {
	previous := Graphics_Producer_Sample {
		valid              = true,
		session_generation = 4,
	}
	previous.vm.step_calls = 99
	previous.machine.gsw3d.device_generation = 8
	current := Graphics_Producer_Sample {
		valid              = true,
		session_generation = 5,
	}
	current.vm.step_calls = 3
	current.machine.gsw3d.device_generation = 1
	current.machine.gsw3d.queue_depth_high_water = 2
	interval := graphics_producer_interval(current, previous)
	testing.expect_value(t, interval.vm_step_calls, u64(3))
	testing.expect_value(t, interval.counter_resets, u64(1))
	testing.expect_value(t, interval.generation_changes, u64(1))

	total := Graphics_Producer_Interval {
		vm_step_calls = max(u64) - 1,
	}
	graphics_producer_interval_add(&total, interval)
	testing.expect(t, total.valid)
	testing.expect_value(t, total.vm_step_calls, max(u64))
	testing.expect_value(t, total.session_generation, u64(5))
	testing.expect_value(t, total.device_generation, u64(1))
	testing.expect_value(t, total.gsw3d_queue_depth_high_water, 2)
}

@(test)
graphics_producer_test_text_labels_upper_bounds_and_unavailable_state :: proc(t: ^testing.T) {
	unavailable := graphics_producer_sample_text({})
	defer delete(unavailable)
	testing.expect_value(t, unavailable, "graphics producer unavailable")

	sample := Graphics_Producer_Sample {
		valid              = true,
		session_generation = 7,
	}
	sample.machine.mode = {
		kind   = .Indexed_8,
		width  = 320,
		height = 200,
	}
	sample.machine.lfb_dirty_page_observations = 2
	sample.machine.lfb_dirty_page_coverage_bytes_upper_bound = 8192
	sample.machine.whpx.physical_exit_reasons[int(hv.Whpx_Physical_Exit_Reason.Memory_Access)] = 4
	sample.machine.gsw2d.metrics.commands = 3
	sample.machine.gsw2d.metrics.mmio_write_count = 2
	sample.machine.gsw2d.metrics.mmio_write_bytes = 8
	sample.machine.mode.io_write_count = 5
	sample.machine.mode.io_write_bytes = 7
	sample.machine.gsw3d.metrics.batch_bytes = 2048
	text := graphics_producer_sample_text(sample)
	defer delete(text)
	testing.expect(t, strings.contains(text, "measured.session_generation=7"))
	testing.expect(t, strings.contains(text, "measured.lfb_dirty_pages=2"))
	testing.expect(
		t,
		strings.contains(text, "derived.lfb_dirty_page_coverage_bytes_upper_bound=8192"),
	)
	testing.expect(t, strings.contains(text, "measured.whpx_exit_Memory_Access=4"))
	testing.expect(t, strings.contains(text, "measured.gsw2d=3/"))
	testing.expect(t, strings.contains(text, "measured.vga_io_writes=5/7_bytes"))
	testing.expect(t, strings.contains(text, "measured.gsw_control_writes=2/8_bytes"))
	testing.expect(t, strings.contains(text, "measured.gsw3d=0/0/0/2048/"))
}
