// SPDX-License-Identifier: GPL-3.0-only
package machine

import hv "../hv"
import "core:fmt"
import "core:strings"

HARDWARE_TRACE_CAPACITY :: 4096
HARDWARE_TRACE_LINE_MAX_BYTES :: 128
HARDWARE_TRACE_TEXT_MAX_BYTES :: HARDWARE_TRACE_CAPACITY * HARDWARE_TRACE_LINE_MAX_BYTES
HARDWARE_TRACE_NOISY_WINDOW :: 65_536
HARDWARE_TRACE_NOISY_RETAIN :: 1
HARDWARE_TRACE_NOISY_INITIAL_RETAIN :: 8
HARDWARE_TRACE_NOISY_KINDS :: 13

Hardware_Event_Kind :: enum u8 {
	None,
	Wake_Arm,
	Wake_Fire,
	Wake_Disarm,
	Hv_Exit,
	Pic_Command,
	Pic_Queue,
	Pic_Inject,
	Pic_Delivery_State,
	Pit_Access,
	Pit_Program,
	Rtc_Access,
	Dma_Access,
	I8042_Access,
	Reset_Request,
	Pci_Config,
	Pirq,
	Ide_Access,
	Bmide_Access,
	Atapi_Packet,
	Fdc_Access,
	Isa_Pnp_Access,
	Sb16_Command,
	Sb16_Response,
	Sb16_Poll,
	Vga_Access,
	Mmio_Access,
	Freeze,
	Progress,
}

Hardware_Event :: struct {
	tick: u64,
	kind: Hardware_Event_Kind,
	a:    u64,
	b:    u64,
	c:    u64,
}

Hardware_Trace_Stats :: struct {
	observed:   u64,
	retained:   u64,
	suppressed: u64,
}

Hardware_Trace :: struct {
	enabled:          bool,
	events:           [HARDWARE_TRACE_CAPACITY]Hardware_Event,
	observed_count:   u64,
	retained_count:   u64,
	suppressed_count: u64,
	noisy_observed:   [HARDWARE_TRACE_NOISY_KINDS]u64,
}

machine_set_hardware_trace :: proc(m: ^Machine, enabled: bool) -> bool {
	if m == nil {return false}
	if enabled && m.hardware_trace == nil {m.hardware_trace = new(Hardware_Trace)}
	if m.hardware_trace == nil {return !enabled}
	hardware_trace_enable(m.hardware_trace, enabled)
	return true
}

machine_hardware_trace_detach :: proc(m: ^Machine) -> ^Hardware_Trace {
	if m == nil {return nil}
	trace := m.hardware_trace
	m.hardware_trace = nil
	return trace
}

machine_hardware_trace_attach :: proc(m: ^Machine, trace: ^Hardware_Trace) -> bool {
	if m == nil || m.hardware_trace != nil {return false}
	m.hardware_trace = trace
	return true
}

machine_hardware_trace_text :: proc(m: ^Machine) -> string {
	if m == nil || m.hardware_trace == nil {return ""}
	return hardware_trace_text(m.hardware_trace)
}

machine_hardware_trace_count :: proc(m: ^Machine) -> u64 {
	return m != nil && m.hardware_trace != nil ? m.hardware_trace.retained_count : 0
}

machine_hardware_trace_stats :: proc(m: ^Machine) -> Hardware_Trace_Stats {
	if m == nil {return {}}
	return hardware_trace_stats(m.hardware_trace)
}

machine_trace_record :: proc(
	m: ^Machine,
	kind: Hardware_Event_Kind,
	a: u64 = 0,
	b: u64 = 0,
	c: u64 = 0,
) {
	if m == nil || m.hardware_trace == nil {return}
	hardware_trace_record(m.hardware_trace, master_timeline_now(m.timeline), kind, a, b, c)
}

hardware_trace_enable :: proc(trace: ^Hardware_Trace, enabled: bool) {
	if trace == nil {return}
	trace.enabled = enabled
}

hardware_trace_stats :: proc(trace: ^Hardware_Trace) -> Hardware_Trace_Stats {
	if trace == nil {return {}}
	return {
		observed = trace.observed_count,
		retained = trace.retained_count,
		suppressed = trace.suppressed_count,
	}
}

@(private = "file")
hardware_trace_noisy_index :: proc(kind: Hardware_Event_Kind) -> (int, bool) {
	#partial switch kind {
	case .Wake_Arm:
		return 0, true
	case .Wake_Fire:
		return 1, true
	case .Wake_Disarm:
		return 2, true
	case .Hv_Exit:
		return 3, true
	case .Pit_Access:
		return 4, true
	case .Mmio_Access:
		return 5, true
	case .Vga_Access:
		return 6, true
	case .Ide_Access:
		return 7, true
	case .Sb16_Poll:
		return 8, true
	case .Pic_Command:
		return 9, true
	case .Pic_Queue:
		return 10, true
	case .Pic_Inject:
		return 11, true
	case .Pic_Delivery_State:
		return 12, true
	case:
		return 0, false
	}
}

@(private = "file")
hardware_trace_exceptional_hv_exit :: proc(kind: Hardware_Event_Kind, value: u64) -> bool {
	return(
		kind == .Hv_Exit &&
		(value == u64(hv.Exit_Kind.Reset) || value == u64(hv.Exit_Kind.Failed)) \
	)
}

@(private = "file")
hardware_trace_should_retain :: proc(
	trace: ^Hardware_Trace,
	kind: Hardware_Event_Kind,
	a: u64,
) -> bool {
	index, noisy := hardware_trace_noisy_index(kind)
	if !noisy {return true}
	sequence := trace.noisy_observed[index]
	trace.noisy_observed[index] += 1
	if hardware_trace_exceptional_hv_exit(kind, a) {return true}
	if sequence < HARDWARE_TRACE_NOISY_INITIAL_RETAIN {return true}
	return sequence % HARDWARE_TRACE_NOISY_WINDOW < HARDWARE_TRACE_NOISY_RETAIN
}

hardware_trace_record :: proc(
	trace: ^Hardware_Trace,
	tick: u64,
	kind: Hardware_Event_Kind,
	a: u64 = 0,
	b: u64 = 0,
	c: u64 = 0,
) {
	if trace == nil || !trace.enabled || kind == .None {return}
	trace.observed_count += 1
	if !hardware_trace_should_retain(trace, kind, a) {
		trace.suppressed_count += 1
		return
	}
	trace.events[trace.retained_count % HARDWARE_TRACE_CAPACITY] = {
		tick = tick,
		kind = kind,
		a    = a,
		b    = b,
		c    = c,
	}
	trace.retained_count += 1
}

hardware_trace_io_kind :: proc(
	port: u16,
	write: bool,
	isa_pnp: ^Isa_Pnp = nil,
	value: u32 = 0,
) -> Hardware_Event_Kind {
	if write && port == 0x0092 && value & 1 != 0 {return .Reset_Request}
	if write && port == 0x0CF9 && value & 0x04 != 0 {return .Reset_Request}
	if write && port >= 0x0040 && port <= 0x0042 {return .Pit_Program}
	if write && port == 0x0043 && value != 0 {return .Pit_Program}
	if write && port == 0x0061 {return .Pit_Program}
	if port >= 0x0040 && port <= 0x0042 {return .Pit_Access}
	if write && (port == 0x0043 || port == 0x0061) {return .Pit_Access}
	if write && (port == ISA_PNP_ADDRESS_PORT || port == ISA_PNP_WRITE_DATA_PORT) {
		return .Isa_Pnp_Access
	}
	if !write && isa_pnp != nil {
		read_data_port, programmed := isa_pnp_read_data_selection(isa_pnp)
		if programmed && port == read_data_port {return .Isa_Pnp_Access}
	}
	if port >= 0x0220 && port <= 0x022F {
		if write {return .Sb16_Command}
		if port == 0x022A {return .Sb16_Response}
		if port == 0x022C || port == 0x022E || port == 0x022F {return .Sb16_Poll}
	}
	if port == 0x0020 || port == 0x0021 || port == 0x00A0 || port == 0x00A1 {
		return write ? .Pic_Command : .None
	}
	if port == 0x0070 || port == 0x0071 {return .Rtc_Access}
	if port == 0x0060 || (port == 0x0064 && write) {return .I8042_Access}
	if port <= 0x000F ||
	   port == 0x0081 ||
	   port == 0x0082 ||
	   port == 0x0083 ||
	   port == 0x0087 ||
	   port == 0x0089 ||
	   port == 0x008A ||
	   port == 0x008B ||
	   port == 0x008F ||
	   port >= 0x00C0 && port <= 0x00DE {
		return .Dma_Access
	}
	if write && port >= 0x0CF8 && port <= 0x0CFF {return .Pci_Config}
	if port == 0x01F7 || port == 0x0177 || port == 0x03F6 || port == 0x0376 {
		return write ? .Ide_Access : .None
	}
	if port >= 0x03F2 && port <= 0x03F7 {
		if port == 0x03F5 || write {return .Fdc_Access}
	}
	if port >= 0x03B0 && port <= 0x03DF && (write || port == 0x03DA) {return .Vga_Access}
	return .None
}

hardware_event_kind_name :: proc(kind: Hardware_Event_Kind) -> string {
	switch kind {
	case .None:
		return "none"
	case .Wake_Arm:
		return "wake-arm"
	case .Wake_Fire:
		return "wake-fire"
	case .Wake_Disarm:
		return "wake-disarm"
	case .Hv_Exit:
		return "hv-exit"
	case .Pic_Command:
		return "pic"
	case .Pic_Queue:
		return "pic-queue"
	case .Pic_Inject:
		return "pic-inject"
	case .Pic_Delivery_State:
		return "pic-state"
	case .Pit_Access:
		return "pit"
	case .Pit_Program:
		return "pit-program"
	case .Rtc_Access:
		return "rtc"
	case .Dma_Access:
		return "dma"
	case .I8042_Access:
		return "i8042"
	case .Reset_Request:
		return "reset"
	case .Pci_Config:
		return "pci-config"
	case .Pirq:
		return "pirq"
	case .Ide_Access:
		return "ide"
	case .Bmide_Access:
		return "bmide"
	case .Atapi_Packet:
		return "atapi"
	case .Fdc_Access:
		return "fdc"
	case .Isa_Pnp_Access:
		return "isa-pnp"
	case .Sb16_Command:
		return "sb16-command"
	case .Sb16_Response:
		return "sb16-response"
	case .Sb16_Poll:
		return "sb16-poll"
	case .Vga_Access:
		return "vga"
	case .Mmio_Access:
		return "mmio"
	case .Freeze:
		return "freeze"
	case .Progress:
		return "progress"
	}
	return "unknown"
}

hardware_trace_text :: proc(trace: ^Hardware_Trace) -> string {
	if trace == nil {return ""}
	builder := strings.builder_make(
		0,
		int(min(trace.retained_count, u64(HARDWARE_TRACE_CAPACITY))) *
		HARDWARE_TRACE_LINE_MAX_BYTES,
	)
	count := min(trace.retained_count, u64(HARDWARE_TRACE_CAPACITY))
	start := trace.retained_count - count
	for sequence in start ..< trace.retained_count {
		event := trace.events[sequence % HARDWARE_TRACE_CAPACITY]
		fmt.sbprintfln(
			&builder,
			"%08d tick=%d %-12s a=%016x b=%016x c=%016x",
			sequence,
			event.tick,
			hardware_event_kind_name(event.kind),
			event.a,
			event.b,
			event.c,
		)
	}
	text := strings.to_string(builder)
	assert(len(text) <= HARDWARE_TRACE_TEXT_MAX_BYTES)
	return text
}
