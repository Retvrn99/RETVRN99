// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "fat32"
import "machine"
import "profile"
import "vga"
import "win98prep"

install_test_snapshot :: proc(line: string) -> vga.Text_Snapshot {
	snap: vga.Text_Snapshot
	for &cell in snap.cells {cell = u16(' ')}
	for ch, col in line {
		if col >= 80 {break}
		snap.cells[24 * 80 + col] = u16(ch)
	}
	return snap
}

@(test)
install_test_requires_root_c_prompt :: proc(t: ^testing.T) {
	root := install_test_snapshot(`C:\>`)
	testing.expect(t, snapshot_has_c_prompt(&root))
	lower := install_test_snapshot(`c:\>`)
	testing.expect(t, snapshot_has_c_prompt(&lower))

	boot_text := install_test_snapshot(`Checking drive C:`)
	testing.expect(t, !snapshot_has_c_prompt(&boot_text))
	floppy := install_test_snapshot(`A:\>`)
	testing.expect(t, !snapshot_has_c_prompt(&floppy))
	subdirectory := install_test_snapshot(`C:\WINDOWS>`)
	testing.expect(t, !snapshot_has_c_prompt(&subdirectory))
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
install_test_invalid_retry_restores_previous_launch_pending_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	state_path, _ := filepath.join({dir, "install-state.json"})
	missing_iso, _ := filepath.join({dir, "missing.iso"})
	install_root, _ := filepath.join({dir, "install"})
	c_drive, _ := filepath.join({dir, "c_drive"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{install_state = state_path},
		install_state = profile.Install_State {
			phase = .Launch_Pending,
			source_path = strings.clone("original.iso"),
			reset_count = 3,
		},
		cdrom_path = strings.clone("original.iso"),
	}
	defer profile.install_state_destroy(&ctx.install_state)
	defer delete(ctx.cdrom_path)
	defer vm_log_destroy(&shared)
	previous := install_state_clone(&ctx.install_state)
	previous_cdrom_path := strings.clone(ctx.cdrom_path)
	defer profile.install_state_destroy(&previous)
	defer delete(previous_cdrom_path)

	profile.install_state_destroy(&ctx.install_state)
	ctx.install_state = install_state_candidate("retry.iso", nil, false, &previous)
	delete(ctx.cdrom_path)
	ctx.cdrom_path = strings.clone("retry.iso")
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &ctx.install_state),
		profile.Install_State_Diagnostic.None,
	)
	report := win98prep.prepare(missing_iso, install_root, c_drive)
	defer win98prep.report_destroy(&report)
	testing.expect_value(t, report.diagnostic, win98prep.Diagnostic.Media_Rejected)
	testing.expect_value(
		t,
		report.transaction.state,
		win98prep.Preparation_Transaction_State.Inactive,
	)
	testing.expect_value(
		t,
		install_preparation_restore_previous(&ctx, &previous, &previous_cdrom_path, &report),
		Install_Preparation_State_Restore.Restored,
	)
	testing.expect_value(t, ctx.install_state.phase, profile.Install_Phase.Launch_Pending)
	testing.expect_value(t, ctx.install_state.source_path, "original.iso")
	testing.expect_value(t, ctx.install_state.reset_count, u32(3))
	testing.expect_value(t, ctx.cdrom_path, "original.iso")
	waiting, typing, key_index := false, true, 9
	install_autorun_restore(&waiting, &typing, &key_index, &ctx.install_state)
	testing.expect(t, waiting)
	testing.expect(t, !typing)
	testing.expect_value(t, key_index, 0)
	loaded, diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, profile.Install_Phase.Launch_Pending)
	testing.expect_value(t, loaded.source_path, "original.iso")
}

@(test)
install_test_initial_safe_failure_restores_inactive_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	state_path, _ := filepath.join({dir, "install-state.json"})
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		paths = profile.Paths{install_state = state_path},
		install_state = profile.Install_State {
			phase = .Preparing,
			source_path = strings.clone("retry.iso"),
		},
		cdrom_path = strings.clone("retry.iso"),
	}
	defer profile.install_state_destroy(&ctx.install_state)
	defer delete(ctx.cdrom_path)
	defer vm_log_destroy(&shared)
	previous: profile.Install_State
	previous_cdrom_path := ""
	testing.expect_value(
		t,
		profile.install_state_save(state_path, &ctx.install_state),
		profile.Install_State_Diagnostic.None,
	)
	report := win98prep.Report {
		diagnostic = .Extract_Failed,
		transaction = win98prep.Preparation_Transaction{state = .Rolled_Back},
	}
	testing.expect_value(
		t,
		install_preparation_restore_previous(&ctx, &previous, &previous_cdrom_path, &report),
		Install_Preparation_State_Restore.Restored,
	)
	testing.expect(t, !profile.install_state_active(&ctx.install_state))
	testing.expect_value(t, ctx.install_state.source_path, "")
	testing.expect_value(t, ctx.cdrom_path, "")
	loaded, diagnostic := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded)
	testing.expect_value(t, diagnostic, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.phase, profile.Install_Phase.None)
}

@(test)
install_test_previous_state_restore_failure_keeps_preparing_recovery_state :: proc(t: ^testing.T) {
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
			phase = .Preparing,
			source_path = strings.clone("retry.iso"),
		},
		cdrom_path = strings.clone("retry.iso"),
	}
	defer profile.install_state_destroy(&ctx.install_state)
	defer delete(ctx.cdrom_path)
	defer vm_log_destroy(&shared)
	previous := profile.Install_State {
		phase       = .Launch_Pending,
		source_path = strings.clone("original.iso"),
	}
	previous_cdrom_path := strings.clone("original.iso")
	defer profile.install_state_destroy(&previous)
	defer delete(previous_cdrom_path)
	report := win98prep.Report {
		diagnostic = .Extract_Failed,
		transaction = win98prep.Preparation_Transaction{state = .Rolled_Back},
	}

	testing.expect_value(
		t,
		install_preparation_restore_previous(&ctx, &previous, &previous_cdrom_path, &report),
		Install_Preparation_State_Restore.Persistence_Failed,
	)
	testing.expect_value(t, ctx.install_state.phase, profile.Install_Phase.Preparing)
	testing.expect_value(t, ctx.install_state.source_path, "retry.iso")
	testing.expect_value(t, ctx.cdrom_path, "retry.iso")
	testing.expect(t, !install_state_launch_pending(&ctx.install_state))
	testing.expect_value(t, previous.phase, profile.Install_Phase.Launch_Pending)
	testing.expect_value(t, previous.source_path, "original.iso")
	testing.expect(t, strings.contains(shared.frozen_msg, "recovery state retained"))
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
	m: machine.Machine
	testing.expect(t, install_session_finish(&ctx, &m))
	loaded_cmos, diagnostic := profile.cmos_load(cmos_path)
	testing.expect_value(t, diagnostic, profile.Cmos_Diagnostic.None)
	testing.expect_value(t, loaded_cmos[0x38], u8(0xA5))
	testing.expect_value(t, loaded_cmos[0x3D], u8(0x5A))
}

@(test)
install_test_preparing_state_never_autoruns :: proc(t: ^testing.T) {
	preparing := profile.Install_State {
		phase = .Preparing,
	}
	pending := profile.Install_State {
		phase = .Launch_Pending,
	}
	running := profile.Install_State {
		phase = .Setup_Running,
	}
	testing.expect(t, !install_state_launch_pending(&preparing))
	testing.expect(t, install_state_launch_pending(&pending))
	testing.expect(t, !install_state_launch_pending(&running))
}

@(test)
install_test_retry_cancels_pending_autorun :: proc(t: ^testing.T) {
	waiting := true
	typing := true
	key_index := 7
	install_autorun_cancel(&waiting, &typing, &key_index)
	testing.expect(t, !waiting)
	testing.expect(t, !typing)
	testing.expect_value(t, key_index, 0)
}

@(test)
install_test_reboot_restores_only_surviving_launch_pending :: proc(t: ^testing.T) {
	pending := profile.Install_State {
		phase = .Launch_Pending,
	}
	waiting := false
	typing := true
	key_index := 7
	install_autorun_restore(&waiting, &typing, &key_index, &pending)
	testing.expect(t, waiting)
	testing.expect(t, !typing)
	testing.expect_value(t, key_index, 0)

	preparing := profile.Install_State {
		phase = .Preparing,
	}
	waiting = true
	typing = true
	key_index = 4
	install_autorun_restore(&waiting, &typing, &key_index, &preparing)
	testing.expect(t, !waiting)
	testing.expect(t, !typing)
	testing.expect_value(t, key_index, 0)
}

@(test)
install_test_launch_state_save_failure_freezes_before_enter :: proc(t: ^testing.T) {
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
	waiting := true
	typing := true
	key_index := len(INSTALL_AUTORUN_KEYS) - 1
	frozen := false
	testing.expect(t, !install_autorun_prepare_enter(&ctx, &waiting, &typing, &key_index, &frozen))
	testing.expect_value(t, ctx.install_state.phase, profile.Install_Phase.Launch_Pending)
	testing.expect(t, waiting)
	testing.expect(t, !typing)
	testing.expect_value(t, key_index, 0)
	testing.expect(t, frozen)
	testing.expect(t, strings.contains(shared.frozen_msg, "Reset to retry"))
}

@(test)
install_test_rollback_failure_report_always_blocks_reboot :: proc(t: ^testing.T) {
	failed_state := win98prep.Report {
		diagnostic = .Launcher_Failed,
		transaction = win98prep.Preparation_Transaction{state = .Rollback_Failed},
	}
	testing.expect(t, install_preparation_rollback_failed(&failed_state))
	failed_diagnostic := win98prep.Report {
		diagnostic = .Rollback_Failed,
	}
	testing.expect(t, install_preparation_rollback_failed(&failed_diagnostic))
	safe_failure := win98prep.Report {
		diagnostic = .Launcher_Failed,
	}
	testing.expect(t, !install_preparation_rollback_failed(&safe_failure))
}

@(test)
install_test_attached_boot_requires_live_volume :: proc(t: ^testing.T) {
	ctx := Vm_Ctx {
		attach = true,
	}
	m: machine.Machine
	m.cmos.ram[0x20] = 0x7A
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, !vm_boot(&ctx, &m))
	testing.expect_value(t, m.cmos.ram[0x20], u8(0x7A))

	ctx.attach = false
	testing.expect(t, vm_volume_ready(&ctx))
}

@(test)
install_test_reset_can_reopen_missing_protected_volume :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	dir := install_test_directory(t)
	defer os.remove_all(dir)
	io_sys_path, _ := filepath.join({dir, "IO.SYS"})
	testing.expect(t, os.write_entire_file(io_sys_path, "boot") == nil)
	shared: Shared
	ctx := Vm_Ctx {
		shared = &shared,
		attach = true,
		paths = profile.Paths{c_drive = dir},
	}
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, vm_ensure_volume(&ctx))
	testing.expect(t, vm_volume_ready(&ctx))
	testing.expect(t, vm_close_volume(&ctx))
	testing.expect(t, ctx.volume == nil)
}

@(test)
install_test_reset_rejects_frozen_protected_volume :: proc(t: ^testing.T) {
	volume := fat32.Volume {
		frozen = true,
	}
	ctx := Vm_Ctx {
		attach = true,
		volume = &volume,
		bd     = fat32.volume_block_device(&volume),
	}
	testing.expect(t, !vm_volume_ready(&ctx))
	testing.expect(t, !vm_ensure_volume(&ctx))
	testing.expect(t, ctx.volume == &volume)
}

@(test)
install_test_failed_close_keeps_machine_live_for_retry :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	shared: Shared
	volume := fat32.Volume {
		frozen = true,
	}
	ctx := Vm_Ctx {
		shared = &shared,
		volume = &volume,
	}
	ctx.guard.valid = true
	m: machine.Machine
	machine_live := true
	testing.expect(t, !vm_close_then_shutdown(&ctx, &m, &machine_live))
	testing.expect(t, machine_live)
	testing.expect(t, ctx.guard.valid)
	testing.expect(t, ctx.volume == &volume)
	vm_log_destroy(&shared)
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
	guest_path, _ := filepath.join({dir, "c_drive", "WINDOWS", "WIN.COM"})
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
	m: machine.Machine
	m.cmos.ram[0x20] = 0x99
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	testing.expect(t, install_session_finish(&ctx, &m))
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
	m: machine.Machine
	testing.expect(t, install_session_finish(&ctx, &m))
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
	m: machine.Machine

	testing.expect(t, install_session_finish(&ctx, &m))
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
	m: machine.Machine
	m.cmos.ram[0x38] = 0x15
	m.cmos.ram[0x3D] = 0x32
	testing.expect(t, !install_session_finish(&ctx, &m))
	testing.expect(t, profile.install_state_active(&ctx.install_state))
	testing.expect_value(t, ctx.install_state.source_path, "WIN98SE.ISO")
	testing.expect(t, shared.installing_windows_98)
	testing.expect(t, shared.cdrom_mounted)
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
install_test_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	dir, dir_error := os.make_directory_temp(
		base,
		"retvrn99_install_lifecycle_*",
		context.allocator,
	)
	testing.expect(t, dir_error == nil)
	return dir
}
