// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"

Machine_Graphics_Observability :: struct {
	mode:                                             video.Vga_Mode_Observability,
	whpx:                                             hv.Whpx_Graphics_Observability,
	legacy_aperture_read_bytes:                       u64,
	legacy_aperture_write_bytes:                      u64,
	lfb_dirty_page_observations:                      u64,
	lfb_dirty_page_coverage_bytes_upper_bound:        u64,
	bank_alias_dirty_page_observations:               u64,
	bank_alias_dirty_page_coverage_bytes_upper_bound: u64,
	gsw2d:                                            video.Gsw2d_Observability,
	gsw3d:                                            video.Gsw3d_Queue_Snapshot,
}

@(private = "package")
machine_graphics_saturating_add :: proc(left, right: u64) -> u64 {
	return left + min(right, max(u64) - left)
}

@(private = "file")
machine_dirty_page_coverage_bytes_upper_bound :: proc(pages: u64) -> u64 {
	if pages > max(u64) / 4096 {return max(u64)}
	return pages * 4096
}

machine_graphics_observability :: proc(m: ^Machine) -> Machine_Graphics_Observability {
	if m == nil {return {}}
	return {
		mode = video.vga_mode_observability(&m.vga),
		whpx = hv.whpx_graphics_observability(&m.vm),
		legacy_aperture_read_bytes = m.legacy_aperture_read_bytes,
		legacy_aperture_write_bytes = m.legacy_aperture_write_bytes,
		lfb_dirty_page_observations = m.lfb_dirty_page_observations,
		lfb_dirty_page_coverage_bytes_upper_bound = machine_dirty_page_coverage_bytes_upper_bound(
			m.lfb_dirty_page_observations,
		),
		bank_alias_dirty_page_observations = m.bank_alias_dirty_page_observations,
		bank_alias_dirty_page_coverage_bytes_upper_bound = machine_dirty_page_coverage_bytes_upper_bound(
			m.bank_alias_dirty_page_observations,
		),
		gsw2d = video.gsw2d_observability(&m.gsw_vga),
		gsw3d = video.gsw3d_queue_snapshot(&m.gsw_vga.three_d),
	}
}
