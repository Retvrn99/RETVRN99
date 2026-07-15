// SPDX-License-Identifier: GPL-3.0-only
package machine

ISA_PNP_ADDRESS_PORT    :: u16(0x0279)
ISA_PNP_WRITE_DATA_PORT :: u16(0x0A79)
ISA_PNP_READ_DATA_MIN   :: u16(0x0203)
ISA_PNP_READ_DATA_MAX   :: u16(0x03FF)

ISA_PNP_SET_READ_DATA :: u8(0x00)
ISA_PNP_CONFIG_CONTROL :: u8(0x02)

ISA_PNP_CONFIG_WAIT_FOR_KEY :: u8(0x02)
ISA_PNP_CONFIG_RESET_CSN    :: u8(0x04)

ISA_PNP_KEY_INITIAL :: u8(0x6A)
ISA_PNP_KEY_LENGTH  :: u8(32)

Isa_Pnp :: struct {
	address:              u8,
	write_data:           u8,
	selected_register:    u8,
	read_data_port:       u16,
	read_data_programmed: bool,
	configuration_mode:   bool,
	key_expected:         u8,
	key_count:            u8,
}

isa_pnp_init :: proc(p: ^Isa_Pnp) {
	p^ = {}
	p.key_expected = ISA_PNP_KEY_INITIAL
}

isa_pnp_reset :: proc(p: ^Isa_Pnp) {
	isa_pnp_init(p)
}

@(private = "file")
isa_pnp_key_next :: proc(value: u8) -> u8 {
	return value >> 1 | ((value & 1) ~ ((value >> 1) & 1)) << 7
}

@(private = "file")
isa_pnp_key_write :: proc(p: ^Isa_Pnp, value: u8) {
	if value != p.key_expected {
		p.key_count = 0
		p.key_expected = ISA_PNP_KEY_INITIAL
		return
	}
	p.key_count += 1
	if p.key_count == ISA_PNP_KEY_LENGTH {
		p.configuration_mode = true
		p.key_count = 0
		p.key_expected = ISA_PNP_KEY_INITIAL
		return
	}
	p.key_expected = isa_pnp_key_next(p.key_expected)
}

@(private = "file")
isa_pnp_address_write :: proc(p: ^Isa_Pnp, value: u8) {
	p.address = value
	if !p.configuration_mode {
		isa_pnp_key_write(p, value)
		return
	}
	p.selected_register = value
}

@(private = "file")
isa_pnp_write_data_write :: proc(p: ^Isa_Pnp, value: u8) {
	p.write_data = value
	if !p.configuration_mode {return}

	switch p.selected_register {
	case ISA_PNP_SET_READ_DATA:
		port := u16(value) << 2 | 3
		if port >= ISA_PNP_READ_DATA_MIN && port <= ISA_PNP_READ_DATA_MAX {
			p.read_data_port = port
			p.read_data_programmed = true
		}
	case ISA_PNP_CONFIG_CONTROL:
		if value & ISA_PNP_CONFIG_WAIT_FOR_KEY != 0 {
			p.configuration_mode = false
			p.key_count = 0
			p.key_expected = ISA_PNP_KEY_INITIAL
		}
	}
}

isa_pnp_out :: proc(p: ^Isa_Pnp, port: u16, value: u8) -> bool {
	switch port {
	case ISA_PNP_ADDRESS_PORT:
		isa_pnp_address_write(p, value)
		return true
	case ISA_PNP_WRITE_DATA_PORT:
		isa_pnp_write_data_write(p, value)
		return true
	}
	return false
}

isa_pnp_read_data_selection :: proc(p: ^Isa_Pnp) -> (port: u16, programmed: bool) {
	return p.read_data_port, p.read_data_programmed
}

isa_pnp_in :: proc(p: ^Isa_Pnp, port: u16) -> (value: u8, driven: bool) {
	return 0xFF, false
}
