// SPDX-License-Identifier: GPL-3.0-only
package main

// Task 12 console harness: SeaBIOS POST with the port 0x402 debug log on
// stdout, periodic VGA text snapshots, and the FAT32 volume on the primary
// IDE channel. Run with --no-disk to leave the IDE ports floating.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:thread"
import "core:time"
import "fat32"
import "hv"
import "machine"
import "vga"

RUN_SECONDS :: 60
VGA_PERIOD :: 500 * time.Millisecond
WATCHDOG_PERIOD :: 100 * time.Millisecond

// A guest that stops doing I/O (e.g. executing junk after a boot sector
// with no real code) never leaves WHvRunVirtualProcessor; periodic cancels
// keep the main loop's clock, debug drain and time cap alive.
watchdog_stop: bool

vm_watchdog :: proc(vm: ^hv.Vm) {
	for !watchdog_stop {
		time.sleep(WATCHDOG_PERIOD)
		hv.cancel(vm)
	}
}

main :: proc() {
	context.logger = log.create_console_logger(.Info, {.Level})

	m := new(machine.Machine)
	if !machine.machine_init(m, 64 * 1024 * 1024) {
		fmt.eprintln("machine_init failed (WHPX unavailable?)")
		os.exit(1)
	}
	if !machine.load_roms(&m.vm) {
		fmt.eprintln("load_roms failed")
		os.exit(1)
	}

	attach := true
	for a in os.args[1:] {
		if a == "--no-disk" { attach = false }
	}
	if attach {
		home := os.get_env("USERPROFILE", context.allocator)
		if home == "" { home = os.get_env("HOME", context.allocator) }
		path, _ := filepath.join({home, ".mate98", "c_drive"})
		vol := fat32.volume_open(path, 2048)
		if vol == nil {
			fmt.eprintfln("volume_open failed: %s", path)
			os.exit(1)
		}
		machine.machine_attach_disk(m, fat32.volume_block_device(vol))
		fmt.printfln("disk: %s as 2048MB FAT32 volume", path)
	} else {
		fmt.println("disk: none (--no-disk)")
	}

	thread.create_and_start_with_poly_data(&m.vm, vm_watchdog)
	defer watchdog_stop = true

	start := time.tick_now()
	last_vga := start
	prev: vga.Text_Snapshot
	shown := false
	raw: [dynamic]u8
	line: [dynamic]u8
	iterations := 0

	for {
		alive := machine.step(m)
		iterations += 1
		drain_dbg(m, &raw, &line)
		now := time.tick_now()
		if !alive {
			flush_partial(&line)
			fmt.printfln("VM frozen after %d iterations: %s", iterations, m.bus.freeze_msg)
			dump_state(m)
			print_grid(vga.vga_snapshot(&m.vga, m.vm.ram))
			os.exit(2)
		}
		if time.tick_diff(last_vga, now) >= VGA_PERIOD {
			last_vga = now
			snap := vga.vga_snapshot(&m.vga, m.vm.ram)
			if !shown || snap.cells != prev.cells {
				prev = snap
				shown = true
				print_grid(snap)
			}
		}
		if time.tick_diff(start, now) >= RUN_SECONDS * time.Second {
			flush_partial(&line)
			fmt.printfln("time cap (%ds) reached after %d iterations, exiting", RUN_SECONDS, iterations)
			dump_state(m)
			print_grid(vga.vga_snapshot(&m.vga, m.vm.ram))
			break
		}
	}
}

// splits drained 0x402 bytes into "seabios: " lines
drain_dbg :: proc(m: ^machine.Machine, raw: ^[dynamic]u8, line: ^[dynamic]u8) {
	clear(raw)
	machine.machine_drain_dbg(m, raw)
	for c in raw {
		switch c {
		case '\n':
			fmt.printfln("seabios: %s", string(line[:]))
			clear(line)
		case '\r':
		case:
			append(line, c)
		}
	}
}

flush_partial :: proc(line: ^[dynamic]u8) {
	if len(line) > 0 {
		fmt.printfln("seabios: %s", string(line[:]))
		clear(line)
	}
}

print_grid :: proc(snap: vga.Text_Snapshot) {
	border := "vga: +--------------------------------------------------------------------------------+"
	fmt.println(border)
	for row in 0 ..< 25 {
		buf: [80]u8
		for col in 0 ..< 80 {
			ch := u8(snap.cells[row * 80 + col])
			buf[col] = ch >= 0x20 && ch < 0x7F ? ch : ' '
		}
		fmt.printfln("vga: |%s|", string(buf[:]))
	}
	fmt.println(border)
	fmt.printfln("vga: cursor row=%d col=%d on=%v", snap.cursor_row, snap.cursor_col, snap.cursor_on)
}

dump_state :: proc(m: ^machine.Machine) {
	r := hv.get_regs(&m.vm)
	fmt.printfln("regs: CS=%04x (base %08x) RIP=%08x RFLAGS=%08x", r.cs_sel, r.cs_base, r.rip, r.rflags)
	fmt.printfln("      RAX=%08x RBX=%08x RCX=%08x RDX=%08x", r.rax, r.rbx, r.rcx, r.rdx)
	fmt.printfln("      RSI=%08x RDI=%08x RSP=%08x RBP=%08x", r.rsi, r.rdi, r.rsp, r.rbp)
	count := int(min(m.exit_count, u64(machine.EXIT_HISTORY)))
	fmt.printf("last %d exits:", count)
	for i in 0 ..< count {
		idx := (m.exit_count - u64(count) + u64(i)) % machine.EXIT_HISTORY
		fmt.printf(" %v", m.exit_hist[idx])
	}
	fmt.println()
}
