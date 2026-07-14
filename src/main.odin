// SPDX-License-Identifier: GPL-3.0-only
package main

// GUI by default: SDL3 window + ImGui menu, with the machine on its own
// thread. --console runs a headless harness (SeaBIOS POST on stdout) for
// boot debugging. --profile-root:PATH isolates profile-backed runs.

import imgui "../vendor_local/imgui"
import "../vendor_local/imgui/imgui_impl_sdl3"
import "../vendor_local/imgui/imgui_impl_sdlrenderer3"
import "acceptance"
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
import "disk"
import "fat32"
import "host"
import "hv"
import "machine"
import "profile"
import sdl3 "vendor:sdl3"
import "vga"
import "vmconfig"
import "win98prep"

RAM_SIZE :: vmconfig.GSW_RAM_BYTES
VOLUME_MB :: 2048
SNAP_PERIOD :: 8 * time.Millisecond
MAX_LOG_LINES :: 2000
HOST_SDL_EVENTS_PER_FRAME :: 512
HOST_INPUTS_PER_VM_STEP :: 256

Command_Kind :: enum {
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Eject_Cdrom,
	Install_Windows_98,
	Finish_Windows_98_Installation,
	Set_Cpu_Mode,
	Set_Pause,
}

Command :: struct {
	kind:         Command_Kind,
	path:         string, // Mount_Floppy; owned by the VM thread once queued
	cpu_mode:     vmconfig.Cpu_Mode, // Set_Cpu_Mode: absolute selection
	pause_reason: host.Pause_Reason,
	pause_active: bool,
}

Shared :: struct {
	mu:                    sync.Mutex,
	snap:                  vga.Text_Snapshot,
	frames:                Frame_Mailbox,
	log_lines:             [dynamic]string,
	cmds:                  [dynamic]Command,
	running:               bool,
	frozen_msg:            string,
	exit_stats:            [hv.Exit_Kind]u64,
	regs_text:             string,
	cdrom_mounted:         bool,
	installing_windows_98: bool,
	pause_state:           host.Pause_State,
	input:                 host.Host_Input_Queue,
	guard:                 ^Vm_Guard,
}

Vm_Ctx :: struct {
	shared:                  ^Shared,
	guard:                   Vm_Guard,
	audio:                   host.Host_Audio,
	audio_enabled:           bool,
	volume:                  ^fat32.Volume,
	bd:                      disk.Block_Device,
	attach:                  bool,
	floppy:                  []u8, // retained copy of the mounted image so Reset keeps it in the drive
	floppy_path:             string,
	cdrom_path:              string, // retained path; each machine instance opens its own handle
	cpu_mode:                vmconfig.Cpu_Mode,
	paths:                   profile.Paths,
	cmos:                    profile.Cmos_Data,
	has_cmos:                bool,
	install_state:           profile.Install_State,
	preparation_interrupted: bool,
	preparation_recovered:   bool,
	firmware_log_all:        bool,
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
	profile_root := ""
	frame_dump_path := ""
	seconds_explicit := false
	acceptance_options, acceptance_diagnostic := acceptance.options_parse(os.args[1:])
	if acceptance_diagnostic != .None {
		fmt.eprintfln("acceptance option error: %v", acceptance_diagnostic)
		return 1
	}
	if acceptance.options_request_headless(&acceptance_options) {console = true}
	for a in os.args[1:] {
		if a == "--console" {console = true}
		if a == "--no-disk" {attach = false}
		if strings.has_prefix(a, "--auto-close:") {
			auto_close, _ = strconv.parse_int(a[len("--auto-close:"):])
		}
		if strings.has_prefix(a, "--seconds:") {
			run_seconds, _ = strconv.parse_int(a[len("--seconds:"):])
			seconds_explicit = true
		}
		if strings.has_prefix(a, "--floppy:") {
			floppy_path = a[len("--floppy:"):]
		}
		if strings.has_prefix(a, "--cdrom:") {
			cdrom_path = a[len("--cdrom:"):]
		}
		if strings.has_prefix(a, "--profile-root:") {
			profile_root = a[len("--profile-root:"):]
		}
		if strings.has_prefix(a, "--frame-dump:") {
			frame_dump_path = a[len("--frame-dump:"):]
		}
	}
	if acceptance_options.accept_until == .Hardware_Detection && !seconds_explicit {
		run_seconds = 30 * 60
	}

	paths: profile.Paths
	perr: os.Error
	if profile_root == "" {
		paths, perr = profile.paths_default()
	} else {
		paths, perr = profile.paths_from_root(profile_root)
	}
	if perr != nil {
		fmt.eprintfln("profile path resolution failed: %v", perr)
		return console_acceptance_configuration_error(
			&acceptance_options,
			nil,
			.GSW_886,
			"profile path resolution failed",
		)
	}
	defer profile.paths_destroy(&paths)
	switch dos_diagnostic := profile.dos_seed_prepare(paths.c_drive); dos_diagnostic {
	case .Updated:
		fmt.println("DOS seed: disabled the IO.SYS boot logo in placeholder MSDOS.SYS")
	case .Missing, .Preserved:
	case .Path_Failed,
	     .Read_Failed,
	     .Create_Directory_Failed,
	     .Temporary_Path_Failed,
	     .Write_Failed,
	     .Replace_Failed:
		fmt.eprintfln("DOS seed warning: MSDOS.SYS preparation failed (%v)", dos_diagnostic)
	}
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
		owned_cdrom_path := ""
		defer delete(owned_cdrom_path)
		if acceptance_options.install_windows {
			if !attach {
				fmt.eprintln("Windows 98: --install-windows requires the protected C: drive")
				return console_acceptance_configuration_error(
					&acceptance_options,
					&paths,
					settings.cpu_mode,
					"Windows 98 installation requires the protected C: drive",
				)
			}
			if acceptance_options.install_windows_path != "" {
				if !console_prepare_windows_install(
					acceptance_options.install_windows_path,
					&paths,
					cmos,
					has_cmos,
					floppy_path,
				) {
					return console_acceptance_configuration_error(
						&acceptance_options,
						&paths,
						settings.cpu_mode,
						"Windows 98 media preparation failed",
					)
				}
				owned_cdrom_path = strings.clone(acceptance_options.install_windows_path)
			} else {
				state, diagnostic := profile.install_state_load(paths.install_state)
				if diagnostic != .None || !profile.install_state_active(&state) {
					profile.install_state_destroy(&state)
					fmt.eprintln("Windows 98: no prepared installation session to resume")
					return console_acceptance_configuration_error(
						&acceptance_options,
						&paths,
						settings.cpu_mode,
						"no prepared Windows 98 installation session",
					)
				}
				owned_cdrom_path = strings.clone(state.source_path)
				profile.install_state_destroy(&state)
			}
			floppy_path = ""
			cdrom_path = owned_cdrom_path
		}
		return console_main(
			attach,
			run_seconds,
			floppy_path,
			cdrom_path,
			&paths,
			settings,
			cmos,
			has_cmos,
			frame_dump_path,
			acceptance_options,
		)
	}
	return gui_main(
		attach,
		auto_close,
		&paths,
		settings,
		cmos,
		has_cmos,
		acceptance_options.firmware_log_all,
	)
}

// --- GUI ---

gui_main :: proc(
	attach: bool,
	auto_close: int,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
	firmware_log_all: bool,
) -> (
	result: int,
) {
	active_settings := settings
	auto_close_after := auto_close
	ctx := new(Vm_Ctx)
	shared := new(Shared)
	defer {
		if ctx.volume != nil {
			if fat32.volume_close(ctx.volume) {
				ctx.volume = nil
			} else {
				fmt.eprintln("disk: close failed; staged C: writes remain retained")
				if result == 0 {result = 1}
			}
		}
		profile.install_state_destroy(&ctx.install_state)
		frame_mailbox_destroy(&shared.frames)
		command_queue_destroy(shared)
		vm_log_destroy(shared)
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
	ctx.firmware_log_all = firmware_log_all
	install_state, install_diagnostic := profile.install_state_load(paths.install_state)
	ctx.install_state = install_state
	ctx.preparation_interrupted, ctx.preparation_recovered =
		install_interrupted_preparation_recover(&ctx.paths, &ctx.install_state)
	if profile.install_state_active(&ctx.install_state) {
		shared.installing_windows_98 = true
		ctx.cdrom_path = strings.clone(ctx.install_state.source_path)
	}
	if install_diagnostic != .None && install_diagnostic != .Missing {
		vm_log(shared, fmt.tprintf("Windows 98: install state ignored (%v)", install_diagnostic))
	}
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
	lifecycle_watch := Lifecycle_Watch {
			shared = shared,
		}
	lifecycle_watch_registered := sdl3.AddEventWatch(lifecycle_event_watch, &lifecycle_watch)
	if !lifecycle_watch_registered {
		fmt.eprintfln("SDL lifecycle watch failed: %s", sdl3.GetError())
		host.host_destroy(&h)
		return 1
	}
	defer {
		if lifecycle_watch_registered {
			sdl3.RemoveEventWatch(lifecycle_event_watch, &lifecycle_watch)
		}
	}

	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.IniFilename = nil // no imgui.ini
	host.theme_apply()
	imgui_impl_sdl3.InitForSDLRenderer(h.win, h.ren)
	imgui_impl_sdlrenderer3.Init(h.ren)

	if !vm_guard_init(&ctx.guard) {
		fmt.eprintln("vCPU wake adapter initialization failed")
		return 1
	}
	shared.guard = &ctx.guard
	ctx.audio_enabled = true
	defer {
		shared.guard = nil
		vm_guard_destroy(&ctx.guard)
	}
	vm_thr := thread.create_and_start_with_poly_data(ctx, vm_thread_proc)

	st := host.Menu_State {
			cpu_mode = ctx.cpu_mode,
		}
	floppy_pending := pending_mount_create()
	cdrom_pending := pending_mount_create()
	install_pending := pending_mount_create()
	release_mouse_key := false
	keyboard: host.Host_Keyboard
	start := time.tick_now()

	for {
		sync.lock(&shared.mu)
		running := shared.running
		sync.unlock(&shared.mu)
		if !running {break}

		ev: sdl3.Event
		for event_count in 0 ..< HOST_SDL_EVENTS_PER_FRAME {
			if !sdl3.PollEvent(&ev) {break}
			mouse_event :=
				ev.type == .MOUSE_MOTION ||
				ev.type == .MOUSE_BUTTON_DOWN ||
				ev.type == .MOUSE_BUTTON_UP ||
				ev.type == .MOUSE_WHEEL
			if !h.mouse_captured || !mouse_event {imgui_impl_sdl3.ProcessEvent(&ev)}
			#partial switch ev.type {
			case .QUIT:
				push_cmd(shared, Command{kind = .Power_Off})
			case .KEY_DOWN, .KEY_UP:
				if ev.key.repeat {continue}
				if ev.key.scancode == .RCTRL &&
				   ((ev.key.down && h.mouse_captured) || release_mouse_key) {
					if ev.key.down {
						release_mouse_key = true
						if host.mouse_capture(&h, false) {push_mouse_buttons(shared, 0, true)}
					} else {
						release_mouse_key = false
					}
					continue
				}
				// releases always reach the guest: swallowing a break code
				// while ImGui captures the keyboard leaves a stuck key
				if ev.key.down && io.WantCaptureKeyboard {continue}
				push_host_key(shared, &keyboard, ev.key.scancode, ev.key.down)
			case .MOUSE_MOTION:
				if h.mouse_captured {
					h.mouse_buttons = host.mouse_buttons_from_sdl(ev.motion.state)
					push_mouse_motion(
						shared,
						i32(ev.motion.xrel),
						i32(ev.motion.yrel),
						h.mouse_buttons,
					)
				}
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				if !h.mouse_captured {
					if !ev.button.down ||
					   io.WantCaptureMouse ||
					   !host.mouse_inside_guest(&h, ev.button.x, ev.button.y) ||
					   !host.mouse_capture(&h, true) {
						continue
					}
				}
				h.mouse_buttons = host.mouse_set_button(
					h.mouse_buttons,
					ev.button.button,
					ev.button.down,
				)
				push_mouse_buttons(shared, h.mouse_buttons, !ev.button.down)
			case .MOUSE_WHEEL:
				if h.mouse_captured {
					wheel := ev.wheel.integer_y
					if wheel == 0 && ev.wheel.y != 0 {wheel = ev.wheel.y > 0 ? 1 : -1}
					if ev.wheel.direction == .FLIPPED {wheel = -wheel}
					push_mouse_wheel(shared, wheel, h.mouse_buttons)
				}
			case .WINDOW_FOCUS_LOST, .WILL_ENTER_BACKGROUND, .DID_ENTER_BACKGROUND:
				release_mouse_key = false
				release_held_keys(shared, &keyboard)
				if h.mouse_captured {
					_ = host.mouse_capture(&h, false)
					push_mouse_buttons(shared, 0, true)
				}
			}
		}

		if path, ready := pending_take(floppy_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Floppy, path = path})
		}
		if path, ready := pending_take(cdrom_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Cdrom, path = path})
		}
		if path, ready := pending_take(install_pending); ready {
			push_cmd(shared, Command{kind = .Install_Windows_98, path = path})
		}

		// copy of the shared state for this frame
		sync.lock(&shared.mu)
		frozen := strings.clone(shared.frozen_msg, context.temp_allocator)
		regs := strings.clone(shared.regs_text, context.temp_allocator)
		stats := shared.exit_stats
		st.cdrom_mounted = shared.cdrom_mounted
		st.installing_windows_98 = shared.installing_windows_98
		st.user_paused = host.pause_reason_active(&shared.pause_state, .User)
		nlog := len(shared.log_lines)
		first := max(0, nlog - 200)
		logs := make([]string, nlog - first, context.temp_allocator)
		for line, i in shared.log_lines[first:] {
			logs[i] = strings.clone(line, context.temp_allocator)
		}
		sync.unlock(&shared.mu)

		exit_lines := make([dynamic]string, context.temp_allocator)
		for kind in hv.Exit_Kind {
			append(&exit_lines, fmt.tprintf("%v: %d", kind, stats[kind]))
		}

		if frame_slot := frame_mailbox_acquire(&shared.frames); frame_slot != nil {
			if frame := vga.scanout_descriptor_render(&frame_slot.scanout); frame != nil {
				_ = host.host_upload_frame(&h, frame)
			}
			frame_mailbox_release(&shared.frames, frame_slot)
		}
		host.host_render_guest(&h)

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
		case .Toggle_Pause:
			st.user_paused = !st.user_paused
			push_cmd(
				shared,
				Command{kind = .Set_Pause, pause_reason = .User, pause_active = st.user_paused},
			)
		case .Power_Off:
			push_cmd(shared, Command{kind = .Power_Off})
		case .Mount_Floppy:
			pending_mount_show(floppy_pending, h.win)
		case .Eject_Floppy:
			push_cmd(shared, Command{kind = .Eject_Floppy})
		case .Mount_Cdrom:
			pending_mount_show(cdrom_pending, h.win)
		case .Eject_Cdrom:
			push_cmd(shared, Command{kind = .Eject_Cdrom})
		case .Install_Windows_98:
			pending_mount_show(install_pending, h.win)
		case .Finish_Windows_98_Installation:
			push_cmd(shared, Command{kind = .Finish_Windows_98_Installation})
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

		if auto_close_after >= 0 &&
		   time.duration_seconds(time.tick_since(start)) >= f64(auto_close_after) {
			push_cmd(shared, Command{kind = .Power_Off})
			auto_close_after = -1
		}
	}
	sdl3.RemoveEventWatch(lifecycle_event_watch, &lifecycle_watch)
	lifecycle_watch_registered = false
	pending_mount_release(floppy_pending)
	floppy_pending = nil
	pending_mount_release(cdrom_pending)
	cdrom_pending = nil
	pending_mount_release(install_pending)
	install_pending = nil

	thread.destroy(vm_thr)

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
	mu:        sync.Mutex,
	allocator: runtime.Allocator,
	path:      string,
	has:       bool,
	dialogs:   int,
	detached:  bool,
}

pending_mount_create :: proc() -> ^Pending_Mount {
	allocator := context.allocator
	p := new(Pending_Mount, allocator)
	p.allocator = allocator
	return p
}

pending_mount_show :: proc(p: ^Pending_Mount, window: ^sdl3.Window) {
	if p == nil {return}
	sync.lock(&p.mu)
	if p.detached {
		sync.unlock(&p.mu)
		return
	}
	p.dialogs += 1
	sync.unlock(&p.mu)
	sdl3.ShowOpenFileDialog(mount_dialog_cb, p, window, nil, 0, nil, false)
}

mount_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	p := (^Pending_Mount)(userdata)
	if p == nil {return}
	sync.lock(&p.mu)
	if !p.detached && filelist != nil && filelist[0] != nil {
		delete(p.path, p.allocator)
		p.path = strings.clone(string(filelist[0]), p.allocator)
		p.has = true
	}
	if p.dialogs > 0 {p.dialogs -= 1}
	free_after := p.detached && p.dialogs == 0
	sync.unlock(&p.mu)
	if free_after {free(p, p.allocator)}
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

pending_mount_release :: proc(p: ^Pending_Mount) {
	if p == nil {return}
	sync.lock(&p.mu)
	p.detached = true
	delete(p.path, p.allocator)
	p.path = ""
	p.has = false
	free_now := p.dialogs == 0
	sync.unlock(&p.mu)
	if free_now {free(p, p.allocator)}
}

set_running :: proc(s: ^Shared, v: bool) {
	sync.lock(&s.mu)
	s.running = v
	sync.unlock(&s.mu)
}

push_cmd :: proc(s: ^Shared, cmd: Command) -> bool {
	sync.lock(&s.mu)
	if !s.running {
		sync.unlock(&s.mu)
		delete(cmd.path)
		return false
	}
	append(&s.cmds, cmd)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
	return true
}

command_queue_destroy :: proc(s: ^Shared) {
	if s == nil {return}
	sync.lock(&s.mu)
	for cmd in s.cmds {delete(cmd.path)}
	delete(s.cmds)
	s.cmds = nil
	sync.unlock(&s.mu)
}

push_host_key :: proc(
	s: ^Shared,
	keyboard: ^host.Host_Keyboard,
	scancode: sdl3.Scancode,
	down: bool,
) {
	sync.lock(&s.mu)
	_ = host.host_input_push_key(&s.input, keyboard, scancode, down, false)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

release_held_keys :: proc(s: ^Shared, keyboard: ^host.Host_Keyboard) {
	sync.lock(&s.mu)
	_ = host.host_input_release_held_keys(&s.input, keyboard)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_motion :: proc(s: ^Shared, dx, dy: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_motion(&s.input, dx, dy, buttons)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_buttons :: proc(s: ^Shared, buttons: u8, durable_release: bool = false) {
	sync.lock(&s.mu)
	_ = host.host_input_push_buttons(&s.input, buttons, durable_release)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_wheel :: proc(s: ^Shared, wheel: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_wheel(&s.input, wheel, buttons)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

// --- VM thread ---

vm_thread_proc :: proc(c: ^Vm_Ctx) {
	context.logger = log.create_console_logger(.Info, {.Level})
	s := c.shared
	m := new(machine.Machine)
	pause_state: host.Pause_State

	preparation_blocked := !install_state_boot_allowed(&c.install_state)
	launch_state_ready := !preparation_blocked && install_launch_prepare(c)
	machine_live := false
	if launch_state_ready {
		machine_live = vm_boot(c, m, !host.pause_active(&pause_state))
	}
	if preparation_blocked {
		message := "Windows 98: interrupted preparation is blocked; choose Install Windows 98 to retry"
		if !c.preparation_recovered {
			message = "Windows 98: interrupted preparation recovery is ambiguous; retained files were preserved"
		}
		publish_freeze(s, message, "")
	} else if !launch_state_ready {
		publish_freeze(
			s,
			"Windows 98: cannot record the direct Setup launch; fix install-state storage and Reset to retry",
			"",
		)
	} else if !machine_live {
		publish_freeze(s, "machine init failed (WHPX unavailable?)", "")
	} else {
		vm_log(s, cpu_mode_log(c.cpu_mode))
	}

	firmware: Firmware_Log
	firmware.live_stdout = c.firmware_log_all
	defer firmware_log_destroy(&firmware)
	stats: [hv.Exit_Kind]u64
	frozen := false
	if c.install_state.phase == .Preparing {
		if c.preparation_recovered {
			vm_log(
				s,
				"Windows 98: interrupted preparation recovered; select Install Windows 98 to retry",
			)
		} else {
			vm_log(
				s,
				"Windows 98: interrupted preparation retained because recovery was not provably safe",
			)
		}
	} else if c.install_state.phase == .Setup_Running {
		vm_log(
			s,
			fmt.tprintf(
				"Windows 98: resuming Setup session after %d guest reset(s)",
				c.install_state.reset_count,
			),
		)
	}
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
			if quit {
				delete(cmd.path)
				continue
			}
			switch cmd.kind {
			case .Reset:
				if machine_live {
					vm_shutdown(c, m)
					machine_live = false
				}
				stats = {}
				volume_ready := vm_ensure_volume(c)
				preparation_blocked = !install_state_boot_allowed(&c.install_state)
				state_ready :=
					!preparation_blocked &&
					(!profile.install_state_active(&c.install_state) ||
							install_state_save(c, "before manual reset"))
				launch_ready := state_ready && install_launch_prepare(c)
				if volume_ready && launch_ready {
					machine_live = vm_boot(c, m, !host.pause_active(&pause_state))
				}
				if machine_live {
					frozen = false
					publish_freeze(s, "", "")
					vm_log(
						s,
						fmt.tprintf("machine: reset (%s)", vmconfig.cpu_mode_name(c.cpu_mode)),
					)
				} else if preparation_blocked {
					frozen = true
					publish_freeze(
						s,
						"reset blocked: interrupted Windows 98 preparation must be retried or finished",
						"",
					)
				} else if !launch_ready {
					frozen = true
					publish_freeze(
						s,
						"reset blocked: Windows 98 install state or direct launch could not be persisted",
						"",
					)
				} else if !volume_ready {
					frozen = true
					publish_freeze(s, "reset failed: cannot reopen protected C:", "")
				} else {
					frozen = true
					publish_freeze(s, "reset failed: machine init error", "")
				}
			case .Power_Off:
				if !vm_close_then_shutdown(c, m, &machine_live) {
					frozen = true
					publish_freeze(
						s,
						"disk reconciliation failed; staged C: writes retained; retry Power Off",
						"",
					)
					continue
				}
				sync.lock(&s.mu)
				s.running = false
				sync.unlock(&s.mu)
				quit = true
			case .Mount_Floppy:
				if !machine_live {
					vm_log(s, "floppy: machine is not running; Reset before mounting media")
					delete(cmd.path)
					continue
				}
				if img, err := os.read_entire_file_from_path(cmd.path, context.allocator);
				   err == nil {
					if machine.machine_mount_floppy(m, img) {
						delete(c.floppy)
						c.floppy = img
						delete(c.floppy_path)
						c.floppy_path = strings.clone(cmd.path)
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
				if !machine_live {
					vm_log(s, "floppy: machine is not running; Reset before ejecting media")
					continue
				}
				machine.machine_eject_floppy(m)
				delete(c.floppy)
				c.floppy = nil
				delete(c.floppy_path)
				c.floppy_path = ""
				vm_log(s, "floppy: ejected")
			case .Mount_Cdrom:
				if !machine_live {
					vm_log(s, "CD-ROM: machine is not running; Reset before mounting media")
					delete(cmd.path)
					continue
				}
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
				if !machine_live {
					vm_log(s, "CD-ROM: machine is not running; Reset before ejecting media")
					continue
				}
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
				if !vm_close_then_shutdown(c, m, &machine_live) {
					publish_install_state(s, profile.install_state_active(&c.install_state))
					delete(cmd.path)
					frozen = true
					publish_freeze(
						s,
						"Windows 98: C: reconciliation failed before preparation; staged writes are retained",
						"",
					)
					continue
				}

				launch_ready := false
				rollback_failed := false
				state_restore_failed := false
				previous_state := install_state_clone(&c.install_state)
				previous_cdrom_path := strings.clone(c.cdrom_path)
				candidate := install_state_candidate(
					cmd.path,
					c.cmos[:],
					c.has_cmos,
					&c.install_state,
				)
				if install_state_save_value(c, &candidate, "before media preparation") {
					profile.install_state_destroy(&c.install_state)
					c.install_state = candidate
					candidate = {}
					delete(c.cdrom_path)
					c.cdrom_path = strings.clone(cmd.path)

					report := win98prep.prepare(
						cmd.path,
						c.paths.install,
						c.paths.c_drive,
						c.floppy_path,
					)
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
						c.install_state.phase = .Launch_Pending
						if install_state_save(c, "after media preparation") {
							if !win98prep.prepare_finish(&report) {
								vm_log(
									s,
									"Windows 98: prepared generation is active; obsolete backups could not be removed",
								)
							}
							launch_ready = true
							if c.floppy_path != "" {
								delete(c.floppy)
								c.floppy = nil
								delete(c.floppy_path)
								c.floppy_path = ""
								vm_log(
									s,
									"Windows 98: boot floppy seed consumed; direct HDD launch armed",
								)
							}
							if report.retry_cleanup.archived_count > 0 {
								vm_log(
									s,
									fmt.tprintf(
										"Windows 98: archived %d failed-Setup artifacts in %s",
										report.retry_cleanup.archived_count,
										report.retry_cleanup.archive_path,
									),
								)
							}
						} else {
							c.install_state.phase = .Preparing
							if !win98prep.prepare_rollback(&report) {
								rollback_failed = true
								vm_log(
									s,
									"Windows 98: preparation rollback failed; retained generations require manual recovery",
								)
							}
						}
					} else {
						if report.bootstrap_diagnostic == .Boot_Image_Required {
							vm_log(
								s,
								"Windows 98: mount a matching Windows 98 boot floppy before retrying a fresh installation",
							)
						}
						vm_log(
							s,
							fmt.tprintf(
								"Windows 98: preparation failed (%v, media %v, bootstrap %v, cleanup %v)",
								report.diagnostic,
								report.media_diagnostic,
								report.bootstrap_diagnostic,
								report.retry_cleanup.diagnostic,
							),
						)
						rollback_failed = install_preparation_rollback_failed(&report)
					}
					if !launch_ready && !rollback_failed {
						switch install_preparation_restore_previous(
							c,
							&previous_state,
							&previous_cdrom_path,
							&report,
						) {
						case .Restored:
							vm_log(
								s,
								"Windows 98: failed preparation rolled back; previous installation state restored",
							)
						case .Persistence_Failed:
							state_restore_failed = true
						case .Unsafe:
							rollback_failed = true
						}
					}
					win98prep.report_destroy(&report)
				} else {
					profile.install_state_destroy(&candidate)
				}
				profile.install_state_destroy(&previous_state)
				delete(previous_cdrom_path)
				publish_install_state(s, profile.install_state_active(&c.install_state))
				delete(cmd.path)
				if !vm_open_volume(c) {
					frozen = true
					publish_freeze(s, "Windows 98: cannot reopen C: after preparation", "")
					continue
				}
				if rollback_failed {
					frozen = true
					publish_freeze(
						s,
						"Windows 98: preparation rollback failed; retained generations require manual recovery",
						"",
					)
					continue
				}
				if state_restore_failed {
					frozen = true
					publish_freeze(
						s,
						"Windows 98: previous install state could not be restored; preparation recovery state retained",
						"",
					)
					continue
				}
				preparation_blocked = !install_state_boot_allowed(&c.install_state)
				if preparation_blocked {
					frozen = true
					publish_freeze(
						s,
						"Windows 98: interrupted preparation remains blocked; retry installation or finish the session",
						"",
					)
					continue
				}
				launch_state_ready = install_launch_prepare(c)
				if launch_state_ready {
					machine_live = vm_boot(c, m, !host.pause_active(&pause_state))
				}
				if machine_live {
					frozen = false
					publish_freeze(s, "", "")
					if launch_ready {
						vm_log(s, "Windows 98: booting the direct unattended Setup launcher")
					}
				} else if !launch_state_ready {
					frozen = true
					publish_freeze(
						s,
						"Windows 98: direct Setup launch state could not be persisted; Reset to retry",
						"",
					)
				} else {
					frozen = true
					publish_freeze(s, "Windows 98: reboot after preparation failed", "")
				}
			case .Finish_Windows_98_Installation:
				_ = install_session_finish(c, m)
			case .Set_Cpu_Mode:
				c.cpu_mode = cmd.cpu_mode
				if machine_live {machine.machine_set_cpu_mode(m, c.cpu_mode)}
				vm_log(s, cpu_mode_log(c.cpu_mode))
			case .Set_Pause:
				transition := host.pause_set(&pause_state, cmd.pause_reason, cmd.pause_active)
				if machine_live && transition != .Unchanged {
					machine.machine_clock_set_running(m, transition == .Resumed)
				}
				publish_pause_state(s, pause_state)
			}
		}
		delete(cmds)
		if quit {break loop}
		if machine_live && !frozen && !host.pause_active(&pause_state) {
			input_events: [HOST_INPUTS_PER_VM_STEP]host.Host_Input_Event
			sync.lock(&s.mu)
			input_count := host.host_input_drain(&s.input, input_events[:])
			sync.unlock(&s.mu)
			for event in input_events[:input_count] {
				switch event.kind {
				case .Key:
					for i in 0 ..< int(event.key_n) {machine.machine_key(m, event.key[i])}
				case .Mouse_Motion, .Mouse_Buttons:
					machine.machine_mouse(m, event.dx, event.dy, event.buttons)
				case .Mouse_Wheel:
					machine.machine_mouse_wheel(m, event.wheel, event.buttons)
				}
			}
		}

		if machine_live && !frozen && !host.pause_active(&pause_state) {
			alive := machine.step(m)
			stats[m.exit_hist[(m.exit_count - 1) % machine.EXIT_HISTORY]] += 1
			firmware_log_drain(&firmware, m, s)
			if vm_guard_failed(&c.guard) {
				frozen = true
				publish_freeze(s, "vCPU watchdog scheduling failed", "")
				continue loop
			}
			if !alive {
				if machine.machine_cpu_reset_pending(m) {
					reason := machine.machine_cpu_reset_reason(m)
					reset_code := m.cpu_reset_cmos_0f
					sync.lock(&c.guard.mu)
					c.guard.valid = false
					reset_ok := machine.machine_cpu_reset(m)
					c.guard.valid = reset_ok
					sync.unlock(&c.guard.mu)
					if reset_ok {
						vm_guard_rearm(&c.guard, machine.machine_next_wake_ns(m))
					}
					if reset_ok {
						frozen = false
						vm_log(
							s,
							fmt.tprintf(
								"machine: warm CPU reset (%s, CMOS 0F=%02x)",
								reason,
								reset_code,
							),
						)
					} else {
						frozen = true
						publish_freeze(s, m.bus.freeze_msg, "")
					}
				} else if machine.machine_reset_requested(m) {
					vm_shutdown(c, m)
					machine_live = false
					if profile.install_state_active(&c.install_state) {
						c.install_state.reset_count += 1
						if c.install_state.phase == .Setup_Running {
							_ = profile.install_state_advance_milestone(
								&c.install_state,
								.First_Reboot,
							)
						}
						if !install_state_save(c, "after guest reset") {
							frozen = true
							publish_freeze(
								s,
								"guest reset blocked: Windows 98 install state could not be persisted; Reset to retry",
								"",
							)
							continue loop
						}
					}
					stats = {}
					machine_live = vm_boot(c, m, !host.pause_active(&pause_state))
					if machine_live {
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
		if machine_live && time.tick_diff(last_snap, now) >= SNAP_PERIOD {
			last_snap = now
			snap := machine.machine_text_snapshot(m)
			if frame_mailbox_publish(&s.frames, m) {
				machine.machine_note_scanout_copy(m)
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
	firmware_log_host_flush(&firmware, s)
	if machine_live {vm_shutdown(c, m)}
	delete(c.floppy)
	delete(c.floppy_path)
	delete(c.cdrom_path)
	free(m)
}

vm_open_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || !c.attach {return c != nil}
	if vm_volume_ready(c) {return true}
	if c.volume != nil {return false}
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

vm_volume_ready :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil {return false}
	if !c.attach {return true}
	return(
		c.volume != nil &&
		!c.volume.frozen &&
		c.bd.ctx == rawptr(c.volume) &&
		c.bd.sector_count > 0 &&
		c.bd.read != nil &&
		c.bd.write != nil &&
		c.bd.flush != nil \
	)
}

vm_ensure_volume :: proc(c: ^Vm_Ctx) -> bool {
	if vm_volume_ready(c) {return true}
	return vm_open_volume(c)
}

vm_close_volume :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil || c.volume == nil {return true}
	if !fat32.volume_close(c.volume) {
		vm_log(c.shared, "disk: reconciliation failed; staged C: writes retained")
		return false
	}
	c.volume = nil
	c.bd = {}
	return true
}

vm_close_then_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine, machine_live: ^bool) -> bool {
	if c == nil {return false}
	if !vm_close_volume(c) {return false}
	if machine_live != nil && machine_live^ {
		vm_shutdown(c, m)
		machine_live^ = false
	}
	return true
}

vm_boot :: proc(c: ^Vm_Ctx, m: ^machine.Machine, clock_running: bool = true) -> bool {
	if c == nil ||
	   m == nil ||
	   !install_state_boot_allowed(&c.install_state) ||
	   !vm_volume_ready(c) {
		return false
	}
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	host.host_audio_close(&c.audio)
	m^ = {}
	if !machine.machine_init(m, RAM_SIZE) {return false}
	if !clock_running {machine.machine_clock_set_running(m, false)}
	frame_mailbox_reset(&c.shared.frames)
	if c.has_cmos {_ = machine.machine_cmos_import(m, c.cmos[:])}
	if profile.install_state_active(&c.install_state) {
		if !install_prepare_boot_cmos(c, m.cmos.ram[:]) {
			machine.machine_destroy(m)
			return false
		}
	}
	machine.machine_set_cpu_mode(m, c.cpu_mode)
	if !machine.load_roms(&m.vm) {
		machine.machine_destroy(m)
		return false
	}
	if c.attach {machine.machine_attach_disk(m, c.bd)}
	if c.floppy != nil {_ = machine.machine_mount_floppy(m, c.floppy)}
	if c.cdrom_path != "" {
		if machine.machine_attach_cdrom(m, c.cdrom_path) {
			publish_cdrom_state(c.shared, true)
		} else {
			publish_cdrom_state(c.shared, false)
			vm_log(c.shared, fmt.tprintf("CD-ROM: cannot reopen %s", c.cdrom_path))
		}
	}
	if c.audio_enabled && !host.host_audio_open(&c.audio, machine.machine_audio_output(m)) {
		vm_log(c.shared, fmt.tprintf("audio: SDL3 output unavailable (%s)", sdl3.GetError()))
	}
	c.guard.vm = &m.vm
	c.guard.valid = true
	machine.machine_set_wake_adapter(m, &c.guard, vm_guard_schedule)
	return true
}

vm_shutdown :: proc(c: ^Vm_Ctx, m: ^machine.Machine) {
	sync.lock(&c.guard.mu)
	defer sync.unlock(&c.guard.mu)
	c.guard.valid = false
	host.host_audio_close(&c.audio)
	if m == nil || m.vm.part == nil {return}
	saved_cmos := machine.machine_cmos_export(m)
	copy(c.cmos[:], saved_cmos[:])
	c.has_cmos = true
	if diag := profile.cmos_save(c.paths.cmos, c.cmos); diag != .None {
		vm_log(c.shared, fmt.tprintf("CMOS: save failed (%v)", diag))
	}
	machine.machine_destroy(m)
	c.guard.vm = nil
}

install_state_save :: proc(c: ^Vm_Ctx, reason: string) -> bool {
	return install_state_save_value(c, &c.install_state, reason)
}

install_state_save_value :: proc(
	c: ^Vm_Ctx,
	state: ^profile.Install_State,
	reason: string,
) -> bool {
	diagnostic := profile.install_state_save(c.paths.install_state, state)
	if diagnostic == .None {return true}
	vm_log(
		c.shared,
		fmt.tprintf("Windows 98: install state save failed %s (%v)", reason, diagnostic),
	)
	return false
}

Install_Preparation_State_Restore :: enum {
	Unsafe,
	Restored,
	Persistence_Failed,
}

install_state_clone :: proc(state: ^profile.Install_State) -> profile.Install_State {
	if state == nil {return {}}
	return profile.Install_State {
		phase = state.phase,
		milestone = state.milestone,
		source_path = strings.clone(state.source_path),
		reset_count = state.reset_count,
		saved_cmos_valid = state.saved_cmos_valid,
		saved_cmos_38 = state.saved_cmos_38,
		saved_cmos_3d = state.saved_cmos_3d,
	}
}

install_preparation_restore_previous :: proc(
	c: ^Vm_Ctx,
	previous: ^profile.Install_State,
	previous_cdrom_path: ^string,
	report: ^win98prep.Report,
) -> Install_Preparation_State_Restore {
	if c == nil || previous == nil || previous_cdrom_path == nil || report == nil {
		return .Unsafe
	}
	if report.diagnostic == .Rollback_Failed ||
	   (report.transaction.state != .Inactive && report.transaction.state != .Rolled_Back) {
		return .Unsafe
	}
	if !install_state_save_value(c, previous, "after failed media preparation") {
		if c.shared != nil {
			publish_freeze(
				c.shared,
				"Windows 98: previous install state could not be restored; preparation recovery state retained",
				"",
			)
		}
		return .Persistence_Failed
	}
	profile.install_state_destroy(&c.install_state)
	c.install_state = previous^
	previous^ = {}
	delete(c.cdrom_path)
	c.cdrom_path = previous_cdrom_path^
	previous_cdrom_path^ = ""
	return .Restored
}

install_state_candidate :: proc(
	source_path: string,
	cmos: []u8,
	cmos_valid: bool,
	previous: ^profile.Install_State,
) -> profile.Install_State {
	saved_cmos_38, saved_cmos_3d := u8(0), u8(0)
	saved_cmos_valid := cmos_valid && len(cmos) > 0x3D
	if saved_cmos_valid {
		saved_cmos_38 = cmos[0x38]
		saved_cmos_3d = cmos[0x3D]
	}
	if profile.install_state_active(previous) {
		saved_cmos_valid = previous.saved_cmos_valid
		saved_cmos_38 = previous.saved_cmos_38
		saved_cmos_3d = previous.saved_cmos_3d
	}
	return profile.Install_State {
		phase = .Preparing,
		source_path = strings.clone(source_path),
		saved_cmos_valid = saved_cmos_valid,
		saved_cmos_38 = saved_cmos_38,
		saved_cmos_3d = saved_cmos_3d,
	}
}

install_prepare_boot_cmos :: proc(c: ^Vm_Ctx, cmos: []u8) -> bool {
	if c == nil || len(cmos) <= 0x3D {return false}
	if !profile.install_state_active(&c.install_state) {return true}
	if !c.install_state.saved_cmos_valid {
		candidate := c.install_state
		candidate.saved_cmos_valid = true
		candidate.saved_cmos_38 = cmos[0x38]
		candidate.saved_cmos_3d = cmos[0x3D]
		if !install_state_save_value(c, &candidate, "before install boot override") {
			return false
		}
		c.install_state.saved_cmos_valid = true
		c.install_state.saved_cmos_38 = candidate.saved_cmos_38
		c.install_state.saved_cmos_3d = candidate.saved_cmos_3d
	}
	install_apply_boot_order(cmos)
	return true
}

install_preparation_rollback_failed :: proc(report: ^win98prep.Report) -> bool {
	return(
		report != nil &&
		(report.diagnostic == .Rollback_Failed || report.transaction.state == .Rollback_Failed) \
	)
}

install_launch_stage :: proc(
	state: ^profile.Install_State,
) -> (
	previous_phase: profile.Install_Phase,
	previous_milestone: profile.Install_Milestone,
	changed, ok: bool,
) {
	if state == nil {return {}, {}, false, false}
	previous_phase = state.phase
	previous_milestone = state.milestone
	if state.phase == .Preparing {return previous_phase, previous_milestone, false, false}
	if state.phase != .Launch_Pending {return previous_phase, previous_milestone, false, true}
	state.phase = .Setup_Running
	target := profile.Install_Milestone.DOS_Setup
	if state.reset_count > 0 {target = .First_Reboot}
	if !profile.install_state_advance_milestone(state, target) {
		state.phase = previous_phase
		state.milestone = previous_milestone
		return previous_phase, previous_milestone, false, false
	}
	return previous_phase, previous_milestone, true, true
}

install_launch_restore :: proc(
	state: ^profile.Install_State,
	phase: profile.Install_Phase,
	milestone: profile.Install_Milestone,
) {
	if state == nil {return}
	state.phase = phase
	state.milestone = milestone
}

install_launch_prepare :: proc(c: ^Vm_Ctx) -> bool {
	if c == nil {return false}
	phase, milestone, changed, ok := install_launch_stage(&c.install_state)
	if !ok {return false}
	if !changed {return true}
	if install_state_save(c, "before direct Setup launch") {return true}
	install_launch_restore(&c.install_state, phase, milestone)
	return false
}

install_session_finish :: proc(c: ^Vm_Ctx, m: ^machine.Machine) -> bool {
	if c == nil || m == nil || !profile.install_state_active(&c.install_state) {return false}

	live := vm_machine_live(c, m)
	restored_cmos: profile.Cmos_Data
	have_cmos := false
	if live {
		restored_cmos = machine.machine_cmos_export(m)
		have_cmos = true
	} else if c.has_cmos {
		restored_cmos = c.cmos
		have_cmos = true
	}
	restored_boot_order := have_cmos && c.install_state.saved_cmos_valid
	if restored_boot_order {
		restored_cmos[0x38] = c.install_state.saved_cmos_38
		restored_cmos[0x3D] = c.install_state.saved_cmos_3d
	}
	if have_cmos {
		if diagnostic := profile.cmos_save(c.paths.cmos, restored_cmos); diagnostic != .None {
			vm_log(
				c.shared,
				fmt.tprintf(
					"Windows 98: cannot finish installation session; CMOS save failed (%v)",
					diagnostic,
				),
			)
			return false
		}
	}
	if diagnostic := profile.install_state_save_inactive(c.paths.install_state);
	   diagnostic != .None {
		vm_log(
			c.shared,
			fmt.tprintf(
				"Windows 98: cannot finish installation session; install state save failed (%v)",
				diagnostic,
			),
		)
		return false
	}

	if have_cmos {
		copy(c.cmos[:], restored_cmos[:])
		c.has_cmos = true
	}
	if live {
		m.cmos.ram[0x38] = restored_cmos[0x38]
		m.cmos.ram[0x3D] = restored_cmos[0x3D]
	}
	profile.install_state_destroy(&c.install_state)
	publish_install_state(c.shared, false)
	if restored_boot_order {
		vm_log(c.shared, "Windows 98: installation session finished; original boot order restored")
	} else if have_cmos {
		vm_log(
			c.shared,
			"Windows 98: installation session finished; original boot order was unknown, current boot order retained",
		)
	} else {
		vm_log(
			c.shared,
			"Windows 98: installation session finished; no CMOS snapshot was available",
		)
	}
	return true
}

vm_machine_live :: proc(c: ^Vm_Ctx, m: ^machine.Machine) -> bool {
	if c == nil || m == nil {return false}
	sync.lock(&c.guard.mu)
	live := c.guard.valid && m.vm.part != nil
	sync.unlock(&c.guard.mu)
	return live
}

install_apply_boot_order :: proc(cmos: []u8) {
	if len(cmos) <= 0x3D {return}
	cmos[0x38] = (cmos[0x38] & 0x0F) | 0x10
	cmos[0x3D] = 0x32
}

publish_freeze :: proc(s: ^Shared, msg: string, regs: string) {
	sync.lock(&s.mu)
	s.frozen_msg = msg
	s.regs_text = regs
	sync.unlock(&s.mu)
}

publish_pause_state :: proc(s: ^Shared, state: host.Pause_State) {
	sync.lock(&s.mu)
	s.pause_state = state
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
	if len(s.log_lines) >= MAX_LOG_LINES {
		delete(s.log_lines[0])
		ordered_remove(&s.log_lines, 0)
	}
	append(&s.log_lines, owned)
	sync.unlock(&s.mu)
}

vm_log_destroy :: proc(s: ^Shared) {
	sync.lock(&s.mu)
	for line in s.log_lines {delete(line)}
	delete(s.log_lines)
	s.log_lines = nil
	sync.unlock(&s.mu)
}

cpu_mode_log :: proc(mode: vmconfig.Cpu_Mode) -> string {
	switch mode {
	case .GSW_886:
		return "cpu: GSW-886 (700 MHz TSC, K7-class throughput)"
	case .Turbo:
		return "cpu: Turbo (700 MHz TSC, unrestricted throughput)"
	}
	return "cpu: unknown mode"
}

// --- console harness (--console) ---

console_reinitialize_machine :: proc(
	m: ^machine.Machine,
	guard: ^Vm_Guard,
	vol: ^^fat32.Volume,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: []u8,
	attach: bool,
	cdrom_path: string,
	floppy: []u8,
	options: ^acceptance.Options,
) -> bool {
	if m == nil || guard == nil || vol == nil || paths == nil || options == nil {return false}
	reinitialized := false
	success := false
	defer if reinitialized && !success {machine.machine_destroy(m)}
	vm_guard_unbind(guard)
	machine.machine_destroy(m)
	if vol^ != nil {
		if !fat32.volume_close(vol^) {return false}
		vol^ = nil
	}
	m^ = {}
	if !machine.machine_init(m, RAM_SIZE) {return false}
	reinitialized = true
	if len(cmos) > 0 {_ = machine.machine_cmos_import(m, cmos)}
	if !machine.load_roms(&m.vm) {return false}
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	machine.bus_set_strict_io(&m.bus, options.strict_io)
	machine.machine_set_diagnostic_tracing(m, options.strict_io)
	if options.test_device {machine.machine_enable_test_device(m)}
	if attach {
		vol^ = fat32.volume_open(paths.c_drive, VOLUME_MB)
		if vol^ == nil {return false}
		vol^^.on_fail = proc(ctx: rawptr, msg: string) {
			fmt.printfln("disk: writes frozen: %s", msg)
		}
		machine.machine_attach_disk(m, fat32.volume_block_device(vol^))
	}
	if cdrom_path != "" && !machine.machine_attach_cdrom(m, cdrom_path) {return false}
	if len(floppy) > 0 && !machine.machine_mount_floppy(m, floppy) {return false}
	vm_guard_bind(guard, &m.vm)
	machine.machine_set_wake_adapter(m, guard, vm_guard_schedule)
	success = true
	return true
}

console_main :: proc(
	attach: bool,
	run_seconds: int,
	floppy_path: string,
	cdrom_path: string,
	paths: ^profile.Paths,
	settings: profile.Settings,
	cmos: profile.Cmos_Data,
	has_cmos: bool,
	frame_dump_path: string,
	options: acceptance.Options,
) -> (
	result: int,
) {
	run_options := options
	start := time.tick_now()
	run_result := acceptance.Result {
		stop_reason            = .Configuration_Error,
		exit_code              = 1,
		cpu_mode               = console_cpu_mode_name(settings.cpu_mode),
		installation_milestone = "none",
	}
	defer console_result_destroy(&run_result)
	firmware: Firmware_Log
	firmware.live_stdout =
		run_options.firmware_log_all || !acceptance.options_request_headless(&run_options)
	loaded_cmos := cmos
	install_state, install_diagnostic := profile.install_state_load(paths.install_state)
	defer profile.install_state_destroy(&install_state)
	if install_diagnostic != .None && install_diagnostic != .Missing {
		fmt.eprintfln("Windows 98: install state ignored (%v)", install_diagnostic)
	}
	interrupted, recovered := install_interrupted_preparation_recover(paths, &install_state)
	if interrupted {
		message := "interrupted Windows 98 preparation recovered; rerun --install-windows with media"
		if !recovered {
			message = "interrupted Windows 98 preparation recovery was not provably safe"
		}
		fmt.eprintln(message)
		return console_acceptance_configuration_error(
			&run_options,
			paths,
			settings.cpu_mode,
			message,
		)
	}
	if profile.install_state_active(&install_state) {install_apply_boot_order(loaded_cmos[:])}
	vol: ^fat32.Volume
	floppy_image: []u8
	defer delete(floppy_image)
	m := new(machine.Machine)
	if !machine.machine_init(m, RAM_SIZE) {
		fmt.eprintln("machine_init failed (WHPX unavailable?)")
		console_acceptance_finalize(
			&run_options,
			&run_result,
			m,
			nil,
			&firmware,
			paths,
			start,
			&result,
		)
		firmware_log_destroy(&firmware)
		free(m)
		return 1
	}
	machine_live := true
	defer {
		if machine_live {
			saved_cmos := machine.machine_cmos_export(m)
			stored: profile.Cmos_Data
			copy(stored[:], saved_cmos[:])
			if diag := profile.cmos_save(paths.cmos, stored); diag != .None {
				fmt.eprintfln("CMOS save failed: %v", diag)
			}
			machine.machine_destroy(m)
		}
		free(m)
	}
	defer firmware_log_destroy(&firmware)
	defer console_acceptance_finalize(
		&run_options,
		&run_result,
		m,
		&machine_live,
		&firmware,
		paths,
		start,
		&result,
	)
	defer {
		if vol != nil {
			closed := fat32.volume_close(vol)
			vol = nil
			if !closed {
				fmt.eprintln("disk: close failed; staged C: writes remain retained")
				result = 2
				run_result.stop_reason = .Fatal_Virtualization_Failure
				run_result.exit_code = result
			}
		}
	}
	defer {
		if frame_dump_path != "" && machine_live {
			console_dump_frame(frame_dump_path, machine.machine_display_frame(m))
		}
	}
	launch_phase, launch_milestone, launch_changed, launch_ok := install_launch_stage(
		&install_state,
	)
	if !launch_ok {
		fmt.eprintln("Windows 98: invalid pending Setup launch state")
		return 1
	}
	if launch_changed {
		if diagnostic := profile.install_state_save(paths.install_state, &install_state);
		   diagnostic != .None {
			install_launch_restore(&install_state, launch_phase, launch_milestone)
			fmt.eprintfln("Windows 98: cannot persist direct Setup launch state (%v)", diagnostic)
			return 1
		}
		fmt.println("Windows 98: direct unattended Setup launch armed")
	}
	if has_cmos {_ = machine.machine_cmos_import(m, loaded_cmos[:])}
	if !machine.load_roms(&m.vm) {
		fmt.eprintln("load_roms failed")
		return 1
	}
	machine.machine_set_cpu_mode(m, settings.cpu_mode)
	machine.bus_set_strict_io(&m.bus, options.strict_io)
	machine.machine_set_diagnostic_tracing(m, options.strict_io)
	if options.test_device {machine.machine_enable_test_device(m)}
	fmt.println(cpu_mode_log(settings.cpu_mode))
	if cdrom_path != "" {
		if !machine.machine_attach_cdrom(m, cdrom_path) {
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
			floppy_image = img
			if machine.machine_mount_floppy(m, floppy_image) {
				fmt.printfln("floppy: mounted %s", floppy_path)
			} else {
				fmt.eprintfln("floppy: %s is not a 1.44MB image", floppy_path)
				return 1
			}
		} else {
			fmt.eprintfln("floppy: cannot read %s", floppy_path)
			return 1
		}
	}

	// a guest that stops doing I/O never leaves WHvRunVirtualProcessor;
	// periodic cancels keep the clock and the time cap alive
	guard: Vm_Guard
	if !vm_guard_init(&guard) {
		fmt.eprintln("vCPU wake adapter initialization failed")
		return 1
	}
	defer vm_guard_destroy(&guard)
	vm_guard_bind(&guard, &m.vm)
	machine.machine_set_wake_adapter(m, &guard, vm_guard_schedule)

	last_vga := start
	prev: vga.Text_Snapshot
	shown := false
	last_frame_kind := vga.Display_Kind.Invalid
	last_frame_width, last_frame_height := 0, 0
	graphics_content_reported := false
	iterations := 0
	setup_log_names := []string{"SETUPLOG.TXT"}
	detection_log_names := []string{"DETLOG.TXT", "DETCRASH.LOG"}
	setup_log_baseline := console_log_total_size(paths.c_drive, setup_log_names)
	detection_log_baseline := console_log_total_size(paths.c_drive, detection_log_names)
	last_evidence_check := start
	post_reset_activity_generation: u64
	post_reset_frame_changes := 0
	hardware_detection_at: time.Tick
	hardware_detection_seen := false
	detection_activity := 0
	if install_state.milestone == .Hardware_Detection {
		hardware_detection_at = start
		hardware_detection_seen = true
	}
	stress_queue: host.Host_Input_Queue
	stress_next := start
	stress_phase: u64
	if options.accept_until == .Hardware_Detection &&
	   !profile.install_state_active(&install_state) {
		fmt.eprintln("acceptance: hardware detection requires an active Windows 98 installation")
		return 1
	}

	loop: for {
		if options.mouse_stress &&
		   time.tick_diff(stress_next, time.tick_now()) >= 4 * time.Millisecond {
			stress_phase += 1
			buttons := u8((stress_phase / 32) & 1)
			dx := stress_phase & 1 == 0 ? i32(7) : i32(-5)
			dy := stress_phase & 2 == 0 ? i32(3) : i32(-4)
			_ = host.host_input_push_motion(&stress_queue, dx, dy, buttons)
			if stress_phase % 32 == 0 {
				previous_buttons := u8(((stress_phase - 1) / 32) & 1)
				released := previous_buttons & ~buttons != 0
				_ = host.host_input_push_buttons(&stress_queue, buttons, released)
			}
			if stress_phase % 64 == 0 {_ = host.host_input_push_wheel(&stress_queue, 1, buttons)}
			if stress_phase % 128 == 0 {
				make := host.Host_Input_Event {
					kind  = .Key,
					key_n = 1,
				}
				make.key[0] = 0x1e
				brk := host.Host_Input_Event {
					kind  = .Key,
					key_n = 1,
				}
				brk.key[0] = 0x9e
				_ = host.host_input_push(&stress_queue, make)
				_ = host.host_input_push(&stress_queue, brk)
			}
			stress_events: [64]host.Host_Input_Event
			stress_count := host.host_input_drain(&stress_queue, stress_events[:])
			for event in stress_events[:stress_count] {
				switch event.kind {
				case .Mouse_Motion, .Mouse_Buttons:
					machine.machine_mouse(m, event.dx, event.dy, event.buttons)
				case .Mouse_Wheel:
					machine.machine_mouse_wheel(m, event.wheel, event.buttons)
				case .Key:
					for i in 0 ..< int(event.key_n) {machine.machine_key(m, event.key[i])}
				}
			}
			stress_next = time.tick_now()
		}
		alive := machine.step(m)
		iterations += 1
		firmware_log_drain(&firmware, m, nil)
		now := time.tick_now()
		if vm_guard_failed(&guard) {
			fmt.eprintln("vCPU watchdog scheduling failed")
			run_result.stop_reason = .Fatal_Virtualization_Failure
			result = 2
			run_result.exit_code = result
			break loop
		}
		switch command := machine.machine_test_device_take_command(m); command {
		case .Crc:
			_ = machine.machine_test_device_frame_crc(m)
		case .Snapshot:
			if options.artifacts != "" {
				frame := machine.machine_display_frame(m)
				_ = acceptance.artifact_write_bundle(
					options.artifacts,
					"guest-requested snapshot\n",
					frame.pixels,
					frame.width,
					frame.height,
				)
			}
		case .Exit:
			run_result.stop_reason = .Test_Exit
			run_result.test_exit_code = machine.machine_test_device_exit_code(m)
			result = run_result.test_exit_code == 0 ? 0 : 2
			run_result.exit_code = result
			break loop
		case .None:
		}
		if !alive {
			if machine.machine_cpu_reset_pending(m) {
				reason := strings.clone(machine.machine_cpu_reset_reason(m))
				reset_code := m.cpu_reset_cmos_0f
				sync.lock(&guard.mu)
				guard.valid = false
				reset_ok := machine.machine_cpu_reset(m)
				guard.valid = reset_ok
				sync.unlock(&guard.mu)
				if reset_ok {vm_guard_rearm(&guard, machine.machine_next_wake_ns(m))}
				if !reset_ok {
					firmware_log_host_flush(&firmware, nil)
					fmt.printfln("CPU reset failed: %s", m.bus.freeze_msg)
					dump_state(m)
					run_result.stop_reason = .Fatal_Virtualization_Failure
					result = 2
					run_result.exit_code = result
					delete(reason)
					break loop
				}
				console_result_record_reset(&run_result, reason)
				firmware_log_host_flush(&firmware, nil)
				fmt.printfln(
					"warm CPU reset %d after %d iterations: %s, CMOS 0F=%02x",
					m.cpu_reset_count,
					iterations,
					reason,
					reset_code,
				)
				delete(reason)
				free_all(context.temp_allocator)
				continue
			} else if machine.machine_reset_requested(m) {
				reset_message := strings.clone(m.bus.freeze_msg)
				firmware_log_host_flush(&firmware, nil)
				fmt.printfln(
					"guest reset requested after %d iterations: %s",
					iterations,
					m.bus.freeze_msg,
				)
				console_result_record_reset(&run_result, reset_message)
				delete(reset_message)
				if !profile.install_state_active(&install_state) {
					run_result.stop_reason = .Reset
					run_result.exit_code = 0
					break loop
				}
				console_result_accumulate_machine(&run_result, m)
				reboot_cmos := machine.machine_cmos_export(m)
				install_state.reset_count += 1
				if install_state.phase == .Setup_Running {
					_ = profile.install_state_advance_milestone(&install_state, .First_Reboot)
				}
				if diagnostic := profile.install_state_save(paths.install_state, &install_state);
				   diagnostic != .None {
					fmt.eprintfln("Windows 98: cannot persist first-reboot state (%v)", diagnostic)
					run_result.stop_reason = .Configuration_Error
					result = 2
					run_result.exit_code = result
					break loop
				}
				install_apply_boot_order(reboot_cmos[:])
				machine_live = false
				if !console_reinitialize_machine(
					m,
					&guard,
					&vol,
					paths,
					settings,
					reboot_cmos[:],
					attach,
					cdrom_path,
					floppy_image,
					&run_options,
				) {
					fmt.eprintln("Windows 98: machine reinitialization failed after guest reset")
					run_result.stop_reason = .Fatal_Virtualization_Failure
					result = 2
					run_result.exit_code = result
					break loop
				}
				machine_live = true
				last_vga = time.tick_now()
				post_reset_activity_generation = 0
				post_reset_frame_changes = 0
				free_all(context.temp_allocator)
				continue
			}
			firmware_log_host_flush(&firmware, nil)
			fmt.printfln("VM frozen after %d iterations: %s", iterations, m.bus.freeze_msg)
			dump_state(m)
			print_grid(machine.machine_text_snapshot(m))
			if options.strict_io &&
			   (strings.has_prefix(m.bus.freeze_msg, "unclassified port") ||
					   strings.has_prefix(m.bus.freeze_msg, "unclassified MMIO")) {
				run_result.stop_reason = .Strict_IO_Failure
			} else {
				run_result.stop_reason = .Fatal_Virtualization_Failure
			}
			result = 2
			run_result.exit_code = result
			break loop
		}
		if time.tick_diff(last_vga, now) >= VGA_PERIOD {
			last_vga = now
			snap := machine.machine_text_snapshot(m)
			frame := machine.machine_display_frame(m)
			if install_state.reset_count > 0 && frame.kind != .Invalid {
				if console_acceptance_observe_display_activity(
					&post_reset_activity_generation,
					frame,
				) {
					post_reset_frame_changes += 1
					if hardware_detection_seen {detection_activity += 1}
				}
			}
			if frame.kind != last_frame_kind ||
			   frame.width != last_frame_width ||
			   frame.height != last_frame_height {
				last_frame_kind = frame.kind
				last_frame_width = frame.width
				last_frame_height = frame.height
				graphics_content_reported = false
				fmt.printfln(
					"display: %v %dx%d generation=%d",
					frame.kind,
					frame.width,
					frame.height,
					frame.generation,
				)
			}
			if frame.kind != .Invalid && frame.kind != .Text && !graphics_content_reported {
				for pixel in frame.pixels {
					if pixel != 0xFF000000 {
						graphics_content_reported = true
						fmt.printfln(
							"display: nonblack graphics content at generation=%d",
							frame.generation,
						)
						break
					}
				}
			}
			if !shown || snap.cells != prev.cells {
				prev = snap
				shown = true
				fmt.printfln("[%.0fs]", time.duration_seconds(time.tick_diff(start, now)))
				print_grid(snap)
			}
		}
		if profile.install_state_active(&install_state) &&
		   install_state.reset_count > 0 &&
		   time.tick_diff(last_evidence_check, now) >= time.Second {
			last_evidence_check = now
			if vol != nil && !fat32.volume_flush(vol) {
				fmt.eprintln("Windows 98: C: reconciliation failed while observing Setup")
				run_result.stop_reason = .Fatal_Virtualization_Failure
				result = 2
				run_result.exit_code = result
				break loop
			}
			setup_size := console_log_total_size(paths.c_drive, setup_log_names)
			detection_size := console_log_total_size(paths.c_drive, detection_log_names)
			logs_changed :=
				setup_size > 0 &&
				detection_size > 0 &&
				setup_size != setup_log_baseline &&
				detection_size != detection_log_baseline
			if !hardware_detection_seen && logs_changed && post_reset_frame_changes >= 2 {
				if profile.install_state_advance_milestone(&install_state, .Hardware_Detection) &&
				   profile.install_state_save(paths.install_state, &install_state) == .None {
					hardware_detection_seen = true
					hardware_detection_at = now
					detection_activity = 0
					fmt.println("Windows 98: hardware-detection milestone reached")
				}
			}
		}
		if options.accept_until == .Hardware_Detection &&
		   hardware_detection_seen &&
		   detection_activity > 0 &&
		   time.tick_diff(hardware_detection_at, now) >= HARDWARE_DETECTION_STABLE_TIME {
			run_result.stop_reason = .Acceptance_Reached
			run_result.exit_code = 0
			result = 0
			fmt.println("Windows 98: hardware detection remained active for 60 seconds")
			break loop
		}
		if time.tick_diff(start, now) >= time.Duration(run_seconds) * time.Second {
			firmware_log_host_flush(&firmware, nil)
			fmt.printfln(
				"time cap (%ds) reached after %d iterations, exiting",
				run_seconds,
				iterations,
			)
			dump_state(m)
			print_grid(machine.machine_text_snapshot(m))
			run_result.stop_reason = .Timeout
			result = acceptance.options_request_headless(&run_options) ? 2 : 0
			run_result.exit_code = result
			break loop
		}
		free_all(context.temp_allocator)
	}
	return result
}

@(private)
console_dump_frame :: proc(path: string, frame: ^vga.Display_Frame) {
	if frame == nil || frame.width <= 0 || frame.height <= 0 || len(frame.pixels) == 0 {
		return
	}
	header := fmt.tprintf("P6\n%d %d\n255\n", frame.width, frame.height)
	data := make([]u8, len(header) + frame.width * frame.height * 3, context.temp_allocator)
	copy(data, header)
	offset := len(header)
	for pixel in frame.pixels[:frame.width * frame.height] {
		data[offset] = u8(pixel >> 16)
		data[offset + 1] = u8(pixel >> 8)
		data[offset + 2] = u8(pixel)
		offset += 3
	}
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("frame dump failed: %v", err)
	}
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
