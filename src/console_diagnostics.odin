// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:strings"
import "disk"
import "hv"
import "machine"

format_regs :: proc(r: hv.Regs, m: ^machine.Machine) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(
		&b,
		"CS=%04x (base %08x) RIP=%08x RFLAGS=%08x",
		r.cs_sel,
		r.cs_base,
		r.rip,
		r.rflags,
	)
	fmt.sbprintfln(&b, "RAX=%08x RBX=%08x RCX=%08x RDX=%08x", r.rax, r.rbx, r.rcx, r.rdx)
	fmt.sbprintfln(&b, "RSI=%08x RDI=%08x RSP=%08x RBP=%08x", r.rsi, r.rdi, r.rsp, r.rbp)
	fmt.sbprintfln(&b, "CR0=%08x CR3=%08x", r.cr0, r.cr3)
	fmt.sbprintfln(
		&b,
		"SS=%04x (base %08x) DS=%04x ES=%04x",
		r.ss_sel,
		r.ss_base,
		r.ds_sel,
		r.es_sel,
	)
	count := int(min(m.exit_count, u64(machine.EXIT_HISTORY)))
	fmt.sbprintf(&b, "last %d exits:", count)
	for i in 0 ..< count {
		idx := (m.exit_count - u64(count) + u64(i)) % machine.EXIT_HISTORY
		fmt.sbprintf(&b, " %v", m.exit_hist[idx])
	}
	return strings.to_string(b)
}

dump_state :: proc(m: ^machine.Machine) {
	r := hv.get_regs(&m.vm)
	registers := format_regs(r, m)
	fmt.println(registers)
	delete(registers)
	code: [32]u8
	linear := r.cs_base + r.rip
	if hv.linear_read(&m.vm, linear, code[:]) {
		fmt.printf("guest code %08x:", linear)
		for byte in code {fmt.printf(" %02x", byte)}
		fmt.println()
	} else {
		fmt.printfln("guest code %08x: unavailable", linear)
	}
	code_lo := linear >= 0x200 ? linear - 0x200 : 0
	dump_linear(m, "code", code_lo, 0x400)
	if m.diagnostic_tracing {
		nio := int(min(m.io_count, u64(machine.IO_HISTORY)))
		fmt.printf("last %d io:", nio)
		for i in 0 ..< nio {
			idx := (m.io_count - u64(nio) + u64(i)) % machine.IO_HISTORY
			t := m.io_hist[idx]
			fmt.printf(" %s[%04x]=%x", t.write ? "w" : "r", t.port, t.val)
		}
		fmt.println()
	} else {
		fmt.println("legacy I/O histories unavailable (diagnostic tracing disabled)")
	}
	fmt.print("irq injections:")
	for c, v in m.inj_count {
		if c > 0 {fmt.printf(" vec%02x=%d", v, c)}
	}
	fmt.println()
	fmt.printfln(
		"irq delivery: queued=%t vector=%02x machine=%d/%d whpx=%d/%d pending_exits=%d",
		m.pic_offer_queued,
		m.pic_queued_offer.vector,
		m.pic_queue_count,
		m.pic_delivery_count,
		m.vm.irq_queue_count,
		m.vm.irq_delivery_count,
		m.vm.irq_pending_exit_count,
	)
	fmt.printfln(
		"irq queue: pending_event_deferrals=%d deferred_event=%016x:%016x last_event=%016x CS=%04x:%08x linear=%08x",
		m.vm.irq_pending_event_deferrals,
		m.vm.irq_pending_event_high,
		m.vm.irq_pending_event_low,
		m.vm.irq_queue_event,
		m.vm.irq_queue_cs,
		m.vm.irq_queue_rip,
		m.vm.irq_queue_cs_base + m.vm.irq_queue_rip,
	)
	fmt.printfln(
		"last irq delivery: reason=%d state=%04x pending=%016x CS=%04x:%08x linear=%08x RFLAGS=%08x",
		m.vm.irq_delivery_reason,
		m.vm.irq_delivery_state,
		m.vm.irq_delivery_pending,
		m.vm.irq_delivery_cs,
		m.vm.irq_delivery_rip,
		m.vm.irq_delivery_cs_base + m.vm.irq_delivery_rip,
		m.vm.irq_delivery_rflags,
	)
	fmt.printf(
		"last irq delivery I/O: port=%04x access=%08x RAX=%08x instruction=",
		m.vm.irq_delivery_io_port,
		m.vm.irq_delivery_io_access,
		m.vm.irq_delivery_io_rax,
	)
	for index in 0 ..< int(m.vm.irq_delivery_ins_len) {
		fmt.printf("%02x", m.vm.irq_delivery_ins[index])
	}
	fmt.println()
	kbd_diag := machine.i8042_diagnostics(&m.kbd)
	fmt.printfln(
		"i8042: queued=%d keyboard=%d auxiliary=%d obf=%t aux=%t ibf=%t",
		kbd_diag.queued,
		kbd_diag.keyboard_queued,
		kbd_diag.auxiliary_queued,
		kbd_diag.output_full,
		kbd_diag.output_aux,
		kbd_diag.input_busy,
	)
	fmt.printfln(
		"a20: controller=%t applied=%t requested=%t requests=%d remaps=%d",
		m.kbd.a20,
		m.vm.a20_enabled,
		m.vm.a20_requested,
		m.vm.a20_request_count,
		m.vm.a20_apply_count,
	)
	natapi := int(min(m.atapi.trace_count, u64(disk.ATAPI_TRACE_HISTORY)))
	fmt.printfln("last %d ATAPI packets (of %d):", natapi, m.atapi.trace_count)
	for i in 0 ..< natapi {
		idx := (m.atapi.trace_count - u64(natapi) + u64(i)) % disk.ATAPI_TRACE_HISTORY
		trace := m.atapi.trace_hist[idx]
		fmt.printf("  %02x", trace.packet[0])
		for byte in trace.packet[1:] {fmt.printf(" %02x", byte)}
		fmt.printfln(
			" limit=%d dispatch=%02x/%02x sense=%02x/%02x/%02x",
			trace.phase_limit,
			trace.dispatch_status,
			trace.dispatch_error,
			trace.dispatch_key,
			trace.dispatch_asc,
			trace.dispatch_ascq,
		)
	}
	fmt.printfln(
		"pic: master irr=%02x imr=%02x isr=%02x base=%02x auto_eoi=%t init=%v slave irr=%02x imr=%02x isr=%02x base=%02x auto_eoi=%t init=%v",
		m.pic.master.irr,
		m.pic.master.imr,
		m.pic.master.isr,
		m.pic.master.base,
		m.pic.master.auto_eoi,
		m.pic.master.init,
		m.pic.slave.irr,
		m.pic.slave.imr,
		m.pic.slave.isr,
		m.pic.slave.base,
		m.pic.slave.auto_eoi,
		m.pic.slave.init,
	)
	if m.bus.diagnostic_tracing {
		nide := int(min(m.ide_count, u64(machine.IDE_HISTORY)))
		fmt.printf("last %d ide io (of %d):", nide, m.ide_count)
		for i in 0 ..< nide {
			idx := (m.ide_count - u64(nide) + u64(i)) % machine.IDE_HISTORY
			t := m.ide_hist[idx]
			fmt.printf(" %s[%04x]=%x", t.write ? "w" : "r", t.port, t.val)
		}
		fmt.println()
	}
	dump_ram(m, "ivt 00-1F", 0x0000, 0x80)
	dump_ram(m, "mbr@0600", 0x0600, 0x20)
	dump_ram(m, "iosys@0700", 0x0700, 0x40)
	dump_ram(m, "msload@0900", 0x0900, 0x40)
	dump_ram(m, "vbr@7C00", 0x7C00, 0x40)
	stack_offset := r.rsp & 0xFFFF
	if r.cr0 & 1 != 0 {stack_offset = r.rsp & 0xFFFF_FFFF}
	stack_linear := r.ss_base + stack_offset
	stack_lo := stack_linear >= 0x20 ? stack_linear - 0x20 : 0
	dump_linear(m, "stack", stack_lo, 0xA0)
	if m.bus.diagnostic_tracing {
		ncmd := int(min(m.cmd_count, u64(machine.IDE_HISTORY)))
		fmt.printf("last %d ide cmds (of %d):", ncmd, m.cmd_count)
		for i in 0 ..< ncmd {
			idx := (m.cmd_count - u64(ncmd) + u64(i)) % machine.IDE_HISTORY
			t := m.cmd_hist[idx]
			fmt.printf(" %02x@%x*%d", t.cmd, t.lba, t.count)
		}
		fmt.println()
	}
}

dump_linear :: proc(m: ^machine.Machine, tag: string, base: u64, n: int) {
	for off := 0; off < n; off += 16 {
		line: [16]u8
		linear := base + u64(off)
		if !hv.linear_read(&m.vm, linear, line[:]) {
			fmt.printfln("linear %s %08x: unavailable", tag, linear)
			continue
		}
		fmt.printf("linear %s %08x:", tag, linear)
		for byte in line {fmt.printf(" %02x", byte)}
		fmt.println()
	}
}

dump_ram :: proc(m: ^machine.Machine, tag: string, base, n: int) {
	for off := 0; off < n; off += 16 {
		fmt.printf("ram %s %05x:", tag, base + off)
		for i in 0 ..< 16 {
			fmt.printf(" %02x", m.vm.ram[base + off + i])
		}
		fmt.println()
	}
}
