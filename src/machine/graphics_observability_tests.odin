// SPDX-License-Identifier: GPL-3.0-only
package machine

import video "../vga"
import "core:testing"

@(test)
machine_graphics_observability_test_projects_cumulative_producers :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	video.gsw_vga_init(&m.gsw_vga, nil)
	defer video.gsw_vga_destroy(&m.gsw_vga)
	m.vga.content_generation = 9
	m.legacy_aperture_read_bytes = 17
	m.legacy_aperture_write_bytes = 23
	m.lfb_dirty_page_observations = 3
	m.bank_alias_dirty_page_observations = 5
	m.vm.run_calls = 7
	m.vm.physical_exit_count = 6
	m.gsw_vga.metrics.fenced_command_completions = 4
	m.gsw_vga.metrics.mmio_write_count = 5
	m.gsw_vga.metrics.mmio_write_bytes = 20
	m.gsw_vga.completed_fence = 11
	m.vga.io_write_count = 3
	m.vga.io_write_bytes = 6
	m.gsw_vga.three_d.metrics.presents = 2
	m.gsw_vga.three_d.queue_depth_high_water = 8

	snapshot := machine_graphics_observability(m)
	testing.expect_value(t, snapshot.mode.scanout_generation, u64(9))
	testing.expect_value(t, snapshot.legacy_aperture_read_bytes, u64(17))
	testing.expect_value(t, snapshot.legacy_aperture_write_bytes, u64(23))
	testing.expect_value(t, snapshot.lfb_dirty_page_observations, u64(3))
	testing.expect_value(t, snapshot.lfb_dirty_page_coverage_bytes_upper_bound, u64(3 * 4096))
	testing.expect_value(t, snapshot.bank_alias_dirty_page_observations, u64(5))
	testing.expect_value(
		t,
		snapshot.bank_alias_dirty_page_coverage_bytes_upper_bound,
		u64(5 * 4096),
	)
	testing.expect_value(t, snapshot.whpx.run_calls, u64(7))
	testing.expect_value(t, snapshot.whpx.physical_exit_count, u64(6))
	testing.expect_value(t, snapshot.gsw2d.metrics.fenced_command_completions, u64(4))
	testing.expect_value(t, snapshot.gsw2d.metrics.mmio_write_count, u64(5))
	testing.expect_value(t, snapshot.gsw2d.metrics.mmio_write_bytes, u64(20))
	testing.expect_value(t, snapshot.mode.io_write_count, u64(3))
	testing.expect_value(t, snapshot.mode.io_write_bytes, u64(6))
	testing.expect_value(t, snapshot.gsw2d.completed_fence, u64(11))
	testing.expect_value(t, snapshot.gsw3d.submitted_presents, u64(2))
	testing.expect_value(t, snapshot.gsw3d.queue_depth_high_water, 8)
}

@(test)
machine_graphics_observability_test_page_coverage_is_saturating_upper_bound :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	video.gsw_vga_init(&m.gsw_vga, nil)
	defer video.gsw_vga_destroy(&m.gsw_vga)
	m.lfb_dirty_page_observations = max(u64)

	snapshot := machine_graphics_observability(m)
	testing.expect_value(t, snapshot.lfb_dirty_page_coverage_bytes_upper_bound, max(u64))
	testing.expect_value(t, machine_graphics_saturating_add(max(u64) - 1, 9), max(u64))
}
