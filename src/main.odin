// SPDX-License-Identifier: GPL-3.0-only
package main

// GUI by default: SDL3 window + ImGui menu, with the machine on its own
// thread. --console keeps the Phase D harness (SeaBIOS POST on stdout) for
// the smoke test. --auto-close:N closes the GUI after N seconds.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import sdl3 "vendor:sdl3"
import imgui "../vendor_local/imgui"
import "../vendor_local/imgui/imgui_impl_sdl3"
import "../vendor_local/imgui/imgui_impl_sdlrenderer3"
import "disk"
import "fat32"
import "host"
import "hv"
import "machine"
import "vga"

RAM_SIZE :: 64 * 1024 * 1024
VOLUME_MB :: 2048
WATCHDOG_PERIOD :: 50 * time.Millisecond
SNAP_PERIOD :: 8 * time.Millisecond
MAX_LOG_LINES :: 2000

Command_Kind :: enum {
	Key,
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Toggle_Throttle,
}

Command :: struct {
	kind:  Command_Kind,
	key:   [2]u8, // set-1 bytes (E0-prefixed when extended)
	key_n: int,
	path:  string, // Mount_Floppy; owned by the VM thread once queued
}

Shared :: struct {
	mu:         sync.Mutex,
	snap:       vga.Text_Snapshot, // copied by the VM thread every ~8ms
	log_lines:  [dynamic]string,
	cmds:       [dynamic]Command,
	running:    bool,
	frozen_msg: string,
	exit_stats: [hv.Exit_Kind]u64,
	regs_text:  string,
}

// shields the ^hv.Vm from the watchdog during destroy/reinit
Vm_Guard :: struct {
	mu:    sync.Mutex,
	vm:    ^hv.Vm,
	valid: bool,
	stop:  bool,
}

Vm_Ctx :: struct {
	shared: ^Shared,
	guard:  Vm_Guard,
	bd:     disk.Block_Device,
	attach: bool,
}

main :: proc() {
	context.logger = log.create_console_logger(.Info, {.Level})

	console := false
	attach := true
	auto_close := -1
	for a in os.args[1:] {
		if a == "--console" { console = true }
		if a == "--no-disk" { attach = false }
		if strings.has_prefix(a, "--auto-close:") {
			auto_close, _ = strconv.parse_int(a[len("--auto-close:"):])
		}
	}

	if console {
		console_main(attach)
		return
	}
	gui_main(attach, auto_close)
}

// --- GUI ---

gui_main :: proc(attach: bool, auto_close: int) {
	ctx := new(Vm_Ctx)
	shared := new(Shared)
	shared.running = true
	ctx.shared = shared
	ctx.attach = attach
	if attach {
		vol := fat32.volume_open(default_c_drive(), VOLUME_MB)
		if vol == nil {
			fmt.eprintfln("volume_open failed: %s", default_c_drive())
			os.exit(1)
		}
		ctx.bd = fat32.volume_block_device(vol)
		fmt.printfln("disk: %s as %dMB FAT32 volume", default_c_drive(), VOLUME_MB)
	} else {
		fmt.println("disk: none (--no-disk)")
	}

	h: host.Host
	if !host.host_init(&h) {
		fmt.eprintfln("host_init failed: %s", sdl3.GetError())
		os.exit(1)
	}

	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.IniFilename = nil // no imgui.ini
	imgui.StyleColorsDark()
	imgui_impl_sdl3.InitForSDLRenderer(h.win, h.ren)
	imgui_impl_sdlrenderer3.Init(h.ren)

	vm_thr := thread.create_and_start_with_poly_data(ctx, vm_thread_proc)
	wd_thr := thread.create_and_start_with_poly_data(&ctx.guard, watchdog_proc)

	st: host.Menu_State
	pending: Pending_Mount
	start := time.tick_now()

	for {
		sync.lock(&shared.mu)
		running := shared.running
		sync.unlock(&shared.mu)
		if !running { break }

		ev: sdl3.Event
		for sdl3.PollEvent(&ev) {
			imgui_impl_sdl3.ProcessEvent(&ev)
			#partial switch ev.type {
			case .QUIT:
				set_running(shared, false)
			case .KEY_DOWN, .KEY_UP:
				if io.WantCaptureKeyboard { continue }
				if s, ok := host.scancode_to_set1(ev.key.scancode); ok {
					buf, n := host.set1_bytes(s, ev.key.down)
					push_cmd(shared, Command{kind = .Key, key = buf, key_n = n})
				}
			}
		}

		// path picked in the floppy dialog (async callback)
		sync.lock(&pending.mu)
		if pending.has {
			pending.has = false
			push_cmd(shared, Command{kind = .Mount_Floppy, path = pending.path})
			pending.path = ""
		}
		sync.unlock(&pending.mu)

		// copy of the shared state for this frame
		sync.lock(&shared.mu)
		snap := shared.snap
		frozen := strings.clone(shared.frozen_msg, context.temp_allocator)
		regs := strings.clone(shared.regs_text, context.temp_allocator)
		stats := shared.exit_stats
		nlog := len(shared.log_lines)
		first := max(0, nlog - 200)
		logs := make([]string, nlog - first, context.temp_allocator)
		copy(logs, shared.log_lines[first:]) // strings are never freed: safe
		sync.unlock(&shared.mu)

		exit_lines := make([dynamic]string, context.temp_allocator)
		for kind in hv.Exit_Kind {
			append(&exit_lines, fmt.tprintf("%v: %d", kind, stats[kind]))
		}

		host.render_grid(&h, &snap)

		imgui_impl_sdlrenderer3.NewFrame()
		imgui_impl_sdl3.NewFrame()
		imgui.NewFrame()
		info := host.Menu_Info {
			frozen_msg = frozen,
			regs_text  = regs,
			exit_lines = exit_lines[:],
			log_lines  = logs,
		}
		switch host.menu_draw(&st, info) {
		case .Reset:
			push_cmd(shared, Command{kind = .Reset})
		case .Power_Off:
			push_cmd(shared, Command{kind = .Power_Off})
		case .Mount_Floppy:
			sdl3.ShowOpenFileDialog(mount_dialog_cb, &pending, h.win, nil, 0, nil, false)
		case .Eject_Floppy:
			push_cmd(shared, Command{kind = .Eject_Floppy})
		case .Toggle_Throttle:
			push_cmd(shared, Command{kind = .Toggle_Throttle})
		case .None:
		}
		imgui.Render()
		imgui_impl_sdlrenderer3.RenderDrawData(imgui.GetDrawData(), h.ren)
		sdl3.RenderPresent(h.ren)

		free_all(context.temp_allocator)

		if auto_close >= 0 && time.duration_seconds(time.tick_since(start)) >= f64(auto_close) {
			set_running(shared, false)
		}
	}

	thread.join(vm_thr)
	sync.lock(&ctx.guard.mu)
	ctx.guard.stop = true
	sync.unlock(&ctx.guard.mu)
	thread.join(wd_thr)

	imgui_impl_sdlrenderer3.Shutdown()
	imgui_impl_sdl3.Shutdown()
	imgui.DestroyContext()
	host.host_destroy(&h)

	fmt.print("exit stats:")
	for kind in hv.Exit_Kind {
		fmt.printf(" %v=%d", kind, shared.exit_stats[kind])
	}
	fmt.println()
}

Pending_Mount :: struct {
	mu:   sync.Mutex,
	path: string,
	has:  bool,
}

mount_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	p := (^Pending_Mount)(userdata)
	if filelist == nil || filelist[0] == nil { return } // error or canceled
	sync.lock(&p.mu)
	p.path = strings.clone(string(filelist[0]))
	p.has = true
	sync.unlock(&p.mu)
}

set_running :: proc(s: ^Shared, v: bool) {
	sync.lock(&s.mu)
	s.running = v
	sync.unlock(&s.mu)
}

push_cmd :: proc(s: ^Shared, cmd: Command) {
	sync.lock(&s.mu)
	append(&s.cmds, cmd)
	sync.unlock(&s.mu)
}

// --- VM thread ---

vm_thread_proc :: proc(c: ^Vm_Ctx) {
	context.logger = log.create_console_logger(.Info, {.Level})
	s := c.shared
	m := new(machine.Machine)

	if !vm_boot(c, m) {
		publish_freeze(s, "machine init failed (WHPX unavailable?)", "")
	}

	raw: [dynamic]u8
	line: [dynamic]u8
	stats: [hv.Exit_Kind]u64
	frozen := false
	sync.lock(&s.mu)
	frozen = s.frozen_msg != ""
	sync.unlock(&s.mu)
	last_snap := time.tick_now()

	loop: for {
		// commands from the UI
		sync.lock(&s.mu)
		if !s.running { sync.unlock(&s.mu); break loop }
		cmds := make([]Command, len(s.cmds), context.allocator)
		copy(cmds, s.cmds[:])
		clear(&s.cmds)
		sync.unlock(&s.mu)

		quit := false
		for cmd in cmds {
			switch cmd.kind {
			case .Key:
				if !frozen {
					for i in 0 ..< cmd.key_n { machine.i8042_key(&m.kbd, cmd.key[i]) }
				}
			case .Reset:
				vm_shutdown(c, m)
				stats = {}
				if vm_boot(c, m) {
					frozen = false
					publish_freeze(s, "", "")
					vm_log(s, "machine: reset")
				} else {
					frozen = true
					publish_freeze(s, "reset failed: machine init error", "")
				}
			case .Power_Off:
				sync.lock(&s.mu)
				s.running = false
				sync.unlock(&s.mu)
				quit = true
			case .Mount_Floppy:
				if img, err := os.read_entire_file_from_path(cmd.path, context.allocator); err == nil {
					if machine.machine_mount_floppy(m, img) {
						vm_log(s, fmt.tprintf("floppy: mounted %s", cmd.path))
					} else {
						vm_log(s, fmt.tprintf("floppy: %s is not a 1.44MB image", cmd.path))
					}
					delete(img)
				} else {
					vm_log(s, fmt.tprintf("floppy: cannot read %s", cmd.path))
				}
				delete(cmd.path)
			case .Eject_Floppy:
				machine.machine_eject_floppy(m)
				vm_log(s, "floppy: ejected")
			case .Toggle_Throttle:
				m.throttle.enabled = !m.throttle.enabled
				m.throttle.budget_pct = 50
				vm_log(s, m.throttle.enabled ? "throttle: on (50%)" : "throttle: off")
			}
		}
		delete(cmds)
		if quit { break loop }

		if !frozen {
			alive := machine.step(m)
			stats[m.exit_hist[(m.exit_count - 1) % machine.EXIT_HISTORY]] += 1
			vm_drain_dbg(s, m, &raw, &line)
			if !alive {
				frozen = true
				r := hv.get_regs(&m.vm)
				msg := strings.clone(m.bus.freeze_msg)
				regs := format_regs(r, m)
				publish_freeze(s, msg, regs)
				fmt.printfln("VM frozen: %s", msg)
			}
		} else {
			time.sleep(10 * time.Millisecond)
		}

		now := time.tick_now()
		if time.tick_diff(last_snap, now) >= SNAP_PERIOD {
			last_snap = now
			snap := vga.vga_snapshot(&m.vga, m.vm.ram)
			sync.lock(&s.mu)
			s.snap = snap
			s.exit_stats = stats
			sync.unlock(&s.mu)
		}
		free_all(context.temp_allocator)
	}

	sync.lock(&s.mu)
	s.exit_stats = stats
	sync.unlock(&s.mu)
	vm_shutdown(c, m)
	free(m)
}

vm_boot :: proc(c: ^Vm_Ctx, m: ^machine.Machine) -> bool {
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	m^ = {}
	if !machine.machine_init(m, RAM_SIZE) { return false }
	if !machine.load_roms(&m.vm) {
		machine.machine_destroy(m)
		return false
	}
	if c.attach { machine.machine_attach_disk(m, c.bd) }
	c.guard.vm = &m.vm
	c.guard.valid = true
	return true
}

vm_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine) {
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	if !c.guard.valid { return }
	c.guard.valid = false
	machine.machine_destroy(m)
}

publish_freeze :: proc(s: ^Shared, msg: string, regs: string) {
	sync.lock(&s.mu)
	s.frozen_msg = msg
	s.regs_text = regs
	sync.unlock(&s.mu)
}

format_regs :: proc(r: hv.Regs, m: ^machine.Machine) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "CS=%04x (base %08x) RIP=%08x RFLAGS=%08x", r.cs_sel, r.cs_base, r.rip, r.rflags)
	fmt.sbprintfln(&b, "RAX=%08x RBX=%08x RCX=%08x RDX=%08x", r.rax, r.rbx, r.rcx, r.rdx)
	fmt.sbprintfln(&b, "RSI=%08x RDI=%08x RSP=%08x RBP=%08x", r.rsi, r.rdi, r.rsp, r.rbp)
	count := int(min(m.exit_count, u64(machine.EXIT_HISTORY)))
	fmt.sbprintf(&b, "last %d exits:", count)
	for i in 0 ..< count {
		idx := (m.exit_count - u64(count) + u64(i)) % machine.EXIT_HISTORY
		fmt.sbprintf(&b, " %v", m.exit_hist[idx])
	}
	return strings.to_string(b)
}

// line to the device-log panel
vm_log :: proc(s: ^Shared, msg: string) {
	owned := strings.clone(msg)
	sync.lock(&s.mu)
	if len(s.log_lines) >= MAX_LOG_LINES { ordered_remove(&s.log_lines, 0) }
	append(&s.log_lines, owned)
	sync.unlock(&s.mu)
}

vm_drain_dbg :: proc(s: ^Shared, m: ^machine.Machine, raw: ^[dynamic]u8, line: ^[dynamic]u8) {
	clear(raw)
	machine.machine_drain_dbg(m, raw)
	for ch in raw {
		switch ch {
		case '\n':
			fmt.printfln("seabios: %s", string(line[:]))
			vm_log(s, fmt.tprintf("seabios: %s", string(line[:])))
			clear(line)
		case '\r':
		case:
			append(line, ch)
		}
	}
}

watchdog_proc :: proc(g: ^Vm_Guard) {
	for {
		time.sleep(WATCHDOG_PERIOD)
		sync.lock(&g.mu)
		if g.stop {
			sync.unlock(&g.mu)
			return
		}
		if g.valid { hv.cancel(g.vm) }
		sync.unlock(&g.mu)
	}
}

// --- console harness (Phase D, --console) ---

RUN_SECONDS :: 60
VGA_PERIOD :: 500 * time.Millisecond
CONSOLE_WATCHDOG_PERIOD :: 100 * time.Millisecond

// A guest that stops doing I/O never leaves WHvRunVirtualProcessor;
// periodic cancels keep the clock and the time cap alive.
console_watchdog_stop: bool

console_watchdog :: proc(vm: ^hv.Vm) {
	for !console_watchdog_stop {
		time.sleep(CONSOLE_WATCHDOG_PERIOD)
		hv.cancel(vm)
	}
}

console_main :: proc(attach: bool) {
	m := new(machine.Machine)
	if !machine.machine_init(m, RAM_SIZE) {
		fmt.eprintln("machine_init failed (WHPX unavailable?)")
		os.exit(1)
	}
	if !machine.load_roms(&m.vm) {
		fmt.eprintln("load_roms failed")
		os.exit(1)
	}

	if attach {
		path := default_c_drive()
		vol := fat32.volume_open(path, VOLUME_MB)
		if vol == nil {
			fmt.eprintfln("volume_open failed: %s", path)
			os.exit(1)
		}
		machine.machine_attach_disk(m, fat32.volume_block_device(vol))
		fmt.printfln("disk: %s as %dMB FAT32 volume", path, VOLUME_MB)
	} else {
		fmt.println("disk: none (--no-disk)")
	}

	thread.create_and_start_with_poly_data(&m.vm, console_watchdog)
	defer console_watchdog_stop = true

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

default_c_drive :: proc() -> string {
	home := os.get_env("USERPROFILE", context.allocator)
	if home == "" { home = os.get_env("HOME", context.allocator) }
	path, _ := filepath.join({home, ".retvrn99", "c_drive"})
	return path
}
