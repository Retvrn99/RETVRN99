// SPDX-License-Identifier: GPL-3.0-only
package machine

ISA_IO_DELAY_NS :: u64(1_000)

Isa_Delay :: struct {
	value:        u8,
	access_count: u64,
}

isa_delay_read :: proc(delay: ^Isa_Delay) -> (u8, u64) {
	delay.access_count += 1
	return delay.value, ISA_IO_DELAY_NS
}

isa_delay_write :: proc(delay: ^Isa_Delay, value: u8) -> u64 {
	delay.value = value
	delay.access_count += 1
	return ISA_IO_DELAY_NS
}
