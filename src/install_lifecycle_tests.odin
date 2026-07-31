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
	shared: Shared
	defer vm_log_destroy(&shared)
	ctx := Vm_Ctx {
		shared = &shared,
	}
	ctx.volume_open_error = fat32session.error_make(
		.Image_Missing,
		false,
		.Not_Started,
		0,
		0,
		"selected hard-drive image does not exist",
	)
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
		shared = &shared,
		cpu_mode = .GSW_886,
		paths = profile.Paths{cmos = cmos_path, install_state = state_path},
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
		},
	}
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	if !testing.expect(t, machine.machine_init(m, 64 * 1024 * 1024)) {return}
	defer machine.machine_destroy(m)
	ctx.lifetime.m = m
	ctx.lifetime.state = .Running
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
	initial_cmos: profile.Cmos_Data
	ctx.install_state = install_state_candidate("WIN98SE.ISO", initial_cmos[:], false, nil)
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

	ctx.lifetime.state = .Stopped
	ctx.lifetime.cmos = boot_cmos
	ctx.lifetime.has_cmos = true
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
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
			reset_count = 2,
			saved_cmos_valid = true,
			saved_cmos_38 = 0xA5,
			saved_cmos_3d = 0x5A,
		},
	}
	ctx.lifetime.state = .Stopped
	ctx.lifetime.has_cmos = true
	ctx.lifetime.cmos[0x20] = 0x77
	ctx.lifetime.cmos[0x38] = 0x15
	ctx.lifetime.cmos[0x3D] = 0x32
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
	retained_cmos, retained := vm_lifetime_cmos_snapshot(&ctx.lifetime)
	testing.expect(t, retained)
	testing.expect_value(t, retained_cmos[0x20], u8(0x77))
	testing.expect_value(t, retained_cmos[0x38], u8(0xA5))
	testing.expect_value(t, retained_cmos[0x3D], u8(0x5A))

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
	ctx.lifetime.state = .Stopped
	defer vm_log_destroy(&shared)
	m := new(machine.Machine)
	defer free(m)
	testing.expect(t, install_session_finish(&ctx, m))
	testing.expect(t, !profile.install_state_active(&ctx.install_state))
	_, retained := vm_lifetime_cmos_snapshot(&ctx.lifetime)
	testing.expect(t, !retained)
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
		install_state = profile.Install_State {
			phase = .Setup_Running,
			source_path = strings.clone("WIN98SE.ISO"),
		},
	}
	ctx.lifetime.state = .Stopped
	ctx.lifetime.has_cmos = true
	ctx.lifetime.cmos[0x38] = 0x15
	ctx.lifetime.cmos[0x3D] = 0x32
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
	ctx.lifetime.state = .Stopped
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
install_test_console_finish_restores_boot_order_and_releases_install_media :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	paths := profile.Paths {
		cmos          = cmos_path,
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
		desktop_marker_seen    = true,
		desktop_enum_valid     = true,
		desktop_vga_irq11_seen = true,
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
install_test_console_finish_without_saved_boot_order_retains_current_cmos :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	paths := profile.Paths {
		cmos          = cmos_path,
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
install_test_shared_finish_without_cmos_snapshot_only_inactivates_install :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	state_path, _ := filepath.join({dir, "install-state.json"})
	testing.expect(t, os.write_entire_file(cmos_path, "keep") == nil)
	paths := profile.Paths {
		cmos          = cmos_path,
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
install_test_console_finish_failure_is_nonzero_and_preserves_evidence :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	cmos_path, _ := filepath.join({dir, "cmos.bin"})
	blocked_parent, _ := filepath.join({dir, "not-a-directory"})
	testing.expect(t, os.write_entire_file(blocked_parent, "blocked") == nil)
	state_path, _ := filepath.join({blocked_parent, "install-state.json"})
	paths := profile.Paths {
		cmos          = cmos_path,
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
		desktop_marker_seen    = true,
		desktop_enum_valid     = true,
		desktop_vga_irq11_seen = true,
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
