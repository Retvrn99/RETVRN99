// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"

@(private = "file")
machine_legacy_aperture_execution_layout :: proc(user_data: rawptr) -> hv.Legacy_Aperture_Layout {
	if user_data == nil {return {}}
	m := (^Machine)(user_data)
	source := video.vga_legacy_aperture_execution_layout(&m.vga)
	if source.kind != .Indexed_Unchained {return {}}
	return {
		kind          = .Indexed_Unchained,
		width         = source.width,
		height        = source.height,
		pitch_bytes   = source.pitch_bytes,
		aperture_base = source.aperture_base,
		aperture_size = source.aperture_size,
	}
}

machine_bind_legacy_aperture_execution :: proc(m: ^Machine) {
	if m == nil {return}
	hv.legacy_aperture_execution_set_layout_adapter(
		&m.vm,
		{
			user_data = m,
			snapshot  = machine_legacy_aperture_execution_layout,
		},
	)
}
