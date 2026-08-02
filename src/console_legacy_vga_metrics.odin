// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "hv"
import "machine"
import "vga"

console_legacy_vga_host_metrics_enabled :: proc(options: ^acceptance.Options) -> bool {
	return(
		options != nil &&
		options.test_device &&
		options.artifacts != "" &&
		options.guest_report_kind_set &&
		options.guest_report_kind == .Legacy_VGA &&
		options.legacy_aperture_mode_set \
	)
}

console_legacy_vga_mode_x_candidate :: proc(m: ^machine.Machine) -> bool {
	if m == nil {return false}
	return vga.vga_legacy_aperture_execution_layout(&m.vga).kind == .Indexed_Unchained
}

console_legacy_vga_sample_performance :: proc(
	m: ^machine.Machine,
	metrics: ^acceptance.Legacy_Vga_Host_Metrics,
	sample: acceptance.Legacy_Aperture_Performance_Sample,
) {
	if metrics == nil {return}
	previous := metrics.performance.phase
	acceptance.legacy_vga_host_metrics_sample(metrics, sample)
	current := metrics.performance.phase
	if m == nil {return}
	if current == .Measuring && previous != .Measuring {
		_ = hv.legacy_aperture_execution_histogram_begin(&m.vm)
	} else if previous == .Measuring && current != .Measuring {
		_ = hv.legacy_aperture_execution_histogram_end(&m.vm)
	}
}

@(private = "file")
console_legacy_vga_owner_generation :: proc(lifetime: ^Vm_Lifetime) -> u64 {
	if lifetime == nil {return 0}
	return vm_lifetime_observation(lifetime).machine_generation
}

console_legacy_vga_performance_sample :: proc(
	m: ^machine.Machine,
	lifetime: ^Vm_Lifetime,
	frame: ^vga.Display_Frame,
	wall_ns: u64,
) -> acceptance.Legacy_Aperture_Performance_Sample {
	if m == nil || frame == nil {return {}}
	layout := vga.vga_legacy_aperture_execution_layout(&m.vga)
	identity := vga.vga_active_presentation_identity(&m.vga, &m.gsw_vga)
	aperture := hv.legacy_aperture_execution_observability(&m.vm)
	active :=
		identity.valid &&
		identity.owner == .Legacy &&
		layout.kind == .Indexed_Unchained &&
		layout.width > 0 &&
		layout.height > 0 &&
		u32(layout.width) == identity.width &&
		u32(layout.height) == identity.height
	return {
		wall_ns = wall_ns,
		active_mode_x = active,
		width = active ? u32(layout.width) : 0,
		height = active ? u32(layout.height) : 0,
		content_generation = frame.content_generation,
		owner_generation = console_legacy_vga_owner_generation(lifetime),
		mode_generation = active ? identity.mode_generation : 0,
		surface_generation = active ? identity.surface_generation : 0,
		aperture_exits = aperture.memory_access_exits,
	}
}

console_legacy_vga_capture_sample :: proc(
	m: ^machine.Machine,
	lifetime: ^Vm_Lifetime,
	frame: ^vga.Display_Frame,
	label: u8,
	wall_ns: u64,
) -> acceptance.Legacy_Vga_Host_Capture_Sample {
	if m == nil || frame == nil {return {}}
	identity := vga.vga_active_presentation_identity(&m.vga, &m.gsw_vga)
	aperture := hv.legacy_aperture_execution_observability(&m.vm)
	return {
		valid = identity.valid,
		label = label,
		time_ns = wall_ns,
		width = identity.width,
		height = identity.height,
		owner_generation = console_legacy_vga_owner_generation(lifetime),
		mode_generation = identity.mode_generation,
		surface_generation = identity.surface_generation,
		content_generation = frame.content_generation,
		aperture_exits = aperture.memory_access_exits,
	}
}
