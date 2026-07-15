// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_pc_at_platform_owns_promoted_fixed_hardware :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	testing.expect_value(t, offset_of(Machine, platform), uintptr(0))
	testing.expect(t, &m.bus == &m.platform.bus)
	testing.expect(t, &m.pic == &m.platform.pic)
	testing.expect(t, &m.pit == &m.platform.pit)
	testing.expect(t, &m.cmos == &m.platform.cmos)
	testing.expect(t, &m.kbd == &m.platform.kbd)
	testing.expect(t, &m.dma == &m.platform.dma)
	testing.expect(t, &m.serial1 == &m.platform.serial1)
	testing.expect(t, &m.serial2 == &m.platform.serial2)
	testing.expect(t, &m.parallel1 == &m.platform.parallel1)
	testing.expect(t, &m.parallel2 == &m.platform.parallel2)
	testing.expect(t, &m.isa_pnp == &m.platform.isa_pnp)
	testing.expect(t, &m.isa_delay == &m.platform.isa_delay)
}

@(test)
test_pc_at_platform_owns_typed_reset_state :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	m.reset_requested = true
	m.reset_source = .Port_92
	m.reset_reason = "port 92 reset"
	m.reset_count = 2
	m.cpu_reset_pending = true
	m.cpu_reset_count = 3
	m.reset_control = 0x02
	m.reset_history[1] = {
		source = .Pci_Cf9,
		master_tick = 1234,
		cmos_shutdown = 0x0A,
	}
	testing.expect(t, m.platform.reset.reset_requested)
	testing.expect_value(t, m.platform.reset.reset_source, Reset_Provenance.Port_92)
	testing.expect_value(t, m.platform.reset.reset_reason, "port 92 reset")
	testing.expect_value(t, m.platform.reset.reset_count, u64(2))
	testing.expect(t, m.platform.reset.cpu_reset_pending)
	testing.expect_value(t, m.platform.reset.cpu_reset_count, u64(3))
	testing.expect_value(t, m.platform.reset.reset_control, u8(0x02))
	testing.expect_value(t, len(m.platform.reset.reset_history), PC_AT_RESET_HISTORY)
	testing.expect_value(t, m.platform.reset.reset_history[1].source, Reset_Provenance.Pci_Cf9)
}
