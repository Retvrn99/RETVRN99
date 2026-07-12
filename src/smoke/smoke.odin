// SPDX-License-Identifier: GPL-3.0-only
package main

// Headless M1 smoke test: boot MS-DOS 7.1 from ~/.retvrn99/c_drive, wait for
// the C:\> prompt, type DIR, and expect a known filename in the text grid.
// Exits 0 on success, 1 on failure, 0 with a SKIP note when WHPX or the
// user-provided DOS files are absent.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../fat32"
import "../hosttime"
import "../hv"
import "../machine"
import "../vga"

// a guest that stops doing I/O never exits WHvRunVirtualProcessor;
// periodic cancels keep step() returning (same as the GUI watchdog)
Watchdog :: struct {
	vm:   ^hv.Vm,
	stop: bool,
	mu:   sync.Mutex,
}

BOOT_DEADLINE :: 60 * time.Second
DIR_DEADLINE :: 15 * time.Second
VCPU_PULSE_PERIOD :: time.Millisecond

main :: proc() {
	if !hv.available() {
		fmt.println("SKIP: WHPX not available")
		return
	}
	home := os.get_env("USERPROFILE", context.allocator)
	if home == "" { home = os.get_env("HOME", context.allocator) }
	c_drive, _ := filepath.join({home, ".retvrn99", "c_drive"})
	io_sys, _ := filepath.join({c_drive, "IO.SYS"})
	if !os.exists(io_sys) {
		fmt.printfln("SKIP: %s not found (user-provided MS-DOS 7.1 files required)", io_sys)
		return
	}

	m := new(machine.Machine)
	if !machine.machine_init(m, 64 * 1024 * 1024) { fail("machine_init") }
	if !machine.load_roms(&m.vm) { fail("load_roms") }
	vol := fat32.volume_open(c_drive, 2048)
	if vol == nil { fail("volume_open") }
	vol.on_fail = proc(ctx: rawptr, msg: string) {
		fmt.printfln("disk: writes frozen: %s", msg)
	}
	machine.machine_attach_disk(m, fat32.volume_block_device(vol))

	wd := Watchdog{vm = &m.vm}
	wd_thr := thread.create_and_start_with_poly_data(&wd, proc(w: ^Watchdog) {
		waiter: hosttime.Waiter
		hosttime.waiter_init(&waiter)
		defer hosttime.waiter_destroy(&waiter)
		for {
			sync.lock(&w.mu)
			stop := w.stop
			sync.unlock(&w.mu)
			if stop { return }
			hv.cancel(w.vm)
			hosttime.waiter_sleep(&waiter, VCPU_PULSE_PERIOD)
		}
	})
	defer {
		sync.lock(&wd.mu)
		wd.stop = true
		sync.unlock(&wd.mu)
		thread.join(wd_thr)
	}

	// The very first prompt renders as "C:" only: the IO.SYS boot-logo
	// (mode 13h) round trip swallows the "\>" glyphs. Every later prompt
	// renders "C:\>" in full, so the canonical needle is checked after DIR.
	if !run_until(m, BOOT_DEADLINE, "C:") { fail("no C: prompt within deadline") }
	fmt.println("prompt reached, typing DIR")

	// DIR + Enter, set-1 make/break pairs
	for sc in ([]u8{0x20, 0x17, 0x13, 0x1C}) {
		machine.i8042_key(&m.kbd, sc)
		machine.i8042_key(&m.kbd, sc | 0x80)
		step_for(m, 100 * time.Millisecond)
	}
	// any file we know the user placed there; COMMAND.COM must exist to boot
	if !run_until(m, DIR_DEADLINE, "COMMAND") { fail("DIR output not found") }
	if !run_until(m, DIR_DEADLINE, "C:\\>") { fail("no C:\\> prompt after DIR") }
	fmt.println("PASS: booted to prompt, DIR lists COMMAND, C:\\> renders")
}

fail :: proc(msg: string) {
	fmt.printfln("FAIL: %s", msg)
	os.exit(1)
}

grid_text :: proc(snap: ^vga.Text_Snapshot) -> string {
	buf: [80 * 25]u8
	for i in 0 ..< 80 * 25 {
		ch := u8(snap.cells[i])
		buf[i] = ch >= 0x20 && ch < 0x7F ? ch : ' '
	}
	return strings.clone_from_bytes(buf[:], context.temp_allocator)
}

run_until :: proc(m: ^machine.Machine, deadline: time.Duration, needle: string) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < deadline {
		step_for(m, 250 * time.Millisecond)
		snap := vga.vga_snapshot(&m.vga, m.vm.ram)
		if strings.contains(grid_text(&snap), needle) { return true }
		free_all(context.temp_allocator)
		if m.bus.frozen {
			fmt.printfln("frozen: %s", m.bus.freeze_msg)
			return false
		}
	}
	return false
}

step_for :: proc(m: ^machine.Machine, d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		if !machine.step(m) { return }
	}
}
