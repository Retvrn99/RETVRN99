// SPDX-License-Identifier: GPL-3.0-only
package machine

PC_AT_RESET_HISTORY :: 32
APM_POWER_OFF_PORT :: u16(0xB004)
APM_POWER_OFF_VALUE :: u16(0x2000)

Reset_Provenance :: enum u8 {
	None,
	Kbc_Controller_Pulse,
	Kbc_Output_Port,
	Port_92,
	Pci_Cf9,
	Triple_Fault,
	Dos_Extender_Warm_Resume,
}

Reset_Record :: struct {
	source:        Reset_Provenance,
	master_tick:   u64,
	cmos_shutdown: u8,
}

Pc_At_Reset_State :: struct {
	reset_requested:   bool,
	reset_source:      Reset_Provenance,
	reset_reason:      string,
	reset_history:     [PC_AT_RESET_HISTORY]Reset_Record,
	reset_count:       u64,
	cpu_reset_pending: bool,
	cpu_reset_reason:  string,
	cpu_reset_cmos_0f: u8,
	cpu_reset_count:   u64,
	reset_control:     u8,
}

Pc_At_Power_State :: struct {
	power_off_requested: bool,
	power_off_reason:    string,
}

Pc_At_Platform :: struct {
	bus:       Bus,
	pic:       Pic_Pair,
	pit:       Pit,
	cmos:      Cmos,
	kbd:       I8042,
	dma:       Dma,
	serial1:   Uart_16450,
	serial2:   Uart_16450,
	parallel1: Lpt,
	parallel2: Lpt,
	isa_pnp:   Isa_Pnp,
	isa_pnp_passive_port:      u16,
	isa_pnp_passive_installed: bool,
	isa_delay: Isa_Delay,
	using reset: Pc_At_Reset_State,
	using power: Pc_At_Power_State,
}
