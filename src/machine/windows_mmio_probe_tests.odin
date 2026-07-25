// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_windows_ram_sizing_probe_is_narrow :: proc(t: ^testing.T) {
	ram_bytes := u64(256 * 1024 * 1024)
	testing.expect(t, machine_windows_ram_probe(0x1000_0000, false, 4, ram_bytes))
	testing.expect(t, machine_windows_ram_probe(0x2000_0000, true, 4, ram_bytes))
	testing.expect(t, machine_windows_ram_probe(0x4000_0000, false, 4, ram_bytes))
	testing.expect(t, !machine_windows_ram_probe(ram_bytes - 4, false, 4, ram_bytes))
	testing.expect(t, !machine_windows_ram_probe(ram_bytes + 4, false, 4, ram_bytes))
	testing.expect(t, !machine_windows_ram_probe(0x8000_0000, false, 4, ram_bytes))
	testing.expect(t, !machine_windows_ram_probe(ram_bytes, false, 2, ram_bytes))
	testing.expect(t, !machine_windows_ram_probe(ram_bytes, false, 4, 0))
}
