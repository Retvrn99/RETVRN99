// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "disk"
import "fat32session"
import "host"
import "machine"
import "profile"

Vm_Lifetime_Test_Event :: enum u8 {
	Barrier_Reset,
	Barrier_Clean_Close,
	Disk_Detach,
	Session_Commit,
	Session_Retain,
	Guard_Unbind,
	Audio_Close,
	Cmos_Save,
	Machine_Destroy,
	Machine_Init,
	Configure,
	Disk_Attach,
	Guard_Bind,
}

Vm_Lifetime_Test_Context :: struct {
	events:             [64]Vm_Lifetime_Test_Event,
	event_count:        int,
	machine_live:       bool,
	machine_init_ok:    bool,
	commit_close_fails: bool,
}

vm_lifetime_test_record :: proc(ctx: ^Vm_Lifetime_Test_Context, event: Vm_Lifetime_Test_Event) {
	if ctx == nil || ctx.event_count >= len(ctx.events) {return}
	ctx.events[ctx.event_count] = event
	ctx.event_count += 1
}

vm_lifetime_test_machine_init :: proc(ctx: rawptr, _: ^machine.Machine, _: int) -> bool {
	test_ctx := (^Vm_Lifetime_Test_Context)(ctx)
	vm_lifetime_test_record(test_ctx, .Machine_Init)
	test_ctx.machine_live = test_ctx.machine_init_ok
	return test_ctx.machine_live
}

vm_lifetime_test_machine_destroy :: proc(ctx: rawptr, _: ^machine.Machine) {
	test_ctx := (^Vm_Lifetime_Test_Context)(ctx)
	vm_lifetime_test_record(test_ctx, .Machine_Destroy)
	test_ctx.machine_live = false
}

vm_lifetime_test_machine_live :: proc(ctx: rawptr, _: ^machine.Machine) -> bool {
	return (^Vm_Lifetime_Test_Context)(ctx).machine_live
}

vm_lifetime_test_configure :: proc(ctx: rawptr, _: ^machine.Machine, _: []u8) -> bool {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Configure)
	return true
}

vm_lifetime_test_disk_attach :: proc(ctx: rawptr, m: ^machine.Machine, _: disk.Block_Device) {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Disk_Attach)
	m.has_disk = true
}

vm_lifetime_test_disk_detach :: proc(ctx: rawptr, m: ^machine.Machine) -> bool {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Disk_Detach)
	m.has_disk = false
	return true
}

vm_lifetime_test_barrier :: proc(
	ctx: rawptr,
	_: ^fat32session.Machine_Session,
	reason: fat32session.Barrier_Reason,
) -> (
	fat32session.Barrier_Result,
	fat32session.Session_Error,
) {
	test_ctx := (^Vm_Lifetime_Test_Context)(ctx)
	switch reason {
	case .Reset:
		vm_lifetime_test_record(test_ctx, .Barrier_Reset)
	case .Clean_Close:
		vm_lifetime_test_record(test_ctx, .Barrier_Clean_Close)
	case .Block_Flush, .Observation, .Stop:
	}
	return {}, {}
}

vm_lifetime_test_close :: proc(
	ctx: rawptr,
	_: ^fat32session.Machine_Session,
	mode: fat32session.Close_Mode,
) -> fat32session.Session_Error {
	test_ctx := (^Vm_Lifetime_Test_Context)(ctx)
	if mode == .Retain {
		vm_lifetime_test_record(test_ctx, .Session_Retain)
		return {}
	}
	vm_lifetime_test_record(test_ctx, .Session_Commit)
	if test_ctx.commit_close_fails {
		return fat32session.error_make(.Wal_IO, false, .Retained, 0, 0, "injected close failure")
	}
	return {}
}

vm_lifetime_test_session_ready :: proc(_: rawptr, session: ^fat32session.Machine_Session) -> bool {
	return session != nil
}

vm_lifetime_test_audio_close :: proc(ctx: rawptr, _: ^host.Host_Audio) {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Audio_Close)
}

vm_lifetime_test_cmos_save :: proc(
	ctx: rawptr,
	_: string,
	_: profile.Cmos_Data,
) -> profile.Cmos_Diagnostic {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Cmos_Save)
	return .None
}

vm_lifetime_test_guard_bind :: proc(ctx: rawptr, _: ^Vm_Guard, _: ^machine.Machine) {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Guard_Bind)
}

vm_lifetime_test_guard_unbind :: proc(ctx: rawptr, _: ^Vm_Guard) {
	vm_lifetime_test_record((^Vm_Lifetime_Test_Context)(ctx), .Guard_Unbind)
}

vm_lifetime_test_adapters :: proc(ctx: ^Vm_Lifetime_Test_Context) -> Vm_Lifetime_Adapters {
	return {
		ctx = ctx,
		configure = vm_lifetime_test_configure,
		machine_init = vm_lifetime_test_machine_init,
		machine_destroy = vm_lifetime_test_machine_destroy,
		machine_live = vm_lifetime_test_machine_live,
		disk_attach = vm_lifetime_test_disk_attach,
		disk_detach = vm_lifetime_test_disk_detach,
		barrier = vm_lifetime_test_barrier,
		close_session = vm_lifetime_test_close,
		session_ready = vm_lifetime_test_session_ready,
		audio_close = vm_lifetime_test_audio_close,
		cmos_save = vm_lifetime_test_cmos_save,
		guard_bind = vm_lifetime_test_guard_bind,
		guard_unbind = vm_lifetime_test_guard_unbind,
	}
}

vm_lifetime_test_init :: proc(
	t: ^testing.T,
	lifetime: ^Vm_Lifetime,
	ctx: ^Vm_Lifetime_Test_Context,
) -> bool {
	result := vm_lifetime_init(
		lifetime,
		{
			ram_size = 1024 * 1024,
			attach_storage = true,
			cmos_path = "cmos.bin",
			clock_running = true,
		},
		vm_lifetime_test_adapters(ctx),
	)
	return testing.expect(t, result.completed)
}

vm_lifetime_test_expect_events :: proc(
	t: ^testing.T,
	ctx: ^Vm_Lifetime_Test_Context,
	expected: []Vm_Lifetime_Test_Event,
) -> bool {
	if !testing.expect_value(t, ctx.event_count, len(expected)) {return false}
	for event, index in expected {
		if !testing.expect_value(t, ctx.events[index], event) {return false}
	}
	return true
}

@(test)
vm_lifetime_test_stop_orders_durability_before_teardown_and_retains_once :: proc(t: ^testing.T) {
	ctx := Vm_Lifetime_Test_Context {
		machine_live    = true,
		machine_init_ok = true,
	}
	lifetime: Vm_Lifetime
	if !vm_lifetime_test_init(t, &lifetime, &ctx) {return}
	session := new(fat32session.Machine_Session)
	defer free(session)
	lifetime.session = session
	lifetime.state = .Running
	lifetime.machine_generation = 1
	lifetime.m.has_disk = true

	result := vm_lifetime_stop(&lifetime)
	if !testing.expect(t, result.completed) {return}
	testing.expect_value(t, result.state, Vm_Lifetime_State.Stopped)
	vm_lifetime_test_expect_events(
		t,
		&ctx,
		[]Vm_Lifetime_Test_Event {
			.Barrier_Clean_Close,
			.Disk_Detach,
			.Session_Commit,
			.Guard_Unbind,
			.Audio_Close,
			.Cmos_Save,
			.Machine_Destroy,
		},
	)
	observation := vm_lifetime_observation(&lifetime)
	testing.expect(t, observation.cmos_retained_once)
	_ = vm_lifetime_destroy(&lifetime)
}

@(test)
vm_lifetime_test_clean_close_failure_keeps_machine_and_session_recoverable :: proc(t: ^testing.T) {
	ctx := Vm_Lifetime_Test_Context {
		machine_live       = true,
		machine_init_ok    = true,
		commit_close_fails = true,
	}
	lifetime: Vm_Lifetime
	if !vm_lifetime_test_init(t, &lifetime, &ctx) {return}
	session := new(fat32session.Machine_Session)
	defer free(session)
	lifetime.session = session
	lifetime.state = .Running
	lifetime.machine_generation = 1
	lifetime.m.has_disk = true

	result := vm_lifetime_stop(&lifetime)
	testing.expect(t, !result.completed)
	testing.expect_value(t, result.diagnostic, Vm_Lifetime_Diagnostic.Clean_Close_Failed)
	testing.expect_value(t, result.state, Vm_Lifetime_State.Running)
	testing.expect(t, result.recoverable && result.session_retained)
	testing.expect(t, lifetime.session == session && ctx.machine_live && lifetime.m.has_disk)
	vm_lifetime_test_expect_events(
		t,
		&ctx,
		[]Vm_Lifetime_Test_Event {
			.Barrier_Clean_Close,
			.Disk_Detach,
			.Session_Commit,
			.Disk_Attach,
		},
	)

	ctx.commit_close_fails = false
	_ = vm_lifetime_destroy(&lifetime)
}

@(test)
vm_lifetime_test_reset_uses_same_boot_and_teardown_trace :: proc(t: ^testing.T) {
	ctx := Vm_Lifetime_Test_Context {
		machine_live    = true,
		machine_init_ok = true,
	}
	lifetime: Vm_Lifetime
	if !vm_lifetime_test_init(t, &lifetime, &ctx) {return}
	session := new(fat32session.Machine_Session)
	defer free(session)
	lifetime.session = session
	lifetime.state = .Running
	lifetime.machine_generation = 1
	lifetime.m.has_disk = true

	result := vm_lifetime_reset(&lifetime)
	if !testing.expect(t, result.completed) {return}
	vm_lifetime_test_expect_events(
		t,
		&ctx,
		[]Vm_Lifetime_Test_Event {
			.Barrier_Reset,
			.Disk_Detach,
			.Guard_Unbind,
			.Audio_Close,
			.Cmos_Save,
			.Machine_Destroy,
			.Machine_Init,
			.Configure,
			.Disk_Attach,
			.Guard_Bind,
		},
	)
	ctx.event_count = 0
	_ = vm_lifetime_destroy(&lifetime)
}

@(test)
vm_lifetime_test_failed_boot_releases_session_with_recovery_evidence :: proc(t: ^testing.T) {
	ctx := Vm_Lifetime_Test_Context {
		machine_init_ok    = false,
		commit_close_fails = true,
	}
	lifetime: Vm_Lifetime
	if !vm_lifetime_test_init(t, &lifetime, &ctx) {return}
	session := new(fat32session.Machine_Session)
	defer free(session)
	lifetime.session = session

	result := vm_lifetime_start(&lifetime)
	testing.expect(t, !result.completed)
	testing.expect_value(t, result.diagnostic, Vm_Lifetime_Diagnostic.Machine_Init_Failed)
	testing.expect_value(t, result.state, Vm_Lifetime_State.Recovery)
	testing.expect(t, result.recoverable && result.session_retained)
	testing.expect(t, lifetime.session == nil)
	vm_lifetime_test_expect_events(
		t,
		&ctx,
		[]Vm_Lifetime_Test_Event {
			.Machine_Init,
			.Guard_Unbind,
			.Audio_Close,
			.Machine_Destroy,
			.Session_Commit,
			.Session_Retain,
		},
	)
	_ = vm_lifetime_destroy(&lifetime)
}

vm_lifetime_test_frontend_trace :: proc(t: ^testing.T, ctx: ^Vm_Lifetime_Test_Context) -> bool {
	ctx.machine_init_ok = true
	lifetime: Vm_Lifetime
	if !vm_lifetime_test_init(t, &lifetime, ctx) {return false}
	session := new(fat32session.Machine_Session)
	defer free(session)
	lifetime.session = session
	if !testing.expect(t, vm_lifetime_start(&lifetime).completed) {return false}
	if !testing.expect(t, vm_lifetime_reset(&lifetime).completed) {return false}
	if !testing.expect(t, vm_lifetime_stop(&lifetime).completed) {return false}
	return testing.expect(t, vm_lifetime_destroy(&lifetime).completed)
}

@(test)
vm_lifetime_test_gui_and_console_share_start_reset_stop_trace :: proc(t: ^testing.T) {
	gui, console: Vm_Lifetime_Test_Context
	if !vm_lifetime_test_frontend_trace(t, &gui) {return}
	if !vm_lifetime_test_frontend_trace(t, &console) {return}
	if !testing.expect_value(t, gui.event_count, console.event_count) {return}
	for index in 0 ..< gui.event_count {
		if !testing.expect_value(t, gui.events[index], console.events[index]) {return}
	}
}
