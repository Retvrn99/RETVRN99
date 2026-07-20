// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import video "../vga"
import "core:fmt"
import "core:strings"

MACHINE_STALLED_HALT_NS :: u64(5_000_000_000)
MACHINE_VGA_POLL_STALL_NS :: u64(2_000_000_000)
MACHINE_VGA_IRQ_STORM_NS :: u64(1_000_000_000)
MACHINE_VGA_IRQ_STORM_COUNT :: u64(256)
MACHINE_SHUTDOWN_MARKER_CAPACITY :: 32
MACHINE_GSW_SHUTDOWN_STALL_NS :: u64(5_000_000_000)
MACHINE_MMIO_STORM_WINDOW_NS :: u64(1_000_000_000)
MACHINE_MMIO_STORM_THRESHOLD :: u64(20_000)

Runtime_Diagnostic_Kind :: enum u8 {
	None,
	Halted,
	Vga_Status_Poll,
	Vga_Irq_Storm,
	Gsw_Shutdown,
	Mmio_Storm,
}

Runtime_Diagnostic_State :: struct {
	pending:                  Runtime_Diagnostic_Kind,
	halt_active:              bool,
	halt_started_ns:          u64,
	halt_cs:                  u16,
	halt_rip:                 u64,
	halt_rflags:              u64,
	halt_reported:            bool,
	vga_poll_active:          bool,
	vga_poll_started_ns:      u64,
	vga_poll_origin:          u64,
	vga_poll_count:           u64,
	vga_poll_value:           u8,
	vga_poll_reported:        bool,
	vga_irq_window_active:    bool,
	vga_irq_window_ns:        u64,
	vga_irq_window_count:     u64,
	vga_irq_reported:         bool,
	last_io:                  Io_Trace,
	apm_write_count:          u64,
	apm_last_size:            u8,
	apm_last_value:           u32,
	shutdown_markers:         [MACHINE_SHUTDOWN_MARKER_CAPACITY]u8,
	shutdown_marker_count:    u64,
	shutdown_marker_active:   bool,
	shutdown_marker_started:  u64,
	shutdown_marker_reported: bool,
	mmio_window_ns:           u64,
	mmio_window_fallbacks:    u64,
	mmio_window_scalar:       u64,
	mmio_window_string:       u64,
	mmio_report_fallbacks:    u64,
	mmio_report_scalar:       u64,
	mmio_report_string:       u64,
	mmio_reported:            bool,
}

@(private = "file")
machine_runtime_diagnostic_queue :: proc(m: ^Machine, kind: Runtime_Diagnostic_Kind) {
	if m == nil || kind == .None || m.runtime_diagnostic.pending != .None {return}
	m.runtime_diagnostic.pending = kind
}

@(private = "package")
machine_runtime_diagnostic_note_halt :: proc(m: ^Machine, ex: hv.Exit) {
	if m == nil {return}
	d := &m.runtime_diagnostic
	d.halt_active = true
	d.halt_started_ns = m.active_ns
	d.halt_cs = ex.cs
	d.halt_rip = ex.rip
	d.halt_rflags = ex.rflags
	d.halt_reported = false
}

@(private = "package")
machine_runtime_diagnostic_note_resume :: proc(m: ^Machine) {
	if m == nil {return}
	m.runtime_diagnostic.halt_active = false
	m.runtime_diagnostic.halt_started_ns = 0
	m.runtime_diagnostic.halt_reported = false
}

@(private = "package")
machine_runtime_diagnostic_check_halt :: proc(m: ^Machine) {
	if m == nil {return}
	d := &m.runtime_diagnostic
	if !d.halt_active || d.halt_reported || m.active_ns < d.halt_started_ns {return}
	if m.active_ns - d.halt_started_ns < MACHINE_STALLED_HALT_NS {return}
	d.halt_reported = true
	machine_runtime_diagnostic_queue(m, .Halted)
}

@(private = "package")
machine_runtime_diagnostic_note_io :: proc(
	m: ^Machine,
	port: u16,
	write: bool,
	size: u8,
	value: u32,
) {
	if m == nil {return}
	d := &m.runtime_diagnostic
	d.last_io = {
		port  = port,
		write = write,
		size  = size,
		val   = value,
	}
	status_read := !write && size == 1 && (port == 0x03BA || port == 0x03DA)
	if !status_read {
		d.vga_poll_active = false
		d.vga_poll_started_ns = 0
		d.vga_poll_origin = 0
		d.vga_poll_count = 0
		d.vga_poll_reported = false
		return
	}
	origin := m.vm.io_origin.valid ? m.vm.io_origin.linear : 0
	if !d.vga_poll_active || d.vga_poll_origin != origin {
		d.vga_poll_active = true
		d.vga_poll_started_ns = m.active_ns
		d.vga_poll_origin = origin
		d.vga_poll_count = 0
		d.vga_poll_reported = false
	}
	d.vga_poll_count += 1
	d.vga_poll_value = u8(value)
	if !d.vga_poll_reported &&
	   m.active_ns >= d.vga_poll_started_ns &&
	   m.active_ns - d.vga_poll_started_ns >= MACHINE_VGA_POLL_STALL_NS {
		d.vga_poll_reported = true
		machine_runtime_diagnostic_queue(m, .Vga_Status_Poll)
	}
}

@(private = "package")
machine_runtime_diagnostic_note_irq :: proc(m: ^Machine, offer: Pic_Interrupt_Token) {
	if m == nil || offer.kind != .Slave || offer.slave_irq != 1 {return}
	d := &m.runtime_diagnostic
	if !d.vga_irq_window_active ||
	   m.active_ns < d.vga_irq_window_ns ||
	   m.active_ns - d.vga_irq_window_ns >= MACHINE_VGA_IRQ_STORM_NS {
		d.vga_irq_window_active = true
		d.vga_irq_window_ns = m.active_ns
		d.vga_irq_window_count = 0
		d.vga_irq_reported = false
	}
	d.vga_irq_window_count += 1
	if !d.vga_irq_reported && d.vga_irq_window_count >= MACHINE_VGA_IRQ_STORM_COUNT {
		d.vga_irq_reported = true
		machine_runtime_diagnostic_queue(m, .Vga_Irq_Storm)
	}
}

@(private = "package")
machine_runtime_diagnostic_note_apm_write :: proc(m: ^Machine, size: u8, value: u32) {
	if m == nil {return}
	m.runtime_diagnostic.apm_write_count += 1
	m.runtime_diagnostic.apm_last_size = size
	m.runtime_diagnostic.apm_last_value = value
	m.runtime_diagnostic.shutdown_marker_active = false
}

@(private = "package")
machine_runtime_diagnostic_note_shutdown_marker :: proc(m: ^Machine, value: u8) {
	if m == nil || value < 0xD0 || value > 0xDE {return}
	d := &m.runtime_diagnostic
	d.shutdown_markers[d.shutdown_marker_count % MACHINE_SHUTDOWN_MARKER_CAPACITY] = value
	d.shutdown_marker_count += 1
	if (value == 0xD5 || value == 0xD6) && !d.shutdown_marker_active {
		d.shutdown_marker_active = true
		d.shutdown_marker_started = m.active_ns
		d.shutdown_marker_reported = false
	} else if value == 0xDC {
		d.shutdown_marker_active = false
	}
}

@(private = "package")
machine_runtime_diagnostic_check_shutdown :: proc(m: ^Machine) {
	if m == nil {return}
	d := &m.runtime_diagnostic
	if !d.shutdown_marker_active ||
	   d.shutdown_marker_reported ||
	   m.active_ns < d.shutdown_marker_started ||
	   m.active_ns - d.shutdown_marker_started < MACHINE_GSW_SHUTDOWN_STALL_NS {
		return
	}
	d.shutdown_marker_reported = true
	machine_runtime_diagnostic_queue(m, .Gsw_Shutdown)
}

@(private = "package")
machine_runtime_diagnostic_check_mmio :: proc(m: ^Machine) {
	if m == nil {return}
	d := &m.runtime_diagnostic
	if d.mmio_window_ns == 0 || m.active_ns < d.mmio_window_ns {
		d.mmio_window_ns = m.active_ns
		d.mmio_window_fallbacks = m.vm.mmio_fallbacks
		d.mmio_window_scalar = m.vm.mmio_scalar_fallbacks
		d.mmio_window_string = m.vm.mmio_string_fallbacks
		return
	}
	if m.active_ns - d.mmio_window_ns < MACHINE_MMIO_STORM_WINDOW_NS {return}
	fallbacks := m.vm.mmio_fallbacks - min(m.vm.mmio_fallbacks, d.mmio_window_fallbacks)
	scalar := m.vm.mmio_scalar_fallbacks - min(m.vm.mmio_scalar_fallbacks, d.mmio_window_scalar)
	string := m.vm.mmio_string_fallbacks - min(m.vm.mmio_string_fallbacks, d.mmio_window_string)
	d.mmio_window_ns = m.active_ns
	d.mmio_window_fallbacks = m.vm.mmio_fallbacks
	d.mmio_window_scalar = m.vm.mmio_scalar_fallbacks
	d.mmio_window_string = m.vm.mmio_string_fallbacks
	if fallbacks < MACHINE_MMIO_STORM_THRESHOLD {
		d.mmio_reported = false
		return
	}
	if d.mmio_reported {return}
	d.mmio_report_fallbacks = fallbacks
	d.mmio_report_scalar = scalar
	d.mmio_report_string = string
	d.mmio_reported = true
	machine_runtime_diagnostic_queue(m, .Mmio_Storm)
}

machine_take_runtime_diagnostic :: proc(m: ^Machine) -> (string, bool) {
	if m == nil || m.runtime_diagnostic.pending == .None {return "", false}
	d := &m.runtime_diagnostic
	kind := d.pending
	d.pending = .None
	builder := strings.builder_make(0, 320, context.allocator)
	switch kind {
	case .Halted:
		last := d.last_io
		fmt.sbprintf(
			&builder,
			"diagnostic: guest halted for 5s CS:IP=%04x:%08x IF=%d last_io=%c[%04x]/%d=%08x crtc11=%02x crtc17=%02x",
			d.halt_cs,
			d.halt_rip,
			d.halt_rflags & 0x200 != 0 ? 1 : 0,
			last.write ? 'w' : 'r',
			last.port,
			last.size,
			last.val,
			m.vga.crtc[0x11],
			m.vga.crtc[0x17],
		)
	case .Vga_Status_Poll:
		fmt.sbprintf(
			&builder,
			"diagnostic: guest polled VGA status for 2s origin=%08x reads=%d status=%02x crtc11=%02x crtc17=%02x",
			d.vga_poll_origin,
			d.vga_poll_count,
			d.vga_poll_value,
			m.vga.crtc[0x11],
			m.vga.crtc[0x17],
		)
	case .Vga_Irq_Storm:
		fmt.sbprintf(
			&builder,
			"diagnostic: VGA IRQ9 storm deliveries=%d crtc11=%02x crtc17=%02x",
			d.vga_irq_window_count,
			m.vga.crtc[0x11],
			m.vga.crtc[0x17],
		)
	case .Gsw_Shutdown:
		fmt.sbprintf(&builder, "diagnostic: GSW shutdown stalled for 5s markers=")
		count := min(d.shutdown_marker_count, u64(MACHINE_SHUTDOWN_MARKER_CAPACITY))
		start := d.shutdown_marker_count - count
		for index in start ..< d.shutdown_marker_count {
			fmt.sbprintf(
				&builder,
				"%02x",
				d.shutdown_markers[index % MACHINE_SHUTDOWN_MARKER_CAPACITY],
			)
		}
	case .Mmio_Storm:
		alias := hv.Device_Alias{}
		if len(m.vm.device_aliases) > 0 {alias = m.vm.device_aliases[0]}
		fmt.sbprintf(
			&builder,
			"diagnostic: MMIO exit storm fallbacks=%d scalar=%d string=%d vbe=%02x bpp=%d bank=%d/%d alias=%d pending=%d offset=%x requested=%x maps=%d unmaps=%d map_fail=%d dirty_q=%d dirty_fail=%d",
			d.mmio_report_fallbacks,
			d.mmio_report_scalar,
			d.mmio_report_string,
			m.vga.dispi[video.DISPI_INDEX_ENABLE],
			m.vga.dispi[video.DISPI_INDEX_BPP],
			m.vga.bank_read,
			m.vga.bank_write,
			alias.mapped ? 1 : 0,
			alias.request_pending ? 1 : 0,
			alias.backing_offset,
			alias.requested_offset,
			m.vm.device_alias_maps,
			m.vm.device_alias_unmaps,
			m.vm.device_alias_map_failures,
			m.vm.device_alias_dirty_queries,
			m.vm.device_alias_query_failures,
		)
	case .None:
		strings.builder_destroy(&builder)
		return "", false
	}
	fmt.sbprintf(
		&builder,
		" irq9 irr=%02x isr=%02x imr=%02x elcr=%02x line=%02x apm_writes=%d last_apm=%d/%08x",
		m.pic.slave.irr,
		m.pic.slave.isr,
		m.pic.slave.imr,
		m.pic.slave.elcr,
		m.pic.source_asserted[9],
		d.apm_write_count,
		d.apm_last_size,
		d.apm_last_value,
	)
	return strings.to_string(builder), true
}
