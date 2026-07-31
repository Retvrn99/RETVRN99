// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "fat32session"
import "host"
import "hv"
import "machine"
import "profile"
import "vmconfig"
import video "videopresentation"
import "win98imageprep"

GUI_INSTALL_COMPLETION_POLL_INTERVAL :: 2 * time.Second

gui_install_completion_poll_due :: proc(
	state: ^profile.Install_State,
	machine_live, frozen, volume_ready: bool,
	last_check, now: time.Tick,
) -> bool {
	return(
		state != nil &&
		state.phase == .Setup_Running &&
		state.reset_count > 0 &&
		machine_live &&
		!frozen &&
		volume_ready &&
		time.tick_diff(last_check, now) >= GUI_INSTALL_COMPLETION_POLL_INTERVAL \
	)
}

gui_install_completion_marker_exists :: proc(session: ^fat32session.Machine_Session) -> bool {
	if session == nil {return false}
	probes := [?]fat32session.Probe {
		{.Read_Range, fmt.tprintf("GSWSETUP/%s", win98imageprep.DESKTOP_MARKER_FILE), 0, 64},
	}
	batch, observe_error := fat32session.observe(session, probes[:], context.temp_allocator)
	defer fat32session.observation_batch_destroy(&batch, context.temp_allocator)
	if observe_error.code != .None || batch.pending || len(batch.items) != 1 {return false}
	marker := &batch.items[0]
	return(
		marker.type == .Regular &&
		marker.size > 0 &&
		marker.size <= 64 &&
		strings.trim_space(string(marker.data)) == "READY" \
	)
}

gui_guest_power_off_complete :: proc(s: ^Shared, reason: string) {
	if s == nil {return}
	publish_freeze(s, "", "")
	publish_machine_running(s, false)
	vm_log(s, fmt.tprintf("machine: stopped (%s)", reason))
}

// --- VM thread ---

vm_thread_proc :: proc(c: ^Vm_Ctx) {
	context.logger = log.create_console_logger(.Info, {.Level})
	s := c.shared
	m := new(machine.Machine)
	pause_state: host.Pause_State

	preparation_blocked := !install_state_boot_allowed(&c.install_state)
	machine_live := false
	publish_machine_running(s, machine_live)
	if preparation_blocked {
		message := "Windows 98: interrupted preparation is blocked; choose Install Windows 98 to retry"
		if !c.preparation_recovered {
			message = "Windows 98: interrupted preparation recovery is ambiguous; retained files were preserved"
		}
		publish_freeze(s, message, "")
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
	last_install_completion_check := last_snap
	storage_activity_session: u64
	graphics_vm_execution: Graphics_Vm_Execution_Sample

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
				delete(cmd.boot_path)
				delete(cmd.locale_language)
				delete(cmd.locale_country)
				continue
			}
			switch cmd.kind {
			case .Start, .Reset:
				starting := cmd.kind == .Start
				if starting && machine_live {continue}
				if !starting && !machine_live {continue}
				install_gate := Install_Image_Boot_Result {
					allowed = true,
				}
				if starting {
					selected_image_path := c.attach ? c.hard_drive_path : ""
					install_gate = install_image_boot_gate_loaded(
						&c.install_state,
						selected_image_path,
						c.install_state_diagnostic,
					)
				}
				preparation_blocked =
					!install_state_boot_allowed(&c.install_state) || !install_gate.allowed
				state_ready :=
					!preparation_blocked &&
					(!profile.install_state_active(&c.install_state) ||
							install_state_save(c, "before manual reset"))
				launch_ready := state_ready && install_launch_prepare(c)
				reset_diagnostic := Vm_Reinitialize_Diagnostic.None
				if launch_ready && starting {
					if !vm_start_machine(c, m, &machine_live, !host.pause_active(&pause_state)) {
						reset_diagnostic = .Machine_Init_Failed
						if c.volume_open_error.code != .None {
							reset_diagnostic = .Volume_Open_Failed
						}
					}
				} else if launch_ready {
					publish_machine_reinitializing(s)
					reset_diagnostic = vm_reinitialize_machine(
						c,
						m,
						&machine_live,
						!host.pause_active(&pause_state),
					)
				}
				if launch_ready && reset_diagnostic == .None && machine_live {
					storage_activity_session += 1
					stats = {}
					frozen = false
					publish_freeze(s, "", "")
					vm_log(
						s,
						fmt.tprintf(
							"machine: %s (%s)",
							starting ? "started" : "reset",
							vmconfig.cpu_mode_name(
								install_runtime_cpu_mode(c.cpu_mode, &c.install_state),
							),
						),
					)
				} else if preparation_blocked {
					frozen = true
					message := "reset blocked: interrupted Windows 98 preparation must be retried or finished"
					if !install_gate.allowed {
						message = fmt.tprintf(
							"start blocked: %s",
							install_image_boot_diagnostic_text(&install_gate),
						)
					}
					publish_freeze(s, message, "")
				} else if !launch_ready {
					frozen = true
					publish_freeze(
						s,
						"reset blocked: Windows 98 install state or direct launch could not be persisted",
						"",
					)
				} else if reset_diagnostic == .Durability_Failed {
					frozen = true
					publish_freeze(
						s,
						"reset blocked: disk durability barrier failed; recovery state retained; retry Reset or Exit",
						"",
					)
				} else if reset_diagnostic == .Volume_Open_Failed {
					frozen = true
					publish_freeze(
						s,
						vm_volume_open_failure_message(c, starting ? "start" : "reset"),
						"",
					)
				} else {
					frozen = true
					publish_freeze(s, "reset failed: machine init error", "")
				}
				publish_machine_running(s, machine_live)
			case .Stop:
				if !machine_live {continue}
				if !vm_close_then_shutdown(c, m, &machine_live) {
					frozen = true
					publish_freeze(
						s,
						"disk close failed; recovery state was retained; retry Stop",
						"",
					)
					continue
				}
				frozen = false
				publish_freeze(s, "", "")
				publish_machine_running(s, false)
				vm_log(s, "machine: stopped")
			case .Power_Off:
				if !vm_close_then_shutdown(c, m, &machine_live) {
					frozen = true
					publish_freeze(s, "disk close failed; recovery state retained; retry Exit", "")
					continue
				}
				sync.lock(&s.mu)
				s.running = false
				s.machine_running = false
				sync.unlock(&s.mu)
				quit = true
			case .Mount_Floppy:
				if install_state_storage_locked(&c.install_state, c.install_state_diagnostic) {
					publish_media_failure(
						s,
						.Floppy,
						cmd.path,
						"Windows 98 installation locks removable media",
					)
					vm_log(
						s,
						"floppy: Windows 98 installation or recovery state locks media controls",
					)
					delete(cmd.path)
					continue
				}
				if img, err := os.read_entire_file_from_path(cmd.path, context.allocator);
				   err == nil {
					valid := len(img) == 1_474_560
					if valid && (!machine_live || machine.machine_mount_floppy(m, img)) {
						delete(c.floppy)
						c.floppy = img
						delete(c.floppy_path)
						c.floppy_path = strings.clone(cmd.path)
						delete(c.user_floppy)
						c.user_floppy = media_clone_bytes(img)
						delete(c.user_floppy_path)
						c.user_floppy_path = strings.clone(cmd.path)
						publish_floppy_state(s, true, c.floppy_path, "", "", true)
						vm_log(s, fmt.tprintf("floppy: mounted %s", cmd.path))
					} else {
						diagnostic := fmt.tprintf("%s is not a readable 1.44MB image", cmd.path)
						publish_media_failure(s, .Floppy, cmd.path, diagnostic)
						vm_log(s, fmt.tprintf("floppy: %s", diagnostic))
						delete(img)
					}
				} else {
					publish_media_failure(s, .Floppy, cmd.path, "The image could not be read")
					vm_log(s, fmt.tprintf("floppy: cannot read %s", cmd.path))
				}
				delete(cmd.path)
			case .Eject_Floppy:
				if install_state_storage_locked(&c.install_state, c.install_state_diagnostic) {
					vm_log(
						s,
						"floppy: Windows 98 installation or recovery state locks media controls",
					)
					continue
				}
				if machine_live {machine.machine_eject_floppy(m)}
				delete(c.floppy)
				c.floppy = nil
				delete(c.floppy_path)
				c.floppy_path = ""
				delete(c.user_floppy)
				c.user_floppy = nil
				delete(c.user_floppy_path)
				c.user_floppy_path = ""
				publish_floppy_state(s, false, "", "", "", true)
				vm_log(s, "floppy: ejected")
			case .Mount_Cdrom:
				if install_state_storage_locked(&c.install_state, c.install_state_diagnostic) {
					publish_media_failure(
						s,
						.Cdrom,
						cmd.path,
						"Windows 98 installation locks removable media",
					)
					vm_log(
						s,
						"CD-ROM: Windows 98 installation or recovery state locks media controls",
					)
					delete(cmd.path)
					continue
				}
				if !machine_live {
					if !cdrom_path_supported(cmd.path) {
						publish_media_failure(
							s,
							.Cdrom,
							cmd.path,
							"The disc image is unsupported or unreadable",
						)
						vm_log(
							s,
							fmt.tprintf("CD-ROM: unsupported or unreadable image %s", cmd.path),
						)
						delete(cmd.path)
						continue
					}
					delete(c.cdrom_path)
					c.cdrom_path = strings.clone(cmd.path)
					delete(c.user_cdrom_path)
					c.user_cdrom_path = strings.clone(cmd.path)
					publish_cdrom_state(s, true, c.cdrom_path, "", "", true)
					vm_log(s, fmt.tprintf("CD-ROM: selected %s", c.cdrom_path))
					delete(cmd.path)
					continue
				}
				if machine.machine_mount_cdrom(m, cmd.path) {
					delete(c.cdrom_path)
					c.cdrom_path = strings.clone(cmd.path)
					delete(c.user_cdrom_path)
					c.user_cdrom_path = strings.clone(cmd.path)
					publish_cdrom_state(s, true, c.cdrom_path, "", "", true)
					vm_log(s, fmt.tprintf("CD-ROM: mounted %s", c.cdrom_path))
				} else {
					publish_media_failure(
						s,
						.Cdrom,
						cmd.path,
						"The disc image is unsupported or unreadable",
					)
					vm_log(s, fmt.tprintf("CD-ROM: unsupported or unreadable image %s", cmd.path))
				}
				delete(cmd.path)
			case .Eject_Cdrom:
				if install_state_storage_locked(&c.install_state, c.install_state_diagnostic) {
					vm_log(
						s,
						"CD-ROM: Windows 98 installation or recovery state locks media controls",
					)
					continue
				}
				if !machine_live {
					delete(c.cdrom_path)
					c.cdrom_path = ""
					delete(c.user_cdrom_path)
					c.user_cdrom_path = ""
					publish_cdrom_state(s, false, "", "", "", true)
					vm_log(s, "CD-ROM: ejected")
					continue
				}
				machine.machine_eject_cdrom(m)
				delete(c.cdrom_path)
				c.cdrom_path = ""
				delete(c.user_cdrom_path)
				c.user_cdrom_path = ""
				publish_cdrom_state(s, false, "", "", "", true)
				vm_log(s, "CD-ROM: ejected")
			case .Install_Windows_98:
				if machine_live {
					vm_log(s, "Windows 98: stop the machine before starting installation")
					install_prepare_status_finish(
						s,
						false,
						"Stop the machine before starting Windows 98 installation.",
					)
					delete(cmd.path)
					delete(cmd.boot_path)
					delete(cmd.locale_language)
					delete(cmd.locale_country)
					continue
				}
				if install_state_storage_locked(&c.install_state, c.install_state_diagnostic) {
					vm_log(
						s,
						"Windows 98: abandon the retained installation state before starting another installation",
					)
					install_prepare_status_finish(
						s,
						false,
						"Abandon the retained Windows 98 installation before starting another one.",
					)
					delete(cmd.path)
					delete(cmd.boot_path)
					delete(cmd.locale_language)
					delete(cmd.locale_country)
					continue
				}
				if !c.allow_hard_drive || c.hard_drive_path == "" {
					vm_log(s, "Windows 98: create or select a hard drive before installation")
					delete(cmd.path)
					delete(cmd.boot_path)
					delete(cmd.locale_language)
					delete(cmd.locale_country)
					continue
				}
				publish_install_state(s, true)
				_ = install_prepare_status_begin(s)
				vm_log(s, fmt.tprintf("Windows 98: preparing %s through RETVRN99-FAT32", cmd.path))
				boot_path := cmd.boot_path
				if boot_path == "" {boot_path = c.floppy_path}
				prepare_options := guided_install_prepare_options(
					{language = cmd.locale_language, country = cmd.locale_country},
				)
				flow := install_image_prepare(
					&c.paths,
					&c.install_state,
					c.hard_drive_path,
					cmd.path,
					boot_path,
					c.cmos[:],
					c.has_cmos,
					prepare_options,
					win98imageprep.Cancellation{ctx = s, check = install_prepare_cancel_check},
				)
				if profile.install_state_bound(&c.install_state) {
					c.install_state_diagnostic = .None
				}
				if flow.error.code != .None {
					failure_message := fmt.tprintf(
						"Image preparation failed (%v): %s",
						flow.error.code,
						win98imageprep.error_text(&flow.error),
					)
					install_prepare_status_finish(s, false, failure_message)
					vm_log(
						s,
						fmt.tprintf(
							"Windows 98: image preparation failed (%v): %s%s",
							flow.error.code,
							win98imageprep.error_text(&flow.error),
							flow.state_retained ? "; recovery state retained" : "",
						),
					)
					publish_install_state(s, profile.install_state_active(&c.install_state))
					preparation_blocked = !install_state_boot_allowed(&c.install_state)
					if flow.state_retained {
						frozen = true
						publish_freeze(
							s,
							"Windows 98: preparation recovery state is retained; abandon the installation before using disk tools",
							"",
						)
					}
					install_image_flow_result_destroy(&flow)
					delete(cmd.path)
					delete(cmd.boot_path)
					delete(cmd.locale_language)
					delete(cmd.locale_country)
					continue
				}
				vm_log(
					s,
					fmt.tprintf(
						"Windows 98: staged %d files (%d bytes), setup is %s",
						flow.preparation.media_info.win98_file_count,
						flow.preparation.media_info.win98_total_bytes,
						flow.preparation.media_info.setup_executable,
					),
				)
				install_prepare_status_finish(s, true, "Windows 98 installation is ready")
				delete(c.cdrom_path)
				c.cdrom_path = strings.clone(cmd.path)
				publish_cdrom_state(s, true, c.cdrom_path)
				if c.floppy_path != "" {
					delete(c.floppy)
					c.floppy = nil
					delete(c.floppy_path)
					c.floppy_path = ""
					publish_floppy_state(s, false)
				}
				install_image_flow_result_destroy(&flow)
				delete(cmd.path)
				delete(cmd.boot_path)
				delete(cmd.locale_language)
				delete(cmd.locale_country)
				publish_install_state(s, true)
				preparation_blocked = !install_state_boot_allowed(&c.install_state)
				install_gate := install_image_boot_gate_loaded(
					&c.install_state,
					c.hard_drive_path,
					c.install_state_diagnostic,
				)
				launch_state_ready := install_gate.allowed && install_launch_prepare(c)
				if launch_state_ready {
					_ = vm_start_machine(c, m, &machine_live, !host.pause_active(&pause_state))
				}
				if machine_live {
					storage_activity_session += 1
					frozen = false
					publish_freeze(s, "", "")
					vm_log(s, "Windows 98: booting the direct unattended Setup launcher")
				} else {
					frozen = true
					message := "Windows 98: reboot after image preparation failed"
					if !install_gate.allowed {
						message = fmt.tprintf(
							"Windows 98: start blocked: %s",
							install_image_boot_diagnostic_text(&install_gate),
						)
					} else if !launch_state_ready {
						message = "Windows 98: direct Setup launch state could not be persisted"
					}
					publish_freeze(s, message, "")
				}
				publish_machine_running(s, machine_live)
				continue
			case .Abandon_Windows_98_Installation:
				if machine_live {
					vm_log(s, "Windows 98: stop the machine before abandoning installation")
					continue
				}
				if profile.install_state_recovery_required(c.install_state_diagnostic) {
					evidence_path, recovery_diagnostic := profile.install_state_abandon_invalid(
						c.paths.install_state,
						c.install_state_diagnostic,
					)
					if recovery_diagnostic != .None {
						frozen = true
						publish_freeze(
							s,
							fmt.tprintf(
								"Windows 98: invalid install state could not be abandoned (%v); recovery evidence remains locked",
								recovery_diagnostic,
							),
							"",
						)
						delete(evidence_path)
						continue
					}
					c.install_state_diagnostic = .None
					publish_install_recovery_state(s, false)
					preparation_blocked = false
					frozen = false
					publish_freeze(s, "", "")
					vm_log(
						s,
						fmt.tprintf(
							"Windows 98: invalid install state abandoned; evidence retained at %s",
							evidence_path,
						),
					)
					delete(evidence_path)
					continue
				}
				abandon_error := install_image_abandon(&c.paths, &c.install_state)
				if abandon_error.code != .None {
					frozen = true
					publish_freeze(
						s,
						fmt.tprintf(
							"Windows 98: abandonment failed (%v): %s",
							abandon_error.code,
							win98imageprep.error_text(&abandon_error),
						),
						"",
					)
					continue
				}
				if !install_session_finish(c, m) {
					frozen = true
					publish_freeze(
						s,
						"Windows 98: preparation was removed, but install state could not be cleared",
						"",
					)
					continue
				}
				vm_restore_user_media(c, m, machine_live)
				preparation_blocked = false
				frozen = false
				publish_freeze(s, "", "")
				vm_log(s, "Windows 98: installation preparation abandoned")
				continue
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
			case .Set_Volume:
				c.volume_gain = clamp(cmd.volume_gain, 0, 1)
				_ = host.host_audio_set_gain(&c.audio, c.volume_gain)
			}
		}
		delete(cmds)
		if quit {break loop}
		if machine_live && !frozen && !host.pause_active(&pause_state) {
			input_events: [HOST_INPUTS_PER_VM_STEP]host.Host_Input_Event
			sync.lock(&s.mu)
			input_count := host.host_input_drain(&s.input, input_events[:])
			input_generation := s.input_generation
			sync.unlock(&s.mu)
			input_drained_at := time.tick_now()
			input_residence_ns, max_input_residence_ns: u64
			oldest_input_queued_at: time.Tick
			input_applied_count := 0
			control_applied_count, control_stale_count: u64
			for &event in input_events[:input_count] {
				if !input_control_event_current(&event, input_generation) {
					if event.control_generation != 0 {control_stale_count += 1}
					continue
				}
				if event.control_generation != 0 {control_applied_count += 1}
				input_applied_count += 1
				residence_ns := host.host_input_residence_ns(&event, input_drained_at)
				input_residence_ns += residence_ns
				max_input_residence_ns = max(max_input_residence_ns, residence_ns)
				if event.queued_at != (time.Tick{}) &&
				   (oldest_input_queued_at == (time.Tick{}) ||
						   time.tick_diff(event.queued_at, oldest_input_queued_at) > 0) {
					oldest_input_queued_at = event.queued_at
				}
				switch event.kind {
				case .Key:
					for i in 0 ..< int(event.key_n) {machine.machine_key(m, event.key[i])}
				case .Mouse_Motion, .Mouse_Buttons:
					machine.machine_mouse(m, event.dx, event.dy, event.buttons)
				case .Mouse_Wheel:
					machine.machine_mouse_wheel(m, event.wheel, event.buttons)
				}
			}
			if control_applied_count != 0 || control_stale_count != 0 {
				sync.lock(&s.mu)
				s.input_control_stats.applied = saturating_counter_add(
					s.input_control_stats.applied,
					control_applied_count,
				)
				s.input_control_stats.stale_dropped = saturating_counter_add(
					s.input_control_stats.stale_dropped,
					control_stale_count,
				)
				sync.unlock(&s.mu)
			}
			graphics_presentation_note_input(
				&s.video_presentation,
				nil,
				u64(input_applied_count),
				input_residence_ns,
				max_input_residence_ns,
				input_drained_at,
				oldest_input_queued_at,
			)
		}

		if machine_live && !frozen && !host.pause_active(&pause_state) {
			step_started := time.tick_now()
			alive := machine.step(m)
			step_ended := time.tick_now()
			graphics_vm_execution.step_calls = saturating_counter_add(
				graphics_vm_execution.step_calls,
				1,
			)
			graphics_vm_execution.step_wall_ns = saturating_counter_add(
				graphics_vm_execution.step_wall_ns,
				u64(max(time.Duration(0), time.tick_diff(step_started, step_ended))),
			)
			if diagnostic, available := machine.machine_take_runtime_diagnostic(m); available {
				fmt.printfln("%s", diagnostic)
				vm_log(s, diagnostic)
				delete(diagnostic)
			}
			if storage_error, terminal := vm_volume_terminal_error(c); terminal {
				frozen = true
				diagnostic := fat32session.error_text(&storage_error)
				vm_log(s, fmt.tprintf("disk: terminal FAT32 session failure: %s", diagnostic))
				publish_freeze(s, fmt.tprintf("storage helper failed: %s", diagnostic), "")
				continue loop
			}
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
						frozen = false
						gui_guest_power_off_complete(s, power_reason)
						continue loop
					}
					frozen = true
					publish_freeze(
						s,
						"APM power off blocked: disk close failed; recovery state retained",
						"",
					)
				} else if machine.machine_cpu_reset_pending(m) {
					reason := machine.machine_cpu_reset_reason(m)
					reset_code := m.cpu_reset_cmos_0f
					publish_machine_reinitializing(s)
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
					publish_machine_running(s, machine_live)
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
					publish_machine_reinitializing(s)
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
						storage_activity_session += 1
						_ = install_reset_transaction_commit(&reset_transaction)
						stats = {}
						frozen = false
						publish_freeze(s, "", "")
						vm_log(s, fmt.tprintf("machine: reset (%s)", reset_reason))
					} else if rollback_diagnostic != .None {
						frozen = true
						publish_freeze(s, "guest reset failed: install state rollback failed", "")
					} else if reset_diagnostic == .Durability_Failed {
						frozen = true
						publish_freeze(
							s,
							"guest reset blocked: disk durability barrier failed; recovery state retained; retry Reset or Exit",
							"",
						)
					} else if reset_diagnostic == .Volume_Open_Failed {
						frozen = true
						publish_freeze(s, "guest reset failed: cannot reopen protected C:", "")
					} else {
						frozen = true
						publish_freeze(s, "guest reset failed: machine init error", "")
					}
					publish_machine_running(s, machine_live)
					delete(reset_reason)
				} else {
					frozen = true
					r := hv.get_regs(&m.vm)
					msg := strings.clone(m.bus.freeze_msg)
					regs := format_regs(r, m)
					publish_freeze(s, msg, regs)
					fmt.printfln("VM frozen: %s", msg)
					delete(msg)
					delete(regs)
				}
			}
		} else {
			wait_started := time.tick_now()
			time.sleep(10 * time.Millisecond)
			graphics_vm_execution.inactive_wait_ns = saturating_counter_add(
				graphics_vm_execution.inactive_wait_ns,
				u64(max(time.Duration(0), time.tick_since(wait_started))),
			)
		}

		now := time.tick_now()
		if gui_install_completion_poll_due(
			&c.install_state,
			machine_live,
			frozen,
			c.fat_session != nil,
			last_install_completion_check,
			now,
		) {
			last_install_completion_check = now
			if gui_install_completion_marker_exists(c.fat_session) {
				if !install_session_finish(c, m) {
					vm_log(
						s,
						"Windows 98: detected the completed desktop, but could not finish the installation session",
					)
				} else {
					vm_restore_user_media(c, m, machine_live)
				}
			}
		}
		if machine_live && time.tick_diff(last_snap, now) >= SNAP_PERIOD {
			last_snap = now
			snap := machine.machine_text_snapshot(m)
			if video.video_presentation_publish_observed(
				&s.video_presentation,
				m,
				storage_activity_session,
				graphics_vm_execution,
			) {
				machine.machine_note_scanout_copy(m)
			}
			sync.lock(&s.mu)
			s.snap = snap
			s.exit_stats = stats
			s.storage_activity = machine.machine_storage_activity(m)
			s.storage_activity_session = storage_activity_session
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
	publish_machine_running(s, false)
	delete(c.floppy)
	delete(c.floppy_path)
	delete(c.cdrom_path)
	delete(c.user_floppy)
	delete(c.user_floppy_path)
	delete(c.user_cdrom_path)
	free(m)
}
