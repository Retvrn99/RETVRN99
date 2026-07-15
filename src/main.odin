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
	if acceptance_options.accept_until == .Desktop && !seconds_explicit {
		run_seconds = 2 * 60 * 60
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
					acceptance_options.setup_diagnostics,
					acceptance_options.accept_until == .Desktop,
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
	guard_storage_retained := false
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
		if !guard_storage_retained {free(ctx)}
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
		if !vm_guard_destroy(&ctx.guard) {
			guard_storage_retained = true
			fmt.eprintln("vCPU wake adapter teardown failed; callback storage retained")
			if result == 0 {result = 1}
		}
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
		vm_log(s, cpu_mode_log(install_runtime_cpu_mode(c.cpu_mode, &c.install_state)))
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
				preparation_blocked = !install_state_boot_allowed(&c.install_state)
				state_ready :=
					!preparation_blocked &&
					(!profile.install_state_active(&c.install_state) ||
							install_state_save(c, "before manual reset"))
				launch_ready := state_ready && install_launch_prepare(c)
				reset_diagnostic := Vm_Reinitialize_Diagnostic.None
				if launch_ready {
					reset_diagnostic = vm_reinitialize_machine(
						c,
						m,
						&machine_live,
						!host.pause_active(&pause_state),
					)
				}
				if launch_ready && reset_diagnostic == .None && machine_live {
					stats = {}
					frozen = false
					publish_freeze(s, "", "")
					vm_log(
						s,
						fmt.tprintf(
							"machine: reset (%s)",
							vmconfig.cpu_mode_name(
								install_runtime_cpu_mode(c.cpu_mode, &c.install_state),
							),
						),
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
				} else if reset_diagnostic == .Reconciliation_Failed {
					frozen = true
					publish_freeze(
						s,
						"reset blocked: disk reconciliation failed; staged C: writes retained; retry Reset or Power Off",
						"",
					)
				} else if reset_diagnostic == .Volume_Open_Failed {
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
				runtime_mode := install_runtime_cpu_mode(c.cpu_mode, &c.install_state)
				if machine_live {machine.machine_set_cpu_mode(m, runtime_mode)}
				vm_log(s, cpu_mode_log(runtime_mode))
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
			vm_guard_flush_wake_evidence(&c.guard, m)
			stats[m.exit_hist[(m.exit_count - 1) % machine.EXIT_HISTORY]] += 1
			firmware_log_drain(&firmware, m, s)
			if vm_guard_failed(&c.guard) {
				frozen = true
				publish_freeze(s, "vCPU watchdog scheduling failed", "")
				continue loop
			}
			if !alive {
				if machine.machine_power_off_requested(m) {
					power_reason := machine.machine_power_off_reason(m)
					if vm_close_then_shutdown(c, m, &machine_live) {
						vm_log(s, fmt.tprintf("machine: %s", power_reason))
						sync.lock(&s.mu)
						s.running = false
						sync.unlock(&s.mu)
						break loop
					}
					frozen = true
					publish_freeze(
						s,
						"APM power off blocked: disk reconciliation failed; staged writes retained",
						"",
					)
				} else if machine.machine_cpu_reset_pending(m) {
					reason := machine.machine_cpu_reset_reason(m)
					reset_code := m.cpu_reset_cmos_0f
					sync.lock(&c.guard.mu)
					c.guard.valid = false
					reset_ok := machine.machine_cpu_reset(m)
					c.guard.valid = reset_ok
					sync.unlock(&c.guard.mu)
					if reset_ok {
						machine.machine_rearm_wake(m)
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
					reset_reason := strings.clone(machine.machine_reset_reason(m))
					reset_transaction, reset_state_ready := install_reset_transaction_stage(
						&c.install_state,
					)
					if !reset_state_ready {
						frozen = true
						publish_freeze(
							s,
							"guest reset blocked: invalid Windows 98 install state",
							"",
						)
						delete(reset_reason)
						continue loop
					}
					if reset_transaction.state_changed {
						if !install_state_save(c, "after guest reset") {
							install_reset_transaction_restore(&c.install_state, &reset_transaction)
							frozen = true
							publish_freeze(
								s,
								"guest reset blocked: Windows 98 install state could not be persisted; Reset to retry",
								"",
							)
							delete(reset_reason)
							continue loop
						}
					}
					reset_diagnostic := vm_reinitialize_machine(
						c,
						m,
						&machine_live,
						!host.pause_active(&pause_state),
						reset_transaction.state_changed,
					)
					rollback_diagnostic := profile.Install_State_Diagnostic.None
					if reset_diagnostic != .None || !machine_live {
						rollback_diagnostic = install_reset_transaction_rollback(
							c.paths.install_state,
							&c.install_state,
							&reset_transaction,
						)
					}
					if reset_diagnostic == .None && machine_live {
						_ = install_reset_transaction_commit(&reset_transaction)
						stats = {}
						frozen = false
						publish_freeze(s, "", "")
						vm_log(s, fmt.tprintf("machine: reset (%s)", reset_reason))
					} else if rollback_diagnostic != .None {
						frozen = true
						publish_freeze(s, "guest reset failed: install state rollback failed", "")
					} else if reset_diagnostic == .Reconciliation_Failed {
						frozen = true
						publish_freeze(
							s,
							"guest reset blocked: disk reconciliation failed; staged C: writes retained; retry Reset or Power Off",
							"",
						)
					} else if reset_diagnostic == .Install_Cleanup_Failed {
						frozen = true
						publish_freeze(
							s,
							"guest reset blocked: Windows failed-boot sentinel could not be cleared",
							"",
						)
					} else if reset_diagnostic == .Volume_Open_Failed {
						frozen = true
						publish_freeze(s, "guest reset failed: cannot reopen protected C:", "")
					} else {
						frozen = true
						publish_freeze(s, "guest reset failed: machine init error", "")
					}
					delete(reset_reason)
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
	machine.machine_destroy(m)
	delete(c.floppy)
	delete(c.floppy_path)
	delete(c.cdrom_path)
	free(m)
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

install_apply_initial_boot_order :: proc(
	machine_cmos, loaded_cmos: []u8,
	has_cmos: bool,
	state: ^profile.Install_State,
) {
	if !profile.install_state_active(state) {return}
	install_apply_boot_order(has_cmos ? loaded_cmos : machine_cmos)
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
		boot_epoch             = 1,
		last_progress_reason   = "machine_start",
	}
	defer console_result_destroy(&run_result)
	firmware: Firmware_Log
	firmware.live_stdout =
		run_options.firmware_log_all || !acceptance.options_request_headless(&run_options)
	loaded_cmos := cmos
	install_state, install_diagnostic := profile.install_state_load(paths.install_state)
	defer profile.install_state_destroy(&install_state)
	runtime_cpu_mode := install_runtime_cpu_mode(settings.cpu_mode, &install_state)
	runtime_settings := settings
	runtime_settings.cpu_mode = runtime_cpu_mode
	run_result.cpu_mode = console_cpu_mode_name(runtime_cpu_mode)
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
			runtime_cpu_mode,
			message,
		)
	}
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
	machine_segment_accumulated := false
	defer console_acceptance_finalize(
		&run_options,
		&run_result,
		m,
		&machine_live,
		&firmware,
		paths,
		start,
		&result,
		&machine_segment_accumulated,
	)
	defer {
		if vol != nil {
			if machine_live {_ = machine.machine_detach_disk(m)}
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
	input_script: acceptance.Input_Script
	defer acceptance.input_script_destroy(&input_script)
	if run_options.input_script != "" {
		input_diagnostic: acceptance.Input_Script_Diagnostic
		input_script, input_diagnostic = acceptance.input_script_load(run_options.input_script)
		if input_diagnostic != .None {
			fmt.eprintfln("input script error: %v", input_diagnostic)
			run_result.stop_reason = .Configuration_Error
			run_result.exit_code = 1
			result = 1
			return
		}
		fmt.printfln("input script: loaded %d actions", len(input_script.actions))
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
	install_apply_initial_boot_order(m.cmos.ram[:], loaded_cmos[:], has_cmos, &install_state)
	if has_cmos {_ = machine.machine_cmos_import(m, loaded_cmos[:])}
	if !machine.load_roms(&m.vm) {
		fmt.eprintln("load_roms failed")
		return 1
	}
	machine.machine_set_cpu_mode(m, runtime_cpu_mode)
	machine.bus_set_strict_io(&m.bus, options.strict_io)
	machine.machine_set_diagnostic_tracing(m, options.strict_io)
	machine.machine_set_bus_diagnostic_tracing(
		m,
		options.setup_diagnostics == .Hardware,
	)
	if !machine.machine_set_hardware_trace(m, true) {
		fmt.eprintln("hardware flight recorder allocation failed")
		return 1
	}
	if options.test_device {machine.machine_enable_test_device(m)}
	fmt.println(cpu_mode_log(runtime_cpu_mode))
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
	guard := new(Vm_Guard)
	if !vm_guard_init(guard) {
		free(guard)
		fmt.eprintln("vCPU wake adapter initialization failed")
		return 1
	}
	defer {
		if vm_guard_destroy(guard) {
			free(guard)
		} else {
			fmt.eprintln("vCPU wake adapter teardown failed; callback storage retained")
			if run_result.exit_code == 0 {
				run_result.stop_reason = .Fatal_Virtualization_Failure
				run_result.last_progress_reason = "wake_guard_teardown_failed"
			}
			run_result.exit_code = 2
			result = 2
		}
	}
	defer {
		quiesced := vm_guard_quiesce(guard)
		vm_guard_flush_wake_evidence(guard, m)
		stats := vm_guard_stats(guard)
		run_result.wake_guard.generations = stats.generation
		run_result.wake_guard.callbacks = stats.callbacks
		run_result.wake_guard.retry_callbacks = stats.retry_callbacks
		run_result.wake_guard.cancel_calls = stats.cancel_calls
		run_result.wake_guard.stale_callbacks = stats.stale_callbacks
		run_result.wake_guard.evidence_dropped = stats.evidence_dropped
		if !quiesced {
			fmt.eprintln("vCPU wake adapter quiesce failed")
			if run_result.exit_code == 0 {
				run_result.stop_reason = .Fatal_Virtualization_Failure
				run_result.last_progress_reason = "wake_guard_teardown_failed"
			}
			run_result.exit_code = 2
			result = 2
		}
	}
	vm_guard_bind(guard, &m.vm)
	machine.machine_set_wake_adapter(m, guard, vm_guard_schedule)

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
	last_setup_artifact_check := start
	setup_artifact_reset_count: u32
	last_progress_check := start
	progress_watchdog: Console_Progress_Watchdog
	last_display_activity_generation: u64
	post_reset_activity_generation: u64
	post_reset_frame_changes := 0
	hardware_detection_at: time.Tick
	hardware_detection_seen := false
	detection_activity := 0
	desktop_marker_seen := false
	desktop_graphics: Console_Desktop_Graphics_Stability
	primary_dma_epoch_baseline_transactions: u64
	primary_dma_epoch_baseline_bytes: u64
	if install_state.milestone == .Hardware_Detection {
		hardware_detection_at = start
		hardware_detection_seen = true
	}
	stress_queue: host.Host_Input_Queue
	stress_next := start
	stress_phase: u64
	input_phase_start := start
	input_reset_count: u32
	input_actions: [32]acceptance.Input_Action
	input_frame_next := start
	input_visual_cursor := -1
	input_visual_reset: u32
	input_visual_sampled := false
	input_visual_baseline: u64
	input_visual_last: u64
	input_visual_since := start
	input_visual_changed := false
	input_memory_next := start
	if options.accept_until != .None && !profile.install_state_active(&install_state) {
		fmt.eprintln(
			"acceptance: Windows setup milestone requires an active Windows 98 installation",
		)
		return 1
	}

	loop: for {
		input_now := time.tick_now()
		input_phase_ms := i64(time.tick_diff(input_phase_start, input_now) / time.Millisecond)
		input_frame_crc: u32
		input_visual_ready := false
		input_memory_ready := false
		if time.tick_diff(input_memory_next, input_now) >= 0 {
			input_memory_ready = acceptance.input_script_memory_matches(
				&input_script,
				input_reset_count,
				input_phase_ms,
				m.vm.ram,
			)
			input_memory_next = time.tick_add(input_now, 100 * time.Millisecond)
		}
		visual_stable_ms, visual_require_change, visual_due := acceptance.input_script_visual_due(
			&input_script,
			input_reset_count,
			input_phase_ms,
		)
		if (acceptance.input_script_frame_due(&input_script, input_reset_count, input_phase_ms) ||
			   visual_due) &&
		   time.tick_diff(input_frame_next, input_now) >= 0 {
			frame := machine.machine_display_frame(m)
			if acceptance.input_script_frame_due(
				&input_script,
				input_reset_count,
				input_phase_ms,
			) {
				input_frame_crc = acceptance.frame_crc32(frame.pixels, frame.width, frame.height)
			}
			input_frame_next = time.tick_add(input_now, 100 * time.Millisecond)
			if visual_due {
				visual_hash := acceptance.frame_visual_hash(
					frame.pixels,
					frame.width,
					frame.height,
				)
				if input_visual_cursor != input_script.cursor ||
				   input_visual_reset != input_reset_count ||
				   !input_visual_sampled {
					previous_hash := input_visual_last
					previous_valid :=
						input_visual_sampled && input_visual_reset == input_reset_count
					input_visual_cursor = input_script.cursor
					input_visual_reset = input_reset_count
					input_visual_sampled = true
					input_visual_baseline = previous_valid ? previous_hash : visual_hash
					input_visual_last = visual_hash
					input_visual_since = input_now
					input_visual_changed =
						!visual_require_change || (previous_valid && visual_hash != previous_hash)
				} else if visual_hash != input_visual_last {
					input_visual_last = visual_hash
					input_visual_since = input_now
					if visual_hash != input_visual_baseline {input_visual_changed = true}
				} else if input_visual_changed &&
				   time.tick_diff(input_visual_since, input_now) >=
					   time.Duration(visual_stable_ms) * time.Millisecond {
					input_visual_ready = true
				}
			}
		}
		input_count := acceptance.input_script_drain(
			&input_script,
			input_reset_count,
			input_phase_ms,
			input_frame_crc,
			input_visual_ready,
			input_memory_ready,
			input_actions[:],
		)
		for action in input_actions[:input_count] {
			console_input_apply(m, action, input_reset_count, input_phase_ms)
		}
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
		vm_guard_flush_wake_evidence(guard, m)
		iterations += 1
		firmware_log_drain(&firmware, m, nil)
		now := time.tick_now()
		if vm_guard_failed(guard) {
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
			result = console_terminal_exit_code(
				options.accept_until,
				run_result.test_exit_code == 0,
			)
			run_result.exit_code = result
			break loop
		case .None:
		}
		if !alive {
			if machine.machine_power_off_requested(m) {
				fmt.printfln("machine: %s", machine.machine_power_off_reason(m))
				run_result.stop_reason = .Power_Off
				run_result.last_progress_reason = "apm_power_off"
				result = console_terminal_exit_code(options.accept_until, true)
				run_result.exit_code = result
				break loop
			} else if machine.machine_cpu_reset_pending(m) {
				reason := strings.clone(machine.machine_cpu_reset_reason(m))
				reset_code := m.cpu_reset_cmos_0f
				sync.lock(&guard.mu)
				guard.valid = false
				reset_ok := machine.machine_cpu_reset(m)
				guard.valid = reset_ok
				sync.unlock(&guard.mu)
				if reset_ok {machine.machine_rearm_wake(m)}
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
				run_result.last_progress_reason = "warm_reset"
				firmware_log_host_flush(&firmware, nil)
				fmt.printfln(
					"warm CPU reset %d after %d iterations: %s, CMOS 0F=%02x",
					m.cpu_reset_count,
					iterations,
					reason,
					reset_code,
				)
				delete(reason)
				input_reset_count += 1
				input_phase_start = time.tick_now()
				free_all(context.temp_allocator)
				continue
			} else if machine.machine_reset_requested(m) {
				reset_message := strings.clone(machine.machine_reset_reason(m))
				firmware_log_host_flush(&firmware, nil)
				fmt.printfln(
					"guest reset requested after %d iterations: %s",
					iterations,
					reset_message,
				)
				console_result_record_reset_request(&run_result, reset_message)
				run_result.last_progress_reason = "guest_reset"
				delete(reset_message)
				_ = console_result_accumulate_machine_segment(
					&run_result,
					m,
					&machine_segment_accumulated,
				)
				reboot_cmos := machine.machine_cmos_export(m)
				reset_transaction, reset_state_ready := install_reset_transaction_stage(
					&install_state,
				)
				if !reset_state_ready {
					fmt.eprintln("Windows 98: guest reset encountered invalid install state")
					run_result.stop_reason = .Configuration_Error
					result = 2
					run_result.exit_code = result
					break loop
				}
				if reset_transaction.state_changed {
					if diagnostic := profile.install_state_save(
						paths.install_state,
						&install_state,
					); diagnostic != .None {
						install_reset_transaction_restore(&install_state, &reset_transaction)
						fmt.eprintfln(
							"Windows 98: cannot persist first-reboot state (%v)",
							diagnostic,
						)
						run_result.stop_reason = .Configuration_Error
						result = 2
						run_result.exit_code = result
						break loop
					}
					install_apply_boot_order(reboot_cmos[:])
				}
				if !console_reinitialize_machine(
					m,
					guard,
					&machine_live,
					&vol,
					paths,
					runtime_settings,
					reboot_cmos[:],
					attach,
					cdrom_path,
					floppy_image,
					&run_options,
					reset_transaction.state_changed,
				) {
					rollback_diagnostic := install_reset_transaction_rollback(
						paths.install_state,
						&install_state,
						&reset_transaction,
					)
					if rollback_diagnostic != .None {
						fmt.eprintfln(
							"Windows 98: cannot roll back failed guest reset state (%v)",
							rollback_diagnostic,
						)
					}
					if machine_live {
						fmt.eprintln(
							"machine reset blocked: disk reconciliation failed; staged writes retained",
						)
					} else {
						fmt.eprintln("machine reinitialization failed after guest reset")
					}
					run_result.stop_reason = .Fatal_Virtualization_Failure
					result = 2
					run_result.exit_code = result
					break loop
				}
				machine_segment_accumulated = false
				if install_reset_transaction_commit(&reset_transaction) {
					console_result_record_reset_success(&run_result, &desktop_graphics)
					primary_dma_epoch_baseline_transactions =
						run_result.execution.primary_ide_dma_transactions
					primary_dma_epoch_baseline_bytes = run_result.execution.primary_ide_dma_bytes
					if options.accept_until == .Desktop {
						desktop_marker_seen = false
						run_result.desktop_marker_seen = false
						run_result.desktop_enum_valid = false
						run_result.desktop_vga_irq11_seen = false
					}
				}
				input_reset_count += 1
				input_phase_start = time.tick_now()
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
			last_display_activity_generation = frame.guest_activity_generation
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
			if !graphics_content_reported && console_frame_is_nonblack_graphics(frame) {
				graphics_content_reported = true
				fmt.printfln(
					"display: nonblack graphics coverage at generation=%d",
					frame.generation,
				)
			}
			if desktop_marker_seen {
				if console_desktop_graphics_observe(&desktop_graphics, frame, now) {
					fmt.println("Windows 98: desktop marker has continuous graphical output")
				}
			}
			if !shown || snap.cells != prev.cells {
				prev = snap
				shown = true
				fmt.printfln("[%.0fs]", time.duration_seconds(time.tick_diff(start, now)))
				print_grid(snap)
			}
		}
		detection_pending :=
			profile.install_state_active(&install_state) &&
			install_state.reset_count > 0 &&
			!hardware_detection_seen
		desktop_pending :=
			options.accept_until == .Desktop &&
			install_state.reset_count > 0 &&
			!desktop_marker_seen
		if console_setup_artifact_poll_due(
			install_state.reset_count,
			detection_pending,
			desktop_pending,
			&setup_artifact_reset_count,
			&last_setup_artifact_check,
			now,
		) {
			reconciled := vol == nil
			if vol != nil {
				stats := fat32.volume_journal_storage_stats(vol)
				reconciled = !vol.frozen && (stats.dirty_sectors == 0 || fat32.volume_flush(vol))
			}
			last_setup_artifact_check = time.tick_now()
			if !reconciled && vol.frozen {
				fmt.eprintln("Windows 98: C: reconciliation failed while observing Setup")
				run_result.stop_reason = .Fatal_Virtualization_Failure
				result = 2
				run_result.exit_code = result
				break loop
			}
			if reconciled && detection_pending {
				setup_size := console_log_total_size(paths.c_drive, setup_log_names)
				detection_size := console_log_total_size(paths.c_drive, detection_log_names)
				logs_changed :=
					setup_size > 0 &&
					detection_size > 0 &&
					setup_size != setup_log_baseline &&
					detection_size != detection_log_baseline
				if !hardware_detection_seen && logs_changed && post_reset_frame_changes >= 2 {
					if profile.install_state_advance_milestone(
						   &install_state,
						   .Hardware_Detection,
					   ) &&
					   profile.install_state_save(paths.install_state, &install_state) == .None {
						hardware_detection_seen = true
						hardware_detection_at = now
						detection_activity = 0
						run_result.last_progress_reason = "hardware_detection"
						fmt.println("Windows 98: hardware-detection milestone reached")
					}
				}
			}
			if reconciled && desktop_pending {
				enum_evidence, enum_valid := console_desktop_marker_evidence(paths.c_drive)
				primary_dma_transactions, primary_dma_bytes := console_primary_ide_dma_evidence(
					&run_result,
					m,
					machine_segment_accumulated,
					primary_dma_epoch_baseline_transactions,
					primary_dma_epoch_baseline_bytes,
				)
				if enum_valid {
					run_result.desktop_marker_seen = true
					run_result.desktop_enum_valid = true
					run_result.desktop_vga_irq11_seen = enum_evidence.vga_irq11_seen
					if primary_dma_transactions == 0 || primary_dma_bytes == 0 {
						run_result.last_progress_reason =
							DESKTOP_WAITING_PRIMARY_IDE_DMA_PROGRESS_REASON
					}
				}
				if console_desktop_hardware_evidence_complete(
					enum_valid,
					primary_dma_transactions,
					primary_dma_bytes,
				) {
					desktop_marker_seen = true
					progress_watchdog = {}
					run_result.last_progress_reason = "desktop_marker"
					desktop_graphics = {}
					fmt.printfln(
						"Windows 98: desktop evidence reached (GSW VGA IRQ 11, primary IDE BMIDE %d transaction(s), %d bytes)",
						primary_dma_transactions,
						primary_dma_bytes,
					)
				}
			}
		}
		if options.accept_until != .None && console_evidence_poll_due(&last_progress_check, now) {
			desktop_waiting_primary_ide_dma :=
				options.accept_until == .Desktop &&
				run_result.desktop_enum_valid &&
				!desktop_marker_seen
			if console_acceptance_progress_watchdog_poll(
				&run_result,
				m,
				&progress_watchdog,
				last_display_activity_generation,
				now,
				desktop_marker_seen,
				desktop_waiting_primary_ide_dma,
				&firmware,
				iterations,
			) {
				result = 2
				break loop
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
		if options.accept_until == .Desktop &&
		   desktop_marker_seen &&
		   console_desktop_graphics_stable(&desktop_graphics, now) {
			finish_diagnostic := console_install_session_finish(
				paths,
				&install_state,
				m,
				&run_result,
			)
			if finish_diagnostic != .None {
				fmt.eprintfln(
					"Windows 98: cannot finalize completed installation session (%v)",
					finish_diagnostic,
				)
				result = console_install_session_finish_failure(&run_result)
				break loop
			}
			run_result.stop_reason = .Acceptance_Reached
			run_result.exit_code = 0
			run_result.last_progress_reason = "desktop_stable"
			result = 0
			fmt.println("Windows 98: desktop remained graphical and nonblack for ten minutes")
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
