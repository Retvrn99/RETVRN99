// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:fmt"
import "core:strings"
import hv "../hv"
import machine "../machine"
import vga "../vga"

Graphics_Vm_Execution_Sample :: struct {
	step_calls:       u64,
	step_wall_ns:     u64,
	inactive_wait_ns: u64,
}

Graphics_Producer_Sample :: struct {
	valid:                        bool,
	session_generation:           u64,
	vm:                           Graphics_Vm_Execution_Sample,
	machine:                      machine.Machine_Graphics_Observability,
	output_underrun_frames:       u64,
	output_underrun_events:       u64,
	native_pcm_starvation_frames: u64,
}

Graphics_Producer_Interval :: struct {
	valid:                                      bool,
	samples:                                    u64,
	counter_resets:                             u64,
	generation_changes:                         u64,
	session_generation:                         u64,
	device_generation:                          u64,
	mode:                                       vga.Vga_Mode_Observability,
	vm_step_calls:                              u64,
	vm_step_wall_ns:                            u64,
	vm_inactive_wait_ns:                        u64,
	whpx_run_calls:                             u64,
	whpx_physical_exits:                        u64,
	whpx_physical_exit_reasons:                 [hv.WHPX_PHYSICAL_EXIT_REASON_COUNT]u64,
	mmio_fallbacks:                             u64,
	mmio_scalar_fallbacks:                      u64,
	mmio_string_fallbacks:                      u64,
	mmio_string_chunks:                         u64,
	mmio_string_elements:                       u64,
	mmio_fallback_attempts:                     u64,
	mmio_fallback_successes:                    u64,
	mmio_fallback_failures:                     u64,
	winquake_fallback_attempts:                 u64,
	winquake_fallback_successes:                u64,
	winquake_fallback_failures:                 u64,
	legacy_aperture_read_bytes:                 u64,
	legacy_aperture_write_bytes:                u64,
	lfb_dirty_pages:                            u64,
	lfb_dirty_page_coverage_bytes_upper_bound:  u64,
	bank_alias_dirty_pages:                     u64,
	bank_dirty_page_coverage_bytes_upper_bound: u64,
	bank_programs:                              u64,
	bank_changes:                               u64,
	vga_io_writes:                              u64,
	vga_io_write_bytes:                         u64,
	gsw_control_writes:                         u64,
	gsw_control_write_bytes:                    u64,
	gsw2d_commands:                             u64,
	gsw2d_malformed:                            u64,
	gsw2d_presents:                             u64,
	gsw2d_fills:                                u64,
	gsw2d_copies:                               u64,
	gsw2d_palette_updates:                      u64,
	gsw2d_blits:                                u64,
	gsw2d_software_pixels:                      u64,
	gsw2d_fenced_completions:                   u64,
	gsw2d_completed_fence:                      u64,
	gsw3d_descriptors:                          u64,
	gsw3d_malformed:                            u64,
	gsw3d_batches:                              u64,
	gsw3d_batch_bytes:                          u64,
	gsw3d_contexts_created:                     u64,
	gsw3d_regions_registered:                   u64,
	gsw3d_submitted_presents:                   u64,
	gsw3d_uploads:                              u64,
	gsw3d_upload_bytes:                         u64,
	gsw3d_backend_failures:                     u64,
	gsw3d_resets:                               u64,
	gsw3d_queue_retries:                        u64,
	gsw3d_rejections:                           u64,
	gsw3d_rejected_poisoned:                    u64,
	gsw3d_rejected_queue_limit:                 u64,
	gsw3d_rejected_present_limit:               u64,
	gsw3d_rejected_owned_bytes_limit:           u64,
	output_underrun_frames:                     u64,
	output_underrun_events:                     u64,
	native_pcm_starvation_frames:               u64,
	gsw3d_queue_depth_current:                  int,
	gsw3d_queue_depth_sampled_peak:             int,
	gsw3d_queue_depth_high_water:               int,
	gsw3d_queued_presents_current:              int,
	gsw3d_queued_presents_sampled_peak:         int,
	gsw3d_queued_presents_high_water:           int,
	gsw3d_owned_bytes_current:                  u64,
	gsw3d_owned_bytes_sampled_peak:             u64,
	gsw3d_owned_bytes_high_water:               u64,
	gsw3d_completion_depth_current:             int,
	gsw3d_completed_fence:                      u64,
}

@(private = "package")
graphics_counter_add :: proc(left, right: u64) -> u64 {
	return left + min(right, max(u64) - left)
}

@(private = "package")
graphics_interval_add_counter :: proc(destination: ^u64, source: u64) {
	if destination == nil {return}
	destination^ = graphics_counter_add(destination^, source)
}

@(private = "package")
graphics_counter_delta :: proc(current, previous: u64) -> (u64, bool) {
	if current >= previous {return current - previous, false}
	return current, true
}

@(private = "file")
graphics_counter_delta_store :: proc(destination: ^u64, reset: ^bool, current, previous: u64) {
	if destination == nil || reset == nil {return}
	delta, wrapped := graphics_counter_delta(current, previous)
	destination^ = delta
	reset^ = reset^ || wrapped
}

@(private = "file")
graphics_dirty_coverage_upper_bound :: proc(pages: u64) -> u64 {
	if pages > max(u64) / 4096 {return max(u64)}
	return pages * 4096
}

@(private = "package")
graphics_producer_sample :: proc(
	source: ^machine.Machine,
	session_generation: u64,
	vm: Graphics_Vm_Execution_Sample,
) -> Graphics_Producer_Sample {
	if source == nil {return {}}
	audio := machine.machine_audio_observability(source)
	return {
		valid = true,
		session_generation = session_generation,
		vm = vm,
		machine = machine.machine_graphics_observability(source),
		output_underrun_frames = audio.output.underruns,
		output_underrun_events = audio.output.underrun_events,
		native_pcm_starvation_frames = audio.native_starvation_frames,
	}
}

@(private = "package")
graphics_producer_interval :: proc(
	current: Graphics_Producer_Sample,
	previous: Graphics_Producer_Sample,
) -> Graphics_Producer_Interval {
	if !current.valid {return {}}
	result := Graphics_Producer_Interval {
		valid                              = true,
		samples                            = 1,
		session_generation                 = current.session_generation,
		device_generation                  = current.machine.gsw3d.device_generation,
		mode                               = current.machine.mode,
		gsw2d_completed_fence              = current.machine.gsw2d.completed_fence,
		gsw3d_queue_depth_current          = current.machine.gsw3d.queue_depth_current,
		gsw3d_queue_depth_sampled_peak     = current.machine.gsw3d.queue_depth_current,
		gsw3d_queue_depth_high_water       = current.machine.gsw3d.queue_depth_high_water,
		gsw3d_queued_presents_current      = current.machine.gsw3d.queued_presents_current,
		gsw3d_queued_presents_sampled_peak = current.machine.gsw3d.queued_presents_current,
		gsw3d_queued_presents_high_water   = current.machine.gsw3d.queued_presents_high_water,
		gsw3d_owned_bytes_current          = current.machine.gsw3d.owned_work_bytes_current,
		gsw3d_owned_bytes_sampled_peak     = current.machine.gsw3d.owned_work_bytes_current,
		gsw3d_owned_bytes_high_water       = current.machine.gsw3d.owned_work_bytes_high_water,
		gsw3d_completion_depth_current     = current.machine.gsw3d.completion_queue_depth,
		gsw3d_completed_fence              = current.machine.gsw3d.completed_fence,
	}
	if !previous.valid {return result}
	if current.session_generation != previous.session_generation ||
	   current.machine.gsw3d.device_generation != previous.machine.gsw3d.device_generation {
		result.generation_changes = 1
	}
	reset := false
	delta: u64
	wrapped: bool
	delta, wrapped = graphics_counter_delta(current.vm.step_calls, previous.vm.step_calls)
	result.vm_step_calls = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(current.vm.step_wall_ns, previous.vm.step_wall_ns)
	result.vm_step_wall_ns = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.vm.inactive_wait_ns,
		previous.vm.inactive_wait_ns,
	)
	result.vm_inactive_wait_ns = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.whpx.run_calls,
		previous.machine.whpx.run_calls,
	)
	result.whpx_run_calls = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.whpx.physical_exit_count,
		previous.machine.whpx.physical_exit_count,
	)
	result.whpx_physical_exits = delta
	reset = reset || wrapped
	for index in 0 ..< hv.WHPX_PHYSICAL_EXIT_REASON_COUNT {
		graphics_counter_delta_store(
			&result.whpx_physical_exit_reasons[index],
			&reset,
			current.machine.whpx.physical_exit_reasons[index],
			previous.machine.whpx.physical_exit_reasons[index],
		)
	}
	graphics_counter_delta_store(
		&result.mmio_fallbacks,
		&reset,
		current.machine.whpx.mmio_fallbacks,
		previous.machine.whpx.mmio_fallbacks,
	)
	graphics_counter_delta_store(
		&result.mmio_scalar_fallbacks,
		&reset,
		current.machine.whpx.mmio_scalar_fallbacks,
		previous.machine.whpx.mmio_scalar_fallbacks,
	)
	graphics_counter_delta_store(
		&result.mmio_string_fallbacks,
		&reset,
		current.machine.whpx.mmio_string_fallbacks,
		previous.machine.whpx.mmio_string_fallbacks,
	)
	graphics_counter_delta_store(
		&result.mmio_string_chunks,
		&reset,
		current.machine.whpx.mmio_string_chunks,
		previous.machine.whpx.mmio_string_chunks,
	)
	graphics_counter_delta_store(
		&result.mmio_string_elements,
		&reset,
		current.machine.whpx.mmio_string_elements,
		previous.machine.whpx.mmio_string_elements,
	)
	for index in 0 ..< hv.WHPX_MMIO_KIND_COUNT {
		current_kind := current.machine.whpx.mmio_fallback_by_kind[index]
		previous_kind := previous.machine.whpx.mmio_fallback_by_kind[index]
		attempts, attempts_reset := graphics_counter_delta(
			current_kind.attempts,
			previous_kind.attempts,
		)
		successes, successes_reset := graphics_counter_delta(
			current_kind.successes,
			previous_kind.successes,
		)
		failures, failures_reset := graphics_counter_delta(
			current_kind.failures,
			previous_kind.failures,
		)
		result.mmio_fallback_attempts = graphics_counter_add(
			result.mmio_fallback_attempts,
			attempts,
		)
		result.mmio_fallback_successes = graphics_counter_add(
			result.mmio_fallback_successes,
			successes,
		)
		result.mmio_fallback_failures = graphics_counter_add(
			result.mmio_fallback_failures,
			failures,
		)
		if index == int(hv.Whpx_Mmio_Kind.Winquake_Store_Loop) {
			result.winquake_fallback_attempts = attempts
			result.winquake_fallback_successes = successes
			result.winquake_fallback_failures = failures
		}
		reset = reset || attempts_reset || successes_reset || failures_reset
	}
	delta, wrapped = graphics_counter_delta(
		current.machine.legacy_aperture_read_bytes,
		previous.machine.legacy_aperture_read_bytes,
	)
	result.legacy_aperture_read_bytes = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.legacy_aperture_write_bytes,
		previous.machine.legacy_aperture_write_bytes,
	)
	result.legacy_aperture_write_bytes = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.lfb_dirty_page_observations,
		previous.machine.lfb_dirty_page_observations,
	)
	result.lfb_dirty_pages = delta
	result.lfb_dirty_page_coverage_bytes_upper_bound = graphics_dirty_coverage_upper_bound(delta)
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.bank_alias_dirty_page_observations,
		previous.machine.bank_alias_dirty_page_observations,
	)
	result.bank_alias_dirty_pages = delta
	result.bank_dirty_page_coverage_bytes_upper_bound = graphics_dirty_coverage_upper_bound(delta)
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.mode.bank_program_count,
		previous.machine.mode.bank_program_count,
	)
	result.bank_programs = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.mode.bank_change_count,
		previous.machine.mode.bank_change_count,
	)
	result.bank_changes = delta
	reset = reset || wrapped
	graphics_counter_delta_store(
		&result.vga_io_writes,
		&reset,
		current.machine.mode.io_write_count,
		previous.machine.mode.io_write_count,
	)
	graphics_counter_delta_store(
		&result.vga_io_write_bytes,
		&reset,
		current.machine.mode.io_write_bytes,
		previous.machine.mode.io_write_bytes,
	)
	graphics_counter_delta_store(
		&result.gsw_control_writes,
		&reset,
		current.machine.gsw2d.metrics.mmio_write_count,
		previous.machine.gsw2d.metrics.mmio_write_count,
	)
	graphics_counter_delta_store(
		&result.gsw_control_write_bytes,
		&reset,
		current.machine.gsw2d.metrics.mmio_write_bytes,
		previous.machine.gsw2d.metrics.mmio_write_bytes,
	)
	graphics_counter_delta_store(
		&result.gsw2d_commands,
		&reset,
		current.machine.gsw2d.metrics.commands,
		previous.machine.gsw2d.metrics.commands,
	)
	graphics_counter_delta_store(
		&result.gsw2d_malformed,
		&reset,
		current.machine.gsw2d.metrics.malformed,
		previous.machine.gsw2d.metrics.malformed,
	)
	graphics_counter_delta_store(
		&result.gsw2d_presents,
		&reset,
		current.machine.gsw2d.metrics.presents,
		previous.machine.gsw2d.metrics.presents,
	)
	graphics_counter_delta_store(
		&result.gsw2d_fills,
		&reset,
		current.machine.gsw2d.metrics.fills,
		previous.machine.gsw2d.metrics.fills,
	)
	graphics_counter_delta_store(
		&result.gsw2d_copies,
		&reset,
		current.machine.gsw2d.metrics.copies,
		previous.machine.gsw2d.metrics.copies,
	)
	graphics_counter_delta_store(
		&result.gsw2d_palette_updates,
		&reset,
		current.machine.gsw2d.metrics.palette_updates,
		previous.machine.gsw2d.metrics.palette_updates,
	)
	graphics_counter_delta_store(
		&result.gsw2d_blits,
		&reset,
		current.machine.gsw2d.metrics.blits,
		previous.machine.gsw2d.metrics.blits,
	)
	graphics_counter_delta_store(
		&result.gsw2d_software_pixels,
		&reset,
		current.machine.gsw2d.metrics.software_pixels,
		previous.machine.gsw2d.metrics.software_pixels,
	)
	graphics_counter_delta_store(
		&result.gsw2d_fenced_completions,
		&reset,
		current.machine.gsw2d.metrics.fenced_command_completions,
		previous.machine.gsw2d.metrics.fenced_command_completions,
	)
	result.gsw2d_completed_fence = current.machine.gsw2d.completed_fence
	graphics_counter_delta_store(
		&result.gsw3d_descriptors,
		&reset,
		current.machine.gsw3d.metrics.descriptors,
		previous.machine.gsw3d.metrics.descriptors,
	)
	graphics_counter_delta_store(
		&result.gsw3d_malformed,
		&reset,
		current.machine.gsw3d.metrics.malformed,
		previous.machine.gsw3d.metrics.malformed,
	)
	graphics_counter_delta_store(
		&result.gsw3d_batches,
		&reset,
		current.machine.gsw3d.metrics.batches,
		previous.machine.gsw3d.metrics.batches,
	)
	graphics_counter_delta_store(
		&result.gsw3d_batch_bytes,
		&reset,
		current.machine.gsw3d.metrics.batch_bytes,
		previous.machine.gsw3d.metrics.batch_bytes,
	)
	graphics_counter_delta_store(
		&result.gsw3d_contexts_created,
		&reset,
		current.machine.gsw3d.metrics.contexts_created,
		previous.machine.gsw3d.metrics.contexts_created,
	)
	graphics_counter_delta_store(
		&result.gsw3d_regions_registered,
		&reset,
		current.machine.gsw3d.metrics.regions_registered,
		previous.machine.gsw3d.metrics.regions_registered,
	)
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.submitted_presents,
		previous.machine.gsw3d.submitted_presents,
	)
	result.gsw3d_submitted_presents = delta
	reset = reset || wrapped
	graphics_counter_delta_store(
		&result.gsw3d_uploads,
		&reset,
		current.machine.gsw3d.metrics.uploads,
		previous.machine.gsw3d.metrics.uploads,
	)
	graphics_counter_delta_store(
		&result.gsw3d_upload_bytes,
		&reset,
		current.machine.gsw3d.metrics.upload_bytes,
		previous.machine.gsw3d.metrics.upload_bytes,
	)
	graphics_counter_delta_store(
		&result.gsw3d_backend_failures,
		&reset,
		current.machine.gsw3d.metrics.backend_failures,
		previous.machine.gsw3d.metrics.backend_failures,
	)
	graphics_counter_delta_store(
		&result.gsw3d_resets,
		&reset,
		current.machine.gsw3d.metrics.resets,
		previous.machine.gsw3d.metrics.resets,
	)
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.queue_retries,
		previous.machine.gsw3d.queue_retries,
	)
	result.gsw3d_queue_retries = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.admission_rejections.total,
		previous.machine.gsw3d.admission_rejections.total,
	)
	result.gsw3d_rejections = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.admission_rejections.poisoned,
		previous.machine.gsw3d.admission_rejections.poisoned,
	)
	result.gsw3d_rejected_poisoned = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.admission_rejections.queue_limit,
		previous.machine.gsw3d.admission_rejections.queue_limit,
	)
	result.gsw3d_rejected_queue_limit = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.admission_rejections.present_limit,
		previous.machine.gsw3d.admission_rejections.present_limit,
	)
	result.gsw3d_rejected_present_limit = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.machine.gsw3d.admission_rejections.owned_bytes_limit,
		previous.machine.gsw3d.admission_rejections.owned_bytes_limit,
	)
	result.gsw3d_rejected_owned_bytes_limit = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.output_underrun_frames,
		previous.output_underrun_frames,
	)
	result.output_underrun_frames = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.output_underrun_events,
		previous.output_underrun_events,
	)
	result.output_underrun_events = delta
	reset = reset || wrapped
	delta, wrapped = graphics_counter_delta(
		current.native_pcm_starvation_frames,
		previous.native_pcm_starvation_frames,
	)
	result.native_pcm_starvation_frames = delta
	reset = reset || wrapped
	if reset {result.counter_resets = 1}
	return result
}

@(private = "package")
graphics_producer_interval_add :: proc(
	target: ^Graphics_Producer_Interval,
	addition: Graphics_Producer_Interval,
) {
	if target == nil || !addition.valid {return}
	target.valid = true
	target.samples = graphics_counter_add(target.samples, addition.samples)
	target.counter_resets = graphics_counter_add(target.counter_resets, addition.counter_resets)
	target.generation_changes = graphics_counter_add(
		target.generation_changes,
		addition.generation_changes,
	)
	graphics_interval_add_counter(&target.vm_step_calls, addition.vm_step_calls)
	graphics_interval_add_counter(&target.vm_step_wall_ns, addition.vm_step_wall_ns)
	graphics_interval_add_counter(&target.vm_inactive_wait_ns, addition.vm_inactive_wait_ns)
	graphics_interval_add_counter(&target.whpx_run_calls, addition.whpx_run_calls)
	graphics_interval_add_counter(&target.whpx_physical_exits, addition.whpx_physical_exits)
	for index in 0 ..< hv.WHPX_PHYSICAL_EXIT_REASON_COUNT {
		graphics_interval_add_counter(
			&target.whpx_physical_exit_reasons[index],
			addition.whpx_physical_exit_reasons[index],
		)
	}
	graphics_interval_add_counter(&target.mmio_fallbacks, addition.mmio_fallbacks)
	graphics_interval_add_counter(&target.mmio_scalar_fallbacks, addition.mmio_scalar_fallbacks)
	graphics_interval_add_counter(&target.mmio_string_fallbacks, addition.mmio_string_fallbacks)
	graphics_interval_add_counter(&target.mmio_string_chunks, addition.mmio_string_chunks)
	graphics_interval_add_counter(&target.mmio_string_elements, addition.mmio_string_elements)
	graphics_interval_add_counter(&target.mmio_fallback_attempts, addition.mmio_fallback_attempts)
	graphics_interval_add_counter(
		&target.mmio_fallback_successes,
		addition.mmio_fallback_successes,
	)
	graphics_interval_add_counter(&target.mmio_fallback_failures, addition.mmio_fallback_failures)
	graphics_interval_add_counter(
		&target.winquake_fallback_attempts,
		addition.winquake_fallback_attempts,
	)
	graphics_interval_add_counter(
		&target.winquake_fallback_successes,
		addition.winquake_fallback_successes,
	)
	graphics_interval_add_counter(
		&target.winquake_fallback_failures,
		addition.winquake_fallback_failures,
	)
	graphics_interval_add_counter(
		&target.legacy_aperture_read_bytes,
		addition.legacy_aperture_read_bytes,
	)
	graphics_interval_add_counter(
		&target.legacy_aperture_write_bytes,
		addition.legacy_aperture_write_bytes,
	)
	graphics_interval_add_counter(&target.lfb_dirty_pages, addition.lfb_dirty_pages)
	graphics_interval_add_counter(
		&target.lfb_dirty_page_coverage_bytes_upper_bound,
		addition.lfb_dirty_page_coverage_bytes_upper_bound,
	)
	graphics_interval_add_counter(&target.bank_alias_dirty_pages, addition.bank_alias_dirty_pages)
	graphics_interval_add_counter(
		&target.bank_dirty_page_coverage_bytes_upper_bound,
		addition.bank_dirty_page_coverage_bytes_upper_bound,
	)
	graphics_interval_add_counter(&target.bank_programs, addition.bank_programs)
	graphics_interval_add_counter(&target.bank_changes, addition.bank_changes)
	graphics_interval_add_counter(&target.vga_io_writes, addition.vga_io_writes)
	graphics_interval_add_counter(&target.vga_io_write_bytes, addition.vga_io_write_bytes)
	graphics_interval_add_counter(&target.gsw_control_writes, addition.gsw_control_writes)
	graphics_interval_add_counter(
		&target.gsw_control_write_bytes,
		addition.gsw_control_write_bytes,
	)
	graphics_interval_add_counter(&target.gsw2d_commands, addition.gsw2d_commands)
	graphics_interval_add_counter(&target.gsw2d_malformed, addition.gsw2d_malformed)
	graphics_interval_add_counter(&target.gsw2d_presents, addition.gsw2d_presents)
	graphics_interval_add_counter(&target.gsw2d_fills, addition.gsw2d_fills)
	graphics_interval_add_counter(&target.gsw2d_copies, addition.gsw2d_copies)
	graphics_interval_add_counter(&target.gsw2d_palette_updates, addition.gsw2d_palette_updates)
	graphics_interval_add_counter(&target.gsw2d_blits, addition.gsw2d_blits)
	graphics_interval_add_counter(&target.gsw2d_software_pixels, addition.gsw2d_software_pixels)
	graphics_interval_add_counter(
		&target.gsw2d_fenced_completions,
		addition.gsw2d_fenced_completions,
	)
	graphics_interval_add_counter(&target.gsw3d_descriptors, addition.gsw3d_descriptors)
	graphics_interval_add_counter(&target.gsw3d_malformed, addition.gsw3d_malformed)
	graphics_interval_add_counter(&target.gsw3d_batches, addition.gsw3d_batches)
	graphics_interval_add_counter(&target.gsw3d_batch_bytes, addition.gsw3d_batch_bytes)
	graphics_interval_add_counter(&target.gsw3d_contexts_created, addition.gsw3d_contexts_created)
	graphics_interval_add_counter(
		&target.gsw3d_regions_registered,
		addition.gsw3d_regions_registered,
	)
	graphics_interval_add_counter(
		&target.gsw3d_submitted_presents,
		addition.gsw3d_submitted_presents,
	)
	graphics_interval_add_counter(&target.gsw3d_uploads, addition.gsw3d_uploads)
	graphics_interval_add_counter(&target.gsw3d_upload_bytes, addition.gsw3d_upload_bytes)
	graphics_interval_add_counter(&target.gsw3d_backend_failures, addition.gsw3d_backend_failures)
	graphics_interval_add_counter(&target.gsw3d_resets, addition.gsw3d_resets)
	graphics_interval_add_counter(&target.gsw3d_queue_retries, addition.gsw3d_queue_retries)
	graphics_interval_add_counter(&target.gsw3d_rejections, addition.gsw3d_rejections)
	graphics_interval_add_counter(
		&target.gsw3d_rejected_poisoned,
		addition.gsw3d_rejected_poisoned,
	)
	graphics_interval_add_counter(
		&target.gsw3d_rejected_queue_limit,
		addition.gsw3d_rejected_queue_limit,
	)
	graphics_interval_add_counter(
		&target.gsw3d_rejected_present_limit,
		addition.gsw3d_rejected_present_limit,
	)
	graphics_interval_add_counter(
		&target.gsw3d_rejected_owned_bytes_limit,
		addition.gsw3d_rejected_owned_bytes_limit,
	)
	graphics_interval_add_counter(&target.output_underrun_frames, addition.output_underrun_frames)
	graphics_interval_add_counter(&target.output_underrun_events, addition.output_underrun_events)
	graphics_interval_add_counter(
		&target.native_pcm_starvation_frames,
		addition.native_pcm_starvation_frames,
	)
	target.session_generation = addition.session_generation
	target.device_generation = addition.device_generation
	target.mode = addition.mode
	target.gsw2d_completed_fence = addition.gsw2d_completed_fence
	target.gsw3d_queue_depth_current = addition.gsw3d_queue_depth_current
	target.gsw3d_queue_depth_sampled_peak = max(
		target.gsw3d_queue_depth_sampled_peak,
		addition.gsw3d_queue_depth_sampled_peak,
	)
	target.gsw3d_queue_depth_high_water = max(
		target.gsw3d_queue_depth_high_water,
		addition.gsw3d_queue_depth_high_water,
	)
	target.gsw3d_queued_presents_current = addition.gsw3d_queued_presents_current
	target.gsw3d_queued_presents_sampled_peak = max(
		target.gsw3d_queued_presents_sampled_peak,
		addition.gsw3d_queued_presents_sampled_peak,
	)
	target.gsw3d_queued_presents_high_water = max(
		target.gsw3d_queued_presents_high_water,
		addition.gsw3d_queued_presents_high_water,
	)
	target.gsw3d_owned_bytes_current = addition.gsw3d_owned_bytes_current
	target.gsw3d_owned_bytes_sampled_peak = max(
		target.gsw3d_owned_bytes_sampled_peak,
		addition.gsw3d_owned_bytes_sampled_peak,
	)
	target.gsw3d_owned_bytes_high_water = max(
		target.gsw3d_owned_bytes_high_water,
		addition.gsw3d_owned_bytes_high_water,
	)
	target.gsw3d_completion_depth_current = addition.gsw3d_completion_depth_current
	target.gsw3d_completed_fence = addition.gsw3d_completed_fence
}

@(private = "package")
graphics_producer_sample_text :: proc(sample: Graphics_Producer_Sample) -> string {
	if !sample.valid {return strings.clone("graphics producer unavailable")}
	m := sample.machine
	builder := strings.builder_make(0, 4096, context.allocator)
	fmt.sbprintf(
		&builder,
		"measured.session_generation=%d measured.device_generation=%d measured.scanout_generation=%d measured.mode=%dx%d/%v measured.vbe=%d measured.bpp_raw=%d measured.bpp_effective=%d derived.pitch_bytes=%d measured.bank=%d/%d measured.bank_programs=%d measured.bank_changes=%d measured.vm_step_calls=%d measured.vm_step_wall_ns=%d measured.vm_inactive_wait_ns=%d measured.whpx_runs=%d measured.physical_exits=%d measured.aperture_read_bytes=%d measured.aperture_write_bytes=%d measured.lfb_dirty_pages=%d derived.lfb_dirty_page_coverage_bytes_upper_bound=%d measured.bank_dirty_pages=%d derived.bank_dirty_page_coverage_bytes_upper_bound=%d measured.gsw2d_fenced=%d measured.gsw3d_queue_current=%d measured.gsw3d_queue_high_water_lifetime=%d measured.gsw3d_present_queue_current=%d measured.gsw3d_present_queue_high_water_lifetime=%d measured.gsw3d_owned_bytes_current=%d measured.gsw3d_owned_bytes_high_water_lifetime=%d measured.gsw3d_completion_depth=%d measured.gsw3d_completed_fence=%d measured.gsw3d_retries=%d measured.gsw3d_rejections=%d measured.audio_underrun_frames=%d measured.audio_underrun_events=%d measured.native_pcm_starvation_frames=%d",
		sample.session_generation,
		m.gsw3d.device_generation,
		m.mode.scanout_generation,
		m.mode.width,
		m.mode.height,
		m.mode.kind,
		m.mode.vbe_enabled ? 1 : 0,
		m.mode.vbe_bpp_raw,
		m.mode.vbe_bpp_effective,
		m.mode.vbe_pitch_bytes_derived,
		m.mode.bank_read,
		m.mode.bank_write,
		m.mode.bank_program_count,
		m.mode.bank_change_count,
		sample.vm.step_calls,
		sample.vm.step_wall_ns,
		sample.vm.inactive_wait_ns,
		m.whpx.run_calls,
		m.whpx.physical_exit_count,
		m.legacy_aperture_read_bytes,
		m.legacy_aperture_write_bytes,
		m.lfb_dirty_page_observations,
		m.lfb_dirty_page_coverage_bytes_upper_bound,
		m.bank_alias_dirty_page_observations,
		m.bank_alias_dirty_page_coverage_bytes_upper_bound,
		m.gsw2d.metrics.fenced_command_completions,
		m.gsw3d.queue_depth_current,
		m.gsw3d.queue_depth_high_water,
		m.gsw3d.queued_presents_current,
		m.gsw3d.queued_presents_high_water,
		m.gsw3d.owned_work_bytes_current,
		m.gsw3d.owned_work_bytes_high_water,
		m.gsw3d.completion_queue_depth,
		m.gsw3d.completed_fence,
		m.gsw3d.queue_retries,
		m.gsw3d.admission_rejections.total,
		sample.output_underrun_frames,
		sample.output_underrun_events,
		sample.native_pcm_starvation_frames,
	)
	fmt.sbprintf(
		&builder,
		" measured.mmio_fallbacks=%d measured.mmio_scalar=%d measured.mmio_string=%d measured.mmio_string_chunks=%d measured.mmio_string_elements=%d measured.vga_io_writes=%d/%d_bytes measured.gsw_control_writes=%d/%d_bytes measured.gsw2d=%d/%d/%d/%d/%d/%d/%d measured.gsw2d_software_pixels=%d measured.gsw2d_completed_fence=%d measured.gsw3d=%d/%d/%d/%d/%d/%d/%d/%d/%d/%d/%d",
		m.whpx.mmio_fallbacks,
		m.whpx.mmio_scalar_fallbacks,
		m.whpx.mmio_string_fallbacks,
		m.whpx.mmio_string_chunks,
		m.whpx.mmio_string_elements,
		m.mode.io_write_count,
		m.mode.io_write_bytes,
		m.gsw2d.metrics.mmio_write_count,
		m.gsw2d.metrics.mmio_write_bytes,
		m.gsw2d.metrics.commands,
		m.gsw2d.metrics.malformed,
		m.gsw2d.metrics.presents,
		m.gsw2d.metrics.fills,
		m.gsw2d.metrics.copies,
		m.gsw2d.metrics.palette_updates,
		m.gsw2d.metrics.blits,
		m.gsw2d.metrics.software_pixels,
		m.gsw2d.completed_fence,
		m.gsw3d.metrics.descriptors,
		m.gsw3d.metrics.malformed,
		m.gsw3d.metrics.batches,
		m.gsw3d.metrics.batch_bytes,
		m.gsw3d.metrics.contexts_created,
		m.gsw3d.metrics.regions_registered,
		m.gsw3d.metrics.presents,
		m.gsw3d.metrics.uploads,
		m.gsw3d.metrics.upload_bytes,
		m.gsw3d.metrics.backend_failures,
		m.gsw3d.metrics.resets,
	)
	for reason in hv.Whpx_Physical_Exit_Reason {
		fmt.sbprintf(
			&builder,
			" measured.whpx_exit_%v=%d",
			reason,
			m.whpx.physical_exit_reasons[int(reason)],
		)
	}
	for kind in hv.Whpx_Mmio_Kind {
		counters := m.whpx.mmio_fallback_by_kind[int(kind)]
		fmt.sbprintf(
			&builder,
			" measured.mmio_%v=%d/%d/%d",
			kind,
			counters.attempts,
			counters.successes,
			counters.failures,
		)
	}
	return strings.to_string(builder)
}
