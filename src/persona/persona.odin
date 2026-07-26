// SPDX-License-Identifier: GPL-3.0-only
package persona

Guest_Persona :: struct {
	ram_mib:               u16,
	cpu_mhz:               u16,
	cpu_tsc_hz:            u64,
	cpu_throughput_hz:     u64,
	max_udma_mode:         u8,
	cd_speed:              u8,
	dvd_speed:             u8,
	vram_bytes:            int,
	graphics_core_mhz:     u16,
	graphics_agp_rate:     u8,
}

GUEST_PERSONA :: Guest_Persona {
	ram_mib            = 256,
	cpu_mhz            = 700,
	cpu_tsc_hz         = 700_000_000,
	cpu_throughput_hz  = 700_000_000,
	max_udma_mode      = 4,
	cd_speed           = 52,
	dvd_speed          = 10,
	vram_bytes         = 64 * 1024 * 1024,
	graphics_core_mhz  = 150,
	graphics_agp_rate  = 4,
}
