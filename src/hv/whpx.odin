// SPDX-License-Identifier: GPL-3.0-only
package hv

import "base:runtime"
import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"

// Windows allows only one WHPX partition with GPA mappings per process:
// a second WHvMapGpaRange fails with 0xC0370008
// (ERROR_VID_PARTITION_ALREADY_EXISTS) while another mapped partition
// exists, even single-threaded. Serialize whole VM lifetimes: whpx_create
// blocks until the previous VM is destroyed. Not reentrant — one thread
// must not create a second VM while holding one.
@(private = "file")
whpx_vm_gate: sync.Mutex

WHPX_A20_BIT :: u64(0x00100000)
WHPX_A20_PAIR_SIZE :: u64(0x00200000)

whpx_available :: proc() -> bool {
	present: win32.BOOL
	written: u32
	hr := WHvGetCapability(.HypervisorPresent, &present, size_of(present), &written)
	return hr >= 0 && bool(present)
}

whpx_create :: proc(vm: ^Vm, ram_size: int, options: Vm_Create_Options) -> bool {
	if !whpx_available() {
		return false
	}

	sync.lock(&whpx_vm_gate)
	part: WHV_PARTITION_HANDLE
	if WHvCreatePartition(&part) < 0 {
		sync.unlock(&whpx_vm_gate)
		return false
	}
	vm.part = part
	vm.guest_ymm_state_enabled = options.guest_ymm_state_enabled
	shutdown_trace_set_enabled(vm, options.shutdown_trace_enabled)

	count: u32 = 1
	if WHvSetPartitionProperty(part, .ProcessorCount, &count, size_of(count)) < 0 {
		whpx_destroy(vm)
		return false
	}
	ext_exits: u64 = 0x3 // CPUID and MSR exits keep the GSW-886 profile independent of the host
	if options.trace_ud_gp_exits {ext_exits |= 1 << 2}
	if WHvSetPartitionProperty(part, .ExtendedVmExits, &ext_exits, size_of(ext_exits)) < 0 {
		whpx_destroy(vm)
		return false
	}
	if options.trace_ud_gp_exits {
		if !whpx_configure_exception_tracing(vm) {
			whpx_destroy(vm)
			return false
		}
	}
	if !whpx_apply_cpu_profile(part) {
		whpx_destroy(vm)
		return false
	}
	if WHvSetupPartition(part) < 0 {
		whpx_destroy(vm)
		return false
	}

	ram := win32.VirtualAlloc(
		nil,
		uint(ram_size),
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if ram == nil {
		whpx_destroy(vm)
		return false
	}
	vm.ram = ([^]u8)(ram)[:ram_size]

	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvMapGpaRange(part, ram, 0, u64(ram_size), flags) < 0 {
		whpx_destroy(vm)
		return false
	}
	vm.a20_enabled = true
	vm.a20_requested = true

	if WHvCreateVirtualProcessor(part, 0, 0) < 0 {
		whpx_destroy(vm)
		return false
	}
	if !whpx_reset_vcpu(vm) {
		whpx_destroy(vm)
		return false
	}

	cb := WHV_EMULATOR_CALLBACKS {
		Size             = size_of(WHV_EMULATOR_CALLBACKS),
		IoPort           = whpx_emu_io,
		Memory           = whpx_emu_mmio,
		GetRegs          = whpx_emu_get_regs,
		SetRegs          = whpx_emu_set_regs,
		TranslateGvaPage = whpx_emu_translate,
	}
	emu: WHV_EMULATOR_HANDLE
	if WHvEmulatorCreateEmulator(&cb, &emu) < 0 {
		whpx_destroy(vm)
		return false
	}
	vm.emu = emu
	return true
}

whpx_destroy :: proc(vm: ^Vm) {
	held_gate := vm.part != nil // only a create that got a partition holds the gate
	if vm.emu != nil {
		WHvEmulatorDestroyEmulator(vm.emu)
		vm.emu = nil
	}
	if vm.part != nil {
		WHvDeletePartition(vm.part)
		vm.part = nil
	}
	if vm.ram != nil {
		win32.VirtualFree(raw_data(vm.ram), 0, win32.MEM_RELEASE)
		vm.ram = nil
	}
	for rom in vm.roms {
		win32.VirtualFree(rom.host, 0, win32.MEM_RELEASE)
	}
	delete(vm.roms)
	vm.roms = nil
	delete(vm.mmio_reservations)
	vm.mmio_reservations = nil
	delete(vm.shadow_mappings)
	vm.shadow_mappings = nil
	for alias in vm.device_aliases {
		if alias.dirty_bitmap != nil {
			delete(alias.dirty_bitmap, runtime.heap_allocator())
		}
	}
	delete(vm.device_aliases)
	vm.device_aliases = nil
	for mapping in vm.device_mappings {
		if mapping.dirty_bitmap != nil {
			delete(mapping.dirty_bitmap, runtime.heap_allocator())
		}
		win32.VirtualFree(mapping.host, 0, win32.MEM_RELEASE)
	}
	delete(vm.device_mappings)
	vm.device_mappings = nil
	delete(vm.exception_trace)
	vm.exception_trace = nil
	vm.exception_count = 0
	shutdown_trace_set_enabled(vm, false)
	vm.trace_ud_gp_exits = false
	vm.guest_ymm_state_enabled = false
	if held_gate {
		sync.unlock(&whpx_vm_gate)
	}
}

@(private = "file")
whpx_page_range_valid :: proc(gpa, size: u64) -> bool {
	return size > 0 && gpa & 0xFFF == 0 && size & 0xFFF == 0 && gpa <= max(u64) - size
}

@(private = "file")
whpx_device_mapping_flags :: proc(track_dirty: bool) -> u32 {
	flags := WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE
	if track_dirty {flags |= WHV_MAP_GPA_RANGE_FLAG_TRACK_DIRTY_PAGES}
	return flags
}

@(private = "file")
whpx_ranges_overlap :: proc(a_gpa, a_size, b_gpa, b_size: u64) -> bool {
	return a_gpa < b_gpa + b_size && b_gpa < a_gpa + a_size
}

@(private = "file")
whpx_reserve_memory :: proc(vm: ^Vm, gpa, size: u64, kind: Memory_Reservation_Kind) -> bool {
	if vm.part == nil || !whpx_page_range_valid(gpa, size) || gpa + size > u64(len(vm.ram)) {
		return false
	}
	for reservation in vm.mmio_reservations {
		if reservation.gpa == gpa && reservation.size == size {
			return reservation.kind == kind
		}
		if whpx_ranges_overlap(gpa, size, reservation.gpa, reservation.size) {
			return false
		}
	}
	for mapping in vm.device_mappings {
		if mapping.mapped && whpx_ranges_overlap(gpa, size, mapping.gpa, u64(mapping.size)) {
			return false
		}
		if mapping.request_pending &&
		   mapping.requested_mapped &&
		   whpx_ranges_overlap(gpa, size, mapping.requested_gpa, u64(mapping.size)) {
			return false
		}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, size, rom.gpa, u64(rom.size)) {
			return false
		}
	}
	if WHvUnmapGpaRange(vm.part, gpa, size) < 0 {
		return false
	}
	append(&vm.mmio_reservations, Mmio_Reservation{gpa = gpa, size = size, kind = kind})
	return true
}

whpx_reserve_mmio :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_memory(vm, gpa, size, .Mmio)
}

whpx_reserve_open_bus :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_memory(vm, gpa, size, .Open_Bus)
}

@(private = "file")
whpx_shadow_flags :: proc(readable, writable: bool) -> u32 {
	if !readable && !writable {return 0}
	flags: u32
	if readable {
		flags |= WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	}
	if writable {flags |= WHV_MAP_GPA_RANGE_FLAG_WRITE}
	return flags
}

@(private = "file")
whpx_map_ram_range :: proc(vm: ^Vm, gpa, size: u64, flags: u32) -> bool {
	if flags == 0 {return true}
	return WHvMapGpaRange(vm.part, raw_data(vm.ram[int(gpa):]), gpa, size, flags) >= 0
}

whpx_set_open_bus_shadow :: proc(vm: ^Vm, gpa, size: u64, readable, writable: bool) -> bool {
	if vm.part == nil || !whpx_page_range_valid(gpa, size) || gpa + size > u64(len(vm.ram)) {
		return false
	}
	contained := false
	for reservation in vm.mmio_reservations {
		if reservation.kind == .Open_Bus &&
		   gpa >= reservation.gpa &&
		   gpa + size <= reservation.gpa + reservation.size {
			contained = true
			break
		}
	}
	if !contained {return false}

	index := -1
	for mapping, i in vm.shadow_mappings {
		if mapping.gpa == gpa && mapping.size == size {
			index = i
			continue
		}
		if whpx_ranges_overlap(gpa, size, mapping.gpa, mapping.size) {return false}
	}
	old_readable, old_writable := false, false
	if index >= 0 {
		old := vm.shadow_mappings[index]
		old_readable, old_writable = old.readable, old.writable
		if old_readable == readable && old_writable == writable {return true}
	}

	new_flags := whpx_shadow_flags(readable, writable)
	if index >= 0 && whpx_shadow_flags(old_readable, old_writable) == new_flags {
		vm.shadow_mappings[index].readable = readable
		vm.shadow_mappings[index].writable = writable
		return true
	}
	if WHvUnmapGpaRange(vm.part, gpa, size) < 0 {return false}
	if !whpx_map_ram_range(vm, gpa, size, new_flags) {
		_ = whpx_map_ram_range(vm, gpa, size, whpx_shadow_flags(old_readable, old_writable))
		return false
	}
	mapping := Shadow_Mapping {
		gpa      = gpa,
		size     = size,
		readable = readable,
		writable = writable,
	}
	if index >= 0 {
		vm.shadow_mappings[index] = mapping
	} else {
		append(&vm.shadow_mappings, mapping)
	}
	return true
}

@(private = "file")
whpx_map_device_memory_internal :: proc(
	vm: ^Vm,
	gpa: u64,
	size: int,
	track_dirty: bool,
) -> (
	[]u8,
	bool,
) {
	if vm.part == nil || size <= 0 || !whpx_page_range_valid(gpa, u64(size)) {
		return nil, false
	}
	map_size := u64(size)
	if gpa < u64(len(vm.ram)) && whpx_ranges_overlap(gpa, map_size, 0, u64(len(vm.ram))) {
		return nil, false
	}
	for reservation in vm.mmio_reservations {
		if whpx_ranges_overlap(gpa, map_size, reservation.gpa, reservation.size) {
			return nil, false
		}
	}
	for mapping in vm.device_mappings {
		if mapping.mapped && whpx_ranges_overlap(gpa, map_size, mapping.gpa, u64(mapping.size)) {
			return nil, false
		}
		if mapping.request_pending &&
		   mapping.requested_mapped &&
		   whpx_ranges_overlap(gpa, map_size, mapping.requested_gpa, u64(mapping.size)) {
			return nil, false
		}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, map_size, rom.gpa, u64(rom.size)) {
			return nil, false
		}
	}
	mem := win32.VirtualAlloc(
		nil,
		uint(size),
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if mem == nil {
		return nil, false
	}
	dirty_bitmap: []u64
	if track_dirty {
		pages := map_size / 0x1000
		words := int((pages + 63) / 64)
		dirty_bitmap = make([]u64, words, runtime.heap_allocator())
		if dirty_bitmap == nil {
			win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
			return nil, false
		}
	}
	flags := whpx_device_mapping_flags(track_dirty)
	if WHvMapGpaRange(vm.part, mem, gpa, map_size, flags) < 0 {
		if dirty_bitmap != nil {delete(dirty_bitmap, runtime.heap_allocator())}
		win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
		return nil, false
	}
	append(
		&vm.device_mappings,
		Device_Mapping {
			gpa = gpa,
			host = mem,
			size = size,
			track_dirty = track_dirty,
			dirty_bitmap = dirty_bitmap,
			mapped = true,
			requested_gpa = gpa,
			requested_mapped = true,
		},
	)
	return ([^]u8)(mem)[:size], true
}

whpx_map_device_memory :: proc(vm: ^Vm, gpa: u64, size: int) -> ([]u8, bool) {
	return whpx_map_device_memory_internal(vm, gpa, size, false)
}

whpx_map_device_memory_tracked :: proc(vm: ^Vm, gpa: u64, size: int) -> ([]u8, bool) {
	return whpx_map_device_memory_internal(vm, gpa, size, true)
}

// Allocates dirty-tracked device memory with no guest address yet. The backing
// joins mappings and aliases exactly like a mapped region; a later
// set_device_memory_mapping call gives it one.
whpx_create_device_memory_tracked :: proc(vm: ^Vm, size: int) -> ([]u8, bool) {
	if vm == nil || vm.part == nil || size <= 0 || u64(size) & 0xFFF != 0 {
		return nil, false
	}
	mem := win32.VirtualAlloc(
		nil,
		uint(size),
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if mem == nil {
		return nil, false
	}
	pages := u64(size) / 0x1000
	words := int((pages + 63) / 64)
	dirty_bitmap := make([]u64, words, runtime.heap_allocator())
	if dirty_bitmap == nil {
		win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
		return nil, false
	}
	append(
		&vm.device_mappings,
		Device_Mapping {
			gpa = 0,
			host = mem,
			size = size,
			track_dirty = true,
			dirty_bitmap = dirty_bitmap,
			mapped = false,
			requested_gpa = 0,
			requested_mapped = false,
		},
	)
	return ([^]u8)(mem)[:size], true
}

@(private = "file")
whpx_device_mapping_index :: proc(vm: ^Vm, backing: []u8) -> int {
	if vm == nil || len(backing) <= 0 {return -1}
	host := raw_data(backing)
	for mapping, i in vm.device_mappings {
		if mapping.host == host && mapping.size == len(backing) {return i}
	}
	return -1
}

@(private = "file")
whpx_dirty_bitmap_pages :: proc(bitmap: []u64) -> u64 {
	pages: u64
	for word in bitmap {
		bits := word
		for bits != 0 {
			bits &= bits - 1
			pages += 1
		}
	}
	return pages
}

@(private = "file")
whpx_dirty_page_add :: proc(set: ^Dirty_Page_Set, page: u64) -> bool {
	if set == nil || page >= DEVICE_DIRTY_MAX_PAGES {return false}
	word := int(page / 64)
	mask := u64(1) << uint(page & 63)
	if set.words[word] & mask == 0 {
		set.words[word] |= mask
		if set.count < max(u32) {set.count += 1}
	}
	return true
}

@(private = "file")
whpx_dirty_page_merge_bitmap :: proc(set: ^Dirty_Page_Set, bitmap: []u64, base_page: u64) -> bool {
	if set == nil {return false}
	for word, word_index in bitmap {
		bits := word
		for bits != 0 {
			bit := 0
			probe := bits
			for probe & 1 == 0 {probe >>= 1; bit += 1}
			if !whpx_dirty_page_add(set, base_page + u64(word_index * 64 + bit)) {return false}
			bits &= bits - 1
		}
	}
	return true
}

@(private = "file")
whpx_capture_device_memory_dirty :: proc(vm: ^Vm, mapping: ^Device_Mapping) -> bool {
	if vm == nil || mapping == nil || !mapping.track_dirty || !mapping.mapped {return true}
	if len(mapping.dirty_bitmap) == 0 {return false}
	for &word in mapping.dirty_bitmap {word = 0}
	bitmap_size := u32(len(mapping.dirty_bitmap) * size_of(u64))
	if WHvQueryGpaRangeDirtyBitmap(
		   vm.part,
		   mapping.gpa,
		   u64(mapping.size),
		   &mapping.dirty_bitmap[0],
		   bitmap_size,
	   ) <
	   0 {
		return false
	}
	pages := whpx_dirty_bitmap_pages(mapping.dirty_bitmap)
	if pages > 0 {
		if !whpx_dirty_page_merge_bitmap(&mapping.dirty_pages, mapping.dirty_bitmap, 0) {
			return false
		}
		mapping.dirty_pending = true
		mapping.dirty_pending_pages += pages
	}
	return true
}

whpx_query_device_memory_dirty :: proc(vm: ^Vm, backing: []u8) -> (dirty: bool, ok: bool) {
	dirty, _, ok = whpx_query_device_memory_dirty_pages(vm, backing)
	return
}

whpx_query_device_memory_dirty_pages :: proc(
	vm: ^Vm,
	backing: []u8,
) -> (
	dirty: bool,
	pages: u64,
	ok: bool,
) {
	set: Dirty_Page_Set
	if !whpx_query_device_memory_dirty_page_set(vm, backing, &set) {return false, 0, false}
	return set.count != 0, u64(set.count), true
}

whpx_query_device_memory_dirty_page_set :: proc(
	vm: ^Vm,
	backing: []u8,
	pages: ^Dirty_Page_Set,
) -> bool {
	if pages == nil {return false}
	pages^ = {}
	if vm == nil || vm.part == nil {return false}
	index := whpx_device_mapping_index(vm, backing)
	if index < 0 {return false}
	mapping := &vm.device_mappings[index]
	if !mapping.track_dirty {return false}
	if !whpx_capture_device_memory_dirty(vm, mapping) {return false}
	pages^ = mapping.dirty_pages
	mapping.dirty_pages = {}
	mapping.dirty_pending = false
	mapping.dirty_pending_pages = 0
	return true
}

@(private = "file")
whpx_device_alias_index :: proc(vm: ^Vm, gpa, size: u64) -> int {
	if vm == nil {return -1}
	for alias, i in vm.device_aliases {
		if alias.gpa == gpa && alias.size == size {return i}
	}
	return -1
}

@(private = "file")
whpx_capture_device_alias_dirty :: proc(vm: ^Vm, alias: ^Device_Alias) -> bool {
	if vm == nil || alias == nil || !alias.mapped {return true}
	if alias.mapping_index < 0 || alias.mapping_index >= len(vm.device_mappings) {return false}
	mapping := &vm.device_mappings[alias.mapping_index]
	if !mapping.track_dirty {return true}
	if len(alias.dirty_bitmap) == 0 {return false}
	vm.device_alias_dirty_queries += 1
	for &word in alias.dirty_bitmap {word = 0}
	bitmap_size := u32(len(alias.dirty_bitmap) * size_of(u64))
	if WHvQueryGpaRangeDirtyBitmap(
		   vm.part,
		   alias.gpa,
		   alias.size,
		   &alias.dirty_bitmap[0],
		   bitmap_size,
	   ) <
	   0 {
		vm.device_alias_query_failures += 1
		return false
	}
	pages := whpx_dirty_bitmap_pages(alias.dirty_bitmap)
	if pages > 0 {
		if !whpx_dirty_page_merge_bitmap(
			&alias.dirty_pages,
			alias.dirty_bitmap,
			alias.backing_offset >> DEVICE_DIRTY_PAGE_SHIFT,
		) {return false}
		alias.dirty_pending = true
		alias.dirty_pending_pages += pages
	}
	return true
}

whpx_query_device_memory_alias_dirty :: proc(vm: ^Vm, gpa, size: u64) -> (dirty: bool, ok: bool) {
	dirty, _, ok = whpx_query_device_memory_alias_dirty_pages(vm, gpa, size)
	return
}

whpx_query_device_memory_alias_dirty_pages :: proc(
	vm: ^Vm,
	gpa, size: u64,
) -> (
	dirty: bool,
	pages: u64,
	ok: bool,
) {
	set: Dirty_Page_Set
	if !whpx_query_device_memory_alias_dirty_page_set(vm, gpa, size, &set) {
		return false, 0, false
	}
	return set.count != 0, u64(set.count), true
}

whpx_query_device_memory_alias_dirty_page_set :: proc(
	vm: ^Vm,
	gpa, size: u64,
	pages: ^Dirty_Page_Set,
) -> bool {
	if pages == nil {return false}
	pages^ = {}
	if vm == nil || vm.part == nil {return false}
	index := whpx_device_alias_index(vm, gpa, size)
	if index < 0 {return false}
	alias := &vm.device_aliases[index]
	mapping := &vm.device_mappings[alias.mapping_index]
	if !mapping.track_dirty {return false}
	if !whpx_capture_device_alias_dirty(vm, alias) {return false}
	pages^ = alias.dirty_pages
	alias.dirty_pages = {}
	alias.dirty_pending = false
	alias.dirty_pending_pages = 0
	return true
}

@(private = "file")
whpx_device_alias_target_valid :: proc(vm: ^Vm, gpa, size: u64, ignore_index := -1) -> bool {
	if vm == nil || !whpx_page_range_valid(gpa, size) {return false}
	contained := false
	for reservation in vm.mmio_reservations {
		if reservation.kind == .Mmio &&
		   gpa >= reservation.gpa &&
		   gpa + size <= reservation.gpa + reservation.size {
			contained = true
			break
		}
	}
	if !contained {
		// A fixed aperture above guest RAM, validated the way device mappings
		// are: it may not touch RAM, a reservation, a ROM, or a mapping.
		if whpx_ranges_overlap(gpa, size, 0, u64(len(vm.ram))) {return false}
		for reservation in vm.mmio_reservations {
			if whpx_ranges_overlap(gpa, size, reservation.gpa, reservation.size) {return false}
		}
		for rom in vm.roms {
			if whpx_ranges_overlap(gpa, size, rom.gpa, u64(rom.size)) {return false}
		}
		for mapping in vm.device_mappings {
			if mapping.mapped && whpx_ranges_overlap(gpa, size, mapping.gpa, u64(mapping.size)) {
				return false
			}
		}
	}
	for alias, i in vm.device_aliases {
		if i == ignore_index {continue}
		if whpx_ranges_overlap(gpa, size, alias.gpa, alias.size) {return false}
	}
	return true
}

whpx_set_device_memory_alias :: proc(
	vm: ^Vm,
	backing: []u8,
	gpa, backing_offset, size: u64,
	enabled: bool,
) -> bool {
	if vm == nil || vm.part == nil {return false}
	mapping_index := whpx_device_mapping_index(vm, backing)
	if mapping_index < 0 || !whpx_page_range_valid(backing_offset, size) {return false}
	mapping := &vm.device_mappings[mapping_index]
	if backing_offset > u64(mapping.size) || size > u64(mapping.size) - backing_offset {
		return false
	}
	alias_index := whpx_device_alias_index(vm, gpa, size)
	if !whpx_device_alias_target_valid(vm, gpa, size, alias_index) {return false}
	if alias_index < 0 {
		dirty_bitmap: []u64
		if mapping.track_dirty {
			pages := size / 0x1000
			words := int((pages + 63) / 64)
			dirty_bitmap = make([]u64, words, runtime.heap_allocator())
			if dirty_bitmap == nil {return false}
		}
		append(
			&vm.device_aliases,
			Device_Alias {
				gpa = gpa,
				size = size,
				mapping_index = mapping_index,
				backing_offset = backing_offset,
				dirty_bitmap = dirty_bitmap,
				requested_offset = backing_offset,
				requested_mapped = enabled,
				request_pending = enabled,
			},
		)
		return true
	}

	alias := &vm.device_aliases[alias_index]
	if alias.mapping_index != mapping_index {return false}
	alias.requested_offset = backing_offset
	alias.requested_mapped = enabled
	alias.request_pending = alias.backing_offset != backing_offset || alias.mapped != enabled
	return true
}

@(private = "file")
whpx_device_mapping_target_valid :: proc(vm: ^Vm, index: int, gpa: u64, enabled: bool) -> bool {
	if vm == nil || index < 0 || index >= len(vm.device_mappings) {return false}
	size := u64(vm.device_mappings[index].size)
	if !whpx_page_range_valid(gpa, size) {return false}
	if !enabled {return true}

	if whpx_ranges_overlap(gpa, size, 0, u64(len(vm.ram))) {return false}
	for reservation in vm.mmio_reservations {
		if whpx_ranges_overlap(gpa, size, reservation.gpa, reservation.size) {return false}
	}
	for rom in vm.roms {
		if whpx_ranges_overlap(gpa, size, rom.gpa, u64(rom.size)) {return false}
	}
	for mapping, other_index in vm.device_mappings {
		if other_index == index {continue}
		if mapping.mapped && whpx_ranges_overlap(gpa, size, mapping.gpa, u64(mapping.size)) {
			return false
		}
		if mapping.request_pending &&
		   mapping.requested_mapped &&
		   whpx_ranges_overlap(gpa, size, mapping.requested_gpa, u64(mapping.size)) {
			return false
		}
	}

	for alias in vm.device_aliases {
		if whpx_ranges_overlap(gpa, size, alias.gpa, alias.size) {return false}
	}
	current := &vm.device_mappings[index]
	if current.mapped && current.gpa != gpa && whpx_ranges_overlap(gpa, size, current.gpa, size) {
		return false
	}
	return true
}

whpx_set_device_memory_mapping :: proc(vm: ^Vm, backing: []u8, gpa: u64, enabled: bool) -> bool {
	if vm == nil || vm.part == nil {return false}
	index := whpx_device_mapping_index(vm, backing)
	if !whpx_device_mapping_target_valid(vm, index, gpa, enabled) {return false}

	mapping := &vm.device_mappings[index]
	mapping.requested_gpa = gpa
	mapping.requested_mapped = enabled
	mapping.request_pending = mapping.gpa != gpa || mapping.mapped != enabled
	return true
}

whpx_set_a20 :: proc(vm: ^Vm, enabled: bool) -> bool {
	if vm.part == nil || len(vm.ram) <= int(WHPX_A20_BIT) {
		return false
	}
	if vm.a20_requested != enabled {vm.a20_request_count += 1}
	vm.a20_requested = enabled
	return true
}

@(private = "file")
whpx_map_a20_region :: proc(vm: ^Vm, odd_base: u64, enabled: bool) -> bool {
	ram_size := u64(len(vm.ram))
	if odd_base >= ram_size {return true}
	size := min(WHPX_A20_BIT, ram_size - odd_base)
	source_base := enabled ? odd_base : odd_base &~ WHPX_A20_BIT
	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvUnmapGpaRange(vm.part, odd_base, size) < 0 {return false}
	if WHvMapGpaRange(vm.part, raw_data(vm.ram[int(source_base):]), odd_base, size, flags) < 0 {
		return false
	}

	source_end := source_base + size
	for reservation in vm.mmio_reservations {
		first := max(source_base, reservation.gpa)
		last := min(source_end, reservation.gpa + reservation.size)
		if first >= last {continue}
		alias := odd_base + first - source_base
		if WHvUnmapGpaRange(vm.part, alias, last - first) < 0 {return false}
	}
	return true
}

@(private = "file")
whpx_map_a20_device_region :: proc(
	vm: ^Vm,
	mapping: ^Device_Mapping,
	odd_base: u64,
	enabled: bool,
) -> bool {
	mapping_end := mapping.gpa + u64(mapping.size)
	if odd_base < mapping.gpa || odd_base >= mapping_end {return true}
	size := min(WHPX_A20_BIT, mapping_end - odd_base)
	source_base := enabled ? odd_base : odd_base &~ WHPX_A20_BIT
	if source_base < mapping.gpa || source_base + size > mapping_end {return false}
	if WHvUnmapGpaRange(vm.part, odd_base, size) < 0 {return false}
	source := rawptr(uintptr(mapping.host) + uintptr(source_base - mapping.gpa))
	flags := whpx_device_mapping_flags(mapping.track_dirty)
	return WHvMapGpaRange(vm.part, source, odd_base, size, flags) >= 0
}

@(private = "file")
whpx_map_device_mapping_at :: proc(vm: ^Vm, mapping: ^Device_Mapping, gpa: u64) -> bool {
	flags := whpx_device_mapping_flags(mapping.track_dirty)
	if WHvMapGpaRange(vm.part, mapping.host, gpa, u64(mapping.size), flags) < 0 {return false}
	if vm.a20_enabled {return true}

	temporary := mapping^
	temporary.gpa = gpa
	pair_base := gpa &~ (WHPX_A20_PAIR_SIZE - 1)
	mapping_end := gpa + u64(mapping.size)
	for odd_base := pair_base + WHPX_A20_BIT;
	    odd_base < mapping_end;
	    odd_base += WHPX_A20_PAIR_SIZE {
		if odd_base < gpa {continue}
		if !whpx_map_a20_device_region(vm, &temporary, odd_base, false) {
			_ = WHvUnmapGpaRange(vm.part, gpa, u64(mapping.size))
			return false
		}
	}
	return true
}

@(private = "file")
whpx_apply_device_mapping_request :: proc(
	vm: ^Vm,
	mapping: ^Device_Mapping,
) -> (
	ok: bool,
	rollback_ok: bool,
) {
	if !mapping.request_pending {return true, true}
	old_gpa, old_mapped := mapping.gpa, mapping.mapped
	new_gpa, new_mapped := mapping.requested_gpa, mapping.requested_mapped

	if old_mapped {
		if !whpx_capture_device_memory_dirty(vm, mapping) {return false, true}
		if WHvUnmapGpaRange(vm.part, old_gpa, u64(mapping.size)) < 0 {return false, true}
	}
	if new_mapped && !whpx_map_device_mapping_at(vm, mapping, new_gpa) {
		rollback_ok = !old_mapped || whpx_map_device_mapping_at(vm, mapping, old_gpa)
		return false, rollback_ok
	}

	mapping.gpa = new_gpa
	mapping.mapped = new_mapped
	mapping.request_pending = false
	return true, true
}

@(private = "file")
whpx_apply_device_mapping_requests :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	for &mapping in vm.device_mappings {
		if applied, rollback_applied := whpx_apply_device_mapping_request(vm, &mapping); !applied {
			return false, rollback_applied
		}
	}
	return true, true
}

@(private = "file")
whpx_map_device_alias_at :: proc(vm: ^Vm, alias: ^Device_Alias, backing_offset: u64) -> bool {
	if alias.mapping_index < 0 || alias.mapping_index >= len(vm.device_mappings) {return false}
	mapping := &vm.device_mappings[alias.mapping_index]
	source := rawptr(uintptr(mapping.host) + uintptr(backing_offset))
	flags := whpx_device_mapping_flags(mapping.track_dirty)
	return WHvMapGpaRange(vm.part, source, alias.gpa, alias.size, flags) >= 0
}

@(private = "file")
whpx_apply_device_alias_request :: proc(
	vm: ^Vm,
	alias: ^Device_Alias,
) -> (
	ok: bool,
	rollback_ok: bool,
) {
	if !alias.request_pending {return true, true}
	old_mapped := alias.mapped
	new_offset, new_mapped := alias.requested_offset, alias.requested_mapped

	if old_mapped {
		if !whpx_capture_device_alias_dirty(vm, alias) {
			alias.dirty_pending = true
		}
		if WHvUnmapGpaRange(vm.part, alias.gpa, alias.size) < 0 {return false, true}
		vm.device_alias_unmaps += 1
	}
	if new_mapped && !whpx_map_device_alias_at(vm, alias, new_offset) {
		vm.device_alias_map_failures += 1
		alias.backing_offset = new_offset
		alias.mapped = false
		alias.request_pending = false
		return true, true
	}

	alias.backing_offset = new_offset
	alias.mapped = new_mapped
	if new_mapped {vm.device_alias_maps += 1}
	alias.request_pending = false
	return true, true
}

@(private = "file")
whpx_apply_device_alias_requests :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	for &alias in vm.device_aliases {
		if applied, rollback_applied := whpx_apply_device_alias_request(vm, &alias); !applied {
			return false, rollback_applied
		}
	}
	return true, true
}

@(private = "file")
whpx_apply_a20_mapping :: proc(vm: ^Vm, enabled: bool) -> bool {
	for odd_base := WHPX_A20_BIT; odd_base < u64(len(vm.ram)); odd_base += WHPX_A20_PAIR_SIZE {
		if !whpx_map_a20_region(vm, odd_base, enabled) {return false}
	}
	for &mapping in vm.device_mappings {
		if !mapping.mapped {continue}
		pair_base := mapping.gpa &~ (WHPX_A20_PAIR_SIZE - 1)
		mapping_end := mapping.gpa + u64(mapping.size)
		for odd_base := pair_base + WHPX_A20_BIT;
		    odd_base < mapping_end;
		    odd_base += WHPX_A20_PAIR_SIZE {
			if odd_base < mapping.gpa {continue}
			if !whpx_map_a20_device_region(vm, &mapping, odd_base, enabled) {return false}
		}
	}
	return true
}

@(private = "file")
whpx_apply_a20_request :: proc(vm: ^Vm) -> (ok: bool, rollback_ok: bool) {
	if vm.a20_enabled == vm.a20_requested {return true, true}

	old_enabled := vm.a20_enabled
	new_enabled := vm.a20_requested
	for &mapping in vm.device_mappings {
		if !whpx_capture_device_memory_dirty(vm, &mapping) {return false, true}
	}
	if !whpx_apply_a20_mapping(vm, new_enabled) {
		rollback_ok = whpx_apply_a20_mapping(vm, old_enabled)
		vm.a20_requested = old_enabled
		return false, rollback_ok
	}
	vm.a20_enabled = vm.a20_requested
	vm.a20_apply_count += 1
	return true, true
}

// page-aligned private host copy mapped Read|Write|Execute: guest ROM safety alias
whpx_map_rom :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	size := uint(len(data) + 0xFFF) & ~uint(0xFFF)
	mem := win32.VirtualAlloc(
		nil,
		size,
		win32.MEM_COMMIT | win32.MEM_RESERVE,
		win32.PAGE_READWRITE,
	)
	if mem == nil {
		return false
	}
	copy(([^]u8)(mem)[:len(data)], data)
	flags :=
		WHV_MAP_GPA_RANGE_FLAG_READ | WHV_MAP_GPA_RANGE_FLAG_WRITE | WHV_MAP_GPA_RANGE_FLAG_EXECUTE
	if WHvMapGpaRange(vm.part, mem, gpa, u64(size), flags) < 0 {
		win32.VirtualFree(mem, 0, win32.MEM_RELEASE)
		return false
	}
	append(&vm.roms, Rom_Mapping{gpa = gpa, host = mem, size = int(size)})
	return true
}

// power-on state: real mode, CS F000:FFF0
whpx_reset_vcpu :: proc(vm: ^Vm) -> bool {
	code_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0xFFFF0000,
		Limit      = 0xFFFF,
		Selector   = 0xF000,
		Attributes = 0x009B,
	}
	data_seg := WHV_X64_SEGMENT_REGISTER {
		Base       = 0,
		Limit      = 0xFFFF,
		Selector   = 0,
		Attributes = 0x0093,
	}
	names := [?]WHV_REGISTER_NAME {
		.Cs,
		.Ds,
		.Es,
		.Ss,
		.Fs,
		.Gs,
		.Rip,
		.Rflags,
		.Rax,
		.Rbx,
		.Rcx,
		.Rdx,
		.Rsp,
		.Rbp,
		.Rsi,
		.Rdi,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = code_seg
	for i in 1 ..< 6 {
		vals[i].Segment = data_seg
	}
	vals[6].Reg64 = 0xFFF0
	vals[7].Reg64 = 0x2
	return WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) >= 0
}

whpx_reset_cpu :: proc(vm: ^Vm) -> bool {
	if vm == nil || vm.part == nil {return false}
	if WHvDeleteVirtualProcessor(vm.part, 0) < 0 {return false}
	if WHvCreateVirtualProcessor(vm.part, 0, 0) < 0 {return false}
	vm.irq_queued = false
	vm.irq_vector = 0
	vm.irq_deferred_pending_event = false
	return whpx_reset_vcpu(vm)
}

whpx_set_realmode_entry :: proc(vm: ^Vm, cs_base: u32, ip: u16) {
	names := [?]WHV_REGISTER_NAME{.Cs, .Rip, .Rflags}
	vals: [len(names)]WHV_REGISTER_VALUE
	vals[0].Segment = WHV_X64_SEGMENT_REGISTER {
		Base       = u64(cs_base),
		Limit      = 0xFFFF,
		Selector   = u16(cs_base >> 4),
		Attributes = 0x009B,
	}
	vals[1].Reg64 = u64(ip)
	vals[2].Reg64 = 0x2
	WHvSetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0])
}

// Max IO/MMIO emulation exits handled per whpx_run call. Keeps a port-polling
// guest from starving timers/IRQ injection: after the budget is spent, run
// returns Exit{kind = .Io} and the caller simply calls run again after
// pumping timers/IRQs.
WHPX_EXIT_BUDGET :: 32

whpx_run :: proc(vm: ^Vm) -> Exit {
	exit_ctx: WHV_RUN_VP_EXIT_CONTEXT
	for handled := 0;; handled += 1 {
		if ok, rollback_ok := whpx_apply_a20_request(vm); !ok {
			detail := "global A20 remap failed"
			if !rollback_ok {detail = "global A20 remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if ok, rollback_ok := whpx_apply_device_mapping_requests(vm); !ok {
			detail := "device memory remap failed"
			if !rollback_ok {detail = "device memory remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if ok, rollback_ok := whpx_apply_device_alias_requests(vm); !ok {
			detail := "device memory alias remap failed"
			if !rollback_ok {detail = "device memory alias remap and rollback failed"}
			return Exit{kind = .Failed, detail = detail}
		}
		if handled >= WHPX_EXIT_BUDGET {
			return Exit{kind = .Io}
		}
		vm.run_calls += 1
		hr := WHvRunVirtualProcessor(vm.part, 0, &exit_ctx, size_of(exit_ctx))
		if hr < 0 {
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("WHvRunVirtualProcessor hr=0x%08x", u32(hr)),
			}
		}
		whpx_note_physical_exit(vm, exit_ctx.ExitReason)
		if vm.irq_queued {
			interruption_pending := exit_ctx.VpContext.ExecutionState & (u16(1) << 6) != 0
			if interruption_pending {
				vm.irq_pending_exit_count += 1
			} else {
				pending_name := WHV_REGISTER_NAME.PendingInterruption
				pending_value: WHV_REGISTER_VALUE
				if WHvGetVirtualProcessorRegisters(vm.part, 0, &pending_name, 1, &pending_value) <
				   0 {
					return Exit{kind = .Failed, detail = "failed to verify PIC interrupt delivery"}
				}
				vm.irq_delivery_pending = pending_value.Reg64
				if pending_value.Reg64 & 0x1 != 0 {
					vm.irq_pending_exit_count += 1
				} else {
					vm.irq_delivery_reason = u32(exit_ctx.ExitReason)
					vm.irq_delivery_state = exit_ctx.VpContext.ExecutionState
					vm.irq_delivery_cs = exit_ctx.VpContext.Cs.Selector
					vm.irq_delivery_cs_base = exit_ctx.VpContext.Cs.Base
					vm.irq_delivery_rip = exit_ctx.VpContext.Rip
					vm.irq_delivery_rflags = exit_ctx.VpContext.Rflags
					vm.irq_delivery_io_port = 0
					vm.irq_delivery_io_access = 0
					vm.irq_delivery_io_rax = 0
					vm.irq_delivery_ins_len = 0
					vm.irq_delivery_ins = {}
					if exit_ctx.ExitReason == .X64IoPortAccess {
						io := &exit_ctx.u.IoPortAccess
						vm.irq_delivery_io_port = io.PortNumber
						vm.irq_delivery_io_access = io.AccessInfo
						vm.irq_delivery_io_rax = io.Rax
						vm.irq_delivery_ins_len = min(
							io.InstructionByteCount,
							u8(len(vm.irq_delivery_ins)),
						)
						copy(
							vm.irq_delivery_ins[:vm.irq_delivery_ins_len],
							io.InstructionBytes[:vm.irq_delivery_ins_len],
						)
					}
					if vm.irq_delivered != nil && !vm.irq_delivered(vm.irq_ctx, vm.irq_vector) {
						return Exit {
							kind = .Failed,
							detail = "PIC interrupt delivery callback failed",
						}
					}
					vm.irq_queued = false
					vm.irq_delivery_count += 1
				}
			}
		}
		switch exit_ctx.ExitReason {
		case .X64IoPortAccess:
			if ok, detail := whpx_emulate_io(vm, &exit_ctx.VpContext, &exit_ctx.u.IoPortAccess);
			   !ok {
				return Exit{kind = .Failed, detail = detail}
			}
			if vm.io_should_yield != nil && vm.io_should_yield(vm.io_ctx) {
				return Exit{kind = .Io}
			}
		case .MemoryAccess:
			if ok, detail := whpx_emulate_mmio(vm, &exit_ctx.VpContext, &exit_ctx.u.MemoryAccess);
			   !ok {
				mmio := &exit_ctx.u.MemoryAccess
				return Exit {
					kind = .Mmio_Undecodable,
					detail = detail,
					cs = exit_ctx.VpContext.Cs.Selector,
					rip = exit_ctx.VpContext.Rip,
					rflags = exit_ctx.VpContext.Rflags,
					gpa = mmio.Gpa,
					size = u8((mmio.AccessInfo >> 1) & 0x7),
					write = mmio.AccessInfo & 1 != 0,
				}
			}
			if vm.io_should_yield != nil && vm.io_should_yield(vm.io_ctx) {
				return Exit{kind = .Io}
			}
		case .X64Halt:
			// advance RIP past the HLT
			whpx_advance_rip(vm, &exit_ctx.VpContext)
			return Exit {
				kind = .Halt,
				cs = exit_ctx.VpContext.Cs.Selector,
				rip = exit_ctx.VpContext.Rip,
				rflags = exit_ctx.VpContext.Rflags,
			}
		case .X64InterruptWindow:
			return Exit{kind = .Interrupt_Window}
		case .X64Cpuid:
			if !whpx_handle_cpuid(vm, &exit_ctx.VpContext, &exit_ctx.u.CpuidAccess) {
				return Exit{kind = .Failed, detail = "failed to apply CPUID result"}
			}
		case .X64MsrAccess:
			if !whpx_handle_msr(vm, &exit_ctx.VpContext, &exit_ctx.u.MsrAccess) {
				return Exit{kind = .Failed, detail = "failed to handle MSR access"}
			}
		case .Canceled:
			vm.run_cancellations += 1
			return Exit{kind = .Canceled}
		case .UnrecoverableException:
			return Exit{kind = .Reset, detail = "unrecoverable exception (triple fault)"}
		case .Exception:
			if ok, detail := whpx_trace_and_reinject_exception(
				vm,
				&exit_ctx.VpContext,
				&exit_ctx.u.VpException,
			); !ok {
				return Exit{kind = .Failed, detail = detail}
			}
		case .None, .InvalidVpRegisterValue, .UnsupportedFeature, .X64ApicEoi:
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("unhandled exit: %v", exit_ctx.ExitReason),
			}
		case:
			return Exit {
				kind = .Failed,
				detail = fmt.tprintf("unknown exit: %d", u32(exit_ctx.ExitReason)),
			}
		}
	}
}

// safe to call from another thread while whpx_run is blocked
whpx_cancel :: proc(vm: ^Vm) {
	WHvCancelRunVirtualProcessor(vm.part, 0, 0)
}

whpx_set_time_running :: proc(vm: ^Vm, running: bool) -> bool {
	if vm == nil || vm.part == nil {return false}
	if vm.time_suspended == !running {return true}
	if running {
		if WHvResumePartitionTime(vm.part) < 0 {return false}
		vm.time_suspended = false
	} else {
		if WHvSuspendPartitionTime(vm.part) < 0 {return false}
		vm.time_suspended = true
	}
	return true
}

whpx_advance_rip :: proc(vm: ^Vm, vp_ctx: ^WHV_VP_EXIT_CONTEXT) {
	name := WHV_REGISTER_NAME.Rip
	val: WHV_REGISTER_VALUE
	val.Reg64 = whpx_next_rip(vp_ctx)
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_inject_irq :: proc(vm: ^Vm, vector: u8) {
	name := WHV_REGISTER_NAME.PendingInterruption
	val: WHV_REGISTER_VALUE
	// bit0 pending, type 0 (external interrupt), vector in bits 16..31
	val.Reg64 = 0x1 | (u64(vector) << 16)
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_try_inject_irq :: proc(vm: ^Vm, vector: u8) -> Interrupt_Injection_Result {
	if vm == nil || vm.part == nil {return .Failed}
	vm.irq_deferred_pending_event = false
	names := [?]WHV_REGISTER_NAME {
		.Rflags,
		.PendingInterruption,
		.InterruptState,
		.PendingEvent,
		.Cs,
		.Rip,
	}
	values: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &values[0]) < 0 {
		return .Failed
	}
	if_set := values[0].Reg64 & 0x200 != 0
	pending := values[1].Reg64 & 0x1 != 0
	shadow := values[2].Reg64 & 0x1 != 0
	event_pending := values[3].Reg128[0] & 0x1 != 0
	if event_pending {
		vm.irq_pending_event_deferrals += 1
		vm.irq_deferred_pending_event = true
		vm.irq_pending_event_low = values[3].Reg128[0]
		vm.irq_pending_event_high = values[3].Reg128[1]
	}
	if !if_set || pending || shadow || event_pending {
		if vm.shutdown_trace.armed {
			shutdown_trace_record(
				vm,
				Shutdown_Trace_Event {
					kind  = .Irq_Deferred,
					value = vector,
					cs    = values[4].Segment.Selector,
					flags = u32(if_set ? 0 : 1) |
						u32(pending ? 2 : 0) |
						u32(shadow ? 4 : 0) |
						u32(event_pending ? 8 : 0) |
						(values[0].Reg64 & 0x2_0000 != 0 ? SHUTDOWN_TRACE_FLAG_V86 : 0),
					rip    = values[5].Reg64,
					detail = values[3].Reg128[0],
				},
			)
		}
		return .Deferred
	}

	name := WHV_REGISTER_NAME.PendingInterruption
	value: WHV_REGISTER_VALUE
	value.Reg64 = 0x1 | u64(vector) << 16
	if WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &value) < 0 {
		return .Failed
	}
	if vm.shutdown_trace.armed {
		shutdown_trace_record(
			vm,
			Shutdown_Trace_Event {
				kind  = .Irq_Injected,
				value = vector,
				cs    = values[4].Segment.Selector,
				flags = values[0].Reg64 & 0x2_0000 != 0 ? SHUTDOWN_TRACE_FLAG_V86 : 0,
				rip   = values[5].Reg64,
			},
		)
	}
	vm.irq_queued = true
	vm.irq_vector = vector
	vm.irq_queue_count += 1
	vm.irq_queue_event = values[3].Reg128[0]
	vm.irq_queue_cs = values[4].Segment.Selector
	vm.irq_queue_cs_base = values[4].Segment.Base
	vm.irq_queue_rip = values[5].Reg64
	return .Injected
}

whpx_request_irq_window :: proc(vm: ^Vm, enable: bool) {
	name := WHV_REGISTER_NAME.DeliverabilityNotifications
	val: WHV_REGISTER_VALUE
	val.Reg64 = enable ? 0x2 : 0x0 // bit1 = InterruptNotification
	WHvSetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
}

whpx_can_inject :: proc(vm: ^Vm) -> bool {
	names := [?]WHV_REGISTER_NAME{.Rflags, .PendingInterruption, .InterruptState, .PendingEvent}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return false
	}
	if_set := vals[0].Reg64 & 0x200 != 0
	pending := vals[1].Reg64 & 0x1 != 0
	// WHV_X64_INTERRUPT_STATE_REGISTER: bit0 InterruptShadow, bit1 NmiMasked
	shadow := vals[2].Reg64 & 0x1 != 0
	event_pending := vals[3].Reg128[0] & 0x1 != 0
	return if_set && !pending && !shadow && !event_pending
}

whpx_reg_rax :: proc(vm: ^Vm) -> u64 {
	name := WHV_REGISTER_NAME.Rax
	val: WHV_REGISTER_VALUE
	WHvGetVirtualProcessorRegisters(vm.part, 0, &name, 1, &val)
	return val.Reg64
}

whpx_get_regs_checked :: proc(vm: ^Vm) -> (Regs, bool) {
	if vm == nil || vm.part == nil {return {}, false}
	names := [?]WHV_REGISTER_NAME {
		.Rax,
		.Rbx,
		.Rcx,
		.Rdx,
		.Rsi,
		.Rdi,
		.Rsp,
		.Rbp,
		.Rip,
		.Rflags,
		.Cr0,
		.Cr3,
		.Cs,
		.Ss,
		.Ds,
		.Es,
	}
	vals: [len(names)]WHV_REGISTER_VALUE
	if WHvGetVirtualProcessorRegisters(vm.part, 0, &names[0], u32(len(names)), &vals[0]) < 0 {
		return {}, false
	}
	return Regs {
		rax = vals[0].Reg64,
		rbx = vals[1].Reg64,
		rcx = vals[2].Reg64,
		rdx = vals[3].Reg64,
		rsi = vals[4].Reg64,
		rdi = vals[5].Reg64,
		rsp = vals[6].Reg64,
		rbp = vals[7].Reg64,
		rip = vals[8].Reg64,
		rflags = vals[9].Reg64,
		cr0 = vals[10].Reg64,
		cr3 = vals[11].Reg64,
		cs_sel = vals[12].Segment.Selector,
		cs_base = vals[12].Segment.Base,
		ss_sel = vals[13].Segment.Selector,
		ss_base = vals[13].Segment.Base,
		ds_sel = vals[14].Segment.Selector,
		es_sel = vals[15].Segment.Selector,
	}, true
}

whpx_get_regs :: proc(vm: ^Vm) -> Regs {
	regs, _ := whpx_get_regs_checked(vm)
	return regs
}

whpx_linear_read :: proc(vm: ^Vm, gva: u64, data: []u8) -> bool {
	if vm == nil || vm.part == nil {return false}
	cursor := 0
	for cursor < len(data) {
		linear := gva + u64(cursor)
		translation: WHV_TRANSLATE_GVA_RESULT
		gpa: u64
		if WHvTranslateGva(vm.part, 0, linear, 0x11, &translation, &gpa) < 0 ||
		   translation.ResultCode != .Success {
			return false
		}
		chunk := min(len(data) - cursor, int(0x1000 - (gpa & 0xfff)))
		if !whpx_physical_ram_read(vm, gpa, data[cursor:cursor + chunk]) {return false}
		cursor += chunk
	}
	return true
}

// --- emulator callbacks (WinHvEmulation) ---

whpx_emu_io :: proc "system" (ctx: rawptr, io: ^WHV_EMULATOR_IO_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	if io.Direction == 0 {
		if vm.io_read == nil {
			io.Data = 0xFFFFFFFF
			return 0
		}
		value, ok := vm.io_read(vm.io_ctx, io.Port, u8(io.AccessSize))
		io.Data = value
		if !ok {return HRESULT(-2147467259)}
	} else {
		if vm.io_write != nil && !vm.io_write(vm.io_ctx, io.Port, u8(io.AccessSize), io.Data) {
			return HRESULT(-2147467259)
		}
	}
	return 0
}

// The emulator resolves EVERY memory operand of an emulated instruction
// through this callback — including plain guest RAM (e.g. the buffer of a
// rep insb). Serve RAM and ROM directly; only true device MMIO reaches
// vm.mmio.
whpx_emu_mmio :: proc "system" (ctx: rawptr, mem: ^WHV_EMULATOR_MEMORY_ACCESS_INFO) -> HRESULT {
	context = runtime.default_context()
	return whpx_emulate_memory_access((^Vm)(ctx), mem)
}

whpx_emu_get_regs :: proc "system" (
	ctx: rawptr,
	names: [^]WHV_REGISTER_NAME,
	count: u32,
	values: [^]WHV_REGISTER_VALUE,
) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvGetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

whpx_emu_set_regs :: proc "system" (
	ctx: rawptr,
	names: [^]WHV_REGISTER_NAME,
	count: u32,
	values: [^]WHV_REGISTER_VALUE,
) -> HRESULT {
	vm := (^Vm)(ctx)
	return WHvSetVirtualProcessorRegisters(vm.part, 0, names, count, values)
}

whpx_emu_translate :: proc "system" (
	ctx: rawptr,
	gva: u64,
	flags: u32,
	result: ^WHV_TRANSLATE_GVA_RESULT_CODE,
	gpa: ^u64,
) -> HRESULT {
	context = runtime.default_context()
	vm := (^Vm)(ctx)
	translation: WHV_TRANSLATE_GVA_RESULT
	translated_gpa: u64
	hr := WHvTranslateGva(vm.part, 0, gva, flags, &translation, &translated_gpa)
	result^ = translation.ResultCode
	gpa^ = translated_gpa
	return hr
}
