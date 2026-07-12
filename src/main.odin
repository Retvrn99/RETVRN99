// SPDX-License-Identifier: GPL-3.0-only
package main

// GUI by default: SDL3 window + ImGui menu, with the machine on its own
// thread. --console runs a headless harness (SeaBIOS POST on stdout) for
// boot debugging. --auto-close:N closes the GUI after N seconds.

import imgui "../vendor_local/imgui"
import "../vendor_local/imgui/imgui_impl_sdl3"
import "../vendor_local/imgui/imgui_impl_sdlrenderer3"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "disk"
import "fat32"
import "host"
import "hosttime"
import "hv"
import "machine"
import "profile"
import sdl3 "vendor:sdl3"
import "vga"
import "vmconfig"
import "win98prep"

RAM_SIZE :: 64 * 1024 * 1024
VOLUME_MB :: 2048
VCPU_PULSE_PERIOD :: time.Millisecond
SNAP_PERIOD :: 8 * time.Millisecond
MAX_LOG_LINES :: 2000
INSTALL_AUTORUN_KEYS :: [9]u8{0x22, 0x1F, 0x11, 0x1F, 0x12, 0x14, 0x16, 0x19, 0x1C}

Command_Kind :: enum {
	Key,
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Eject_Cdrom,
	Install_Windows_98,
	Set_Cpu_Mode,
}

Command :: struct {
	kind:     Command_Kind,
	key:      [2]u8, // set-1 bytes (E0-prefixed when extended)
	key_n:    int,
	path:     string, // Mount_Floppy; owned by the VM thread once queued
	cpu_mode: vmconfig.Cpu_Mode, // Set_Cpu_Mode: absolute selection
}

Shared :: struct {
	mu:                    sync.Mutex,
	snap:                  vga.Text_Snapshot, // copied by the VM thread every ~8ms
	log_lines:             [dynamic]string,
	cmds:                  [dynamic]Command,
	running:               bool,
	frozen_msg:            string,
	exit_stats:            [hv.Exit_Kind]u64,
	regs_text:             string,
	cdrom_mounted:         bool,
	installing_windows_98: bool,
}

// shields the ^hv.Vm from the vCPU pacer during destroy/reinit
Vm_Guard :: struct {
	mu:    sync.Mutex,
	vm:    ^hv.Vm,
	valid: bool,
	stop:  bool,
}

Vm_Ctx :: struct {
	shared:     ^Shared,
	guard:      Vm_Guard,
	volume:     ^fat32.Volume,
	bd:         disk.Block_Device,
	attach:     bool,
	floppy:     []u8, // retained copy of the mounted image so Reset keeps it in the drive
	cdrom_path: string, // retained path; each machine instance opens its own handle
	cpu_mode:   vmconfig.Cpu_Mode,
	paths:      profile.Paths,
	cmos:       profile.Cmos_Data,
	has_cmos:   bool,
}

main :: proc() {
	code := run_main()
	if code != 0 {os.exit(code)}
}

run_main :: proc() -> int {
	context.logger = log.create_console_logger(.Info, {.Level})

	console := false
	attach := true
	auto_close := -1
	run_seconds := RUN_SECONDS
	floppy_path := ""
	cdrom_path := ""
	for a in os.args[1:] {
		if a == "--console" {console = true}
		if a == "--no-disk" {attach = false}
		if strings.has_prefix(a, "--auto-close:") {
			auto_close, _ = strconv.parse_int(a[len("--auto-close:"):])
		}
		if strings.has_prefix(a, "--seconds:") {
			run_seconds, _ = strconv.parse_int(a[len("--seconds:"):])
		}
		if strings.has_prefix(a, "--floppy:") {
			floppy_path = a[len("--floppy:"):]
		}
		if strings.has_prefix(a, "--cdrom:") {
			cdrom_path = a[len("--cdrom:"):]
		}
	}

	paths, perr := profile.paths_default()
	if perr != nil {
		fmt.eprintfln("profile path resolution failed: %v", perr)
		return 1
	}
	defer profile.paths_destroy(&paths)
	settings, settings_diag := profile.settings_load(paths.settings)
	if settings_diag == .Missing {
		if save_diag := profile.settings_save(paths.settings, settings); save_diag != .None {
			fmt.eprintfln("settings save failed: %v", save_diag)
		}
	} else if settings_diag != .None {
		fmt.eprintfln("settings load warning: %v; using defaults", settings_diag)
	}
	cmos, cmos_diag := profile.cmos_load(paths.cmos)
	has_cmos := cmos_diag == .None
	if cmos_diag != .None && cmos_diag != .Missing {
		fmt.eprintfln("CMOS load warning: %v; using machine defaults", cmos_diag)
	}

	if console {
		return console_main(
			attach,
			run_seconds,
			floppy_path,
			cdrom_path,
			&paths,
			settings,
			cmos,
			has_cmos,
		)
	}
	return gui_main(attach, auto_close, &paths, settings, cmos, has_cmos)
}

// --- GUI ---

gui_main :: proc(
	attach: bool,
	auto_close: int,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
) -> int {
	active_settings := settings
	ctx := new(Vm_Ctx)
	shared := new(Shared)
	defer {
		fat32.volume_close(ctx.volume)
		free(shared)
		free(ctx)
	}
	shared.running = true
	ctx.shared = shared
	ctx.attach = attach
	ctx.cpu_mode = active_settings.cpu_mode
	ctx.paths = paths^
	ctx.cmos = cmos
	ctx.has_cmos = has_cmos
	if attach {
		if !vm_open_volume(ctx) {
			fmt.eprintfln("volume_open failed: %s", paths.c_drive)
			return 1
		}
		fmt.printfln("disk: %s as %dMB FAT32 volume", paths.c_drive, VOLUME_MB)
	} else {
		fmt.println("disk: none (--no-disk)")
	}

	h: host.Host
	if !host.host_init(&h) {
		fmt.eprintfln("host_init failed: %s", sdl3.GetError())
		return 1
	}

	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.IniFilename = nil // no imgui.ini
	host.theme_apply()
	imgui_impl_sdl3.InitForSDLRenderer(h.win, h.ren)
	imgui_impl_sdlrenderer3.Init(h.ren)

	vm_thr := thread.create_and_start_with_poly_data(ctx, vm_thread_proc)
	pacer_thr := thread.create_and_start_with_poly_data(&ctx.guard, vcpu_pacer_proc)

	st := host.Menu_State {
		cpu_mode = ctx.cpu_mode,
	}
	floppy_pending: Pending_Mount
	cdrom_pending: Pending_Mount
	install_pending: Pending_Mount
	start := time.tick_now()

	for {
		sync.lock(&shared.mu)
		running := shared.running
		sync.unlock(&shared.mu)
		if !running {break}

		ev: sdl3.Event
		for sdl3.PollEvent(&ev) {
			imgui_impl_sdl3.ProcessEvent(&ev)
			#partial switch ev.type {
			case .QUIT:
				set_running(shared, false)
			case .KEY_DOWN, .KEY_UP:
				// releases always reach the guest: swallowing a break code
				// while ImGui captures the keyboard leaves a stuck key
				if ev.key.down && io.WantCaptureKeyboard {continue}
				if s, ok := host.scancode_to_set1(ev.key.scancode); ok {
					buf, n := host.set1_bytes(s, ev.key.down)
					push_cmd(shared, Command{kind = .Key, key = buf, key_n = n})
				}
			}
		}

		if path, ready := pending_take(&floppy_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Floppy, path = path})
		}
		if path, ready := pending_take(&cdrom_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Cdrom, path = path})
		}
		if path, ready := pending_take(&install_pending); ready {
			push_cmd(shared, Command{kind = .Install_Windows_98, path = path})
		}

		// copy of the shared state for this frame
		sync.lock(&shared.mu)
		snap := shared.snap
		frozen := strings.clone(shared.frozen_msg, context.temp_allocator)
		regs := strings.clone(shared.regs_text, context.temp_allocator)
		stats := shared.exit_stats
		st.cdrom_mounted = shared.cdrom_mounted
		st.installing_windows_98 = shared.installing_windows_98
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
			sdl3.ShowOpenFileDialog(mount_dialog_cb, &floppy_pending, h.win, nil, 0, nil, false)
		case .Eject_Floppy:
			push_cmd(shared, Command{kind = .Eject_Floppy})
		case .Mount_Cdrom:
			sdl3.ShowOpenFileDialog(mount_dialog_cb, &cdrom_pending, h.win, nil, 0, nil, false)
		case .Eject_Cdrom:
			push_cmd(shared, Command{kind = .Eject_Cdrom})
		case .Install_Windows_98:
			sdl3.ShowOpenFileDialog(mount_dialog_cb, &install_pending, h.win, nil, 0, nil, false)
		case .Set_Cpu_Mode:
			push_cmd(shared, Command{kind = .Set_Cpu_Mode, cpu_mode = st.cpu_mode})
			active_settings.cpu_mode = st.cpu_mode
			if diag := profile.settings_save(paths.settings, active_settings); diag != .None {
				vm_log(shared, fmt.tprintf("settings: save failed (%v)", diag))
			}
		case .None:
		}
		imgui.Render()
		imgui_impl_sdlrenderer3.RenderDrawData(imgui.GetDrawData(), h.ren)
		sdl3.RenderPresent(h.ren)
		if !h.vsync {time.sleep(8 * time.Millisecond)} 	// no vsync: pace manually

		free_all(context.temp_allocator)

		if auto_close >= 0 && time.duration_seconds(time.tick_since(start)) >= f64(auto_close) {
			set_running(shared, false)
		}
	}

	thread.join(vm_thr)
	sync.lock(&ctx.guard.mu)
	ctx.guard.stop = true
	sync.unlock(&ctx.guard.mu)
	thread.join(pacer_thr)

	imgui_impl_sdlrenderer3.Shutdown()
	imgui_impl_sdl3.Shutdown()
	imgui.DestroyContext()
	host.host_destroy(&h)

	fmt.print("exit stats:")
	for kind in hv.Exit_Kind {
		fmt.printf(" %v=%d", kind, shared.exit_stats[kind])
	}
	fmt.println()
	return 0
}

Pending_Mount :: struct {
	mu:   sync.Mutex,
	path: string,
	has:  bool,
}

mount_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	p := (^Pending_Mount)(userdata)
	if filelist == nil || filelist[0] == nil {return} 	// error or canceled
	sync.lock(&p.mu)
	p.path = strings.clone(string(filelist[0]))
	p.has = true
	sync.unlock(&p.mu)
}

pending_take :: proc(p: ^Pending_Mount) -> (string, bool) {
	sync.lock(&p.mu)
	defer sync.unlock(&p.mu)
	if !p.has {return "", false}
	p.has = false
	path := p.path
	p.path = ""
	return path, true
}

snapshot_contains :: proc(snap: ^vga.Text_Snapshot, needle: string) -> bool {
	if len(needle) == 0 {return true}
	matched := 0
	for cell in snap.cells {
		ch := u8(cell)
		if ch == needle[matched] {
			matched += 1
			if matched == len(needle) {return true}
		} else {
			matched = 1 if ch == needle[0] else 0
		}
	}
	return false
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
	} else {
		vm_log(s, cpu_mode_log(c.cpu_mode))
	}

	raw: [dynamic]u8
	line: [dynamic]u8
	stats: [hv.Exit_Kind]u64
	frozen := false
	install_waiting := false
	install_typing := false
	install_key_index := 0
	install_next_key: time.Tick
	install_keys := INSTALL_AUTORUN_KEYS
	sync.lock(&s.mu)
	frozen = s.frozen_msg != ""
	sync.unlock(&s.mu)
	last_snap := time.tick_now()

	loop: for {
		// commands from the UI
		sync.lock(&s.mu)
		if !s.running {sync.unlock(&s.mu); break loop}
		cmds := make([]Command, len(s.cmds), context.allocator)
		copy(cmds, s.cmds[:])
		clear(&s.cmds)
		sync.unlock(&s.mu)

		quit := false
		for cmd in cmds {
			switch cmd.kind {
			case .Key:
				if !frozen {
					for i in 0 ..< cmd.key_n {machine.i8042_key(&m.kbd, cmd.key[i])}
				}
			case .Reset:
				vm_shutdown(c, m)
				stats = {}
				if vm_boot(c, m) {
					frozen = false
					publish_freeze(s, "", "")
					vm_log(
						s,
						fmt.tprintf("machine: reset (%s)", vmconfig.cpu_mode_name(c.cpu_mode)),
					)
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
				if img, err := os.read_entire_file_from_path(cmd.path, context.allocator);
				   err == nil {
					if machine.machine_mount_floppy(m, img) {
						delete(c.floppy)
						c.floppy = img
						vm_log(s, fmt.tprintf("floppy: mounted %s", cmd.path))
					} else {
						vm_log(s, fmt.tprintf("floppy: %s is not a 1.44MB image", cmd.path))
						delete(img)
					}
				} else {
					vm_log(s, fmt.tprintf("floppy: cannot read %s", cmd.path))
				}
				delete(cmd.path)
			case .Eject_Floppy:
				machine.machine_eject_floppy(m)
				delete(c.floppy)
				c.floppy = nil
				vm_log(s, "floppy: ejected")
			case .Mount_Cdrom:
				if machine.machine_mount_cdrom(m, cmd.path) {
					delete(c.cdrom_path)
					c.cdrom_path = strings.clone(cmd.path)
					publish_cdrom_state(s, true)
					vm_log(s, fmt.tprintf("CD-ROM: mounted %s", c.cdrom_path))
				} else {
					vm_log(s, fmt.tprintf("CD-ROM: unsupported or unreadable image %s", cmd.path))
				}
				delete(cmd.path)
			case .Eject_Cdrom:
				machine.machine_eject_cdrom(m)
				delete(c.cdrom_path)
				c.cdrom_path = ""
				publish_cdrom_state(s, false)
				vm_log(s, "CD-ROM: ejected")
			case .Install_Windows_98:
				if !c.attach {
					vm_log(s, "Windows 98: installation requires the protected C: drive")
					delete(cmd.path)
					continue
				}
				publish_install_state(s, true)
				vm_log(s, fmt.tprintf("Windows 98: validating and extracting %s", cmd.path))
				vm_shutdown(c, m)
				fat32.volume_close(c.volume)
				c.volume = nil
				c.bd = {}
				report := win98prep.prepare(cmd.path, c.paths.install, c.paths.c_drive)
				prepared := report.diagnostic == .None
				if prepared {
					vm_log(
						s,
						fmt.tprintf(
							"Windows 98: staged %d files (%d bytes), setup is %s",
							report.media_info.win98_file_count,
							report.media_info.win98_total_bytes,
							report.media_info.setup_executable,
						),
					)
					delete(c.cdrom_path)
					c.cdrom_path = strings.clone(cmd.path)
				} else {
					vm_log(
						s,
						fmt.tprintf(
							"Windows 98: preparation failed (%v, media %v)",
							report.diagnostic,
							report.media_diagnostic,
						),
					)
					publish_install_state(s, false)
				}
				win98prep.report_destroy(&report)
				delete(cmd.path)
				if !vm_open_volume(c) {
					frozen = true
					publish_freeze(s, "Windows 98: cannot reopen C: after preparation", "")
					continue
				}
				if vm_boot(c, m) {
					frozen = false
					publish_freeze(s, "", "")
					if prepared {
						install_waiting = true
						install_typing = false
						install_key_index = 0
						vm_log(s, "Windows 98: rebooting to DOS before unattended Setup")
					}
				} else {
					frozen = true
					publish_freeze(s, "Windows 98: reboot after preparation failed", "")
				}
			case .Set_Cpu_Mode:
				c.cpu_mode = cmd.cpu_mode
				machine.machine_set_cpu_mode(m, c.cpu_mode)
				vm_log(s, cpu_mode_log(c.cpu_mode))
			}
		}
		delete(cmds)
		if quit {break loop}

		if !frozen {
			alive := machine.step(m)
			stats[m.exit_hist[(m.exit_count - 1) % machine.EXIT_HISTORY]] += 1
			vm_drain_dbg(s, m, &raw, &line)
			if !alive {
				if machine.machine_reset_requested(m) {
					vm_shutdown(c, m)
					stats = {}
					if vm_boot(c, m) {
						frozen = false
						publish_freeze(s, "", "")
						vm_log(s, "machine: guest-requested reset")
					} else {
						frozen = true
						publish_freeze(s, "guest reset failed: machine init error", "")
					}
				} else {
					frozen = true
					r := hv.get_regs(&m.vm)
					msg := strings.clone(m.bus.freeze_msg)
					regs := format_regs(r, m)
					publish_freeze(s, msg, regs)
					fmt.printfln("VM frozen: %s", msg)
				}
			}
		} else {
			time.sleep(10 * time.Millisecond)
		}

		now := time.tick_now()
		if install_typing && time.tick_diff(install_next_key, now) >= 100 * time.Millisecond {
			scancode := install_keys[install_key_index]
			machine.i8042_key(&m.kbd, scancode)
			machine.i8042_key(&m.kbd, scancode | 0x80)
			install_key_index += 1
			install_next_key = now
			if install_key_index == len(install_keys) {
				install_typing = false
				install_waiting = false
				vm_log(s, "Windows 98: GSWSETUP launched")
			}
		}
		if time.tick_diff(last_snap, now) >= SNAP_PERIOD {
			last_snap = now
			snap := vga.vga_snapshot(&m.vga, m.vm.ram)
			if install_waiting && !install_typing && snapshot_contains(&snap, "C:") {
				install_typing = true
				install_next_key = now
				vm_log(s, "Windows 98: DOS prompt reached; starting GSWSETUP")
			}
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
	delete(c.floppy)
	delete(c.cdrom_path)
	free(m)
}

vm_open_volume :: proc(c: ^Vm_Ctx) -> bool {
	vol := fat32.volume_open(c.paths.c_drive, VOLUME_MB)
	if vol == nil {return false}
	vol.fail_ctx = c.shared
	vol.on_fail = proc(ctx: rawptr, msg: string) {
		vm_log((^Shared)(ctx), fmt.tprintf("disk: writes frozen: %s", msg))
	}
	c.volume = vol
	c.bd = fat32.volume_block_device(vol)
	return true
}

vm_boot :: proc(c: ^Vm_Ctx, m: ^machine.Machine) -> bool {
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	m^ = {}
	if !machine.machine_init(m, RAM_SIZE) {return false}
	if c.has_cmos {_ = machine.machine_cmos_import(m, c.cmos[:])}
	machine.machine_set_cpu_mode(m, c.cpu_mode)
	if !machine.load_roms(&m.vm) {
		machine.machine_destroy(m)
		return false
	}
	if c.attach {machine.machine_attach_disk(m, c.bd)}
	if c.floppy != nil {_ = machine.machine_mount_floppy(m, c.floppy)}
	if c.cdrom_path != "" {
		if machine.machine_mount_cdrom(m, c.cdrom_path) {
			publish_cdrom_state(c.shared, true)
		} else {
			publish_cdrom_state(c.shared, false)
			vm_log(c.shared, fmt.tprintf("CD-ROM: cannot reopen %s", c.cdrom_path))
		}
	}
	c.guard.vm = &m.vm
	c.guard.valid = true
	return true
}

vm_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine) {
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	if !c.guard.valid {return}
	c.guard.valid = false
	saved_cmos := machine.machine_cmos_export(m)
	copy(c.cmos[:], saved_cmos[:])
	c.has_cmos = true
	if diag := profile.cmos_save(c.paths.cmos, c.cmos); diag != .None {
		vm_log(c.shared, fmt.tprintf("CMOS: save failed (%v)", diag))
	}
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

// line to the device-log panel
vm_log :: proc(s: ^Shared, msg: string) {
	owned := strings.clone(msg)
	sync.lock(&s.mu)
	if len(s.log_lines) >= MAX_LOG_LINES {ordered_remove(&s.log_lines, 0)}
	append(&s.log_lines, owned)
	sync.unlock(&s.mu)
}

cpu_mode_log :: proc(mode: vmconfig.Cpu_Mode) -> string {
	switch mode {
	case .GSW_886:
		return "cpu: GSW-886 (1 GHz TSC, approximate throughput)"
	case .Turbo:
		return "cpu: Turbo (1 GHz TSC, unrestricted throughput)"
	}
	return "cpu: unknown mode"
}

// splits drained 0x402 bytes into "seabios: " lines; s optionally mirrors
// them into the GUI device log (nil on the console path)
vm_drain_dbg :: proc(s: ^Shared, m: ^machine.Machine, raw: ^[dynamic]u8, line: ^[dynamic]u8) {
	clear(raw)
	machine.machine_drain_dbg(m, raw)
	for ch in raw {
		switch ch {
		case '\n':
			fmt.printfln("seabios: %s", string(line[:]))
			if s != nil {vm_log(s, fmt.tprintf("seabios: %s", string(line[:])))}
			clear(line)
		case '\r':
		case:
			append(line, ch)
		}
	}
}

vcpu_pacer_proc :: proc(g: ^Vm_Guard) {
	waiter: hosttime.Waiter
	hosttime.waiter_init(&waiter)
	defer hosttime.waiter_destroy(&waiter)
	for {
		hosttime.waiter_sleep(&waiter, VCPU_PULSE_PERIOD)
		sync.lock(&g.mu)
		if g.stop {
			sync.unlock(&g.mu)
			return
		}
		if g.valid {hv.cancel(g.vm)}
		sync.unlock(&g.mu)
	}
}

// --- console harness (--console) ---

RUN_SECONDS :: 60
VGA_PERIOD :: 500 * time.Millisecond

console_main :: proc(
	attach: bool,
	run_seconds: int,
	floppy_path: string,
	cdrom_path: string,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
) -> int {
	loaded_cmos := cmos
	vol: ^fat32.Volume
	m := new(machine.Machine)
	if !machine.machine_init(m, RAM_SIZE) {
		fmt.eprintln("machine_init failed (WHPX unavailable?)")
		free(m)
		return 1
	}
	defer {
		saved_cmos := machine.machine_cmos_export(m)
		stored: profile.Cmos_Data
		copy(stored[:], saved_cmos[:])
		if diag := profile.cmos_save(paths.cmos, stored); diag != .None {
			fmt.eprintfln("CMOS save failed: %v", diag)
		}
		machine.machine_destroy(m)
		fat32.volume_close(vol)
		free(m)
	}
	if has_cmos {_ = machine.machine_cmos_import(m, loaded_cmos[:])}
	if !machine.load_roms(&m.vm) {
		fmt.eprintln("load_roms failed")
		return 1
	}
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	fmt.println(cpu_mode_log(settings.cpu_mode))
	if cdrom_path != "" {
		if !machine.machine_mount_cdrom(m, cdrom_path) {
			fmt.eprintfln("CD-ROM: unsupported or unreadable image %s", cdrom_path)
			return 1
		}
		fmt.printfln("CD-ROM: mounted %s", cdrom_path)
	}

	if attach {
		vol = fat32.volume_open(paths.c_drive, VOLUME_MB)
		if vol == nil {
			fmt.eprintfln("volume_open failed: %s", paths.c_drive)
			return 1
		}
		vol.on_fail = proc(ctx: rawptr, msg: string) {
			fmt.printfln("disk: writes frozen: %s", msg)
		}
		machine.machine_attach_disk(m, fat32.volume_block_device(vol))
		fmt.printfln("disk: %s as %dMB FAT32 volume", paths.c_drive, VOLUME_MB)
	} else {
		fmt.println("disk: none (--no-disk)")
	}

	if floppy_path != "" {
		if img, err := os.read_entire_file_from_path(floppy_path, context.allocator); err == nil {
			if machine.machine_mount_floppy(m, img) {
				fmt.printfln("floppy: mounted %s", floppy_path)
			} else {
				fmt.eprintfln("floppy: %s is not a 1.44MB image", floppy_path)
				return 1
			}
			delete(img)
		} else {
			fmt.eprintfln("floppy: cannot read %s", floppy_path)
			return 1
		}
	}

	// a guest that stops doing I/O never leaves WHvRunVirtualProcessor;
	// periodic cancels keep the clock and the time cap alive
	guard: Vm_Guard
	guard.vm = &m.vm
	guard.valid = true
	pacer_thr := thread.create_and_start_with_poly_data(&guard, vcpu_pacer_proc)
	defer {
		sync.lock(&guard.mu)
		guard.stop = true
		sync.unlock(&guard.mu)
		thread.join(pacer_thr)
	}

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
		vm_drain_dbg(nil, m, &raw, &line)
		now := time.tick_now()
		if !alive {
			flush_partial(&line)
			fmt.printfln("VM frozen after %d iterations: %s", iterations, m.bus.freeze_msg)
			dump_state(m)
			print_grid(vga.vga_snapshot(&m.vga, m.vm.ram))
			return 2
		}
		if time.tick_diff(last_vga, now) >= VGA_PERIOD {
			last_vga = now
			snap := vga.vga_snapshot(&m.vga, m.vm.ram)
			if !shown || snap.cells != prev.cells {
				prev = snap
				shown = true
				fmt.printfln("[%.0fs]", time.duration_seconds(time.tick_diff(start, now)))
				print_grid(snap)
			}
		}
		if time.tick_diff(start, now) >= time.Duration(run_seconds) * time.Second {
			flush_partial(&line)
			fmt.printfln(
				"time cap (%ds) reached after %d iterations, exiting",
				run_seconds,
				iterations,
			)
			dump_state(m)
			print_grid(vga.vga_snapshot(&m.vga, m.vm.ram))
			break
		}
	}
	return 0
}

publish_cdrom_state :: proc(s: ^Shared, mounted: bool) {
	sync.lock(&s.mu)
	s.cdrom_mounted = mounted
	sync.unlock(&s.mu)
}

publish_install_state :: proc(s: ^Shared, installing: bool) {
	sync.lock(&s.mu)
	s.installing_windows_98 = installing
	sync.unlock(&s.mu)
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
	fmt.printfln(
		"vga: cursor row=%d col=%d on=%v",
		snap.cursor_row,
		snap.cursor_col,
		snap.cursor_on,
	)
}

dump_state :: proc(m: ^machine.Machine) {
	r := hv.get_regs(&m.vm)
	fmt.println(format_regs(r, m))
	nio := int(min(m.io_count, u64(machine.IO_HISTORY)))
	fmt.printf("last %d io:", nio)
	for i in 0 ..< nio {
		idx := (m.io_count - u64(nio) + u64(i)) % machine.IO_HISTORY
		t := m.io_hist[idx]
		fmt.printf(" %s[%04x]=%x", t.write ? "w" : "r", t.port, t.val)
	}
	fmt.println()
	fmt.print("irq injections:")
	for c, v in m.inj_count {
		if c > 0 {fmt.printf(" vec%02x=%d", v, c)}
	}
	fmt.println()
	fmt.printfln(
		"i8042: count=%d cmd_byte=%02x head=%d tail=%d",
		m.kbd.count,
		m.kbd.cmd_byte,
		m.kbd.head,
		m.kbd.tail,
	)
	fmt.printfln(
		"pic: master irr=%02x imr=%02x isr=%02x base=%02x slave irr=%02x imr=%02x isr=%02x base=%02x",
		m.pic.master.irr,
		m.pic.master.imr,
		m.pic.master.isr,
		m.pic.master.base,
		m.pic.slave.irr,
		m.pic.slave.imr,
		m.pic.slave.isr,
		m.pic.slave.base,
	)
	nide := int(min(m.ide_count, u64(machine.IDE_HISTORY)))
	fmt.printf("last %d ide io (of %d):", nide, m.ide_count)
	for i in 0 ..< nide {
		idx := (m.ide_count - u64(nide) + u64(i)) % machine.IDE_HISTORY
		t := m.ide_hist[idx]
		fmt.printf(" %s[%04x]=%x", t.write ? "w" : "r", t.port, t.val)
	}
	fmt.println()
	dump_ram(m, "ivt 00-1F", 0x0000, 0x80)
	dump_ram(m, "mbr@0600", 0x0600, 0x20)
	dump_ram(m, "iosys@0700", 0x0700, 0x40)
	dump_ram(m, "msload@0900", 0x0900, 0x40)
	dump_ram(m, "vbr@7C00", 0x7C00, 0x40)
	sp := int(r.ss_base) + int(r.rsp & 0xFFFF)
	lo := max(0, sp - 0x20)
	if lo + 0x60 <= len(m.vm.ram) {dump_ram(m, "stack", lo, 0x60)}
	ncmd := int(min(m.cmd_count, u64(machine.IDE_HISTORY)))
	fmt.printf("last %d ide cmds (of %d):", ncmd, m.cmd_count)
	for i in 0 ..< ncmd {
		idx := (m.cmd_count - u64(ncmd) + u64(i)) % machine.IDE_HISTORY
		t := m.cmd_hist[idx]
		fmt.printf(" %02x@%x*%d", t.cmd, t.lba, t.count)
	}
	fmt.println()
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
