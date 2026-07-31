// SPDX-License-Identifier: GPL-3.0-only
package machine

import video "../vga"

machine_request_legacy_full_baseline :: proc(
	m: ^Machine,
	owner_generation, mode_generation, surface_id, surface_generation: u64,
) -> bool {
	if m == nil || owner_generation == 0 {return false}
	return video.vga_request_full_baseline(
		&m.vga,
		mode_generation,
		surface_id,
		surface_generation,
	)
}
