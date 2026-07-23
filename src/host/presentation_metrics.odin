// SPDX-License-Identifier: GPL-3.0-only
package host

Host_Presentation_Metrics :: struct {
	legacy_full_updates:          u64,
	legacy_partial_updates:       u64,
	gsw_snapshot_full_updates:    u64,
	gsw_snapshot_partial_updates: u64,
	copy_bytes:                   u64,
	conversion_pixels:            u64,
	upload_bytes:                 u64,
	upload_regions:               u64,
	stale_generation_drops:       u64,
	stale_finalization_drops:     u64,
	invalid_rejections:           u64,
	closed_rejections:            u64,
	resident_presents:            u64,
	readback_requests:            u64,
	readback_bytes:               u64,
	last_good_restorations:       u64,
	resource_reuses:              u64,
	resource_recreations:         u64,
	resource_retirements:         u64,
	full_fallback_uploads:        u64,
	overlay_invalidated_regions:  u64,
	overlay_full_invalidations:   u64,
	source_full_initial:          u64,
	source_full_mode:             u64,
	source_full_ambiguous:        u64,
	source_full_capacity:         u64,
	source_full_external:         u64,
}

host_presentation_resident_zero_work :: proc(before, after: Host_Presentation_Metrics) -> bool {
	expected := before
	if expected.resident_presents != max(u64) {expected.resident_presents += 1}
	return after == expected
}
