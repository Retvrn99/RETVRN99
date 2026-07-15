// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

ISA_PNP_TEST_KEY :: [32]u8{
	0x6A, 0xB5, 0xDA, 0xED, 0xF6, 0xFB, 0x7D, 0xBE,
	0xDF, 0x6F, 0x37, 0x1B, 0x0D, 0x86, 0xC3, 0x61,
	0xB0, 0x58, 0x2C, 0x16, 0x8B, 0x45, 0xA2, 0xD1,
	0xE8, 0x74, 0x3A, 0x9D, 0xCE, 0xE7, 0x73, 0x39,
}

isa_pnp_test_enter_configuration :: proc(p: ^Isa_Pnp) {
	_ = isa_pnp_out(p, ISA_PNP_ADDRESS_PORT, 0)
	_ = isa_pnp_out(p, ISA_PNP_ADDRESS_PORT, 0)
	for value in ISA_PNP_TEST_KEY {
		_ = isa_pnp_out(p, ISA_PNP_ADDRESS_PORT, value)
	}
}

@(test)
test_isa_pnp_requires_the_complete_initiation_key :: proc(t: ^testing.T) {
	p: Isa_Pnp
	isa_pnp_init(&p)
	key := ISA_PNP_TEST_KEY
	for index in 0 ..< len(key) - 1 {
		_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, key[index])
	}
	testing.expect(t, !p.configuration_mode)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, 0xFF)
	testing.expect_value(t, p.key_count, u8(0))
	testing.expect_value(t, p.key_expected, ISA_PNP_KEY_INITIAL)

	isa_pnp_test_enter_configuration(&p)
	testing.expect(t, p.configuration_mode)
}

@(test)
test_isa_pnp_tracks_address_write_data_and_read_port :: proc(t: ^testing.T) {
	p: Isa_Pnp
	isa_pnp_init(&p)
	isa_pnp_test_enter_configuration(&p)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, ISA_PNP_SET_READ_DATA)
	_ = isa_pnp_out(&p, ISA_PNP_WRITE_DATA_PORT, 0x80)

	port, programmed := isa_pnp_read_data_selection(&p)
	testing.expect(t, programmed)
	testing.expect_value(t, port, ISA_PNP_READ_DATA_MIN)
	testing.expect_value(t, p.address, ISA_PNP_SET_READ_DATA)
	testing.expect_value(t, p.write_data, u8(0x80))
	testing.expect_value(t, p.selected_register, ISA_PNP_SET_READ_DATA)

	_ = isa_pnp_out(&p, ISA_PNP_WRITE_DATA_PORT, 0xFF)
	port, programmed = isa_pnp_read_data_selection(&p)
	testing.expect(t, programmed)
	testing.expect_value(t, port, ISA_PNP_READ_DATA_MAX)
}

@(test)
test_isa_pnp_no_cards_never_drive_isolation_data :: proc(t: ^testing.T) {
	p: Isa_Pnp
	isa_pnp_init(&p)
	isa_pnp_test_enter_configuration(&p)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, ISA_PNP_SET_READ_DATA)
	_ = isa_pnp_out(&p, ISA_PNP_WRITE_DATA_PORT, 0x80)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, 0x01)

	for _ in 0 ..< 144 {
		value, driven := isa_pnp_in(&p, ISA_PNP_READ_DATA_MIN)
		testing.expect_value(t, value, u8(0xFF))
		testing.expect(t, !driven)
	}
}

@(test)
test_isa_pnp_address_read_remains_available_to_lpt2 :: proc(t: ^testing.T) {
	p: Isa_Pnp
	lpt: Lpt
	isa_pnp_init(&p)
	lpt_init_lpt2(&lpt)
	testing.expect(t, isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, 0))
	value, driven := isa_pnp_in(&p, ISA_PNP_ADDRESS_PORT)
	testing.expect_value(t, value, u8(0xFF))
	testing.expect(t, !driven)
	lpt_value, claimed := lpt_in(&lpt, ISA_PNP_ADDRESS_PORT)
	testing.expect(t, claimed)
	testing.expect_value(t, lpt_value, LPT_STATUS_IDLE)
	testing.expect(t, !isa_pnp_out(&p, LPT2_BASE, 0))
}

@(test)
test_isa_pnp_control_preserves_programmed_read_port :: proc(t: ^testing.T) {
	p: Isa_Pnp
	isa_pnp_init(&p)
	isa_pnp_test_enter_configuration(&p)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, ISA_PNP_SET_READ_DATA)
	_ = isa_pnp_out(&p, ISA_PNP_WRITE_DATA_PORT, 0x80)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, ISA_PNP_CONFIG_CONTROL)
	_ = isa_pnp_out(
		&p,
		ISA_PNP_WRITE_DATA_PORT,
		ISA_PNP_CONFIG_WAIT_FOR_KEY | ISA_PNP_CONFIG_RESET_CSN,
	)

	port, programmed := isa_pnp_read_data_selection(&p)
	testing.expect(t, programmed)
	testing.expect_value(t, port, ISA_PNP_READ_DATA_MIN)
	testing.expect(t, !p.configuration_mode)
	testing.expect_value(t, p.key_expected, ISA_PNP_KEY_INITIAL)
}

@(test)
test_isa_pnp_reset_returns_to_power_up_state :: proc(t: ^testing.T) {
	p: Isa_Pnp
	isa_pnp_init(&p)
	isa_pnp_test_enter_configuration(&p)
	_ = isa_pnp_out(&p, ISA_PNP_ADDRESS_PORT, ISA_PNP_SET_READ_DATA)
	_ = isa_pnp_out(&p, ISA_PNP_WRITE_DATA_PORT, 0x80)
	isa_pnp_reset(&p)

	_, programmed := isa_pnp_read_data_selection(&p)
	testing.expect(t, !programmed)
	testing.expect(t, !p.configuration_mode)
	testing.expect_value(t, p.address, u8(0))
	testing.expect_value(t, p.write_data, u8(0))
	testing.expect_value(t, p.key_expected, ISA_PNP_KEY_INITIAL)
}
