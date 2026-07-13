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
import "../profile"
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
	code := run_smoke()
	if code != 0 { os.exit(code) }
}

run_smoke :: proc() -> int {
	if !hv.available() {
		fmt.println("SKIP: WHPX not available")
		return 0
	}
	paths, perr := profile.paths_default()
	if perr != nil { return smoke_fail("profile path resolution") }
	defer profile.paths_destroy(&paths)
	switch profile.dos_seed_prepare(paths.c_drive) {
	case .Missing, .Preserved, .Updated:
	case .Path_Failed, .Read_Failed, .Create_Directory_Failed, .Temporary_Path_Failed,
	     .Write_Failed, .Replace_Failed:
		return smoke_fail("DOS seed MSDOS.SYS preparation")
	}
	io_sys, _ := filepath.join({paths.c_drive, "IO.SYS"})
	if !os.exists(io_sys) {
		fmt.printfln("SKIP: %s not found (user-provided MS-DOS 7.1 files required)", io_sys)
		return 0
	}

	vol: ^fat32.Volume
	m := new(machine.Machine)
	if !machine.machine_init(m, 64 * 1024 * 1024) {
		free(m)
		return smoke_fail("machine_init")
	}
	defer {
		machine.machine_destroy(m)
		fat32.volume_close(vol)
		free(m)
	}
	settings, _ := profile.settings_load(paths.settings)
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	if !machine.load_roms(&m.vm) { return smoke_fail("load_roms") }
	vol = fat32.volume_open(paths.c_drive, 2048)
	if vol == nil { return smoke_fail("volume_open") }
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

	if !run_until(m, BOOT_DEADLINE, "C:\\>") { return smoke_fail("no C:\\> prompt within deadline") }
	fmt.println("prompt reached, typing DIR")

	// DIR + Enter, set-1 make/break pairs
	for sc in ([]u8{0x20, 0x17, 0x13, 0x1C}) {
		machine.i8042_key(&m.kbd, sc)
		machine.i8042_key(&m.kbd, sc | 0x80)
		step_for(m, 100 * time.Millisecond)
	}
	// any file we know the user placed there; COMMAND.COM must exist to boot
	if !run_until(m, DIR_DEADLINE, "COMMAND") { return smoke_fail("DIR output not found") }
	if !run_until(m, DIR_DEADLINE, "C:\\>") { return smoke_fail("no C:\\> prompt after DIR") }
	fmt.println("PASS: booted to prompt, DIR lists COMMAND, C:\\> renders")
	return 0
}

smoke_fail :: proc(msg: string) -> int {
	fmt.printfln("FAIL: %s", msg)
	return 1
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
		snap := machine.machine_text_snapshot(m)
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
