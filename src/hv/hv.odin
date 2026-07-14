// SPDX-License-Identifier: GPL-3.0-only
package hv

// Hypervisor interface. M1: WHPX backend only (the KVM seam comes later).

Exit_Kind :: enum {
	Io,
	Mmio,
	Halt,
	Interrupt_Window,
	Canceled,
	Reset,
	Failed,
}

Exit :: struct {
	kind:   Exit_Kind,
	detail: string, // failure or reset provenance
}

Interrupt_Injection_Result :: enum {
	Injected,
	Deferred,
	Failed,
}

Vm_Create_Options :: struct {
	trace_ud_gp_exits: bool,
}

Exception_Trace_Record :: struct {
	vector:                 u8,
	error_code_valid:       bool,
	software_exception:     bool,
	instruction_byte_count: u8,
	error_code:             u32,
	exception_parameter:    u64,
	rip:                    u64,
	rflags:                 u64,
	instruction_bytes:      [16]u8,
}

Rom_Mapping :: struct {
	gpa:  u64,
	host: rawptr,
	size: int,
}

Mmio_Reservation :: struct {
	gpa:  u64,
	size: u64,
	kind: Memory_Reservation_Kind,
}

Memory_Reservation_Kind :: enum {
	Mmio,
	Open_Bus,
}

Device_Mapping :: struct {
	gpa:  u64,
	host: rawptr,
	size: int,
}

Vm :: struct {
	part:                   rawptr, // WHV_PARTITION_HANDLE
	ram:                    []u8, // contiguous guest RAM mapped at GPA 0
	emu:                    rawptr, // WHV_EMULATOR_HANDLE
	roms:                   [dynamic]Rom_Mapping, // host copies backing map_rom regions
	mmio_reservations:      [dynamic]Mmio_Reservation,
	device_mappings:        [dynamic]Device_Mapping,
	a20_enabled:            bool,
	a20_requested:          bool,
	a20_request_count:      u64,
	a20_apply_count:        u64,
	time_suspended:         bool,
	io_ctx:                 rawptr,
	io_read:                proc(ctx: rawptr, port: u16, size: u8) -> (u32, bool),
	io_write:               proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool,
	io_stream_read:         proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> (int, bool, bool),
	io_stream_write:        proc(ctx: rawptr, port: u16, size: u8, data: []u8) -> (int, bool, bool),
	io_string_budget:       proc(ctx: rawptr) -> u64,
	io_string_begin:        proc(ctx: rawptr),
	io_string_end:          proc(ctx: rawptr),
	io_should_yield:        proc(ctx: rawptr) -> bool,
	io_string_translations: u64,
	run_calls:              u64,
	run_cancellations:      u64,
	mmio:                   proc(ctx: rawptr, gpa: u64, write: bool, data: []u8),
	trace_ud_gp_exits:      bool,
	exception_trace:        [dynamic]Exception_Trace_Record,
	exception_count:        u64,
}

// snapshot of the registers a freeze dump needs
Regs :: struct {
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rsp, rbp: u64,
	rip, rflags:        u64,
	cs_sel:             u16,
	cs_base:            u64,
	ss_sel:             u16,
	ds_sel:             u16,
	es_sel:             u16,
	ss_base:            u64,
}

available :: proc() -> bool {
	return whpx_available()
}

host_clock_hz :: proc() -> u64 {
	return whpx_host_clock_hz()
}

guest_runtime_ns :: proc(vm: ^Vm) -> (u64, bool) {
	return whpx_guest_runtime_ns(vm)
}

set_time_running :: proc(vm: ^Vm, running: bool) -> bool {
	return whpx_set_time_running(vm, running)
}

create :: proc(vm: ^Vm, ram_size: int) -> bool {
	return whpx_create(vm, ram_size, {})
}

create_with_options :: proc(vm: ^Vm, ram_size: int, options: Vm_Create_Options) -> bool {
	return whpx_create(vm, ram_size, options)
}

destroy :: proc(vm: ^Vm) {
	whpx_destroy(vm)
}

run :: proc(vm: ^Vm) -> Exit {
	return whpx_run(vm)
}

// Resets CPU architectural state while preserving guest memory and devices.
reset_cpu :: proc(vm: ^Vm) -> bool {
	return whpx_reset_cpu(vm)
}

// sets PendingInterruption
inject_irq :: proc(vm: ^Vm, vector: u8) {
	whpx_inject_irq(vm, vector)
}

try_inject_irq :: proc(vm: ^Vm, vector: u8) -> Interrupt_Injection_Result {
	return whpx_try_inject_irq(vm, vector)
}

// DeliverabilityNotifications
request_irq_window :: proc(vm: ^Vm, enable: bool) {
	whpx_request_irq_window(vm, enable)
}

// RFLAGS.IF set, nothing pending, and no interrupt shadow
can_inject :: proc(vm: ^Vm) -> bool {
	return whpx_can_inject(vm)
}

// forces the vcpu out of run() from another thread (e.g. UI)
cancel :: proc(vm: ^Vm) {
	whpx_cancel(vm)
}

// for tests
set_realmode_entry :: proc(vm: ^Vm, cs_base: u32, ip: u16) {
	whpx_set_realmode_entry(vm, cs_base, ip)
}

reg_rax :: proc(vm: ^Vm) -> u64 {
	return whpx_reg_rax(vm)
}

// maps a Read|Execute copy of data at gpa (reset-vector alias, option ROMs)
map_rom :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	return whpx_map_rom(vm, gpa, data)
}

// Removes a page-aligned range from the RAM mapping so accesses exit as MMIO.
reserve_mmio :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_mmio(vm, gpa, size)
}

// Removes a page-aligned RAM range and returns all-ones while ignoring writes.
reserve_open_bus :: proc(vm: ^Vm, gpa, size: u64) -> bool {
	return whpx_reserve_open_bus(vm, gpa, size)
}

// Allocates stable page-aligned storage and maps it Read|Write at gpa.
map_device_memory :: proc(vm: ^Vm, gpa: u64, size: int) -> ([]u8, bool) {
	return whpx_map_device_memory(vm, gpa, size)
}

// Requests an HMA mapping change at the next safe vCPU run boundary.
set_a20 :: proc(vm: ^Vm, enabled: bool) -> bool {
	return whpx_set_a20(vm, enabled)
}

get_regs :: proc(vm: ^Vm) -> Regs {
	return whpx_get_regs(vm)
}

cpu_physical_address :: proc(vm: ^Vm, gpa: u64) -> u64 {
	if vm != nil && !vm.a20_enabled {return gpa &~ WHPX_A20_BIT}
	return gpa
}

physical_ram_size :: proc(vm: ^Vm) -> u64 {
	return vm == nil ? 0 : u64(len(vm.ram))
}

physical_ram_read :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	return whpx_physical_ram_read(vm, gpa, data)
}

physical_ram_write :: proc(vm: ^Vm, gpa: u64, data: []u8) -> bool {
	return whpx_physical_ram_write(vm, gpa, data)
}

exception_trace_count :: proc(vm: ^Vm) -> int {
	return whpx_exception_trace_count(vm)
}

exception_trace_record :: proc(vm: ^Vm, index: int) -> (Exception_Trace_Record, bool) {
	return whpx_exception_trace_record(vm, index)
}
