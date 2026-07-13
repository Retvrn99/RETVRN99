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

Rom_Mapping :: struct {
	gpa:  u64,
	host: rawptr,
	size: int,
}

Mmio_Reservation :: struct {
	gpa:  u64,
	size: u64,
}

Device_Mapping :: struct {
	gpa:  u64,
	host: rawptr,
	size: int,
}

Vm :: struct {
	part:              rawptr, // WHV_PARTITION_HANDLE
	ram:               []u8, // 64MB, mapped at GPA 0
	emu:               rawptr, // WHV_EMULATOR_HANDLE
	roms:              [dynamic]Rom_Mapping, // host copies backing map_rom regions
	mmio_reservations: [dynamic]Mmio_Reservation,
	device_mappings:   [dynamic]Device_Mapping,
	a20_enabled:       bool,
	a20_requested:     bool,
	a20_request_count: u64,
	a20_apply_count:   u64,
	time_suspended:    bool,
	io_ctx:            rawptr,
	io_read:           proc(ctx: rawptr, port: u16, size: u8) -> (u32, bool),
	io_write:          proc(ctx: rawptr, port: u16, size: u8, val: u32) -> bool,
	mmio:              proc(ctx: rawptr, gpa: u64, write: bool, data: []u8),
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
	return whpx_create(vm, ram_size)
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
