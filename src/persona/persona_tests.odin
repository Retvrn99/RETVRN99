// SPDX-License-Identifier: GPL-3.0-only
package persona

import "core:testing"

@(test)
guest_persona_test_fixed_capability_envelope :: proc(t: ^testing.T) {
	testing.expect_value(t, GUEST_PERSONA.ram_mib, u16(256))
	testing.expect_value(t, GUEST_PERSONA.cpu_mhz, u16(700))
	testing.expect_value(t, GUEST_PERSONA.max_udma_mode, u8(4))
	testing.expect_value(t, GUEST_PERSONA.cd_speed, u8(52))
	testing.expect_value(t, GUEST_PERSONA.dvd_speed, u8(10))
	testing.expect_value(t, GUEST_PERSONA.vram_bytes, 64 * 1024 * 1024)
	testing.expect_value(t, GUEST_PERSONA.graphics_core_mhz, u16(150))
	testing.expect_value(t, GUEST_PERSONA.graphics_agp_rate, u8(4))
}
