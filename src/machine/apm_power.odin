// SPDX-License-Identifier: GPL-3.0-only
package machine

machine_power_off_requested :: proc(m: ^Machine) -> bool {
	return m != nil && m.platform.power.power_off_requested
}

machine_power_off_reason :: proc(m: ^Machine) -> string {
	return m != nil ? m.platform.power.power_off_reason : ""
}

machine_request_power_off :: proc(m: ^Machine, reason: string) {
	if m != nil {pc_at_platform_request_power_off(&m.platform, reason)}
}

machine_apm_power_read :: proc(ctx: rawptr, port: u16, size: u8) -> u32 {
	m := (^Machine)(ctx)
	return pc_at_apm_power_read(m == nil ? nil : &m.platform, port, size)
}

machine_apm_power_write :: proc(ctx: rawptr, port: u16, size: u8, value: u32) {
	m := (^Machine)(ctx)
	if m == nil {return}
	if m.platform.adapters.ctx == nil {m.platform.adapters = machine_pc_at_adapters(m)}
	pc_at_apm_power_write(&m.platform, port, size, value)
}
