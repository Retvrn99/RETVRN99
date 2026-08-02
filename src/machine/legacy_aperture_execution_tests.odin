// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"

import "core:testing"

@(test)
test_machine_legacy_aperture_execution_layout_adapter_maps_vga_authority :: proc(
	t: ^testing.T,
) {
	m := new(Machine)
	defer free(m)
	m.vga.seq[4] = 0x06
	m.vga.gfx[5] = 0x40
	m.vga.gfx[6] = 0x05
	m.vga.crtc[0x09] = 0x41
	m.vga.crtc[0x13] = 40
	m.vga.timing.visible_dots = 640
	m.vga.timing.visible_lines = 480

	machine_bind_legacy_aperture_execution(m)
	adapter := m.vm.legacy_aperture_execution.layout
	if !testing.expect(t, adapter.snapshot != nil) {return}
	layout := adapter.snapshot(adapter.user_data)
	testing.expect_value(t, layout.kind, hv.Legacy_Aperture_Layout_Kind.Indexed_Unchained)
	testing.expect_value(t, layout.width, 320)
	testing.expect_value(t, layout.height, 240)
	testing.expect_value(t, layout.pitch_bytes, 80)
	testing.expect_value(t, layout.aperture_base, video.LEGACY_APERTURE_BASE)
	testing.expect_value(t, layout.aperture_size, u64(video.LEGACY_PLANE_SIZE))
}
