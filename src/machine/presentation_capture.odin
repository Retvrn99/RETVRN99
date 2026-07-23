// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"

@(private = "package")
machine_vga_sync :: proc(m: ^Machine) {
	machine_sync_time(m)
	video.vga_sync_to(&m.vga, m.active_ns)
	machine_scheduler_refresh(m)
}

@(private = "package")
machine_publish_vbe_writes :: proc(m: ^Machine) -> bool {
	if m == nil || m.vm.part == nil {return true}
	lfb_dirty, lfb_pages, lfb_ok := hv.query_device_memory_dirty_pages(
		&m.vm,
		video.vga_vram(&m.vga),
	)
	bank_dirty, bank_pages, bank_ok := hv.query_device_memory_alias_dirty_pages(
		&m.vm,
		video.LEGACY_APERTURE_BASE,
		video.DISPI_BANK_SIZE,
	)
	if !lfb_ok || !bank_ok {
		bus_freeze(&m.bus, "WHPX VGA dirty-page query failed")
		return false
	}
	m.lfb_dirty_page_observations = machine_graphics_saturating_add(
		m.lfb_dirty_page_observations,
		lfb_pages,
	)
	m.bank_alias_dirty_page_observations = machine_graphics_saturating_add(
		m.bank_alias_dirty_page_observations,
		bank_pages,
	)
	_ = video.vga_publish_external_vbe_writes(&m.vga, lfb_dirty || bank_dirty)
	return true
}

machine_display_frame :: proc(m: ^Machine) -> ^video.Display_Frame {
	machine_vga_sync(m)
	_ = machine_publish_vbe_writes(m)
	return video.vga_display_frame(&m.vga)
}

machine_capture_scanout :: proc(
	m: ^Machine,
	descriptor: ^video.Scanout_Descriptor,
	lifecycle_generation: u64,
) -> bool {
	if m == nil || descriptor == nil || lifecycle_generation == 0 {return false}
	descriptor.bytes_copied = 0
	descriptor.copy_duration_ns = 0
	descriptor.gsw_presentation.bytes_copied = 0
	descriptor.gsw_presentation.copy_duration_ns = 0
	machine_vga_sync(m)
	if !machine_publish_vbe_writes(m) {return false}
	if !video.scanout_descriptor_capture(descriptor, &m.vga) {return false}
	gsw_captured := video.gsw_presentation_descriptor_capture(
		&descriptor.gsw_presentation,
		&m.gsw_vga,
		lifecycle_generation,
		&m.vga.presentation_mode_clock,
	)
	if descriptor.gsw_presentation.bytes_copied > 0 {
		descriptor.bytes_copied += descriptor.gsw_presentation.bytes_copied
	}
	descriptor.copy_duration_ns = machine_graphics_saturating_add(
		descriptor.copy_duration_ns,
		descriptor.gsw_presentation.copy_duration_ns,
	)
	return gsw_captured
}

machine_scanout_generation :: proc(m: ^Machine) -> u64 {
	if m == nil {return 0}
	machine_vga_sync(m)
	_ = machine_publish_vbe_writes(m)
	return video.vga_presentation_sequence(&m.vga)
}

machine_text_snapshot :: proc(m: ^Machine) -> video.Text_Snapshot {
	machine_vga_sync(m)
	return video.vga_text_snapshot(&m.vga)
}
