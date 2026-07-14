// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
test_isa_delay_latches_post_code_and_charges_each_access :: proc(t: ^testing.T) {
	delay: Isa_Delay
	testing.expect_value(t, isa_delay_write(&delay, 0xA5), ISA_IO_DELAY_NS)
	value, elapsed := isa_delay_read(&delay)
	testing.expect_value(t, value, u8(0xA5))
	testing.expect_value(t, elapsed, ISA_IO_DELAY_NS)
	testing.expect_value(t, delay.access_count, u64(2))
}
