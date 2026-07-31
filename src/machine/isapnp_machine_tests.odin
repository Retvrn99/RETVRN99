// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:log"
import "core:testing"

isa_pnp_machine_test_init :: proc(m: ^Machine) {
	assert(pc_at_platform_init(&m.platform, 64 * 1024 * 1024, machine_pc_at_adapters(m)))
	pc_at_platform_install_fixed_io(&m.platform)
}

isa_pnp_machine_test_program_read_data :: proc(m: ^Machine, value: u8) {
	for _ in 0 ..< 2 {bus_io_write(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1, 0)}
	key := ISA_PNP_TEST_KEY
	for byte in key {bus_io_write(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1, u32(byte))}
	bus_io_write(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1, u32(ISA_PNP_SET_READ_DATA))
	bus_io_write(&m.platform.bus, ISA_PNP_WRITE_DATA_PORT, 1, u32(value))
}

@(test)
test_machine_isa_pnp_shares_address_reads_with_lpt2 :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	isa_pnp_machine_test_init(m)
	defer pc_at_platform_destroy(&m.platform)

	testing.expect_value(t, bus_io_read(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1), u32(LPT_STATUS_IDLE))
	bus_io_write(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1, 0)
	testing.expect_value(t, m.platform.isa_pnp.address, u8(0))
	testing.expect_value(t, m.platform.isa_pnp.key_count, u8(0))
	testing.expect_value(t, bus_io_read(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1), u32(LPT_STATUS_IDLE))
}

@(test)
test_machine_isa_pnp_selected_read_data_is_dynamic_open_bus :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	isa_pnp_machine_test_init(m)
	defer pc_at_platform_destroy(&m.platform)
	bus_set_strict_io(&m.platform.bus, true)

	isa_pnp_machine_test_program_read_data(m, 0x82)
	testing.expect(t, m.platform.isa_pnp_passive_installed)
	testing.expect_value(t, m.platform.isa_pnp_passive_port, u16(0x20B))
	for _ in 0 ..< 144 {
		testing.expect_value(t, bus_io_read(&m.platform.bus, 0x20B, 1), u32(0xFF))
	}
	testing.expect(t, !m.platform.bus.frozen)

	bus_io_write(&m.platform.bus, ISA_PNP_ADDRESS_PORT, 1, u32(ISA_PNP_SET_READ_DATA))
	bus_io_write(&m.platform.bus, ISA_PNP_WRITE_DATA_PORT, 1, 0x9A)
	testing.expect_value(t, m.platform.bus.passive[0x20B], u16(0))
	testing.expect_value(t, m.platform.isa_pnp_passive_port, u16(0x26B))
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x26B, 1), u32(0xFF))
	testing.expect(t, !m.platform.bus.frozen)
}

@(test)
test_machine_isa_pnp_existing_read_handler_has_priority :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	isa_pnp_machine_test_init(m)
	defer pc_at_platform_destroy(&m.platform)
	h := Io_Handler {
		read = proc(ctx: rawptr, port: u16, size: u8) -> u32 {return 0x5A},
	}
	bus_register(&m.platform.bus, 0x20B, 0x20B, h)

	isa_pnp_machine_test_program_read_data(m, 0x82)
	testing.expect(t, !m.platform.isa_pnp_passive_installed)
	testing.expect_value(t, m.platform.bus.passive[0x20B], u16(0))
	testing.expect_value(t, bus_io_read(&m.platform.bus, 0x20B, 1), u32(0x5A))
}

@(test)
test_machine_isa_pnp_full_recreation_clears_selection :: proc(t: ^testing.T) {
	if !hv.available() {
		log.warn("WHPX not available")
		return
	}
	m := new(Machine)
	defer free(m)
	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	isa_pnp_machine_test_program_read_data(m, 0x82)
	_, programmed := isa_pnp_read_data_selection(&m.platform.isa_pnp)
	testing.expect(t, programmed)
	machine_destroy(m)

	if !testing.expect(t, machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine_destroy(m)
	_, programmed = isa_pnp_read_data_selection(&m.platform.isa_pnp)
	testing.expect(t, !programmed)
	testing.expect(t, !m.platform.isa_pnp_passive_installed)
}
