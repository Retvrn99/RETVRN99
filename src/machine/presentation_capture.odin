// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import contract "../presentation"
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
	lfb_pages: hv.Dirty_Page_Set
	lfb_ok := hv.query_device_memory_dirty_page_set(&m.vm, video.vga_vram(&m.vga), &lfb_pages)
	bank_pages: hv.Dirty_Page_Set
	bank_ok := hv.query_device_memory_alias_dirty_page_set(
		&m.vm,
		video.LEGACY_APERTURE_BASE,
		video.DISPI_BANK_SIZE,
		&bank_pages,
	)
	legacy_pages: hv.Dirty_Page_Set
	legacy_ok := hv.query_device_memory_alias_dirty_page_set(
		&m.vm,
		video.VBE_LFB_BASE,
		u64(video.VRAM_SIZE),
		&legacy_pages,
	)
	if !lfb_ok || !bank_ok || !legacy_ok {
		bus_freeze(&m.platform.bus, "WHPX VGA dirty-page query failed")
		return false
	}
	m.lfb_dirty_page_observations = machine_graphics_saturating_add(
		m.lfb_dirty_page_observations,
		u64(lfb_pages.count) + u64(legacy_pages.count),
	)
	m.bank_alias_dirty_page_observations = machine_graphics_saturating_add(
		m.bank_alias_dirty_page_observations,
		u64(bank_pages.count),
	)
	for page in 0 ..< hv.DEVICE_DIRTY_MAX_PAGES {
		if !hv.dirty_page_set_contains(&lfb_pages, u32(page)) &&
		   !hv.dirty_page_set_contains(&bank_pages, u32(page)) &&
		   !hv.dirty_page_set_contains(&legacy_pages, u32(page)) {continue}
		start := page * int(hv.DEVICE_DIRTY_PAGE_SIZE)
		if start >= video.VRAM_SIZE {continue}
		length := min(int(hv.DEVICE_DIRTY_PAGE_SIZE), video.VRAM_SIZE - start)
		_ = video.vga_damage_record_backing_range(&m.vga, u32(start), u32(length))
	}
	dirty := lfb_pages.count != 0 || bank_pages.count != 0 || legacy_pages.count != 0
	_ = video.vga_publish_external_backing_writes_paired(&m.vga, &m.gsw_vga, dirty)
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

machine_acknowledge_legacy_scanout :: proc(
	m: ^Machine,
	update: contract.Legacy_Frame_Update,
) -> bool {
	if m == nil {return false}
	return video.vga_damage_acknowledge_identity(
		&m.vga,
		update.header.sequence,
		update.header.mode_generation,
		update.header.surface.id,
		update.header.surface.generation,
	)
}

machine_acknowledge_gsw_scanout :: proc(m: ^Machine, present: contract.Gsw_Present) -> bool {
	if m == nil {return false}
	return video.gsw_presentation_acknowledge(
		&m.gsw_vga,
		present.header.sequence,
		present.header.device_generation,
		present.header.surface.id,
		present.header.surface.generation,
	)
}

machine_text_snapshot :: proc(m: ^Machine) -> video.Text_Snapshot {
	machine_vga_sync(m)
	return video.vga_text_snapshot(&m.vga)
}
