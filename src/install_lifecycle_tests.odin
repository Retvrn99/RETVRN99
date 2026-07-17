// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "disk"
import "fat32session"
import "hv"
import "machine"
import "profile"
import "vmconfig"

INSTALL_TEST_SECTOR_BYTES :: 512
INSTALL_TEST_PARTITION_LBA :: u64(63)

@(test)
install_test_volume_open_failure_is_typed_and_user_facing :: proc(t: ^testing.T) {
	root := install_test_directory(t)
	defer delete(root)
	defer os.remove_all(root)
	missing, path_error := filepath.join({root, "missing.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	shared: Shared
	defer vm_log_destroy(&shared)
	ctx := Vm_Ctx {
		shared             = &shared,
		attach             = true,
		hard_drive_path    = missing,
		machine_session_id = "missing-image-test",
	}
	testing.expect(t, !vm_open_volume_with_adapter(&ctx, .In_Process))
	testing.expect_value(t, ctx.volume_open_error.code, fat32session.Error_Code.Image_Missing)
	message := vm_volume_open_failure_message(&ctx, "start")
	testing.expect(t, strings.contains(message, "start failed"))
	testing.expect(t, strings.contains(message, "Image_Missing"))
	testing.expect(t, strings.contains(message, "does not exist"))
	ctx.volume_open_error = fat32session.error_make(
		.Helper_Missing,
		false,
		.Not_Started,
		0,
		0,
		"retvrn99-fat32.exe is missing beside retvrn99.exe",
	)
	helper_message := vm_volume_open_failure_message(&ctx, "start")
	testing.expect(t, strings.contains(helper_message, "Helper_Missing"))
	testing.expect(t, strings.contains(helper_message, "retvrn99-fat32.exe is missing"))
}

@(test)
install_test_active_session_forces_turbo_without_changing_persona :: proc(t: ^testing.T) {
	persona := vmconfig.Cpu_Mode.GSW_886
	active := profile.Install_State {
		phase = .Setup_Running,
	}
	testing.expect_value(t, install_runtime_cpu_mode(persona, &active), vmconfig.Cpu_Mode.Turbo)
	testing.expect_value(
		t,
		console_cpu_mode_name(install_runtime_cpu_mode(persona, &active)),
		"Turbo",
	)
	testing.expect_value(t, persona, vmconfig.Cpu_Mode.GSW_886)

	inactive: profile.Install_State
	testing.expect_value(t, install_runtime_cpu_mode(persona, &inactive), persona)
}

@(test)
install_test_finish_session_restores_persisted_persona_live :: proc(t: ^testing.T) {
	if !hv.available() {return}
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	shared: Shared
	ctx := Vm_Ctx {
		shared   = &shared,
		cpu_mode = .GSW_886,
		paths    = profile.Paths{cmos = cmos_path, install_state = state_path},
		install_state = profile.Install_State {
			phase       = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
		},
	}
	defer vm_log_destroy(&shared)
	if !testing.expect(t, vm_guard_init(&ctx.guard)) {return}
	defer vm_guard_destroy(&ctx.guard)
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine.machine_destroy(m)
	vm_guard_bind(&ctx.guard, &m.vm)
	defer vm_guard_unbind(&ctx.guard)
	machine.machine_set_cpu_mode(m, .Turbo)

	if !testing.expect(t, install_session_finish(&ctx, m)) {return}
	testing.expect_value(t, m.cpu_mode, vmconfig.Cpu_Mode.GSW_886)
}

@(test)
install_test_hdd_first_boot_order :: proc(t: ^testing.T) {
	cmos: [128]u8
	cmos[0x38] = 0xA5
	cmos[0x3D] = 0xFF
	install_apply_boot_order(cmos[:])
	testing.expect_value(t, cmos[0x38], u8(0x15))
	testing.expect_value(t, cmos[0x3D], u8(0x32))
}

@(test)
install_test_retry_preserves_original_cmos_boot_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	cmos: [128]u8
	cmos[0x38] = 0x11
	cmos[0x3D] = 0x32
	previous := profile.Install_State {
		phase            = .Setup_Running,
		source_path      = strings.clone("first.iso"),
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0xFF,
	}
	defer profile.install_state_destroy(&previous)
	candidate := install_state_candidate("retry.iso", cmos[:], true, &previous)
	defer profile.install_state_destroy(&candidate)
	testing.expect_value(t, candidate.phase, profile.Install_Phase.Preparing)
	testing.expect_value(t, candidate.source_path, "retry.iso")
	testing.expect(t, candidate.saved_cmos_valid)
	testing.expect_value(t, candidate.saved_cmos_38, u8(0xA5))
	testing.expect_value(t, candidate.saved_cmos_3d, u8(0xFF))
}

@(test)
install_test_first_successful_boot_captures_unknown_cmos_before_override :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	state_path, _ := filepath.join({dir, "install-state.json"})
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
	}
	ctx.install_state = install_state_candidate("WIN98SE.ISO", ctx.cmos[:], false, nil)
	install_test_bind_state(t, &ctx.install_state, dir, 12)
	defer profile.install_state_destroy(&ctx.install_state)
	defer vm_log_destroy(&shared)
	testing.expect(t, !ctx.install_state.saved_cmos_valid)

	boot_cmos: profile.Cmos_Data
	boot_cmos[0x38] = 0xA5
	boot_cmos[0x3D] = 0x5A
	testing.expect(t, install_prepare_boot_cmos(&ctx, boot_cmos[:]))
	testing.expect(t, ctx.install_state.saved_cmos_valid)
	testing.expect_value(t, ctx.install_state.saved_cmos_38, u8(0xA5))
	testing.expect_value(t, ctx.install_state.saved_cmos_3d, u8(0x5A))
	testing.expect_value(t, boot_cmos[0x38], u8(0x15))
	testing.expect_value(t, boot_cmos[0x3D], u8(0x32))

	copy(ctx.cmos[:], boot_cmos[:])
	ctx.has_cmos = true
	m := new(machine.Machine)
	defer free(m)
	testing.expect(t, install_session_finish(&ctx, m))
	loaded_cmos, diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, loaded_cmos[0x38], u8(0xA5))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0x5A))
}

@(test)
install_test_direct_launch_only_transitions_pending_state :: proc(t: ^testing.T) {
	phases := [?]profile.Install_Phase {
		profile.Install_Phase.None,
		profile.Install_Phase.Setup_Running,
	}
	for phase in phases {
		state := profile.Install_State {
			phase = phase,
		}
		_, _, changed, ok := install_launch_stage(&state)
		testing.expect(t, ok)
		testing.expect(t, !changed)
		testing.expect_value(t, state.phase, phase)
	}
	preparing := profile.Install_State {
		phase = .Preparing,
	}
	_, _, changed, ok := install_launch_stage(&preparing)
	testing.expect(t, !ok)
	testing.expect(t, !changed)
	testing.expect_value(t, preparing.phase, profile.Install_Phase.Preparing)
	pending := profile.Install_State {
		phase       = .Launch_Pending,
		source_path = "WIN98SE.ISO",
	}
	_, _, changed, ok = install_launch_stage(&pending)
	testing.expect(t, ok)
	testing.expect(t, changed)
	testing.expect_value(t, pending.phase, profile.Install_Phase.Setup_Running)
	testing.expect_value(t, pending.milestone, profile.Install_Milestone.DOS_Setup)
}

@(test)
install_test_launch_state_save_failure_keeps_pending :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	blocked_parent, _ := filepath.join({dir, "not-a-directory"})
	testing.expect(t, os.write_entire_file(blocked_parent, "blocked") == nil)
	state_path, _ := filepath.join({blocked_parent, "install-state.json"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{install_state = state_path},
		install_state = profile.Install_State {
			phase = .Launch_Pending,
			source_path = strings.clone("WIN98SE.ISO"),
		},
	}
	defer profile.install_state_destroy(&ctx.install_state)
	defer vm_log_destroy(&shared)
	testing.expect(t, !install_launch_prepare(&ctx))
	testing.expect_value(t, ctx.install_state.phase, profile.Install_Phase.Launch_Pending)
	testing.expect_value(t, ctx.install_state.milestone, profile.Install_Milestone.None)
	testing.expect_value(t, len(shared.log_lines), 1)
	testing.expect(t, strings.contains(shared.log_lines[0], "before direct Setup launch"))
}

@(test)
install_test_successful_direct_launch_persists_setup_milestone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	state_path, _ := filepath.join({dir, "install-state.json"})
	milestones := [?]profile.Install_Milestone {
		profile.Install_Milestone.DOS_Setup,
		profile.Install_Milestone.First_Reboot,
	}
	for expected, reset_count in milestones {
		shared: Shared
		ctx := Vm_Ctx {
			shared = &shared,
			paths = profile.Paths{install_state = state_path},
			install_state = profile.Install_State {
				phase = .Launch_Pending,
				source_path = strings.clone("WIN98SE.ISO"),
				reset_count = u32(reset_count),
			},
		}
		install_test_bind_state(t, &ctx.install_state, dir, u64(20 + reset_count))
		testing.expect(t, install_launch_prepare(&ctx))
		testing.expect_value(t, ctx.install_state.phase, profile.Install_Phase.Setup_Running)
		testing.expect_value(t, ctx.install_state.milestone, expected)

		loaded, diagnostic := profile.install_state_load(state_path)
		testing.expect_value(t, diagnostic, profile.Install_State_Diagnostic.None)
		testing.expect_value(t, loaded.phase, profile.Install_Phase.Setup_Running)
		testing.expect_value(t, loaded.milestone, expected)
		profile.install_state_destroy(&loaded)
		profile.install_state_destroy(&ctx.install_state)
		vm_log_destroy(&shared)
	}
}

@(test)
install_test_attached_boot_requires_live_volume :: proc(t: ^testing.T) {
	ctx := Vm_Ctx {
		attach = true,
	}
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x20] = 0x7A
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, !vm_boot(&ctx, m))
	testing.expect_value(t, m.cmos.ram[0x20], u8(0x7A))

	ctx.attach = false
	testing.expect(t, vm_volume_ready(&ctx))
}

@(test)
install_test_stopped_machine_can_open_selected_image :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	image_path := test_image_create(t, dir, "reopen.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		nil,
		[]Test_Image_File{{path = "IO.SYS", data = "boot"}},
	) {return}
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		attach = true,
		paths = profile.Paths{root = dir, default_image = image_path},
		hard_drive_path = image_path,
		machine_session_id = "reopen-test",
	}
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, vm_ensure_volume(&ctx))
	testing.expect(t, vm_volume_ready(&ctx))
	testing.expect(t, vm_close_volume(&ctx))
	testing.expect(t, ctx.fat_session == nil)
}

@(test)
install_test_completed_close_warning_releases_volume_without_reattach :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	image_path := test_image_create(t, dir, "completed-close.img")
	if image_path == "" {return}
	shared: Shared
	defer vm_log_destroy(&shared)
	ctx := Vm_Ctx {
		shared             = &shared,
		attach             = true,
		hard_drive_path    = image_path,
		machine_session_id = "completed-close-lifecycle",
	}
	if !testing.expect(t, vm_open_volume_with_adapter(&ctx, .In_Process)) {return}
	state_root, state_error := filepath.join(
		{dir, ".completed-close.img.retvrn99-fat32"},
		context.temp_allocator,
	)
	if !testing.expect(t, state_error == nil) {return}
	blocker, blocker_error := filepath.join(
		{state_root, "unowned-cleanup-blocker.bin"},
		context.temp_allocator,
	)
	if !testing.expect(t, blocker_error == nil) ||
	   !testing.expect_value(t, os.write_entire_file(blocker, "preserve me"), os.Error(nil)) {
		return
	}
	testing.expect(t, vm_close_volume(&ctx))
	testing.expect(t, ctx.fat_session == nil)
	logged := false
	for line in shared.log_lines {
		logged = logged || strings.contains(line, "companion cleanup warning")
	}
	testing.expect(t, logged)
	reopened, reopen_error := fat32session.open_machine(
		image_path,
		"completed-close-reopen",
		.In_Process,
	)
	if !testing.expect_value(t, reopen_error.code, fat32session.Error_Code.None) {return}
	testing.expect_value(
		t,
		fat32session.close(reopened, .Commit).code,
		fat32session.Error_Code.None,
	)
}

@(test)
install_test_reset_rejects_frozen_protected_volume :: proc(t: ^testing.T) {
	dummy := true
	session := fat32session.Machine_Session {
		ctx = &dummy,
		operations = fat32session.Machine_Operations {
			ready = proc(ctx: rawptr) -> bool {return false},
		},
	}
	ctx := Vm_Ctx {
		attach      = true,
		fat_session = &session,
	}
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, !vm_ensure_volume(&ctx))
	testing.expect(t, ctx.fat_session == &session)
}

@(test)
install_test_failed_close_keeps_machine_live_for_retry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shared: Shared
	dummy := true
	session := fat32session.Machine_Session {
		ctx = &dummy,
		operations = fat32session.Machine_Operations {
			ready = proc(ctx: rawptr) -> bool {return false},
			barrier = proc(ctx: rawptr, reason: fat32session.Barrier_Reason) -> (
				fat32session.Barrier_Result,
				fat32session.Session_Error,
			) {
				return {}, fat32session.error_make(
					.FAT_Invalid,
					false,
					.Retained,
					0,
					0,
					"test freeze",
				)
			},
		},
	}
	ctx := Vm_Ctx {
		shared      = &shared,
		attach      = true,
		fat_session = &session,
	}
	ctx.guard.valid = true
	m := new(machine.Machine)
	defer free(m)
	machine_live := true
	diagnostic := vm_reinitialize_machine(&ctx, m, &machine_live)
	testing.expect_value(t, diagnostic, Vm_Reinitialize_Diagnostic.Durability_Failed)
	testing.expect(t, machine_live)
	testing.expect(t, ctx.guard.valid)
	testing.expect(t, ctx.fat_session == &session)
	vm_log_destroy(&shared)
}

Failed_Boot_Close_State :: struct {
	commit_calls: int,
	retain_calls: int,
}

@(test)
install_test_failed_boot_releases_retained_session_before_image_switch :: proc(t: ^testing.T) {
	state: Failed_Boot_Close_State
	session := new(fat32session.Machine_Session)
	session.ctx = &state
	session.operations = fat32session.Machine_Operations {
		close = proc(ctx: rawptr, mode: fat32session.Close_Mode) -> fat32session.Session_Error {
			state := (^Failed_Boot_Close_State)(ctx)
			if mode == .Retain {
				state.retain_calls += 1
				return {}
			}
			state.commit_calls += 1
			return fat32session.error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"test commit failure",
			)
		},
	}
	shared: Shared
	ctx := Vm_Ctx {
		shared          = &shared,
		attach          = true,
		fat_session     = session,
		hard_drive_path = "old.img",
	}

	testing.expect(t, vm_release_failed_boot_volume(&ctx))
	testing.expect(t, ctx.fat_session == nil)
	testing.expect_value(t, state.commit_calls, 1)
	testing.expect_value(t, state.retain_calls, 1)
	ctx.hard_drive_path = "new.img"
	testing.expect(t, ctx.fat_session == nil)
	vm_log_destroy(&shared)
}

@(test)
install_test_failed_reset_releases_session_after_commit_failure :: proc(t: ^testing.T) {
	state: Failed_Boot_Close_State
	session := new(fat32session.Machine_Session)
	session.ctx = &state
	session.operations = fat32session.Machine_Operations {
		close = proc(ctx: rawptr, mode: fat32session.Close_Mode) -> fat32session.Session_Error {
			state := (^Failed_Boot_Close_State)(ctx)
			if mode == .Retain {
				state.retain_calls += 1
				return {}
			}
			state.commit_calls += 1
			return fat32session.error_make(
				.Wal_IO,
				false,
				.Retained,
				0,
				0,
				"test failed-reset commit failure",
			)
		},
	}

	testing.expect(t, machine_session_release_after_failed_reset(&session))
	testing.expect(t, session == nil)
	testing.expect_value(t, state.commit_calls, 1)
	testing.expect_value(t, state.retain_calls, 1)
}

@(test)
install_test_shutdown_unbinds_guard_even_without_live_partition :: proc(t: ^testing.T) {
	ctx: Vm_Ctx
	if !testing.expect(t, vm_guard_init(&ctx.guard)) {return}
	defer vm_guard_destroy(&ctx.guard)
	m := new(machine.Machine)
	defer free(m)
	vm_guard_bind(&ctx.guard, &m.vm)
	before := vm_guard_stats(&ctx.guard)

	vm_shutdown(&ctx, m)
	after := vm_guard_stats(&ctx.guard)
	testing.expect(t, before.valid)
	testing.expect(t, !after.valid)
	testing.expect(t, after.generation > before.generation)
}

@(test)
install_test_gui_boot_retains_callback_evidence_without_legacy_tracing :: proc(t: ^testing.T) {
	if !hv.available() {return}
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths  = profile.Paths{cmos = cmos_path},
	}
	if !testing.expect(t, vm_guard_init(&ctx.guard)) {return}
	defer vm_guard_destroy(&ctx.guard)
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	machine_live := false
	defer {
		if machine_live {vm_shutdown(&ctx, m)}
		machine.machine_destroy(m)
		free(m)
	}

	if !testing.expect(t, vm_boot(&ctx, m, false)) {return}
	machine_live = true
	testing.expect(t, m.hardware_trace != nil && m.hardware_trace.enabled)
	testing.expect(t, !m.diagnostic_tracing)
	testing.expect(t, !m.bus.diagnostic_tracing)

	machine_generation := u64(77)
	if !testing.expect(
		t,
		vm_guard_schedule(&ctx.guard, u64(time.Second), .One_Shot, machine_generation),
	) {return}
	host_generation := vm_guard_stats(&ctx.guard).generation
	vm_guard_deadline(&ctx.guard, host_generation)
	_ = vm_guard_schedule(&ctx.guard, 0, .Disarm, machine_generation + 1)
	vm_guard_flush_wake_evidence(&ctx.guard, m)
	trace := machine.machine_hardware_trace_text(m)
	defer delete(trace)
	correlation := fmt.tprintf(
		"wake-fire    a=%016x b=%016x",
		machine_generation,
		host_generation,
	)
	testing.expect(t, strings.contains(trace, correlation))
}

@(test)
install_test_gui_reset_preserves_hardware_trace_identity :: proc(t: ^testing.T) {
	if !hv.available() {return}
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths  = profile.Paths{cmos = cmos_path},
	}
	if !testing.expect(t, vm_guard_init(&ctx.guard)) {return}
	defer vm_guard_destroy(&ctx.guard)
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	machine_live := false
	defer {
		if machine_live {vm_shutdown(&ctx, m)}
		machine.machine_destroy(m)
		free(m)
	}

	if !testing.expect(t, vm_boot(&ctx, m, false)) {return}
	machine_live = true
	trace_before := m.hardware_trace
	machine.machine_trace_record(m, .Reset_Request, 0xCF9, 0x06)
	diagnostic := vm_reinitialize_machine(&ctx, m, &machine_live, false)
	testing.expect_value(t, diagnostic, Vm_Reinitialize_Diagnostic.None)
	testing.expect(t, machine_live)
	testing.expect_value(t, m.hardware_trace, trace_before)
	testing.expect(t, m.hardware_trace != nil && m.hardware_trace.enabled)
	testing.expect(t, !m.diagnostic_tracing)
	testing.expect(t, !m.bus.diagnostic_tracing)
	trace := machine.machine_hardware_trace_text(m)
	defer delete(trace)
	testing.expect(t, strings.contains(trace, "reset"))
}

@(test)
install_test_full_reset_retains_image_session_and_rebinds_wake_guard :: proc(t: ^testing.T) {
	if !hv.available() {return}
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	image_path := test_image_create(t, dir, "gui-reset.img")
	if image_path == "" {return}
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	if !test_image_write_files(
		t,
		image_path,
		[]string{"WINDOWS"},
		[]Test_Image_File{
			{path = "IO.SYS", data = "boot"},
			{path = "WINDOWS/WNBOOTNG.STS", data = "setup"},
		},
	) {return}
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		attach = true,
		paths = profile.Paths{root = dir, default_image = image_path, cmos = cmos_path},
		hard_drive_path = image_path,
		machine_session_id = "gui-reset-test",
		install_state = profile.Install_State {
			phase = .Setup_Running,
			milestone = .First_Reboot,
			source_path = strings.clone("WIN98SE.ISO"),
			reset_count = 1,
			saved_cmos_valid = true,
		},
	}
	install_test_bind_state(t, &ctx.install_state, dir, 40)
	defer profile.install_state_destroy(&ctx.install_state)
	if !testing.expect(t, vm_guard_init(&ctx.guard)) {return}
	defer vm_guard_destroy(&ctx.guard)
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	machine_live := false
	defer {
		if machine_live {
			_ = vm_close_then_shutdown(&ctx, m, &machine_live)
		} else {
			_ = vm_close_volume(&ctx)
		}
	}

	if !testing.expect(t, vm_ensure_volume(&ctx)) {return}
	if !testing.expect(t, vm_boot(&ctx, m, false)) {return}
	machine_live = true
	before := vm_guard_stats(&ctx.guard)
	diagnostic := vm_reinitialize_machine(&ctx, m, &machine_live, false, true)
	after := vm_guard_stats(&ctx.guard)

	testing.expect_value(t, diagnostic, Vm_Reinitialize_Diagnostic.None)
	testing.expect(t, machine_live)
	testing.expect(t, vm_volume_ready(&ctx))
	sentinel, sentinel_error := fat32session.observe(
		ctx.fat_session,
		[]fat32session.Probe{{kind = .Read_Range, path = "WINDOWS/WNBOOTNG.STS", length = 5}},
		context.temp_allocator,
	)
	if testing.expect_value(t, sentinel_error.code, fat32session.Error_Code.None) {
		defer fat32session.observation_batch_destroy(&sentinel, context.temp_allocator)
		testing.expect_value(t, len(sentinel.items), 1)
		if len(sentinel.items) == 1 {testing.expect_value(t, string(sentinel.items[0].data), "setup")}
	}
	testing.expect(t, after.valid)
	testing.expect(t, after.generation > before.generation)
}

Install_Test_Reset_Route :: enum {
	Pci_Cf9,
	Kbc_Controller_Pulse,
	Kbc_Output_Port,
	Port_92,
}

install_test_u16le :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

install_test_u32le :: proc(data: []u8, offset: int) -> u32 {
	return u32(data[offset]) |
	       u32(data[offset + 1]) << 8 |
	       u32(data[offset + 2]) << 16 |
	       u32(data[offset + 3]) << 24
}

install_test_root_file_lba :: proc(
	device: disk.Block_Device,
	short_name: [11]u8,
) -> (u64, bool) {
	sector: [INSTALL_TEST_SECTOR_BYTES]u8
	if device.read == nil ||
	   !device.read(device.ctx, INSTALL_TEST_PARTITION_LBA, sector[:]) ||
	   install_test_u16le(sector[:], 11) != INSTALL_TEST_SECTOR_BYTES {
		return 0, false
	}
	sectors_per_cluster := u32(sector[13])
	reserved := u32(install_test_u16le(sector[:], 14))
	fat_count := u32(sector[16])
	sectors_per_fat := install_test_u32le(sector[:], 36)
	cluster := install_test_u32le(sector[:], 44)
	if sectors_per_cluster == 0 || fat_count == 0 || sectors_per_fat == 0 || cluster < 2 {
		return 0, false
	}
	data_start := INSTALL_TEST_PARTITION_LBA + u64(reserved + fat_count * sectors_per_fat)
	fat_start := INSTALL_TEST_PARTITION_LBA + u64(reserved)
	for _ in 0 ..< 1024 {
		cluster_lba := data_start + u64(cluster - 2) * u64(sectors_per_cluster)
		for sector_index in u32(0) ..< sectors_per_cluster {
			if !device.read(device.ctx, cluster_lba + u64(sector_index), sector[:]) {
				return 0, false
			}
			for offset := 0; offset < INSTALL_TEST_SECTOR_BYTES; offset += 32 {
				if sector[offset] == 0 {return 0, false}
				if sector[offset] == 0xE5 || sector[offset + 11] == 0x0F {continue}
				matched := true
				for index in 0 ..< 11 {
					if sector[offset + index] != short_name[index] {
						matched = false
						break
					}
				}
				if !matched {continue}
				first := u32(install_test_u16le(sector[:], offset + 26)) |
				         u32(install_test_u16le(sector[:], offset + 20)) << 16
				if first < 2 {return 0, false}
				return data_start + u64(first - 2) * u64(sectors_per_cluster), true
			}
		}
		fat_offset := u64(cluster) * 4
		if !device.read(device.ctx, fat_start + fat_offset / INSTALL_TEST_SECTOR_BYTES, sector[:]) {
			return 0, false
		}
		entry_offset := int(fat_offset % INSTALL_TEST_SECTOR_BYTES)
		next := install_test_u32le(sector[:], entry_offset) & 0x0FFF_FFFF
		if next < 2 || next >= 0x0FFF_FFF8 {return 0, false}
		cluster = next
	}
	return 0, false
}

install_test_request_hardware_reset :: proc(m: ^machine.Machine, route: Install_Test_Reset_Route) {
	switch route {
	case .Pci_Cf9:
		machine.bus_io_write(&m.bus, 0xCF9, 1, 0x06)
	case .Kbc_Controller_Pulse:
		machine.bus_io_write(&m.bus, 0x64, 1, 0xFE)
		machine.machine_advance_time_ns(m, machine.I8042_CONTROLLER_INPUT_NS)
	case .Kbc_Output_Port:
		machine.bus_io_write(&m.bus, 0x64, 1, 0xD1)
		machine.machine_advance_time_ns(m, machine.I8042_CONTROLLER_INPUT_NS)
		machine.bus_io_write(&m.bus, 0x60, 1, 0x00)
		machine.machine_advance_time_ns(m, machine.I8042_CONTROLLER_INPUT_NS)
	case .Port_92:
		machine.bus_io_write(&m.bus, 0x92, 1, 0x03)
	}
}

install_test_full_console_reset_route :: proc(
	t: ^testing.T,
	route: Install_Test_Reset_Route,
	expected_source: machine.Reset_Provenance,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	image_path := test_image_create(t, dir, "reset-route.img")
	if image_path == "" {return}
	if !test_image_write_files(
		t,
		image_path,
		[]string{"WINDOWS"},
		[]Test_Image_File{
			{path = "IO.SYS", data = "boot"},
			{path = "WINDOWS/WNBOOTNG.STS", data = "setup"},
		},
	) {return}

	paths := profile.Paths {
		root          = dir,
		default_image = image_path,
	}
	session, session_error := fat32session.open_in_process(image_path, "reset-route-test")
	if !testing.expect(t, session_error.code == .None && session != nil) {return}
	device := fat32session.block_device(session)
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, 64 * 1024 * 1024)) {
		_ = fat32session.close(session, .Retain)
		return
	}
	machine_live := true
	defer {
		if machine_live {machine.machine_destroy(m)}
		if session != nil {_ = fat32session.close(session, .Commit)}
	}
	if !testing.expect(t, machine.load_roms(&m.vm)) {return}
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {return}
	machine.machine_clock_set_running(m, false)
	machine.machine_attach_disk(m, device)

	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard)) {return}
	defer vm_guard_destroy(&guard)
	vm_guard_bind(&guard, &m.vm)
	machine.machine_set_wake_adapter(m, &guard, vm_guard_schedule)
	wake_before := vm_guard_stats(&guard)

	io_short: [11]u8
	copy(io_short[:], "IO      SYS")
	io_sys_lba, io_sys_found := install_test_root_file_lba(device, io_short)
	if !testing.expect(t, io_sys_found) {return}
	io_sys_sector: [INSTALL_TEST_SECTOR_BYTES]u8
	if !testing.expect(t, device.read(device.ctx, io_sys_lba, io_sys_sector[:])) {return}
	io_sys_sector[1] = 'X'
	expected_sector := io_sys_sector
	if !testing.expect(t, device.write(device.ctx, io_sys_lba, io_sys_sector[:])) {
		return
	}
	install_test_request_hardware_reset(m, route)
	if !testing.expect(t, machine.machine_reset_requested(m)) {return}
	testing.expect_value(t, machine.machine_reset_provenance(m), expected_source)
	reset_record, reset_recorded := machine.machine_reset_record(m, 0)
	testing.expect(t, reset_recorded)
	testing.expect_value(t, reset_record.source, expected_source)
	reset_reason := strings.clone(machine.machine_reset_reason(m))
	defer delete(reset_reason)

	result := acceptance.Result {
		boot_epoch = 1,
	}
	defer console_result_destroy(&result)
	console_result_record_reset_request(&result, reset_reason)
	options := acceptance.Options {
		setup_diagnostics = .Hardware,
	}
	cmos := machine.machine_cmos_export(m)
	reset_ok := console_reinitialize_machine_with_ram(
		m,
		&guard,
		&machine_live,
		&session,
		&paths,
		{},
		cmos[:],
		true,
		"",
		nil,
		&options,
		64 * 1024 * 1024,
		true,
	)
	if !testing.expect(t, reset_ok) {return}
	console_result_record_reset_success(&result)

	testing.expect_value(t, result.boot_epoch, u64(2))
	testing.expect_value(t, result.reset_count, u64(1))
	testing.expect_value(t, result.guest_requested_resets, u64(1))
	testing.expect_value(t, result.reset_history_count, 1)
	testing.expect_value(t, result.reset_history[0], reset_reason)
	testing.expect(t, fat32session.session_ready(session))
	sentinel, sentinel_error := fat32session.observe(
		session,
		[]fat32session.Probe{{kind = .Read_Range, path = "WINDOWS/WNBOOTNG.STS", length = 5}},
		context.temp_allocator,
	)
	if testing.expect(t, sentinel_error.code == .None) {
		defer fat32session.observation_batch_destroy(&sentinel, context.temp_allocator)
		testing.expect_value(t, len(sentinel.items), 1)
		if len(sentinel.items) == 1 {testing.expect_value(t, string(sentinel.items[0].data), "setup")}
	}
	testing.expect(t, m.has_disk)
	testing.expect(t, m.ide.bd.ctx == session.ctx)
	persisted_sector: [INSTALL_TEST_SECTOR_BYTES]u8
	device = fat32session.block_device(session)
	persisted_lba, persisted_found := install_test_root_file_lba(device, io_short)
	if !testing.expect(t, persisted_found) {return}
	if !testing.expect(t, device.read(device.ctx, persisted_lba, persisted_sector[:])) {return}
	testing.expect_value(t, persisted_sector, expected_sector)
	wake_after := vm_guard_stats(&guard)
	testing.expect(t, wake_after.valid)
	testing.expect(t, wake_after.generation > wake_before.generation)
	trace := machine.machine_hardware_trace_text(m)
	defer delete(trace)
	testing.expect(t, strings.contains(trace, "reset"))
	trace_source := fmt.tprintf("a=%016x", u64(expected_source))
	testing.expect(t, strings.contains(trace, trace_source))
}

@(test)
install_test_all_advertised_reset_routes_complete_full_console_lifecycle :: proc(t: ^testing.T) {
	if !hv.available() {return}
	routes := [?]struct {
		route:  Install_Test_Reset_Route,
		source: machine.Reset_Provenance,
	} {
		{.Pci_Cf9, .Pci_Cf9},
		{.Kbc_Controller_Pulse, .Kbc_Controller_Pulse},
		{.Kbc_Output_Port, .Kbc_Output_Port},
		{.Port_92, .Port_92},
	}
	for route in routes {
		install_test_full_console_reset_route(t, route.route, route.source)
	}
}

@(test)
install_test_fresh_profile_applies_boot_order_to_live_cmos :: proc(t: ^testing.T) {
	state := profile.Install_State {
		phase = .Setup_Running,
	}
	machine_cmos: [128]u8
	loaded_cmos: [128]u8
	machine_cmos[0x38] = 0xA5
	loaded_cmos[0x38] = 0xB6
	install_apply_initial_boot_order(machine_cmos[:], loaded_cmos[:], false, &state)
	testing.expect_value(t, machine_cmos[0x38], u8(0x15))
	testing.expect_value(t, machine_cmos[0x3D], u8(0x32))
	testing.expect_value(t, loaded_cmos[0x38], u8(0xB6))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0))

	install_apply_initial_boot_order(machine_cmos[:], loaded_cmos[:], true, &state)
	testing.expect_value(t, loaded_cmos[0x38], u8(0x16))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0x32))
}

@(test)
install_test_failed_reset_rolls_back_memory_and_persisted_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	state_path, _ := filepath.join({dir, "install-state.json"})
	state := profile.Install_State {
		phase       = .Setup_Running,
		milestone   = .DOS_Setup,
		source_path = strings.clone("WIN98SE.ISO"),
	}
	install_test_bind_state(t, &state, dir, 30)
	defer profile.install_state_destroy(&state)
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &state),
		profile.Install_State_Diagnostic.None,
	)

	transaction, ok := install_reset_transaction_stage(&state)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, state.reset_count, u32(1))
	testing.expect_value(t, state.milestone, profile.Install_Milestone.First_Reboot)
	state.saved_cmos_valid = true
	state.saved_cmos_38 = 0x15
	state.saved_cmos_3d = 0x32
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &state),
		profile.Install_State_Diagnostic.None,
	)
	testing.expect_value(
		t,
		install_reset_transaction_rollback(state_path, &state, &transaction),
		profile.Install_State_Diagnostic.None,
	)
	testing.expect_value(t, state.reset_count, u32(0))
	testing.expect_value(t, state.milestone, profile.Install_Milestone.DOS_Setup)
	testing.expect(t, !state.saved_cmos_valid)

	persisted, diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&persisted)
	testing.expect_value(t, diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, persisted.reset_count, u32(0))
	testing.expect_value(t, persisted.milestone, profile.Install_Milestone.DOS_Setup)
	testing.expect(t, !persisted.saved_cmos_valid)
}

@(test)
install_test_successful_reset_transaction_commits_only_once :: proc(t: ^testing.T) {
	state := profile.Install_State {
		phase       = .Setup_Running,
		milestone   = .First_Reboot,
		source_path = "WIN98SE.ISO",
		reset_count = 1,
	}
	transaction, ok := install_reset_transaction_stage(&state)
	testing.expect(t, ok)
	testing.expect_value(t, state.reset_count, u32(2))
	testing.expect(t, install_reset_transaction_commit(&transaction))
	testing.expect(t, !install_reset_transaction_commit(&transaction))
	install_reset_transaction_restore(&state, &transaction)
	testing.expect_value(t, state.reset_count, u32(2))
}

@(test)
install_test_failed_console_reinitialize_preserves_hardware_trace :: proc(t: ^testing.T) {
	if !hv.available() {return}
	context.allocator = context.temp_allocator
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := os.make_directory_temp(
		base,
		"retvrn99_failed_console_reset_*",
		context.temp_allocator,
	)
	defer os.remove_all(dir)
	missing_media, _ := filepath.join({dir, "missing.iso"})
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard)) {return}
	defer vm_guard_destroy(&guard)
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, RAM_SIZE)) {return}
	machine_live := true
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {
		machine.machine_destroy(m)
		return
	}
	machine.machine_trace_record(m, .Reset_Request, 0xCF9, 0x06)
	session: ^fat32session.Machine_Session
	paths: profile.Paths
	options := acceptance.Options {
		setup_diagnostics = .Hardware,
	}
	ok := console_reinitialize_machine(
		m,
		&guard,
		&machine_live,
		&session,
		&paths,
		{},
		nil,
		false,
		missing_media,
		nil,
		&options,
	)
	testing.expect(t, !ok)
	testing.expect(t, !machine_live)
	testing.expect_value(t, machine.machine_hardware_trace_count(m), u64(1))
	trace_text := machine.machine_hardware_trace_text(m)
	testing.expect(t, strings.contains(trace_text, "reset"))
	delete(trace_text)
	trace := machine.machine_hardware_trace_detach(m)
	if trace != nil {free(trace)}
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.vm.ram), 0)
	testing.expect_value(t, len(m.bus.io), 0)
	testing.expect_value(t, len(m.vga.frame_pixels), 0)
	machine.machine_destroy(m)
	machine.machine_destroy(m)
}

@(test)
install_test_failed_replacement_machine_init_preserves_trace_and_cleans_resources :: proc(
	t: ^testing.T,
) {
	if !hv.available() {return}
	guard: Vm_Guard
	if !testing.expect(t, vm_guard_init(&guard)) {return}
	defer vm_guard_destroy(&guard)
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, 64 * 1024 * 1024)) {return}
	machine_live := true
	if !testing.expect(t, machine.machine_set_hardware_trace(m, true)) {
		machine.machine_destroy(m)
		return
	}
	machine.machine_trace_record(m, .Reset_Request, 0xCF9, 0x06)
	session: ^fat32session.Machine_Session
	paths: profile.Paths
	options := acceptance.Options {
		setup_diagnostics = .Hardware,
	}
	ok := console_reinitialize_machine_with_ram(
		m,
		&guard,
		&machine_live,
		&session,
		&paths,
		{},
		nil,
		false,
		"",
		nil,
		&options,
		512 * 1024,
	)
	testing.expect(t, !ok)
	testing.expect(t, !machine_live)
	testing.expect_value(t, machine.machine_hardware_trace_count(m), u64(1))
	trace_text := machine.machine_hardware_trace_text(m)
	testing.expect(t, strings.contains(trace_text, "reset"))
	delete(trace_text)
	testing.expect(t, m.vm.part == nil)
	testing.expect_value(t, len(m.vm.ram), 0)
	testing.expect_value(t, len(m.bus.io), 0)
	testing.expect_value(t, len(m.vga.frame_pixels), 0)
	trace := machine.machine_hardware_trace_detach(m)
	if trace != nil {free(trace)}
	machine.machine_destroy(m)
	machine.machine_destroy(m)
}

@(test)
install_test_finish_session_restores_boot_order_and_releases_media_controls :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	guest_path, _ := filepath.join({dir, "unrelated", "WINDOWS", "WIN.COM"})
	testing.expect(t, os.make_directory_all(filepath.dir(guest_path)) == nil)
	testing.expect(t, os.write_entire_file(guest_path, []u8{'g', 'u', 'e', 's', 't'}) == nil)

	shared := Shared {
		installing_windows_98 = true,
		cdrom_mounted         = true,
	}
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
		has_cmos = true,
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
			reset_count = 2,
			saved_cmos_valid = true,
			saved_cmos_38 = 0xA5,
			saved_cmos_3d = 0x5A,
		},
	}
	ctx.cmos[0x20] = 0x77
	ctx.cmos[0x38] = 0x15
	ctx.cmos[0x3D] = 0x32
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x20] = 0x99
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	testing.expect(t, install_session_finish(&ctx, m))
	testing.expect(t, !profile.install_state_active(&ctx.install_state))
	testing.expect_value(t, ctx.install_state.source_path, "")
	testing.expect(t, !shared.installing_windows_98)
	testing.expect(t, shared.cdrom_mounted)
	testing.expect_value(t, m.cmos.ram[0x38], u8(0x15))
	testing.expect_value(t, m.cmos.ram[0x3D], u8(0x32))
	testing.expect_value(t, ctx.cmos[0x20], u8(0x77))
	testing.expect_value(t, ctx.cmos[0x38], u8(0xA5))
	testing.expect_value(t, ctx.cmos[0x3D], u8(0x5A))
	testing.expect(t, ctx.has_cmos)

	loaded_state, state_diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded_state)
	testing.expect_value(t, state_diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded_state.phase, profile.Install_Phase.None)
	loaded_cmos, cmos_diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, cmos_diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, loaded_cmos[0x20], u8(0x77))
	testing.expect_value(t, loaded_cmos[0x38], u8(0xA5))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0x5A))
	guest, guest_error := os.read_entire_file(guest_path, context.temp_allocator)
	testing.expect(t, guest_error == nil)
	testing.expect_value(t, string(guest), "guest")
}

@(test)
install_test_finish_without_cmos_snapshot_does_not_write_cmos :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	testing.expect(t, os.write_entire_file(cmos_path, "keep") == nil)

	shared := Shared {
		installing_windows_98 = true,
	}
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
		install_state = profile.Install_State {
			phase = .Preparing,
			source_path = strings.clone("WIN98SE.ISO"),
			saved_cmos_valid = true,
			saved_cmos_38 = 0xA5,
			saved_cmos_3d = 0x5A,
		},
	}
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	testing.expect(t, install_session_finish(&ctx, m))
	testing.expect(t, !profile.install_state_active(&ctx.install_state))
	testing.expect(t, !ctx.has_cmos)
	contents, read_error := os.read_entire_file(cmos_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(contents), "keep")
}

@(test)
install_test_finish_with_unknown_boot_order_retains_cmos_and_logs_accurately :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})

	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
		has_cmos = true,
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
		},
	}
	ctx.cmos[0x38] = 0x15
	ctx.cmos[0x3D] = 0x32
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)

	testing.expect(t, install_session_finish(&ctx, m))
	loaded_cmos, diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, loaded_cmos[0x38], u8(0x15))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0x32))
	testing.expect_value(t, len(shared.log_lines), 1)
	testing.expect(t, strings.contains(shared.log_lines[0], "original boot order was unknown"))
	testing.expect(t, strings.contains(shared.log_lines[0], "current boot order retained"))
}

@(test)
install_test_finish_session_save_failure_keeps_active_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	blocked_parent, _ := filepath.join({dir, "not-a-directory"})
	testing.expect(t, os.write_entire_file(blocked_parent, []u8{'x'}) == nil)
	state_path, _ := filepath.join({blocked_parent, "install-state.json"})

	shared := Shared {
		installing_windows_98 = true,
		cdrom_mounted         = true,
	}
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
			reset_count = 2,
			saved_cmos_valid = true,
			saved_cmos_38 = 0xA5,
			saved_cmos_3d = 0x5A,
		},
	}
	defer profile.install_state_destroy(&ctx.install_state)
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	testing.expect(t, !install_session_finish(&ctx, m))
	testing.expect(t, profile.install_state_active(&ctx.install_state))
	testing.expect_value(t, ctx.install_state.source_path, "WIN98SE.ISO")
	testing.expect(t, shared.installing_windows_98)
	testing.expect(t, shared.cdrom_mounted)
	testing.expect_value(t, m.cmos.ram[0x38], u8(0x15))
	testing.expect_value(t, m.cmos.ram[0x3D], u8(0x32))
}

@(test)
install_test_console_finish_restores_boot_order_and_releases_install_media :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	paths := profile.Paths {
		cmos         = cmos_path,
		install_state = state_path,
	}
	state := profile.Install_State {
		phase            = .Setup_Running,
		milestone        = .Hardware_Detection,
		source_path      = strings.clone("WIN98SE.ISO"),
		reset_count      = 3,
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	defer profile.install_state_destroy(&state)
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x20] = 0x77
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	result := acceptance.Result {
		installation_milestone = "none",
		desktop_marker_seen     = true,
		desktop_enum_valid      = true,
		desktop_vga_irq11_seen  = true,
	}

	diagnostic := console_install_session_finish(&paths, &state, m, &result)
	testing.expect_value(t, diagnostic, Install_Session_Finish_Diagnostic.None)
	testing.expect(t, !profile.install_state_active(&state))
	testing.expect_value(t, state.source_path, "")
	testing.expect_value(t, m.cmos.ram[0x38], u8(0xA5))
	testing.expect_value(t, m.cmos.ram[0x3D], u8(0x5A))
	testing.expect_value(t, result.installation_milestone, "hardware_detection")
	testing.expect(t, result.desktop_marker_seen)
	testing.expect(t, result.desktop_enum_valid)
	testing.expect(t, result.desktop_vga_irq11_seen)

	persisted, state_diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&persisted)
	testing.expect_value(t, state_diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect(t, !profile.install_state_active(&persisted))
	testing.expect_value(t, persisted.source_path, "")
	persisted_cmos, cmos_diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, cmos_diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, persisted_cmos[0x20], u8(0x77))
	testing.expect_value(t, persisted_cmos[0x38], u8(0xA5))
	testing.expect_value(t, persisted_cmos[0x3D], u8(0x5A))
}

@(test)
install_test_console_finish_without_saved_boot_order_retains_current_cmos :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	paths := profile.Paths {
		cmos         = cmos_path,
		install_state = state_path,
	}
	state := profile.Install_State {
		phase       = .Setup_Running,
		source_path = strings.clone("WIN98SE.ISO"),
	}
	defer profile.install_state_destroy(&state)
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32

	diagnostic := console_install_session_finish(&paths, &state, m, nil)
	testing.expect_value(t, diagnostic, Install_Session_Finish_Diagnostic.None)
	testing.expect_value(t, m.cmos.ram[0x38], u8(0x15))
	testing.expect_value(t, m.cmos.ram[0x3D], u8(0x32))
	persisted_cmos, cmos_diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, cmos_diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, persisted_cmos[0x38], u8(0x15))
	testing.expect_value(t, persisted_cmos[0x3D], u8(0x32))
}

@(test)
install_test_shared_finish_without_cmos_snapshot_only_inactivates_install :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	testing.expect(t, os.write_entire_file(cmos_path, "keep") == nil)
	paths := profile.Paths {
		cmos         = cmos_path,
		install_state = state_path,
	}
	state := profile.Install_State {
		phase            = .Setup_Running,
		source_path      = strings.clone("WIN98SE.ISO"),
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	defer profile.install_state_destroy(&state)

	finish, diagnostic := install_session_finish_persist(&paths, &state, {}, false)
	testing.expect_value(t, diagnostic, Install_Session_Finish_Diagnostic.None)
	testing.expect(t, !finish.have_cmos)
	testing.expect(t, !finish.restored_boot_order)
	testing.expect(t, !profile.install_state_active(&state))
	contents, read_error := os.read_entire_file(cmos_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(contents), "keep")
}

@(test)
install_test_console_finish_failure_is_nonzero_and_preserves_evidence :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	blocked_parent, _ := filepath.join({dir, "not-a-directory"})
	testing.expect(t, os.write_entire_file(blocked_parent, "blocked") == nil)
	state_path, _ := filepath.join({blocked_parent, "install-state.json"})
	paths := profile.Paths {
		cmos         = cmos_path,
		install_state = state_path,
	}
	state := profile.Install_State {
		phase            = .Setup_Running,
		milestone        = .Hardware_Detection,
		source_path      = strings.clone("WIN98SE.ISO"),
		saved_cmos_valid = true,
		saved_cmos_38    = 0xA5,
		saved_cmos_3d    = 0x5A,
	}
	defer profile.install_state_destroy(&state)
	m := new(machine.Machine)
	defer free(m)
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	result := acceptance.Result {
		installation_milestone = "none",
		desktop_marker_seen     = true,
		desktop_enum_valid      = true,
		desktop_vga_irq11_seen  = true,
	}

	diagnostic := console_install_session_finish(&paths, &state, m, &result)
	testing.expect_value(
		t,
		diagnostic,
		Install_Session_Finish_Diagnostic.Install_State_Save_Failed,
	)
	return_code := console_install_session_finish_failure(&result)
	testing.expect_value(t, return_code, 1)
	testing.expect_value(t, result.exit_code, 1)
	testing.expect_value(t, result.stop_reason, acceptance.Stop_Reason.Configuration_Error)
	testing.expect_value(t, result.last_progress_reason, "install_session_finish_failed")
	testing.expect_value(t, result.installation_milestone, "hardware_detection")
	testing.expect(t, result.desktop_marker_seen)
	testing.expect(t, result.desktop_enum_valid)
	testing.expect(t, result.desktop_vga_irq11_seen)
	testing.expect(t, profile.install_state_active(&state))
	testing.expect_value(t, state.source_path, "WIN98SE.ISO")
	testing.expect_value(t, m.cmos.ram[0x38], u8(0x15))
	testing.expect_value(t, m.cmos.ram[0x3D], u8(0x32))
}

@(test)
install_test_stopped_command_queue_rejects_owned_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shared: Shared
	testing.expect(
		t,
		!push_cmd(&shared, Command{kind = .Install_Windows_98, path = strings.clone("late.iso")}),
	)
	testing.expect_value(t, len(shared.cmds), 0)

	shared.running = true
	testing.expect(
		t,
		push_cmd(&shared, Command{kind = .Mount_Cdrom, path = strings.clone("queued.iso")}),
	)
	testing.expect_value(t, len(shared.cmds), 1)
	command_queue_destroy(&shared)
	testing.expect_value(t, len(shared.cmds), 0)
}

@(test)
install_test_pending_dialog_replaces_owned_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	pending := pending_mount_create()
	pending.dialogs = 2
	first := strings.clone_to_cstring("first.iso")
	second := strings.clone_to_cstring("second.iso")
	defer delete(first)
	defer delete(second)
	first_list := [2]cstring{first, nil}
	second_list := [2]cstring{second, nil}
	mount_dialog_cb(pending, &first_list[0], 0)
	mount_dialog_cb(pending, &second_list[0], 0)
	path, ready := pending_take(pending)
	testing.expect(t, ready)
	testing.expect_value(t, path, "second.iso")
	delete(path)
	pending_mount_release(pending)
}

@(private = "file")
install_test_bind_state :: proc(
	t: ^testing.T,
	state: ^profile.Install_State,
	root: string,
	transaction_id: u64 = 1,
) {
	if state == nil {return}
	image_path, path_error := filepath.join({root, "bound-install.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	identity: profile.Install_Image_Identity
	identity[0] = 0x52
	identity[15] = u8(transaction_id & 0xFF) | 1
	phase := state.phase
	state.phase = .None
	diagnostic := profile.install_state_bind(state, image_path, identity, transaction_id)
	state.phase = phase
	testing.expect_value(t, diagnostic, profile.Install_Binding_Diagnostic.None)
}

install_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	defer delete(base)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(
		base,
		"retvrn99_install_lifecycle_*",
		context.allocator,
	)
	testing.expect(t, dir_error == nil)
	return dir
}
