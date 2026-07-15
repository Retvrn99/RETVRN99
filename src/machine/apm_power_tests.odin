// SPDX-License-Identifier: GPL-3.0-only
package machine

import "core:testing"

@(test)
apm_power_test_requires_signature_and_latches_first_request :: proc(t: ^testing.T) {
	m := new(Machine)
	defer free(m)
	machine_apm_power_write(m, APM_POWER_OFF_PORT, 2, 0x1234)
	testing.expect(t, !machine_power_off_requested(m))
	machine_apm_power_write(m, APM_POWER_OFF_PORT, 1, u32(APM_POWER_OFF_VALUE))
	testing.expect(t, !machine_power_off_requested(m))
	machine_apm_power_write(m, APM_POWER_OFF_PORT, 2, u32(APM_POWER_OFF_VALUE))
	testing.expect(t, machine_power_off_requested(m))
	testing.expect_value(t, machine_power_off_reason(m), "guest requested APM power off")
	machine_request_power_off(m, "later")
	testing.expect_value(t, machine_power_off_reason(m), "guest requested APM power off")
}
