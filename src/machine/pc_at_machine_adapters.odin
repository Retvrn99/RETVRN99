// SPDX-License-Identifier: GPL-3.0-only
package machine

import sound "../audio"
import hv "../hv"

machine_pc_at_guest_memory :: proc(ctx: rawptr) -> []u8 {
	m := (^Machine)(ctx)
	return m == nil ? nil : m.vm.ram
}

machine_pc_at_apply_a20 :: proc(ctx: rawptr, enabled: bool) -> bool {
	m := (^Machine)(ctx)
	return m != nil && hv.set_a20(&m.vm, enabled)
}

machine_pc_at_freeze :: proc(ctx: rawptr, reason: string) {
	m := (^Machine)(ctx)
	if m != nil {bus_freeze(pc_at_platform_bus(&m.platform), reason)}
}

machine_pc_at_master_now :: proc(ctx: rawptr) -> u64 {
	m := (^Machine)(ctx)
	return m == nil ? 0 : master_timeline_now(m.timeline)
}

machine_pc_at_master_advance_ns :: proc(ctx: rawptr, nanoseconds: u64) {
	m := (^Machine)(ctx)
	if m != nil {machine_advance_time_ns(m, nanoseconds)}
}

machine_pc_at_scheduled_device :: proc(device: Pc_At_Device) -> Scheduled_Device {
	switch device {
	case .Pit:
		return .Pit
	case .Uart1:
		return .Uart1
	case .Uart2:
		return .Uart2
	case .Lpt1:
		return .Lpt1
	case .Lpt2:
		return .Lpt2
	case .Dma:
		return .Dma
	case .I8042:
		return .I8042
	case .Cmos:
		return .Cmos
	case .Count:
		return .Count
	}
	return .Count
}

machine_scheduled_pc_at_device :: proc(device: Scheduled_Device) -> (Pc_At_Device, bool) {
	switch device {
	case .Pit:
		return .Pit, true
	case .Uart1:
		return .Uart1, true
	case .Uart2:
		return .Uart2, true
	case .Lpt1:
		return .Lpt1, true
	case .Lpt2:
		return .Lpt2, true
	case .Dma:
		return .Dma, true
	case .I8042:
		return .I8042, true
	case .Cmos:
		return .Cmos, true
	case .Fdc, .Ide, .Atapi, .Bmide, .Audio, .Vga, .Governor, .Count:
	}
	return .Count, false
}

machine_pc_at_sync_device :: proc(ctx: rawptr, device: Pc_At_Device) {
	m := (^Machine)(ctx)
	if m == nil || device == .Count {return}
	machine_sync_device(m, machine_pc_at_scheduled_device(device))
}

machine_pc_at_audio_sync :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	if m != nil {machine_sync_device(m, .Audio)}
}

machine_pc_at_audio_pit_changed :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	if m == nil {return}
	platform := &m.platform
	machine_audio_apply_pit_transitions(m)
	_ = sound.audio_mixer_set_speaker_state(
		&m.audio,
		master_timeline_now(m.timeline),
		platform.pit.port61_low & 0x02 != 0,
		pit_channel_out(&platform.pit, 2),
	)
}

machine_pc_at_request_irq_window :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	if m != nil && m.vm.part != nil {hv.request_irq_window(&m.vm, true)}
}

machine_pc_at_event :: proc(ctx: rawptr, event: Pc_At_Event) {
	m := (^Machine)(ctx)
	if m == nil {return}
	switch event.kind {
	case .Shutdown_Marker:
		machine_runtime_diagnostic_note_shutdown_marker(m, u8(event.a))
	case .Apm_Write:
		machine_runtime_diagnostic_note_apm_write(m, u8(event.a), u32(event.b))
	case .Progress:
		machine_trace_record(m, .Progress, event.a, event.b, event.c)
	case .Reset_Request:
		machine_trace_record(m, .Reset_Request, event.a)
	}
}

machine_pc_at_adapters :: proc(m: ^Machine) -> Pc_At_Adapters {
	return {
		ctx                = m,
		guest_memory       = machine_pc_at_guest_memory,
		apply_a20          = machine_pc_at_apply_a20,
		freeze             = machine_pc_at_freeze,
		master_now         = machine_pc_at_master_now,
		master_advance_ns  = machine_pc_at_master_advance_ns,
		sync_device        = machine_pc_at_sync_device,
		audio_sync         = machine_pc_at_audio_sync,
		audio_pit_changed  = machine_pc_at_audio_pit_changed,
		request_irq_window = machine_pc_at_request_irq_window,
		event              = machine_pc_at_event,
	}
}

@(private = "package")
machine_guest_reset :: proc(ctx: rawptr) {
	m := (^Machine)(ctx)
	if m == nil {return}
	if m.platform.adapters.ctx == nil {m.platform.adapters = machine_pc_at_adapters(m)}
	pc_at_platform_guest_reset(&m.platform)
}
