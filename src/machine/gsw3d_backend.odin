// SPDX-License-Identifier: GPL-3.0-only
package machine

import video "../vga"

machine_set_gsw3d_backend :: proc(m: ^Machine, backend: video.Gsw3d_Backend) -> bool {
	return m != nil && video.gsw_vga_set_3d_backend(&m.gsw_vga, backend)
}
