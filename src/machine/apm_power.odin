// SPDX-License-Identifier: GPL-3.0-only
package machine

machine_power_off_requested :: proc(m: ^Machine) -> bool {
	return m != nil && m.power_off_requested
}

machine_power_off_reason :: proc(m: ^Machine) -> string {
	return m != nil ? m.power_off_reason : ""
}

machine_request_power_off :: proc(m: ^Machine, reason: string) {
	if m == nil || m.power_off_requested {return}
	m.power_off_requested = true
	m.power_off_reason = reason
}

machine_apm_power_read :: proc(_: rawptr, _: u16, size: u8) -> u32 {
	if size == 0 || size > 4 {return 0xFFFF_FFFF}
	return 0
}

machine_apm_power_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	if ctx == nil || port != APM_POWER_OFF_PORT || size < 2 {return}
	if u16(value) != APM_POWER_OFF_VALUE {return}
	m := (^Machine)(ctx)
	machine_trace_record(m, .Progress, u64(port), u64(value), 1)
	machine_request_power_off(m, "guest requested APM power off")
}
