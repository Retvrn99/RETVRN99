// SPDX-License-Identifier: GPL-3.0-only
package main

// Headless M1 smoke test: boot MS-DOS 7.1 from the selected FAT32 image, wait for
// the C:\> prompt, type DIR, and expect a known filename in the text grid.
// Exits 0 on success, 1 on failure, 0 with a SKIP note when WHPX or the
// user-provided DOS files are absent.

import "../fat32session"
import "../hosttime"
import "../hv"
import "../machine"
import "../profile"
import "../vga"
import "../vmconfig"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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
	if code != 0 {os.exit(code)}
}

run_smoke :: proc() -> (result: int) {
	if !hv.available() {
		fmt.println("SKIP: WHPX not available")
		return 0
	}
	paths, perr := profile.paths_default()
	if perr != nil {return smoke_fail("profile path resolution")}
	defer profile.paths_destroy(&paths)
	settings, settings_diagnostic, _ := profile.settings_load(paths.settings)
	defer profile.settings_destroy(&settings)
	if settings_diagnostic != .None || settings.hard_drive_path == "" {
		fmt.println("SKIP: no hard-drive image is selected")
		return 0
	}

	session: ^fat32session.Machine_Session
	m := new(machine.Machine)
	if !machine.machine_init(m, vmconfig.GSW_RAM_BYTES) {
		free(m)
		return smoke_fail("machine_init")
	}
	defer {
		machine.machine_destroy(m)
		if session != nil {
			if close_error := fat32session.close(session, .Commit); close_error.code != .None {
				fmt.eprintfln("disk: close failed: %s", fat32session.error_text(&close_error))
				if close_error.outcome != .Completed {
					_ = fat32session.close(session, .Retain)
				}
				if result == 0 {result = 1}
			}
		}
		free(m)
	}
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	if !machine.load_roms(&m.vm) {return smoke_fail("load_roms")}
	open_error: fat32session.Session_Error
	session, open_error = fat32session.open_machine(settings.hard_drive_path, "smoke", .In_Process)
	if open_error.code != .None {return smoke_fail(fat32session.error_text(&open_error))}
	boot_files, observe_error := fat32session.observe(
		session,
		[]fat32session.Probe{{kind = .Stat, path = "IO.SYS"}},
		context.temp_allocator,
	)
	if observe_error.code != .None ||
	   len(boot_files.items) != 1 ||
	   boot_files.items[0].type != .Regular {
		fat32session.observation_batch_destroy(&boot_files, context.temp_allocator)
		fmt.println("SKIP: IO.SYS is absent from the selected image")
		return 0
	}
	fat32session.observation_batch_destroy(&boot_files, context.temp_allocator)
	machine.machine_attach_disk(m, fat32session.block_device(session))

	wd := Watchdog {
		vm = &m.vm,
	}
	wd_thr := thread.create_and_start_with_poly_data(&wd, proc(w: ^Watchdog) {
		waiter: hosttime.Waiter
		hosttime.waiter_init(&waiter)
		defer hosttime.waiter_destroy(&waiter)
		for {
			sync.lock(&w.mu)
			stop := w.stop
			sync.unlock(&w.mu)
			if stop {return}
			hv.cancel(w.vm)
			hosttime.waiter_sleep(&waiter, VCPU_PULSE_PERIOD)
		}
	})
	defer {
		sync.lock(&wd.mu)
		wd.stop = true
		sync.unlock(&wd.mu)
		thread.destroy(wd_thr)
	}

	if !run_until(m, BOOT_DEADLINE, "C:\\>") {return smoke_fail("no C:\\> prompt within deadline")}
	fmt.println("prompt reached, typing DIR")

	// DIR + Enter, set-1 make/break pairs
	for sc in ([]u8{0x20, 0x17, 0x13, 0x1C}) {
		machine.machine_key(m, sc)
		machine.machine_key(m, sc | 0x80)
		step_for(m, 100 * time.Millisecond)
	}
	// any file we know the user placed there; COMMAND.COM must exist to boot
	if !run_until(m, DIR_DEADLINE, "COMMAND") {return smoke_fail("DIR output not found")}
	if !run_until(m, DIR_DEADLINE, "C:\\>") {return smoke_fail("no C:\\> prompt after DIR")}
	fmt.println("PASS: booted to prompt, DIR lists COMMAND, C:\\> renders")
	return 0
}

smoke_fail :: proc(msg: string) -> int {
	fmt.printfln("FAIL: %s", msg)
	return 1
}

grid_text :: proc(snap: ^vga.Text_Snapshot) -> string {
	buf: [vga.TEXT_SNAPSHOT_MAX_COLUMNS * vga.TEXT_SNAPSHOT_MAX_ROWS]u8
	count := vga.text_snapshot_cell_count(snap)
	for i in 0 ..< count {
		ch := u8(snap.cells[i])
		buf[i] = ch >= 0x20 && ch < 0x7F ? ch : ' '
	}
	return strings.clone_from_bytes(buf[:count], context.temp_allocator)
}

run_until :: proc(m: ^machine.Machine, deadline: time.Duration, needle: string) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < deadline {
		step_for(m, 250 * time.Millisecond)
		snap := machine.machine_text_snapshot(m)
		if strings.contains(grid_text(&snap), needle) {return true}
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
		if !machine.step(m) {return}
	}
}
