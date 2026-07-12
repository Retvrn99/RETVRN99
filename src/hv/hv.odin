// SPDX-License-Identifier: GPL-3.0-only
package hv

// Hypervisor interface. M1: WHPX backend only (the KVM seam comes later).

Exit_Kind :: enum {
	Io,
	Mmio,
	Halt,
	Interrupt_Window,
	Canceled,
	Failed,
}

Exit :: struct {
	kind:   Exit_Kind,
	detail: string, // Failed only
}

Rom_Mapping :: struct {
	gpa:  u64,
	host: rawptr,
	size: int,
}

Vm :: struct {
	part:     rawptr, // WHV_PARTITION_HANDLE
	ram:      []u8,   // 64MB, mapped at GPA 0
	emu:      rawptr, // WHV_EMULATOR_HANDLE
	roms:     [dynamic]Rom_Mapping, // host copies backing map_rom regions
	io_ctx:   rawptr,
	io_read:  proc(ctx: rawptr, port: u16, size: u8) -> u32,
	io_write: proc(ctx: rawptr, port: u16, size: u8, val: u32),
	mmio:     proc(ctx: rawptr, gpa: u64, write: bool, data: []u8),
}

// snapshot of the registers a freeze dump needs
Regs :: struct {
	rax, rbx, rcx, rdx: u64,
	rsi, rdi, rsp, rbp: u64,
	rip, rflags:        u64,
	cs_sel:             u16,
	cs_base:            u64,
}

available :: proc() -> bool {
	return whpx_available()
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

// sets PendingInterruption
inject_irq :: proc(vm: ^Vm, vector: u8) {
	whpx_inject_irq(vm, vector)
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

get_regs :: proc(vm: ^Vm) -> Regs {
	return whpx_get_regs(vm)
}
