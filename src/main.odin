// SPDX-License-Identifier: GPL-3.0-only
package main

// GUI by default: SDL3 window + ImGui menu, with the machine on its own
// thread. --console runs a headless harness (SeaBIOS POST on stdout) for
// boot debugging. --profile-root:PATH isolates profile-backed runs.

import imgui "../vendor_local/imgui"
import "../vendor_local/imgui/imgui_impl_sdl3"
import "../vendor_local/imgui/imgui_impl_sdlrenderer3"
import "acceptance"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fat32session"
import "host"
import "hv"
import "machine"
import "opticaldrive"
import "profile"
import sdl3 "vendor:sdl3"
import "vga"
import "vmconfig"

RAM_SIZE :: vmconfig.GSW_RAM_BYTES
SNAP_PERIOD :: 8 * time.Millisecond
MAX_LOG_LINES :: 2000
HOST_SDL_EVENTS_PER_FRAME :: 512
HOST_INPUTS_PER_VM_STEP :: 256

Command_Kind :: enum {
	Start,
	Stop,
	Reset,
	Power_Off,
	Mount_Floppy,
	Eject_Floppy,
	Mount_Cdrom,
	Eject_Cdrom,
	Install_Windows_98,
	Abandon_Windows_98_Installation,
	Set_Cpu_Mode,
	Set_Pause,
	Set_Volume,
}

Command :: struct {
	kind:            Command_Kind,
	path:            string, // Mount_Floppy; owned by the VM thread once queued
	boot_path:       string, // Install_Windows_98: optional FAT12 boot seed
	locale_language: string, // Install_Windows_98: owned host locale language
	locale_country:  string, // Install_Windows_98: owned host locale country
	cpu_mode:        vmconfig.Cpu_Mode, // Set_Cpu_Mode: absolute selection
	pause_reason:    host.Pause_Reason,
	pause_active:    bool,
	volume_gain:     f32,
}

Shared :: struct {
	mu:                               sync.Mutex,
	snap:                             vga.Text_Snapshot,
	frames:                           Frame_Mailbox,
	graphics_postmortem:              Graphics_Postmortem,
	graphics_trace_enabled:           bool,
	log_lines:                        [dynamic]string,
	cmds:                             [dynamic]Command,
	running:                          bool,
	machine_running:                  bool,
	frozen_msg:                       string,
	frozen_msg_owned:                 bool,
	exit_stats:                       [hv.Exit_Kind]u64,
	regs_text:                        string,
	regs_text_owned:                  bool,
	cdrom_mounted:                    bool,
	floppy_mounted:                   bool,
	cdrom_media:                      Mounted_Media_State,
	floppy_media:                     Mounted_Media_State,
	storage_activity:                 machine.Storage_Activity,
	storage_activity_session:         u64,
	installing_windows_98:            bool,
	install_recovery_required:        bool,
	install_prepare_running:          bool,
	install_prepare_cancel_requested: bool,
	install_prepare_generation:       u64,
	install_prepare_succeeded:        bool,
	install_prepare_message:          string,
	pause_state:                      host.Pause_State,
	input:                            host.Host_Input_Queue,
	input_generation:                 u64,
	input_generation_exhausted:       bool,
	input_control_stats:              Input_Control_Stats,
	guard:                            ^Vm_Guard,
}

Vm_Ctx :: struct {
	shared:                   ^Shared,
	guard:                    Vm_Guard,
	audio:                    host.Host_Audio,
	audio_enabled:            bool,
	volume_gain:              f32,
	fat_session:              ^fat32session.Machine_Session,
	volume_open_error:        fat32session.Session_Error,
	machine_session_id:       string,
	attach:                   bool,
	allow_hard_drive:         bool,
	floppy:                   []u8, // retained copy of the mounted image so Reset keeps it in the drive
	floppy_path:              string,
	cdrom_path:               string, // retained path; each machine instance opens its own handle
	user_floppy:              []u8,
	user_floppy_path:         string,
	user_cdrom_path:          string,
	cpu_mode:                 vmconfig.Cpu_Mode,
	paths:                    profile.Paths,
	cmos:                     profile.Cmos_Data,
	has_cmos:                 bool,
	install_state:            profile.Install_State,
	install_state_diagnostic: profile.Install_State_Diagnostic,
	preparation_interrupted:  bool,
	preparation_recovered:    bool,
	firmware_log_all:         bool,
	hard_drive_path:          string,
	gsw3d_host:               ^host.Host,
}

Machine_Session_Kind :: enum u8 {
	Gui,
	Console,
}

machine_session_nonce_ns :: proc(now: time.Tick) -> u64 {
	elapsed := time.duration_nanoseconds(time.tick_diff(time.Tick{}, now))
	return u64(max(i64(0), elapsed))
}

machine_session_id_text :: proc(kind: Machine_Session_Kind, pid: int, nonce_ns: u64) -> string {
	prefix := "gui"
	if kind == .Console {prefix = "console"}
	return fmt.tprintf("%s-%d-%d", prefix, pid, nonce_ns)
}

machine_session_id_now :: proc(kind: Machine_Session_Kind) -> string {
	return machine_session_id_text(kind, os.get_pid(), machine_session_nonce_ns(time.tick_now()))
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
	screenshot_path := ""
	screenshot_interval_ms := host.HOST_SCREENSHOT_DEFAULT_INTERVAL_MS
	seconds_explicit := false
	start_requested := false
	gsw3d_proof := false
	graphics_trace := false
	control_script_path := ""
	control_script_seen := false
	acceptance_options, acceptance_diagnostic := acceptance.options_parse(os.args[1:])
	if acceptance_diagnostic != .None {
		fmt.eprintfln("acceptance option error: %v", acceptance_diagnostic)
		return 1
	}
	if acceptance.options_request_headless(&acceptance_options) {console = true}
	for a in os.args[1:] {
		if a == "--control-script" {
			fmt.eprintln("--control-script requires a path")
			return 1
		}
		if a == "--console" {console = true}
		if a == "--start" {start_requested = true}
		if a == "--gsw3d-proof" {gsw3d_proof = true}
		if a == "--graphics-trace" {graphics_trace = true}
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
		if strings.has_prefix(a, "--screenshot:") {
			screenshot_path = a[len("--screenshot:"):]
		}
		if strings.has_prefix(a, "--screenshot-every:") {
			screenshot_interval_ms, _ = strconv.parse_int(a[len("--screenshot-every:"):])
		}
		if strings.has_prefix(a, "--control-script:") ||
		   strings.has_prefix(a, "--control-script=") {
			if control_script_seen {
				fmt.eprintln("--control-script may be specified only once")
				return 1
			}
			control_script_seen = true
			control_script_path = a[len("--control-script:"):]
			if control_script_path == "" {
				fmt.eprintln("--control-script requires a path")
				return 1
			}
		}
	}
	if acceptance_options.accept_until == .Hardware_Detection && !seconds_explicit {
		run_seconds = 30 * 60
	}
	if acceptance_options.accept_until == .Desktop && !seconds_explicit {
		run_seconds = 2 * 60 * 60
	}
	if console && gsw3d_proof {
		fmt.eprintln("--gsw3d-proof is available only in the GUI host")
		return 1
	}
	if console && graphics_trace {
		fmt.eprintln("--graphics-trace is available only in the GUI host")
		return 1
	}
	if console && screenshot_path != "" {
		fmt.eprintln(
			"--screenshot is available only in the GUI host; use --frame-dump for the guest canvas",
		)
		return 1
	}
	if control_script_path != "" && !RETVRN99_TEST_CONTROL {
		fmt.eprintln("--control-script requires a RETVRN99_TEST_CONTROL build")
		return 1
	}
	if control_script_path != "" && console {
		fmt.eprintln("--control-script is available only in the GUI host")
		return 1
	}
	if control_script_path != "" && profile_root == "" {
		fmt.eprintln("--control-script requires an explicit --profile-root")
		return 1
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
	profile_lock: profile.Lock
	if lock_diagnostic := profile.lock_acquire(
		&profile_lock,
		paths.root,
		fmt.tprintf("retvrn99-%d", os.get_pid()),
	); lock_diagnostic != .None {
		if lock_diagnostic == .Owned {
			fmt.eprintfln(
				"profile lock: process %d owns this Profile (lock file %s); close that RETVRN99 and try again",
				profile_lock.owner_pid,
				profile_lock.path,
			)
		} else {
			fmt.eprintfln("profile lock failed: %v", lock_diagnostic)
		}
		profile.lock_release(&profile_lock)
		return console_acceptance_configuration_error(
			&acceptance_options,
			&paths,
			.GSW_886,
			"another RETVRN99 session owns this Profile or its lock is unavailable",
		)
	}
	defer profile.lock_release(&profile_lock)
	settings, settings_diag, settings_migration := profile.settings_load(paths.settings)
	defer profile.settings_destroy(&settings)
	if settings_diag == .Missing {
		if save_diag := profile.settings_save(paths.settings, settings); save_diag != .None {
			fmt.eprintfln("settings save failed: %v", save_diag)
		}
	} else if settings_diag != .None {
		fmt.eprintfln("settings load warning: %v; using defaults", settings_diag)
	} else if settings_migration != .None {
		if migration_diagnostic := profile.settings_migrate(
			paths.settings,
			settings,
			settings_migration,
		); migration_diagnostic != .None {
			fmt.eprintfln("settings migration failed: %v", migration_diagnostic)
		} else {
			fmt.printfln("settings: migrated profile preferences to v%d", profile.SETTINGS_VERSION)
		}
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
					settings.hard_drive_path,
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
		start_requested,
		gsw3d_proof,
		graphics_trace,
		screenshot_path,
		screenshot_interval_ms,
		control_script_path,
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
	start_requested: bool,
	gsw3d_proof: bool,
	graphics_trace: bool,
	screenshot_path: string,
	screenshot_interval_ms: int,
	control_script_path: string,
) -> (
	result: int,
) {
	screenshot := host.Host_Screenshot {
		path        = screenshot_path,
		interval_ms = screenshot_interval_ms,
	}
	input_control: Input_Control
	defer input_control_destroy(&input_control)
	input_control_exclusive := control_script_path != ""
	if input_control_exclusive {
		if diagnostic := input_control_load(&input_control, control_script_path);
		   diagnostic != .None {
			fmt.eprintfln("control script: load failed (%v)", diagnostic)
			return 1
		}
		fmt.printfln(
			"control script: loaded %d actions; physical guest input is disabled",
			len(input_control.script.actions),
		)
	}
	active_settings := profile.settings_clone(settings)
	defer profile.settings_destroy(&active_settings)
	settings_save_pending := false
	startup_settings_dirty := false
	if media_settings_reconcile_missing(&active_settings, .Floppy) == .Missing {
		startup_settings_dirty = true
	}
	if media_settings_reconcile_missing(&active_settings, .Cdrom) == .Missing {
		startup_settings_dirty = true
	}
	if startup_settings_dirty {
		if diagnostic := profile.settings_save(paths.settings, active_settings);
		   diagnostic != .None {
			settings_save_pending = true
			fmt.eprintfln(
				"settings: missing removable-media path could not be cleared (%v)",
				diagnostic,
			)
		}
	}
	auto_close_after := auto_close
	ctx := new(Vm_Ctx)
	shared := new(Shared)
	guard_storage_retained := false
	defer {
		if ctx.fat_session != nil {
			close_error := fat32session.close(ctx.fat_session, .Commit)
			if close_error.code == .None || close_error.outcome == .Completed {
				ctx.fat_session = nil
				if close_error.code != .None {
					fmt.eprintfln(
						"disk: close completed with a companion cleanup warning: %s",
						fat32session.error_text(&close_error),
					)
				}
			} else {
				fmt.eprintfln("disk: close failed: %s", fat32session.error_text(&close_error))
				_ = fat32session.close(ctx.fat_session, .Retain)
				ctx.fat_session = nil
				if result == 0 {result = 1}
			}
		}
		delete(ctx.machine_session_id)
		delete(ctx.hard_drive_path)
		profile.install_state_destroy(&ctx.install_state)
		postmortem_enabled := graphics_postmortem_status(&shared.graphics_postmortem).enabled
		postmortem_diagnostic := graphics_postmortem_destroy(&shared.graphics_postmortem)
		if postmortem_enabled && postmortem_diagnostic != .None {
			fmt.eprintfln("graphics postmortem save failed: %v", postmortem_diagnostic)
			if result == 0 {result = 1}
		}
		frame_mailbox_destroy(&shared.frames)
		command_queue_destroy(shared)
		vm_log_destroy(shared)
		shared_media_destroy(shared)
		delete(shared.install_prepare_message)
		free(shared)
		if !guard_storage_retained {free(ctx)}
	}
	shared.running = true
	shared.graphics_trace_enabled = graphics_trace
	frame_mailbox_graphics_telemetry_init(&shared.frames, graphics_trace)
	ctx.shared = shared
	ctx.allow_hard_drive = attach
	ctx.attach = attach
	ctx.cpu_mode = active_settings.cpu_mode
	ctx.paths = paths^
	ctx.machine_session_id = strings.clone(machine_session_id_now(.Gui))
	if postmortem_diagnostic := graphics_postmortem_init(
		&shared.graphics_postmortem,
		{
			enabled = graphics_trace,
			path = paths.graphics_postmortem,
			session = ctx.machine_session_id,
			device = "PCI\\VEN_FFFE&DEV_0002",
		},
	); postmortem_diagnostic != .None {
		fmt.eprintfln("graphics postmortem initialization failed: %v", postmortem_diagnostic)
		return 1
	}
	ctx.cmos = cmos
	ctx.has_cmos = has_cmos
	ctx.firmware_log_all = firmware_log_all
	ctx.hard_drive_path = strings.clone(active_settings.hard_drive_path)
	ctx.user_floppy_path = strings.clone(active_settings.floppy_path)
	ctx.user_cdrom_path = strings.clone(active_settings.cdrom_path)
	ctx.attach = ctx.allow_hard_drive && ctx.hard_drive_path != ""
	install_state, install_diagnostic := profile.install_state_load(paths.install_state)
	ctx.install_state = install_state
	ctx.install_state_diagnostic = install_diagnostic
	shared.install_recovery_required = profile.install_state_recovery_required(install_diagnostic)
	ctx.preparation_interrupted = false
	ctx.preparation_recovered = true
	if profile.install_state_active(&ctx.install_state) {
		shared.installing_windows_98 = true
		ctx.cdrom_path = strings.clone(ctx.install_state.source_path)
		media_state_publish_result(shared, .Cdrom, true, true, ctx.cdrom_path, "", "", false)
	}
	if install_diagnostic != .None && install_diagnostic != .Missing {
		vm_log(
			shared,
			fmt.tprintf(
				"Windows 98: install state is invalid; Start is blocked (%v)",
				install_diagnostic,
			),
		)
	}
	if !ctx.attach {
		fmt.println("disk: none (--no-disk)")
	}

	h: host.Host
	if !host.host_init(&h) {
		fmt.eprintfln("host_init failed: %s", sdl3.GetError())
		return 1
	}
	if gsw3d_proof {
		if !host.host_gsw3d_proof_enable(&h) {
			fmt.eprintfln("GSW3D proof renderer initialization failed: %s", sdl3.GetError())
			host.host_destroy(&h)
			return 1
		}
		ctx.gsw3d_host = &h
		fmt.println("video: developer-only exact GSW3D triangle profile enabled")
	}
	_ = frame_mailbox_graphics_telemetry_note_host_gpu(
		&shared.frames,
		host.host_gsw3d_observability_snapshot(&h),
		time.tick_now(),
	)
	preferred_locale, _ := host.host_preferred_locale()
	defer host.host_locale_destroy(&preferred_locale)
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
	ctx.volume_gain = 1
	defer {
		shared.guard = nil
		if !vm_guard_destroy(&ctx.guard) {
			guard_storage_retained = true
			fmt.eprintln("vCPU wake adapter teardown failed; callback storage retained")
			if result == 0 {result = 1}
		}
	}
	vm_thr := thread.create_and_start_with_poly_data(ctx, vm_thread_proc)
	if !shared.installing_windows_98 {
		if active_settings.floppy_path != "" {
			push_cmd(
				shared,
				Command{kind = .Mount_Floppy, path = strings.clone(active_settings.floppy_path)},
			)
		}
		if active_settings.cdrom_path != "" {
			push_cmd(
				shared,
				Command{kind = .Mount_Cdrom, path = strings.clone(active_settings.cdrom_path)},
			)
		}
	}
	if start_requested {push_cmd(shared, Command{kind = .Start})}

	st := host.Menu_State {
		cpu_mode            = ctx.cpu_mode,
		window_scale        = h.window_scale,
		fullscreen          = h.fullscreen,
		menu_reveal         = 1,
		visual_shader       = h.visual_shader,
		shaders_available   = h.shader_state != nil,
		hard_drive_path     = active_settings.hard_drive_path,
		host_optical_drives = opticaldrive.enumerate(),
	}
	floppy_activity_light: host.Activity_Light_State
	hard_drive_activity_light: host.Activity_Light_State
	dvd_rom_activity_light: host.Activity_Light_State
	gui_hard_drive_status_refresh(&st, active_settings.hard_drive_path)
	defer delete(st.hard_drive_diagnostic)
	floppy_pending := pending_mount_create()
	cdrom_pending := pending_mount_create()
	hard_drive_dialog_pending := pending_hard_drive_dialog_create()
	create_model: host.Hard_Drive_Create_Model
	create_worker: Hard_Drive_Create_Worker
	create_worker.allocator = context.allocator
	defer hard_drive_create_worker_destroy(&create_worker)
	guided_install: Guided_Install_Model
	install_resume_after_create := false
	hard_drive_controller: Hard_Drive_Controller
	hard_drive_controller_init(&hard_drive_controller)
	dropped_paths := make([dynamic]string)
	drop_complete := false
	release_mouse_key := false
	host_hotkey_scancode := sdl3.Scancode.UNKNOWN
	host_lgui_down := false
	host_rgui_down := false
	host_lshift_down := false
	host_rshift_down := false
	hotkey_config := host.host_hotkey_defaults()
	if !host.host_hotkey_config_set_text(
		&hotkey_config,
		.Release_Input,
		active_settings.hotkeys.release_input,
	) {
		vm_log(shared, "settings: invalid release-input hotkey; using the default")
	}
	if !host.host_hotkey_config_set_text(
		&hotkey_config,
		.Toggle_Fullscreen,
		active_settings.hotkeys.toggle_fullscreen,
	) {
		vm_log(shared, "settings: invalid fullscreen hotkey; using the default")
	}
	if !host.host_hotkey_config_set_text(
		&hotkey_config,
		.Toggle_Turbo,
		active_settings.hotkeys.toggle_turbo,
	) {
		vm_log(shared, "settings: invalid Turbo hotkey; using the default")
	}
	if !host.host_hotkey_config_set_text(
		&hotkey_config,
		.Volume_Down,
		active_settings.hotkeys.volume_down,
	) {
		vm_log(shared, "settings: invalid volume-down hotkey; using the default")
	}
	if !host.host_hotkey_config_set_text(
		&hotkey_config,
		.Volume_Up,
		active_settings.hotkeys.volume_up,
	) {
		vm_log(shared, "settings: invalid volume-up hotkey; using the default")
	}
	release_binding_title := gui_release_binding_title(hotkey_config)
	defer delete(release_binding_title)
	st.hotkeys = hotkey_config
	audio_gain := f32(1)
	floppy_media_generation: u64
	cdrom_media_generation: u64
	exit_requested := false
	keyboard: host.Host_Keyboard
	start := time.tick_now()
	menu_animation_tick := start
	last_graphics_vm_checkpoint: time.Tick
	graphics_aggregate_logs: u64
	last_input_control_state := input_control.state

	for {
		sync.lock(&shared.mu)
		running := shared.running
		sync.unlock(&shared.mu)
		if !running {break}

		ev: sdl3.Event
		for _ in 0 ..< HOST_SDL_EVENTS_PER_FRAME {
			if !sdl3.PollEvent(&ev) {break}
			mouse_event :=
				ev.type == .MOUSE_MOTION ||
				ev.type == .MOUSE_BUTTON_DOWN ||
				ev.type == .MOUSE_BUTTON_UP ||
				ev.type == .MOUSE_WHEEL
			if !h.mouse_captured || !mouse_event {imgui_impl_sdl3.ProcessEvent(&ev)}
			#partial switch ev.type {
			case .QUIT:
				exit_requested = true
			case .DROP_BEGIN:
				for path in dropped_paths {delete(path)}
				clear(&dropped_paths)
				drop_complete = false
			case .DROP_FILE:
				if ev.drop.data != nil &&
				   hard_drive_controller_is_open(&hard_drive_controller) &&
				   !st.machine_running {
					append(&dropped_paths, strings.clone(string(ev.drop.data)))
				}
			case .DROP_COMPLETE:
				drop_complete = true
			case .KEY_DOWN, .KEY_UP:
				if ev.key.repeat {continue}
				#partial switch ev.key.scancode {
				case .LGUI:
					host_lgui_down = ev.key.down
				case .RGUI:
					host_rgui_down = ev.key.down
				case .LSHIFT:
					host_lshift_down = ev.key.down
				case .RSHIFT:
					host_rshift_down = ev.key.down
				}
				if !ev.key.down && ev.key.scancode == host_hotkey_scancode {
					host_hotkey_scancode = .UNKNOWN
					continue
				}
				host_modifiers := ev.key.mod
				if host_lgui_down {host_modifiers += {.LGUI}}
				if host_rgui_down {host_modifiers += {.RGUI}}
				if host_lshift_down {host_modifiers += {.LSHIFT}}
				if host_rshift_down {host_modifiers += {.RSHIFT}}
				if host.hotkey_editor_capture_event(
					&st.hotkey_editor,
					ev.key.scancode,
					host_modifiers,
					ev.key.down,
					ev.key.repeat,
				) {
					continue
				}
				hotkey := host.host_hotkey_from_key(
					ev.key.scancode,
					host_modifiers,
					ev.key.down,
					ev.key.repeat,
					&hotkey_config,
				)
				if hotkey != .None {
					host_hotkey_scancode = ev.key.scancode
					switch hotkey {
					case .Release_Input:
						release_mouse_key = false
						release_held_keys(shared, &keyboard)
						if h.mouse_captured {
							_ = host.mouse_capture(&h, false)
							host.host_set_input_title(&h, false)
							push_mouse_buttons(shared, 0, true)
						}
					case .Toggle_Fullscreen:
						_ = host.host_toggle_fullscreen(&h)
						st.fullscreen = h.fullscreen
					case .Toggle_Turbo:
						st.cpu_mode = st.cpu_mode == .Turbo ? .GSW_886 : .Turbo
						push_cmd(shared, Command{kind = .Set_Cpu_Mode, cpu_mode = st.cpu_mode})
						active_settings.cpu_mode = st.cpu_mode
						if diag := profile.settings_save(paths.settings, active_settings);
						   diag != .None {
							vm_log(shared, fmt.tprintf("settings: save failed (%v)", diag))
						}
					case .Volume_Down, .Volume_Up:
						audio_gain = host.host_volume_adjust(audio_gain, hotkey)
						push_cmd(shared, Command{kind = .Set_Volume, volume_gain = audio_gain})
					case .None:
					}
					continue
				}
				if ev.key.scancode == .RCTRL &&
				   ((ev.key.down && h.mouse_captured) || release_mouse_key) {
					if ev.key.down {
						release_mouse_key = true
						release_held_keys(shared, &keyboard)
						_ = host.mouse_capture(&h, false)
						host.host_set_input_title(&h, false)
						push_mouse_buttons(shared, 0, true)
					} else {
						release_mouse_key = false
					}
					continue
				}
				// releases always reach the guest: swallowing a break code
				// while ImGui captures the keyboard leaves a stuck key
				if ev.key.down && io.WantCaptureKeyboard {continue}
				if input_control_exclusive {continue}
				push_host_key(shared, &keyboard, ev.key.scancode, ev.key.down)
			case .MOUSE_MOTION:
				if h.mouse_captured && !input_control_exclusive {
					h.mouse_buttons = host.mouse_buttons_from_sdl(ev.motion.state)
					push_mouse_motion(
						shared,
						i32(ev.motion.xrel),
						i32(ev.motion.yrel),
						h.mouse_buttons,
					)
				}
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				if input_control_exclusive {continue}
				if !h.mouse_captured {
					if !ev.button.down ||
					   io.WantCaptureMouse ||
					   !host.mouse_inside_guest(&h, ev.button.x, ev.button.y) ||
					   !host.mouse_capture(&h, true) {
						continue
					}
					host.host_set_input_title(&h, true, release_binding_title)
				}
				h.mouse_buttons = host.mouse_set_button(
					h.mouse_buttons,
					ev.button.button,
					ev.button.down,
				)
				push_mouse_buttons(shared, h.mouse_buttons, !ev.button.down)
			case .MOUSE_WHEEL:
				if h.mouse_captured && !input_control_exclusive {
					wheel := ev.wheel.integer_y
					if wheel == 0 && ev.wheel.y != 0 {wheel = ev.wheel.y > 0 ? 1 : -1}
					if ev.wheel.direction == .FLIPPED {wheel = -wheel}
					push_mouse_wheel(shared, wheel, h.mouse_buttons)
				}
			case .WINDOW_FOCUS_LOST, .WILL_ENTER_BACKGROUND, .DID_ENTER_BACKGROUND:
				release_mouse_key = false
				host_hotkey_scancode = .UNKNOWN
				host_lgui_down = false
				host_rgui_down = false
				host_lshift_down = false
				host_rshift_down = false
				release_held_keys(shared, &keyboard)
				if h.mouse_captured {
					_ = host.mouse_capture(&h, false)
					host.host_set_input_title(&h, false)
					push_mouse_buttons(shared, 0, true)
				}
			}
		}
		if drop_complete {
			if len(dropped_paths) > 0 {
				drop_machine_running, drop_install_active := gui_storage_lifecycle_snapshot(shared)
				hard_drive_controller.model.machine_running = drop_machine_running
				if gui_storage_dispatch_allowed(
					drop_machine_running,
					drop_install_active,
					guided_install.phase != .Closed || create_model.visible,
				) {
					_ = hard_drive_controller_handle(
						&hard_drive_controller,
						host.hard_drive_browser_accept_drop(
							&hard_drive_controller.model,
							dropped_paths[:],
						),
					)
				}
			}
			for path in dropped_paths {delete(path)}
			clear(&dropped_paths)
			drop_complete = false
		}

		if path, ready := pending_take(floppy_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Floppy, path = path})
		}
		if path, ready := pending_take(cdrom_pending); ready {
			push_cmd(shared, Command{kind = .Mount_Cdrom, path = path})
		}
		if dialog_result, ready := pending_hard_drive_dialog_take(hard_drive_dialog_pending);
		   ready {
			storage_machine_running, storage_install_active := gui_storage_lifecycle_snapshot(
				shared,
			)
			switch dialog_result.purpose {
			case .Select_Image:
				if dialog_result.failed {
					vm_log(
						shared,
						fmt.tprintf(
							"hard drive: file picker failed: %s",
							dialog_result.diagnostic,
						),
					)
				} else if dialog_result.accepted && len(dialog_result.paths) == 1 {
					blocked :=
						guided_install.phase != .Closed ||
						create_model.visible ||
						hard_drive_controller_is_open(&hard_drive_controller)
					if !gui_storage_dispatch_allowed(
						storage_machine_running,
						storage_install_active,
						blocked,
					) {
						vm_log(
							shared,
							"hard drive: selection ignored while storage controls are blocked",
						)
					} else if !gui_hard_drive_select(
						ctx,
						&active_settings,
						&st,
						dialog_result.paths[0],
						storage_machine_running,
						storage_install_active,
					) {
						vm_log(
							shared,
							fmt.tprintf("hard drive: cannot select %s", dialog_result.paths[0]),
						)
					}
				}
			case .Create_Image_Path:
				blocked :=
					guided_install.phase != .Closed ||
					hard_drive_controller_is_open(&hard_drive_controller)
				if dialog_result.failed {
					vm_log(
						shared,
						fmt.tprintf(
							"hard drive: file picker failed: %s",
							dialog_result.diagnostic,
						),
					)
					host.hard_drive_create_accept_result(
						&create_model,
						{
							kind = .Error,
							diagnostic = "The file picker could not be opened. Try Browse again.",
						},
					)
				} else if gui_storage_dispatch_allowed(
					storage_machine_running,
					storage_install_active,
					blocked,
				) {
					_ = host.hard_drive_create_accept_dialog(&create_model, dialog_result)
				} else {
					host.hard_drive_create_accept_result(
						&create_model,
						{
							kind = .Error,
							diagnostic = "Stop the machine before creating a hard drive.",
						},
					)
				}
			case .Import_Files, .Import_Folder, .Export_Entry:
				blocked := guided_install.phase != .Closed || create_model.visible
				if dialog_result.failed {
					vm_log(
						shared,
						fmt.tprintf(
							"hard drive: file picker failed: %s",
							dialog_result.diagnostic,
						),
					)
				} else if gui_storage_dispatch_allowed(
					storage_machine_running,
					storage_install_active,
					blocked,
				) {
					_ = hard_drive_controller_handle(
						&hard_drive_controller,
						host.hard_drive_browser_accept_dialog(
							&hard_drive_controller.model,
							dialog_result,
						),
					)
				}
			case .Install_ISO:
				blocked :=
					create_model.visible || hard_drive_controller_is_open(&hard_drive_controller)
				allowed := gui_storage_dispatch_allowed(
					storage_machine_running,
					storage_install_active,
					blocked,
				)
				if dialog_result.failed {
					guided_install_dialog_error(&guided_install, dialog_result.diagnostic)
				} else if allowed && dialog_result.accepted && len(dialog_result.paths) == 1 {
					action := guided_install_inspect(&guided_install, dialog_result.paths[0], "")
					_ = action
				} else {
					guided_install_dialog_cancel(&guided_install)
				}
			case .Install_Boot_Floppy:
				blocked :=
					create_model.visible || hard_drive_controller_is_open(&hard_drive_controller)
				allowed := gui_storage_dispatch_allowed(
					storage_machine_running,
					storage_install_active,
					blocked,
				)
				if dialog_result.failed {
					guided_install_dialog_error(&guided_install, dialog_result.diagnostic)
				} else if allowed && dialog_result.accepted && len(dialog_result.paths) == 1 {
					_ = guided_install_inspect(
						&guided_install,
						guided_install.iso_path,
						dialog_result.paths[0],
					)
				} else {
					guided_install_dialog_cancel(&guided_install)
				}
			case .None:
			}
			pending_hard_drive_dialog_result_destroy(&dialog_result)
		}

		// copy of the shared state for this frame
		sync.lock(&shared.mu)
		frozen := strings.clone(shared.frozen_msg, context.temp_allocator)
		regs := strings.clone(shared.regs_text, context.temp_allocator)
		machine_running := shared.machine_running
		input_generation := shared.input_generation
		input_generation_exhausted := shared.input_generation_exhausted
		st.user_paused = host.pause_reason_active(&shared.pause_state, .User)
		st.install_active = shared.installing_windows_98
		st.install_recovery_required = shared.install_recovery_required
		st.machine_paused = host.pause_active(&shared.pause_state)
		storage_activity := shared.storage_activity
		storage_activity_session := shared.storage_activity_session
		sync.unlock(&shared.mu)
		floppy_media := media_state_snapshot(shared, .Floppy, context.temp_allocator)
		cdrom_media := media_state_snapshot(shared, .Cdrom, context.temp_allocator)
		st.floppy_mounted = floppy_media.mounted
		st.cdrom_mounted = cdrom_media.mounted
		st.floppy_unavailable = floppy_media.unavailable
		st.cdrom_unavailable = cdrom_media.unavailable
		st.floppy_path =
			floppy_media.mounted ? floppy_media.actual_path : floppy_media.requested_path
		st.cdrom_path = cdrom_media.mounted ? cdrom_media.actual_path : cdrom_media.requested_path
		st.floppy_diagnostic = floppy_media.diagnostic
		st.cdrom_diagnostic = cdrom_media.diagnostic
		media_settings_changed := false
		if media_settings_consume(
			&active_settings,
			.Floppy,
			&floppy_media,
			&floppy_media_generation,
		) {
			media_settings_changed = true
		}
		if media_settings_consume(
			&active_settings,
			.Cdrom,
			&cdrom_media,
			&cdrom_media_generation,
		) {
			media_settings_changed = true
		}
		if media_settings_changed {
			settings_save_pending = profile.settings_save(paths.settings, active_settings) != .None
			if settings_save_pending {
				vm_log(
					shared,
					"settings: mounted-media change could not be saved; it will be retried",
				)
			}
		}

		_ = graphics_presentation_sync_lifecycle(&h, &shared.frames, machine_running)
		if st.machine_running && !machine_running {
			release_mouse_key = false
			host_hotkey_scancode = .UNKNOWN
			host_lgui_down = false
			host_rgui_down = false
			host_lshift_down = false
			host_rshift_down = false
			_ = host.mouse_capture(&h, false)
			host.host_set_input_title(&h, false)
			sync.lock(&shared.mu)
			input_control_note_reset_cancelled_locked(shared)
			host.host_input_discard_after_stop(&shared.input, &keyboard)
			sync.unlock(&shared.mu)
			host.host_clear_frame(&h)
		}
		st.machine_running = machine_running
		st.storage_actions_blocked =
			guided_install.phase != .Closed ||
			create_model.visible ||
			pending_hard_drive_dialog_active(hard_drive_dialog_pending)
		st.window_scale = h.window_scale
		st.fullscreen = h.fullscreen
		st.visual_shader = h.visual_shader
		h.sidebar_collapsed = st.sidebar_collapsed
		menu_animation_now := time.tick_now()
		if input_control_exclusive {
			control_state := input_control_tick(
				&input_control,
				{
					running = machine_running,
					paused = st.machine_paused,
					frozen = frozen != "" || input_generation_exhausted,
					generation = input_generation,
				},
				menu_animation_now,
				input_control_enqueue_shared,
				shared,
			)
			if control_state != last_input_control_state {
				switch control_state {
				case .Running:
					vm_log(shared, "control script: input pump started")
				case .Completed:
					vm_log(shared, "control script: all actions queued")
				case .Failed:
					input_control_release_mouse(&input_control, shared)
					vm_log(
						shared,
						fmt.tprintf("control script: stopped (%v)", input_control.failure),
					)
				case .Disabled, .Waiting:
				}
				last_input_control_state = control_state
			}
		}
		menu_animation_seconds := f32(
			time.duration_seconds(time.tick_diff(menu_animation_tick, menu_animation_now)),
		)
		menu_animation_tick = menu_animation_now
		st.floppy_active = host.activity_light_step(
			&floppy_activity_light,
			storage_activity.floppy,
			storage_activity_session,
			st.machine_running,
			menu_animation_seconds,
		)
		st.hard_drive_active = host.activity_light_step(
			&hard_drive_activity_light,
			storage_activity.hard_drive,
			storage_activity_session,
			st.machine_running,
			menu_animation_seconds,
		)
		st.dvd_rom_active = host.activity_light_step(
			&dvd_rom_activity_light,
			storage_activity.dvd_rom,
			storage_activity_session,
			st.machine_running,
			menu_animation_seconds,
		)
		menu_target := f32(1)
		if h.fullscreen && h.mouse_captured {menu_target = 0}
		st.menu_reveal = host.menu_reveal_step(st.menu_reveal, menu_target, menu_animation_seconds)
		h.menu_reveal = st.menu_reveal

		frame_consumer := graphics_frame_consume(
			shared,
			&h,
			graphics_trace,
			&last_graphics_vm_checkpoint,
		)
		graphics_epoch := frame_consumer.graphics_epoch
		graphics_epoch_pending := frame_consumer.graphics_epoch_pending
		graphics_epoch_reset := false
		postmortem_state := frame_consumer.postmortem_state
		postmortem_state_valid := frame_consumer.postmortem_state_valid
		_ = graphics_presentation_sync_lifecycle(&h, &shared.frames, st.machine_running)
		gpu_drain_started := time.tick_now()
		gpu_drain := host.host_gsw3d_proof_drain(&h)
		gpu_drain_ended := time.tick_now()
		_ = graphics_presentation_sync_lifecycle(&h, &shared.frames, st.machine_running)
		frame_mailbox_graphics_telemetry_note_gpu_drain(
			&shared.frames,
			gpu_drain_started,
			gpu_drain_ended,
			gpu_drain.executed,
			gpu_drain.failed,
			gpu_drain.budget_used,
		)
		host_gpu_snapshot := host.host_gsw3d_observability_snapshot(&h)
		host_gpu_interval := frame_mailbox_graphics_telemetry_note_host_gpu(
			&shared.frames,
			host_gpu_snapshot,
			gpu_drain_ended,
		)
		selection := graphics_presentation_select(
			&shared.frames,
			graphics_epoch,
			graphics_epoch_pending,
			{
				started = gpu_drain_started,
				ended = gpu_drain_ended,
				executed = gpu_drain.executed,
				failed = gpu_drain.failed,
				budget = gpu_drain.budget_used,
				host_gpu = host_gpu_interval,
			},
		)
		graphics_epoch = selection.active_epoch
		graphics_epoch_pending = selection.active
		if graphics_trace && graphics_epoch_pending && graphics_epoch.source == .Gsw3d {
			postmortem_state = graphics_postmortem_measured_state(
				storage_activity_session,
				graphics_epoch.producer.device_generation,
				host_gpu_snapshot.device_generation,
				graphics_epoch.sequence,
				.Gpu_Drain,
			)
			postmortem_state_valid = true
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state)
		} else if graphics_epoch_pending && postmortem_state_valid {
			postmortem_state = graphics_postmortem_measured_state(
				postmortem_state.session_generation,
				postmortem_state.guest_device_generation,
				host_gpu_snapshot.device_generation,
				graphics_epoch.sequence,
				.Gpu_Drain,
			)
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state)
		}
		if graphics_trace && selection.has_terminal {
			terminal := selection.terminal_epoch
			terminal_stage := Graphics_Postmortem_Host_Stage.Complete
			if terminal.result == .Reset || terminal.gpu_failures > 0 {
				terminal_stage = .Failed
			}
			terminal_state := graphics_postmortem_measured_state(
				storage_activity_session,
				terminal.producer.device_generation,
				host_gpu_snapshot.device_generation,
				terminal.sequence,
				terminal_stage,
			)
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, terminal_state)
		}
		if graphics_epoch_pending &&
		   (!st.machine_running ||
				   !frame_mailbox_graphics_epoch_current(&shared.frames, &graphics_epoch)) {
			graphics_epoch_reset = true
			_ = graphics_presentation_sync_lifecycle(&h, &shared.frames, st.machine_running)
			if postmortem_state_valid {
				postmortem_state.host_stage = .Failed
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
		}
		compose_started := time.tick_now()
		if graphics_epoch_pending && postmortem_state_valid {
			postmortem_state.host_stage = .Compose
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state)
		}
		compose_ok := host.host_render_guest(&h, st.machine_running)
		compose_ended := time.tick_now()
		frame_mailbox_graphics_telemetry_note_compose(
			&shared.frames,
			compose_started,
			compose_ended,
		)
		if graphics_epoch_pending {
			graphics_frame_epoch_compose(&graphics_epoch, compose_started, compose_ended)
			if !compose_ok {
				intended := graphics_epoch_reset ? Graphics_Frame_Result.Reset : .Compose_Failed
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&graphics_epoch,
					intended,
					time.tick_now(),
				)
				graphics_epoch_pending = false
				if postmortem_state_valid {
					postmortem_state.host_stage = .Failed
					_ = graphics_postmortem_publish_state(
						&shared.graphics_postmortem,
						postmortem_state,
					)
				}
			}
		}

		imgui_impl_sdlrenderer3.NewFrame()
		imgui_impl_sdl3.NewFrame()
		imgui.NewFrame()
		info := host.Menu_Info {
			frozen_msg = frozen,
			regs_text  = regs,
		}
		st.host_optical_drives = opticaldrive.enumerate()
		switch host.menu_draw(&st, info, h.storage_icons) {
		case .Start:
			if host.menu_action_enabled(&st, .Start) &&
			   !st.storage_actions_blocked &&
			   hard_drive_controller_prepare_machine_start(&hard_drive_controller) {
				if gui_media_queue_before_start(
					shared,
					&active_settings,
					st.install_active || st.install_recovery_required,
				) {
					settings_save_pending =
						profile.settings_save(paths.settings, active_settings) != .None
				}
				push_cmd(shared, Command{kind = .Start})
			}
		case .Stop:
			push_cmd(shared, Command{kind = .Stop})
		case .Reset:
			push_cmd(shared, Command{kind = .Reset})
		case .Toggle_Pause:
			st.user_paused = !st.user_paused
			push_cmd(
				shared,
				Command{kind = .Set_Pause, pause_reason = .User, pause_active = st.user_paused},
			)
		case .Power_Off:
			exit_requested = true
		case .Select_Hard_Drive:
			if host.menu_action_enabled(&st, .Select_Hard_Drive) &&
			   !hard_drive_controller_is_open(&hard_drive_controller) {
				_ = pending_hard_drive_dialog_show(
					hard_drive_dialog_pending,
					h.win,
					host.hard_drive_select_dialog_request(active_settings.hard_drive_path),
				)
			}
		case .Browse_C_Drive:
			if host.menu_action_enabled(&st, .Browse_C_Drive) &&
			   !hard_drive_controller_open(
					   &hard_drive_controller,
					   active_settings.hard_drive_path,
					   st.machine_running,
				   ) {
				vm_log(
					shared,
					fmt.tprintf("hard drive: %s", hard_drive_controller.model.diagnostic),
				)
			}
		case .Create_Hard_Drive:
			if host.menu_action_enabled(&st, .Create_Hard_Drive) &&
			   !hard_drive_controller_is_open(&hard_drive_controller) {
				_ = host.hard_drive_create_open(&create_model, paths.default_image)
			}
		case .Mount_Floppy:
			pending_mount_show(floppy_pending, h.win)
		case .Eject_Floppy:
			push_cmd(shared, Command{kind = .Eject_Floppy})
		case .Mount_Cdrom:
			pending_mount_show(cdrom_pending, h.win)
		case .Mount_Host_Cdrom:
			path := opticaldrive.path(st.requested_host_optical)
			if path != "" {
				push_cmd(shared, Command{kind = .Mount_Cdrom, path = strings.clone(path)})
			}
		case .Eject_Cdrom:
			push_cmd(shared, Command{kind = .Eject_Cdrom})
		case .Install_Windows_98:
			if !host.menu_action_enabled(&st, .Install_Windows_98) ||
			   hard_drive_controller_is_open(&hard_drive_controller) {
				break
			} else if st.hard_drive_status != .Ready || active_settings.hard_drive_path == "" {
				install_resume_after_create = true
				_ = host.hard_drive_create_open(&create_model, paths.default_image)
			} else {
				_ = guided_install_open(&guided_install, active_settings.hard_drive_path)
			}
		case .Abandon_Windows_98_Installation:
			push_cmd(shared, Command{kind = .Abandon_Windows_98_Installation})
		case .Set_Cpu_Mode:
			push_cmd(shared, Command{kind = .Set_Cpu_Mode, cpu_mode = st.cpu_mode})
			active_settings.cpu_mode = st.cpu_mode
			if diag := profile.settings_save(paths.settings, active_settings); diag != .None {
				vm_log(shared, fmt.tprintf("settings: save failed (%v)", diag))
			}
		case .Set_Window_Scale:
			_ = host.host_set_window_scale(&h, st.window_scale)
			st.window_scale = h.window_scale
		case .Toggle_Fullscreen:
			_ = host.host_toggle_fullscreen(&h)
			st.fullscreen = h.fullscreen
		case .Set_Visual_Shader:
			_ = host.host_set_visual_shader(&h, st.visual_shader)
			st.visual_shader = h.visual_shader
		case .Set_Hotkeys:
			hotkey_config = st.hotkeys
			if gui_hotkey_settings_store(&active_settings, hotkey_config) {
				settings_save_pending =
					profile.settings_save(paths.settings, active_settings) != .None
				delete(release_binding_title)
				release_binding_title = gui_release_binding_title(hotkey_config)
				if h.mouse_captured {
					host.host_set_input_title(&h, true, release_binding_title)
				}
			} else {
				vm_log(shared, "settings: hotkey configuration could not be serialized")
			}
		case .Reveal_Cdrom:
			_ = host.host_reveal_path(st.cdrom_path)
		case .Reveal_Floppy:
			_ = host.host_reveal_path(st.floppy_path)
		case .Open_Github:
			_ = sdl3.OpenURL("https://github.com/vorvek/RETVRN99")
		case .Open_Documentation:
			_ = sdl3.OpenURL("https://github.com/vorvek/RETVRN99/blob/main/docs/user-guide.md")
		case .Open_Third_Party:
			_ = sdl3.OpenURL("https://github.com/vorvek/RETVRN99/blob/main/THIRDPARTY.md")
		case .None:
		}
		worker_result := hard_drive_create_worker_poll(&create_worker)
		if worker_result.ready {
			create_machine_running, create_install_active := gui_storage_lifecycle_snapshot(shared)
			if worker_result.cancelled {
				install_resume_after_create = false
				host.hard_drive_create_accept_result(
					&create_model,
					{kind = .Cancelled, diagnostic = "Hard-drive creation was cancelled."},
				)
			} else if worker_result.error.code != .None {
				fat32session.image_info_destroy(&worker_result.info)
				if worker_result.error.outcome == .Completed {
					host.hard_drive_create_accept_result(
						&create_model,
						{
							kind = .Image_Created_Unselected,
							diagnostic = fat32session.error_text(&worker_result.error),
						},
					)
				} else {
					kind := host.Hard_Drive_UI_Result_Kind.Error
					if worker_result.error.code == .Sparse_Unsupported {
						kind = .Sparse_Unsupported
					}
					host.hard_drive_create_accept_result(
						&create_model,
						{kind = kind, diagnostic = fat32session.error_text(&worker_result.error)},
					)
				}
			} else if create_machine_running || create_install_active {
				fat32session.image_info_destroy(&worker_result.info)
				install_resume_after_create = false
				host.hard_drive_create_accept_result(
					&create_model,
					{
						kind = .Image_Created_Unselected,
						diagnostic = "The image was created, but the machine is no longer stopped. Stop it, then select the image.",
					},
				)
			} else {
				fat32session.image_info_destroy(&worker_result.info)
				selected := gui_hard_drive_select(
					ctx,
					&active_settings,
					&st,
					host.hard_drive_create_path(&create_model),
					create_machine_running,
					create_install_active,
				)
				if selected {
					host.hard_drive_create_accept_result(&create_model, {kind = .Image_Created})
					if install_resume_after_create {
						install_resume_after_create = false
						_ = guided_install_open(&guided_install, active_settings.hard_drive_path)
					}
				} else {
					host.hard_drive_create_accept_result(
						&create_model,
						{
							kind = .Image_Created_Unselected,
							diagnostic = "The image was created, but its selection could not be saved. Retry selection below.",
						},
					)
				}
			}
		}
		create_was_visible := create_model.visible
		create_action := host.hard_drive_create_draw(&create_model)
		if create_was_visible && !create_model.visible {install_resume_after_create = false}
		storage_machine_running, storage_install_active := gui_storage_lifecycle_snapshot(shared)
		create_blocked :=
			guided_install.phase != .Closed ||
			hard_drive_controller_is_open(&hard_drive_controller)
		if create_action.kind == .Request_Native_Dialog {
			if gui_storage_dispatch_allowed(
				storage_machine_running,
				storage_install_active,
				create_blocked,
			) {
				_ = pending_hard_drive_dialog_show(
					hard_drive_dialog_pending,
					h.win,
					create_action.dialog,
				)
			}
		} else if create_action.kind == .Cancel_Operation {
			if hard_drive_create_worker_cancel(&create_worker) {
				host.hard_drive_create_accept_result(
					&create_model,
					{
						kind = .Progress,
						progress = {
							active = true,
							completed = 0,
							total = 1,
							message = "Cancelling after the current creation step...",
							cancellable = false,
						},
					},
				)
			}
		} else if create_action.kind == .Select_Created_Image {
			selected :=
				gui_storage_dispatch_allowed(
					storage_machine_running,
					storage_install_active,
					create_blocked,
				) &&
				gui_hard_drive_select(
					ctx,
					&active_settings,
					&st,
					create_action.path,
					storage_machine_running,
					storage_install_active,
				)
			if selected {
				host.hard_drive_create_accept_result(&create_model, {kind = .Image_Created})
				if install_resume_after_create {
					install_resume_after_create = false
					_ = guided_install_open(&guided_install, active_settings.hard_drive_path)
				}
			} else {
				host.hard_drive_create_accept_result(
					&create_model,
					{
						kind = .Image_Created_Unselected,
						diagnostic = "The created image is still valid, but its selection could not be saved.",
					},
				)
			}
		} else if create_action.kind == .Create_Image {
			if !gui_storage_dispatch_allowed(
				storage_machine_running,
				storage_install_active,
				create_blocked,
			) {
				host.hard_drive_create_accept_result(
					&create_model,
					{kind = .Error, diagnostic = "Stop the machine before creating a hard drive."},
				)
			} else if hard_drive_create_worker_begin(
				&create_worker,
				create_action.path,
				u32(create_action.size_gib),
				create_action.allow_full_allocation,
			) {
				host.hard_drive_create_accept_result(
					&create_model,
					{
						kind = .Busy,
						progress = {
							active = true,
							completed = 0,
							total = 1,
							message = "Creating and validating the hard-drive image...",
							cancellable = true,
						},
					},
				)
			} else {
				host.hard_drive_create_accept_result(
					&create_model,
					{kind = .Error, diagnostic = "Hard-drive creation could not be started."},
				)
			}
		}
		hard_drive_controller.model.machine_running = st.machine_running
		hard_drive_controller_step(&hard_drive_controller)
		browser_action := host.hard_drive_browser_draw(
			&hard_drive_controller.model,
			&h.storage_icons,
		)
		storage_machine_running, storage_install_active = gui_storage_lifecycle_snapshot(shared)
		browser_blocked := guided_install.phase != .Closed || create_model.visible
		if browser_action.kind == .Cancel_Close {
			exit_requested = false
		} else if browser_action.kind == .Request_Native_Dialog {
			if gui_storage_dispatch_allowed(
				storage_machine_running,
				storage_install_active,
				browser_blocked,
			) {
				_ = pending_hard_drive_dialog_show(
					hard_drive_dialog_pending,
					h.win,
					browser_action.dialog,
				)
			}
		} else if browser_action.kind != .None {
			if gui_storage_dispatch_allowed(
				storage_machine_running,
				storage_install_active,
				browser_blocked,
			) {
				_ = hard_drive_controller_handle(&hard_drive_controller, browser_action)
			}
		}
		if exit_requested &&
		   hard_drive_controller_prepare_application_exit(&hard_drive_controller) &&
		   push_cmd(shared, Command{kind = .Power_Off}) {
			exit_requested = false
		}
		install_status := install_prepare_status_snapshot(shared)
		guided_install_status_update(&guided_install, install_status)
		install_action := guided_install_draw(&guided_install, install_status)
		storage_machine_running, storage_install_active = gui_storage_lifecycle_snapshot(shared)
		install_action_allowed := gui_storage_dispatch_allowed(
			storage_machine_running,
			storage_install_active,
			create_model.visible || hard_drive_controller_is_open(&hard_drive_controller),
		)
		switch install_action.kind {
		case .Request_ISO:
			if install_action_allowed {
				if !pending_hard_drive_dialog_show(
					hard_drive_dialog_pending,
					h.win,
					guided_install_iso_dialog(),
				) {
					guided_install_dialog_error(
						&guided_install,
						"Another file dialog is already open.",
					)
				}
			}
		case .Request_Boot_Floppy:
			if install_action_allowed {
				if !pending_hard_drive_dialog_show(
					hard_drive_dialog_pending,
					h.win,
					guided_install_boot_dialog(),
				) {
					guided_install_dialog_error(
						&guided_install,
						"Another file dialog is already open.",
					)
				}
			}
		case .Prepare:
			if install_action_allowed {
				install_prepare_status_queue(shared)
				guided_install_prepare_started(&guided_install, install_status.generation)
				queued := push_cmd(
					shared,
					Command {
						kind = .Install_Windows_98,
						path = strings.clone(install_action.iso_path),
						boot_path = strings.clone(install_action.boot_path),
						locale_language = strings.clone(preferred_locale.language),
						locale_country = strings.clone(preferred_locale.country),
					},
				)
				if !queued {
					install_prepare_status_finish(
						shared,
						false,
						"Windows 98 preparation could not be queued",
					)
				}
			} else {
				guided_install_dialog_cancel(&guided_install)
			}
		case .Cancel_Prepare:
			install_prepare_cancel_request(shared)
		case .Close:
			guided_install_destroy(&guided_install)
		case .None:
		}
		if graphics_epoch_pending &&
		   (!st.machine_running ||
				   !frame_mailbox_graphics_epoch_current(&shared.frames, &graphics_epoch)) {
			graphics_epoch_reset = true
			_ = graphics_presentation_sync_lifecycle(&h, &shared.frames, st.machine_running)
			if postmortem_state_valid {
				postmortem_state.host_stage = .Failed
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
		}
		imgui.Render()
		imgui_impl_sdlrenderer3.RenderDrawData(imgui.GetDrawData(), h.ren)
		graphics_present_started := time.tick_now()
		if graphics_epoch_pending {
			if postmortem_state_valid {
				postmortem_state.host_stage = .Present
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
			graphics_frame_epoch_present_begin(&graphics_epoch, graphics_present_started)
		}
		host.host_screenshot_capture(&h, &screenshot, time.tick_now())
		present_ok := sdl3.RenderPresent(h.ren)
		graphics_presented := time.tick_now()
		frame_mailbox_graphics_telemetry_note_present(
			&shared.frames,
			graphics_present_started,
			graphics_presented,
		)
		if graphics_epoch_pending {
			result := present_ok ? Graphics_Frame_Result.Presented : .Present_Failed
			if graphics_epoch_reset || !st.machine_running {
				result = .Reset
			}
			result = frame_mailbox_graphics_epoch_complete_and_record(
				&shared.frames,
				&graphics_epoch,
				result,
				graphics_presented,
			)
			if postmortem_state_valid {
				postmortem_state.host_stage = result == .Presented ? .Complete : .Failed
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
		}
		if !present_ok && graphics_trace {
			fmt.eprintfln("graphics presentation failed: %s", sdl3.GetError())
		}
		if graphics_trace {
			if graphics_window, ready := frame_mailbox_graphics_telemetry_take_window(
				&shared.frames,
				graphics_presented,
			); ready {
				text := graphics_telemetry_window_text(graphics_window)
				if graphics_telemetry_aggregate_log_admit(&graphics_aggregate_logs) {
					fmt.println(text)
				}
				_ = graphics_postmortem_publish_window(
					&shared.graphics_postmortem,
					text,
					graphics_window.latest_epoch,
					.Derived,
					.Measured,
				)
				delete(text)
			}
		}
		if !h.vsync {time.sleep(8 * time.Millisecond)} 	// no vsync: pace manually

		free_all(context.temp_allocator)

		if auto_close_after >= 0 &&
		   time.duration_seconds(time.tick_since(start)) >= f64(auto_close_after) {
			exit_requested = true
			auto_close_after = -1
		}
	}
	if settings_save_pending {
		if diagnostic := profile.settings_save(paths.settings, active_settings);
		   diagnostic != .None {
			fmt.eprintfln("settings: final retry failed (%v)", diagnostic)
		}
	}
	sdl3.RemoveEventWatch(lifecycle_event_watch, &lifecycle_watch)
	lifecycle_watch_registered = false
	pending_mount_release(floppy_pending)
	floppy_pending = nil
	pending_mount_release(cdrom_pending)
	cdrom_pending = nil
	pending_hard_drive_dialog_release(hard_drive_dialog_pending)
	hard_drive_dialog_pending = nil
	for path in dropped_paths {delete(path)}
	delete(dropped_paths)
	hard_drive_controller_destroy(&hard_drive_controller)
	guided_install_destroy(&guided_install)

	if input_control_exclusive {input_control_release_mouse(&input_control, shared)}
	thread.destroy(vm_thr)
	control_exit_failed := false
	if input_control_exclusive {
		sync.lock(&shared.mu)
		input_control_note_reset_cancelled_locked(shared)
		host.host_input_discard(&shared.input)
		control_stats := shared.input_control_stats
		control_pending := host.host_input_control_pending(&shared.input)
		sync.unlock(&shared.mu)
		correlation := frame_mailbox_graphics_input_correlation(&shared.frames)
		resolved := input_control_stats_resolved(control_stats)
		unresolved := u64(0)
		if control_stats.queued > resolved {unresolved = control_stats.queued - resolved}
		over_resolved := u64(0)
		if resolved > control_stats.queued {over_resolved = resolved - control_stats.queued}
		control_success := input_control_exit_success(
			&input_control,
			control_stats,
			control_pending,
		)
		correlation_success := input_control_correlation_success(
			graphics_trace,
			control_stats.applied,
			correlation,
		)
		control_exit_failed = !control_success || !correlation_success
		fmt.printfln(
			"control input: state=%v failure=%v success=%v actions=%d queued=%d applied=%d stale_dropped=%d reset_cancelled=%d resolved=%d unresolved=%d over_resolved=%d pending=%d correlated_events=%d correlated_presentations=%d correlation_success=%v correlation_avg_us=%d correlation_p50_us=%d correlation_p95_us=%d correlation_p99_us=%d correlation_max_us=%d correlation_retained=%d correlation_capacity=%d correlation_dropped=%d correlation_retention_enabled=%v correlation_overflowed=%v correlation_percentiles_valid=%v",
			input_control.state,
			input_control.failure,
			control_success,
			len(input_control.script.actions),
			control_stats.queued,
			control_stats.applied,
			control_stats.stale_dropped,
			control_stats.reset_cancelled,
			resolved,
			unresolved,
			over_resolved,
			control_pending,
			correlation.events,
			correlation.samples,
			correlation_success,
			correlation.total_ns / max(correlation.samples, u64(1)) / u64(time.Microsecond),
			correlation.p50_ns / u64(time.Microsecond),
			correlation.p95_ns / u64(time.Microsecond),
			correlation.p99_ns / u64(time.Microsecond),
			correlation.max_ns / u64(time.Microsecond),
			correlation.retained_samples,
			correlation.retention_capacity,
			correlation.retention_dropped,
			correlation.retention_enabled,
			correlation.retention_overflowed,
			correlation.percentiles_valid,
		)
	}
	if graphics_trace {
		trace := frame_mailbox_graphics_trace_text(&shared.frames)
		if trace != "" {
			fmt.println("graphics trace:")
			fmt.print(trace)
		}
		delete(trace)
	}

	imgui_impl_sdlrenderer3.Shutdown()
	imgui_impl_sdl3.Shutdown()
	imgui.DestroyContext()
	host.host_destroy(&h)

	fmt.print("exit stats:")
	for kind in hv.Exit_Kind {
		fmt.printf(" %v=%d", kind, shared.exit_stats[kind])
	}
	fmt.println()
	if control_exit_failed {return 1}
	return 0
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

install_state_clone :: proc(state: ^profile.Install_State) -> profile.Install_State {
	if state == nil {return {}}
	return profile.Install_State {
		phase = state.phase,
		milestone = state.milestone,
		source_path = strings.clone(state.source_path),
		image_path = strings.clone(state.image_path),
		image_identity = state.image_identity,
		edit_transaction_id = state.edit_transaction_id,
		reset_count = state.reset_count,
		saved_cmos_valid = state.saved_cmos_valid,
		saved_cmos_38 = state.saved_cmos_38,
		saved_cmos_3d = state.saved_cmos_3d,
	}
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
	state := profile.Install_State {
		phase            = .Preparing,
		source_path      = strings.clone(source_path),
		saved_cmos_valid = saved_cmos_valid,
		saved_cmos_38    = saved_cmos_38,
		saved_cmos_3d    = saved_cmos_3d,
	}
	if profile.install_state_bound(previous) {
		state.image_path = strings.clone(previous.image_path)
		state.image_identity = previous.image_identity
		state.edit_transaction_id = previous.edit_transaction_id
	}
	return state
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
	if s == nil {return}
	new_msg := strings.clone(msg)
	new_regs := strings.clone(regs)
	sync.lock(&s.mu)
	old_msg := s.frozen_msg
	old_msg_owned := s.frozen_msg_owned
	old_regs := s.regs_text
	old_regs_owned := s.regs_text_owned
	s.frozen_msg = new_msg
	s.frozen_msg_owned = true
	s.regs_text = new_regs
	s.regs_text_owned = true
	sync.unlock(&s.mu)
	if old_msg_owned {delete(old_msg)}
	if old_regs_owned {delete(old_regs)}
}

publish_pause_state :: proc(s: ^Shared, state: host.Pause_State) {
	if s == nil {return}
	sync.lock(&s.mu)
	s.pause_state = state
	sync.unlock(&s.mu)
}

publish_machine_running :: proc(s: ^Shared, running: bool) {
	if s == nil {return}
	sync.lock(&s.mu)
	if s.machine_running != running && !s.input_generation_exhausted {
		if s.input_generation == max(u64) {
			s.input_generation_exhausted = true
			input_control_note_reset_cancelled_locked(s)
			host.host_input_discard(&s.input)
		} else {
			s.input_generation += 1
		}
	}
	s.machine_running = running
	sync.unlock(&s.mu)
}

publish_machine_reinitializing :: proc(s: ^Shared) {
	publish_machine_running(s, false)
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
	if s == nil {return}
	sync.lock(&s.mu)
	for line in s.log_lines {delete(line)}
	delete(s.log_lines)
	s.log_lines = nil
	if s.frozen_msg_owned {delete(s.frozen_msg)}
	if s.regs_text_owned {delete(s.regs_text)}
	s.frozen_msg = ""
	s.regs_text = ""
	s.frozen_msg_owned = false
	s.regs_text_owned = false
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
	selected_image_path := attach ? settings.hard_drive_path : ""
	install_gate := install_image_boot_gate_loaded(
		&install_state,
		selected_image_path,
		install_diagnostic,
	)
	if !install_gate.allowed {
		fmt.eprintfln(
			"Windows 98: start blocked: %s",
			install_image_boot_diagnostic_text(&install_gate),
		)
		return 1
	}
	runtime_cpu_mode := install_runtime_cpu_mode(settings.cpu_mode, &install_state)
	runtime_settings := settings
	runtime_settings.cpu_mode = runtime_cpu_mode
	run_result.cpu_mode = console_cpu_mode_name(runtime_cpu_mode)
	if install_diagnostic != .None && install_diagnostic != .Missing {
		fmt.eprintfln("Windows 98: install state ignored (%v)", install_diagnostic)
	}
	fat_session: ^fat32session.Machine_Session
	machine_session_id := strings.clone(machine_session_id_now(.Console))
	defer delete(machine_session_id)
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
			nil,
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
	defer {
		if fat_session != nil {
			if machine_live {_ = machine.machine_detach_disk(m)}
			close_error := fat32session.close(fat_session, .Commit)
			if close_error.code == .None || close_error.outcome == .Completed {
				fat_session = nil
			}
			if close_error.code != .None && close_error.outcome != .Completed {
				fmt.eprintfln(
					"disk: close failed; FAT32 session retained: %s",
					fat32session.error_text(&close_error),
				)
				_ = fat32session.close(fat_session, .Retain)
				fat_session = nil
				result = 2
				run_result.stop_reason = .Fatal_Virtualization_Failure
				run_result.exit_code = result
			} else if close_error.code != .None {
				fmt.eprintfln(
					"disk: close completed with a companion cleanup warning: %s",
					fat32session.error_text(&close_error),
				)
			}
		}
	}
	defer console_acceptance_finalize(
		&run_options,
		&run_result,
		m,
		&machine_live,
		&firmware,
		&fat_session,
		paths,
		start,
		&result,
		&machine_segment_accumulated,
	)
	guest_report: acceptance.Guest_Report_Collector
	guest_report_artifacts := run_options.test_device ? run_options.artifacts : ""
	acceptance.guest_report_init(&guest_report, guest_report_artifacts)
	defer acceptance.guest_report_destroy(&guest_report)
	defer {
		_ = acceptance.guest_report_finalize_partial(&guest_report)
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
	machine.machine_set_bus_diagnostic_tracing(m, options.setup_diagnostics == .Hardware)
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

	if attach && settings.hard_drive_path != "" {
		open_error: fat32session.Session_Error
		fat_session, open_error = fat32session.open_machine(
			settings.hard_drive_path,
			machine_session_id,
		)
		if open_error.code != .None {
			fmt.eprintfln("FAT32 session open failed: %s", fat32session.error_text(&open_error))
			return 1
		}
		machine.machine_attach_disk(m, fat32session.block_device(fat_session))
		fmt.printfln("disk: %s", settings.hard_drive_path)
	} else {
		fmt.println("disk: none")
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
	setup_log_baseline := console_log_total_size(fat_session, setup_log_names)
	detection_log_baseline := console_log_total_size(fat_session, detection_log_names)
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
	composed: []u32
	defer delete(composed)
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
	if !console_acceptance_profile_ready(
		options.accept_until,
		&install_state,
		install_diagnostic,
	) {
		fmt.eprintln("acceptance: target requires a valid Windows 98 installation state")
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
		if storage_error, terminal := fat32session.session_terminal_error(fat_session); terminal {
			fmt.eprintfln(
				"disk: terminal FAT32 session failure: %s",
				fat32session.error_text(&storage_error),
			)
			run_result.stop_reason = .Fatal_Virtualization_Failure
			result = 2
			run_result.exit_code = result
			break loop
		}
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
		if options.artifacts != "" {console_drain_serial(options.artifacts, m)}
		if diagnostic, available := machine.machine_take_runtime_diagnostic(m); available {
			fmt.println(diagnostic)
			delete(diagnostic)
		}
		switch command := machine.machine_test_device_take_command(m); command {
		case .Crc:
			_ = machine.machine_test_device_frame_crc(m)
		case .Snapshot:
			taken := false
			if options.artifacts != "" {
				frame := machine.machine_display_frame(m)
				label := machine.machine_test_device_snapshot_index(m)
				taken =
					acceptance.artifact_write_snapshot(
						options.artifacts,
						label,
						frame.pixels,
						frame.width,
						frame.height,
					) ==
					.None
				console_note_capture(options.artifacts, "canvas", label, m, frame)
			}
			// A guest that waits for this is still standing where it asked, so the
			// frame it captured is the one it meant. One that does not wait races
			// its own next mode change.
			machine.machine_test_device_set_report_status(m, taken ? 1 : 2)
		case .Composed_Snapshot:
			taken := false
			if options.artifacts != "" {
				frame := machine.machine_display_frame(m)
				label := machine.machine_test_device_snapshot_index(m)
				if console_compose_frame(&composed, frame) {
					taken =
						acceptance.artifact_write_composed(
							options.artifacts,
							label,
							composed,
							host.WIN_W,
							host.WIN_H,
						) ==
						.None
					console_note_capture(options.artifacts, "composed", label, m, frame)
				}
			}
			machine.machine_test_device_set_report_status(m, taken ? 1 : 2)
		case .Exit:
			run_result.stop_reason = .Test_Exit
			run_result.test_exit_code = machine.machine_test_device_exit_code(m)
			result = console_terminal_exit_code(
				options.accept_until,
				run_result.test_exit_code == 0,
			)
			run_result.exit_code = result
			break loop
		case .Begin_Report:
			status := acceptance.guest_report_begin(&guest_report)
			machine.machine_test_device_set_report_status(m, u8(status))
		case .Append_Report:
			payload, payload_ok := machine.machine_test_device_report_payload(m)
			status := acceptance.Guest_Report_Status.Artifacts_Disabled
			if guest_report_artifacts != "" {
				status = .Bad_Length
			}
			if payload_ok {
				status = acceptance.guest_report_append(&guest_report, payload)
			}
			machine.machine_test_device_set_report_status(m, u8(status))
		case .Commit_Report:
			status := acceptance.guest_report_commit(&guest_report)
			machine.machine_test_device_set_report_status(m, u8(status))
		case .Abort_Report:
			status := acceptance.guest_report_abort(&guest_report)
			machine.machine_test_device_set_report_status(m, u8(status))
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
				reset_source := machine.machine_reset_provenance(m)
				if !console_acceptance_cpu_reset_allowed(
					options.accept_until,
					reset_source,
					profile.install_state_active(&install_state),
				) {
					firmware_log_host_flush(&firmware, nil)
					fmt.printfln(
						"unexpected CPU reset after %d iterations: %s",
						iterations,
						machine.machine_cpu_reset_reason(m),
					)
					run_result.stop_reason = .Fatal_Virtualization_Failure
					run_result.last_progress_reason = "unexpected_cpu_reset"
					result = 2
					run_result.exit_code = result
					break loop
				}
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
				if options.accept_until == .Desktop {
					desktop_marker_seen = false
					run_result.desktop_marker_seen = false
					run_result.desktop_enum_valid = false
					run_result.desktop_vga_irq11_seen = false
					desktop_graphics = {}
				}
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
					&fat_session,
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
							"machine reset blocked: disk durability barrier failed; recovery state retained",
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
						run_result.execution.primary_ide_kernel_dma_transactions
					primary_dma_epoch_baseline_bytes =
						run_result.execution.primary_ide_kernel_dma_bytes
					if options.accept_until == .Desktop {
						desktop_marker_seen = false
						run_result.desktop_marker_seen = false
						run_result.desktop_enum_valid = false
						run_result.desktop_vga_irq11_seen = false
						run_result.desktop_primary_ide_dma_transactions = 0
						run_result.desktop_primary_ide_dma_bytes = 0
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
			if !shown || !vga.text_snapshot_equal(&snap, &prev) {
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
			console_desktop_profile_probe_ready(&install_state) &&
			!desktop_marker_seen
		if console_setup_artifact_poll_due(
			install_state.reset_count,
			detection_pending,
			desktop_pending,
			&setup_artifact_reset_count,
			&last_setup_artifact_check,
			now,
		) {
			materialized := fat_session == nil
			barrier_error: fat32session.Session_Error
			if fat_session != nil {
				barrier_result: fat32session.Barrier_Result
				barrier_result, barrier_error = fat32session.barrier(fat_session, .Observation)
				materialized =
					barrier_error.code == .None && barrier_result.materialization == .Materialized
			}
			last_setup_artifact_check = time.tick_now()
			if !materialized && barrier_error.code != .None {
				fmt.eprintfln(
					"Windows 98: C: observation barrier failed: %s",
					fat32session.error_text(&barrier_error),
				)
				run_result.stop_reason = .Fatal_Virtualization_Failure
				result = 2
				run_result.exit_code = result
				break loop
			}
			if materialized && detection_pending {
				setup_size := console_log_total_size(fat_session, setup_log_names)
				detection_size := console_log_total_size(fat_session, detection_log_names)
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
			if materialized && desktop_pending {
				enum_evidence, marker_seen, enum_valid := console_desktop_marker_evidence(
					fat_session,
				)
				primary_dma_transactions, primary_dma_bytes :=
					console_primary_ide_kernel_dma_evidence(
						&run_result,
						m,
						machine_segment_accumulated,
						primary_dma_epoch_baseline_transactions,
						primary_dma_epoch_baseline_bytes,
					)
				run_result.desktop_primary_ide_dma_transactions = primary_dma_transactions
				run_result.desktop_primary_ide_dma_bytes = primary_dma_bytes
				run_result.desktop_marker_seen = marker_seen
				run_result.desktop_enum_valid = enum_valid
				run_result.desktop_vga_irq11_seen = enum_evidence.vga_irq11_seen
				if marker_seen && enum_valid {
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
			if profile.install_state_active(&install_state) {
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
// The composed buffer is the default window client area, so a capture shows the
// same letterboxing and border proportion a freshly opened window would.
console_compose_frame :: proc(buffer: ^[]u32, frame: ^vga.Display_Frame) -> bool {
	if frame == nil {return false}
	needed := host.host_composite_size(host.WIN_W, host.WIN_H)
	if needed == 0 {return false}
	if len(buffer^) != needed {
		if buffer^ != nil {delete(buffer^)}
		buffer^ = make([]u32, needed)
	}
	return host.host_composite_guest_view(
		buffer^,
		host.WIN_W,
		host.WIN_H,
		frame.pixels,
		frame.width,
		frame.height,
		host.host_border_from_contract(frame.border),
		frame.overscan,
	)
}

// Guest serial output is drained as the run goes rather than at the end, so a
// guest that never reaches a clean exit still leaves its driver trace behind.
console_drain_serial :: proc(directory: string, m: ^machine.Machine) {
	bytes := machine.machine_take_serial_output(m)
	if len(bytes) == 0 {return}
	_ = acceptance.artifact_append_serial(directory, bytes)
	machine.machine_clear_serial_output(m)
}

console_note_capture :: proc(
	directory: string,
	kind: string,
	label: u8,
	m: ^machine.Machine,
	frame: ^vga.Display_Frame,
) {
	if frame == nil {return}
	_ = acceptance.artifact_append_capture(
		directory,
		{
			kind = kind,
			label = label,
			time_ns = machine.machine_active_ns(m),
			canvas_width = frame.width,
			canvas_height = frame.height,
			left = frame.border.left,
			right = frame.border.right,
			top = frame.border.top,
			bottom = frame.border.bottom,
			overscan = frame.overscan,
		},
	)
}

console_dump_frame :: proc(path: string, frame: ^vga.Display_Frame) {
	if frame == nil {return}
	diagnostic := acceptance.artifact_write_frame(path, frame.pixels, frame.width, frame.height)
	if diagnostic != .None {fmt.eprintfln("frame dump failed: %v", diagnostic)}
}

publish_cdrom_state :: proc(
	s: ^Shared,
	mounted: bool,
	actual_path: string = "",
	requested_path: string = "",
	diagnostic: string = "",
	persist: bool = false,
) {
	media_state_publish_result(
		s,
		.Cdrom,
		true,
		mounted,
		actual_path,
		requested_path,
		diagnostic,
		persist,
	)
	sync.lock(&s.mu)
	s.cdrom_mounted = mounted
	sync.unlock(&s.mu)
}

publish_floppy_state :: proc(
	s: ^Shared,
	mounted: bool,
	actual_path: string = "",
	requested_path: string = "",
	diagnostic: string = "",
	persist: bool = false,
) {
	media_state_publish_result(
		s,
		.Floppy,
		true,
		mounted,
		actual_path,
		requested_path,
		diagnostic,
		persist,
	)
	sync.lock(&s.mu)
	s.floppy_mounted = mounted
	sync.unlock(&s.mu)
}

publish_media_failure :: proc(s: ^Shared, kind: Media_Kind, requested_path, diagnostic: string) {
	media_state_publish_result(s, kind, false, false, "", requested_path, diagnostic, false)
}

publish_install_state :: proc(s: ^Shared, installing: bool) {
	sync.lock(&s.mu)
	s.installing_windows_98 = installing
	sync.unlock(&s.mu)
}

publish_install_recovery_state :: proc(s: ^Shared, recovery_required: bool) {
	sync.lock(&s.mu)
	s.install_recovery_required = recovery_required
	sync.unlock(&s.mu)
}

print_grid :: proc(snap: vga.Text_Snapshot) {
	snapshot := snap
	columns := vga.text_snapshot_columns(&snapshot)
	rows := vga.text_snapshot_rows(&snapshot)
	fmt.print("vga: +")
	for _ in 0 ..< columns {fmt.print("-")}
	fmt.println("+")
	for row in 0 ..< rows {
		buf: [vga.TEXT_SNAPSHOT_MAX_COLUMNS]u8
		for col in 0 ..< columns {
			ch := u8(snapshot.cells[vga.text_snapshot_cell_index(&snapshot, row, col)])
			buf[col] = ch >= 0x20 && ch < 0x7F ? ch : ' '
		}
		fmt.printfln("vga: |%s|", string(buf[:columns]))
	}
	fmt.print("vga: +")
	for _ in 0 ..< columns {fmt.print("-")}
	fmt.println("+")
	fmt.printfln(
		"vga: %dx%d cursor row=%d col=%d on=%v",
		columns,
		rows,
		snap.cursor_row,
		snap.cursor_col,
		snap.cursor_on,
	)
}
