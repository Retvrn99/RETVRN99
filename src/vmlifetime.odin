// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:slice"
import "core:strings"
import "core:sync"
import "disk"
import "fat32session"
import "host"
import "machine"
import "profile"

Vm_Lifetime_State :: enum u8 {
	Uninitialized,
	Stopped,
	Running,
	Maintenance,
	Recovery,
	Destroy_Failed,
}

Vm_Lifetime_Diagnostic :: enum u8 {
	None,
	Invalid_State,
	Guard_Init_Failed,
	Volume_Open_Failed,
	Durability_Failed,
	Clean_Close_Failed,
	Machine_Init_Failed,
	Machine_Configure_Failed,
	Hardware_Trace_Failed,
	Media_Failed,
	Guard_Destroy_Failed,
}

Vm_Lifetime_Result :: struct {
	completed:        bool,
	diagnostic:       Vm_Lifetime_Diagnostic,
	state:            Vm_Lifetime_State,
	recoverable:      bool,
	session_retained: bool,
	storage_error:    fat32session.Session_Error,
}

Vm_Lifetime_Observation :: struct {
	state:                   Vm_Lifetime_State,
	running:                 bool,
	maintenance:             bool,
	session_ready:           bool,
	session_retained:        bool,
	machine_generation:      u64,
	cmos_retained_once:      bool,
	hardware_trace_retained: bool,
	floppy_mounted:          bool,
	optical_mounted:         bool,
	guard:                   Vm_Guard_Stats,
}

Vm_Lifetime_Configure_Proc :: proc(ctx: rawptr, m: ^machine.Machine, cmos: []u8) -> bool
Vm_Lifetime_Log_Proc :: proc(ctx: rawptr, message: string)
Vm_Lifetime_Machine_Init_Proc :: proc(ctx: rawptr, m: ^machine.Machine, ram_size: int) -> bool
Vm_Lifetime_Machine_Destroy_Proc :: proc(ctx: rawptr, m: ^machine.Machine)
Vm_Lifetime_Machine_Live_Proc :: proc(ctx: rawptr, m: ^machine.Machine) -> bool
Vm_Lifetime_Disk_Attach_Proc :: proc(ctx: rawptr, m: ^machine.Machine, device: disk.Block_Device)
Vm_Lifetime_Disk_Detach_Proc :: proc(ctx: rawptr, m: ^machine.Machine) -> bool
Vm_Lifetime_Session_Barrier_Proc :: proc(
	ctx: rawptr,
	session: ^fat32session.Machine_Session,
	reason: fat32session.Barrier_Reason,
) -> (
	fat32session.Barrier_Result,
	fat32session.Session_Error,
)
Vm_Lifetime_Session_Close_Proc :: proc(
	ctx: rawptr,
	session: ^fat32session.Machine_Session,
	mode: fat32session.Close_Mode,
) -> fat32session.Session_Error
Vm_Lifetime_Session_Ready_Proc :: proc(ctx: rawptr, session: ^fat32session.Machine_Session) -> bool
Vm_Lifetime_Audio_Open_Proc :: proc(
	ctx: rawptr,
	audio: ^host.Host_Audio,
	m: ^machine.Machine,
) -> bool
Vm_Lifetime_Audio_Close_Proc :: proc(ctx: rawptr, audio: ^host.Host_Audio)
Vm_Lifetime_Cmos_Save_Proc :: proc(
	ctx: rawptr,
	path: string,
	cmos: profile.Cmos_Data,
) -> profile.Cmos_Diagnostic
Vm_Lifetime_Guard_Bind_Proc :: proc(ctx: rawptr, guard: ^Vm_Guard, m: ^machine.Machine)
Vm_Lifetime_Guard_Unbind_Proc :: proc(ctx: rawptr, guard: ^Vm_Guard)
Vm_Lifetime_Guard_Destroy_Proc :: proc(ctx: rawptr, guard: ^Vm_Guard) -> bool

Vm_Lifetime_Adapters :: struct {
	ctx:             rawptr,
	configure:       Vm_Lifetime_Configure_Proc,
	log:             Vm_Lifetime_Log_Proc,
	machine_init:    Vm_Lifetime_Machine_Init_Proc,
	machine_destroy: Vm_Lifetime_Machine_Destroy_Proc,
	machine_live:    Vm_Lifetime_Machine_Live_Proc,
	disk_attach:     Vm_Lifetime_Disk_Attach_Proc,
	disk_detach:     Vm_Lifetime_Disk_Detach_Proc,
	barrier:         Vm_Lifetime_Session_Barrier_Proc,
	close_session:   Vm_Lifetime_Session_Close_Proc,
	session_ready:   Vm_Lifetime_Session_Ready_Proc,
	audio_open:      Vm_Lifetime_Audio_Open_Proc,
	audio_close:     Vm_Lifetime_Audio_Close_Proc,
	cmos_save:       Vm_Lifetime_Cmos_Save_Proc,
	guard_bind:      Vm_Lifetime_Guard_Bind_Proc,
	guard_unbind:    Vm_Lifetime_Guard_Unbind_Proc,
	guard_destroy:   Vm_Lifetime_Guard_Destroy_Proc,
}

Vm_Lifetime_Config :: struct {
	ram_size:            int,
	attach_storage:      bool,
	hard_drive_path:     string,
	machine_session_id:  string,
	session_adapter:     fat32session.Adapter_Kind,
	session_adapter_set: bool,
	cmos_path:           string,
	cmos:                profile.Cmos_Data,
	has_cmos:            bool,
	audio_enabled:       bool,
	volume_gain:         f32,
	clock_running:       bool,
	floppy:              []u8,
	floppy_path:         string,
	optical_path:        string,
}

Vm_Removable_Media :: enum u8 {
	Floppy,
	Optical,
}

Vm_Lifetime :: struct {
	m:                        ^machine.Machine,
	session:                  ^fat32session.Machine_Session,
	guard:                    Vm_Guard,
	audio:                    host.Host_Audio,
	hardware_trace:           ^machine.Hardware_Trace,
	state:                    Vm_Lifetime_State,
	last_result:              Vm_Lifetime_Result,
	adapters:                 Vm_Lifetime_Adapters,
	ram_size:                 int,
	attach_storage:           bool,
	hard_drive_path:          string,
	machine_session_id:       string,
	session_adapter:          fat32session.Adapter_Kind,
	cmos_path:                string,
	cmos:                     profile.Cmos_Data,
	has_cmos:                 bool,
	audio_enabled:            bool,
	volume_gain:              f32,
	clock_running:            bool,
	floppy:                   []u8,
	floppy_path:              string,
	optical_path:             string,
	machine_generation:       u64,
	cmos_retained_generation: u64,
	session_retained:         bool,
	guard_initialized:        bool,
	machine_initialized:      bool,
}

@(private = "file")
vm_lifetime_result :: proc(
	lifetime: ^Vm_Lifetime,
	completed: bool,
	diagnostic: Vm_Lifetime_Diagnostic,
	storage_error := fat32session.Session_Error{},
) -> Vm_Lifetime_Result {
	state := Vm_Lifetime_State.Uninitialized
	session_retained := false
	if lifetime != nil {
		state = lifetime.state
		session_retained = lifetime.session_retained || lifetime.session != nil
	}
	result := Vm_Lifetime_Result {
		completed        = completed,
		diagnostic       = diagnostic,
		state            = state,
		recoverable      = state == .Running || state == .Recovery || session_retained,
		session_retained = session_retained,
		storage_error    = storage_error,
	}
	if lifetime != nil {lifetime.last_result = result}
	return result
}

@(private = "file")
vm_lifetime_log :: proc(lifetime: ^Vm_Lifetime, message: string) {
	if lifetime != nil && lifetime.adapters.log != nil {
		lifetime.adapters.log(lifetime.adapters.ctx, message)
	}
}

@(private = "file")
vm_lifetime_machine_init :: proc(lifetime: ^Vm_Lifetime) -> bool {
	lifetime.machine_initialized = true
	if lifetime.adapters.machine_init != nil {
		return lifetime.adapters.machine_init(lifetime.adapters.ctx, lifetime.m, lifetime.ram_size)
	}
	return machine.machine_init(lifetime.m, lifetime.ram_size)
}

@(private = "file")
vm_lifetime_machine_destroy :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.adapters.machine_destroy != nil {
		lifetime.adapters.machine_destroy(lifetime.adapters.ctx, lifetime.m)
	} else {
		machine.machine_destroy(lifetime.m)
	}
}

@(private = "file")
vm_lifetime_machine_live :: proc(lifetime: ^Vm_Lifetime) -> bool {
	if lifetime.m == nil {return false}
	if lifetime.adapters.machine_live != nil {
		return lifetime.adapters.machine_live(lifetime.adapters.ctx, lifetime.m)
	}
	return lifetime.m.vm.part != nil
}

@(private = "file")
vm_lifetime_disk_attach :: proc(lifetime: ^Vm_Lifetime) {
	device := fat32session.block_device(lifetime.session)
	if lifetime.adapters.disk_attach != nil {
		lifetime.adapters.disk_attach(lifetime.adapters.ctx, lifetime.m, device)
	} else {
		machine.machine_attach_disk(lifetime.m, device)
	}
}

@(private = "file")
vm_lifetime_disk_detach :: proc(lifetime: ^Vm_Lifetime) -> bool {
	if lifetime.m == nil || !lifetime.m.has_disk {return true}
	if lifetime.adapters.disk_detach != nil {
		return lifetime.adapters.disk_detach(lifetime.adapters.ctx, lifetime.m)
	}
	return machine.machine_detach_disk(lifetime.m)
}

@(private = "file")
vm_lifetime_barrier :: proc(
	lifetime: ^Vm_Lifetime,
	reason: fat32session.Barrier_Reason,
) -> (
	fat32session.Barrier_Result,
	fat32session.Session_Error,
) {
	if lifetime.adapters.barrier != nil {
		return lifetime.adapters.barrier(lifetime.adapters.ctx, lifetime.session, reason)
	}
	return fat32session.barrier(lifetime.session, reason)
}

@(private = "file")
vm_lifetime_close_session :: proc(
	lifetime: ^Vm_Lifetime,
	mode: fat32session.Close_Mode,
) -> fat32session.Session_Error {
	if lifetime.session == nil {return {}}
	if lifetime.adapters.close_session != nil {
		return lifetime.adapters.close_session(lifetime.adapters.ctx, lifetime.session, mode)
	}
	return fat32session.close(lifetime.session, mode)
}

@(private = "file")
vm_lifetime_session_ready :: proc(lifetime: ^Vm_Lifetime) -> bool {
	if lifetime.session == nil {return false}
	if lifetime.adapters.session_ready != nil {
		return lifetime.adapters.session_ready(lifetime.adapters.ctx, lifetime.session)
	}
	return fat32session.session_ready(lifetime.session)
}

@(private = "file")
vm_lifetime_audio_close :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.adapters.audio_close != nil {
		lifetime.adapters.audio_close(lifetime.adapters.ctx, &lifetime.audio)
	} else {
		host.host_audio_close(&lifetime.audio)
	}
}

@(private = "file")
vm_lifetime_guard_bind :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.adapters.guard_bind != nil {
		lifetime.adapters.guard_bind(lifetime.adapters.ctx, &lifetime.guard, lifetime.m)
	} else {
		vm_guard_bind(&lifetime.guard, &lifetime.m.vm)
		machine.machine_set_wake_adapter(lifetime.m, &lifetime.guard, vm_guard_schedule)
	}
}

@(private = "file")
vm_lifetime_guard_unbind :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.adapters.guard_unbind != nil {
		lifetime.adapters.guard_unbind(lifetime.adapters.ctx, &lifetime.guard)
	} else {
		vm_guard_unbind(&lifetime.guard)
	}
}

@(private = "file")
vm_lifetime_save_cmos :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.m == nil ||
	   !vm_lifetime_machine_live(lifetime) ||
	   lifetime.cmos_retained_generation == lifetime.machine_generation {
		return
	}
	saved := machine.machine_cmos_export(lifetime.m)
	copy(lifetime.cmos[:], saved[:])
	lifetime.has_cmos = true
	lifetime.cmos_retained_generation = lifetime.machine_generation
	if lifetime.cmos_path == "" {return}
	diagnostic := profile.Cmos_Diagnostic.None
	if lifetime.adapters.cmos_save != nil {
		diagnostic = lifetime.adapters.cmos_save(
			lifetime.adapters.ctx,
			lifetime.cmos_path,
			lifetime.cmos,
		)
	} else {
		diagnostic = profile.cmos_save(lifetime.cmos_path, lifetime.cmos)
	}
	if diagnostic != .None {vm_lifetime_log(lifetime, "CMOS retention failed")}
}

@(private = "file")
vm_lifetime_retain_trace :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.m == nil {return}
	trace := machine.machine_hardware_trace_detach(lifetime.m)
	if trace == nil {return}
	if lifetime.hardware_trace == nil {
		lifetime.hardware_trace = trace
	} else if lifetime.hardware_trace != trace {
		free(trace)
	}
}

@(private = "file")
vm_lifetime_shutdown_machine :: proc(lifetime: ^Vm_Lifetime) {
	vm_lifetime_guard_unbind(lifetime)
	vm_lifetime_audio_close(lifetime)
	live := vm_lifetime_machine_live(lifetime)
	if live {vm_lifetime_save_cmos(lifetime)}
	if !lifetime.machine_initialized && !live {return}
	vm_lifetime_retain_trace(lifetime)
	vm_lifetime_machine_destroy(lifetime)
	lifetime.machine_initialized = false
}

@(private = "file")
vm_lifetime_release_failed_boot_session :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime.session == nil {return}
	close_error := vm_lifetime_close_session(lifetime, .Commit)
	if close_error.code == .None || close_error.outcome == .Completed {
		lifetime.session = nil
		return
	}
	_ = vm_lifetime_close_session(lifetime, .Retain)
	lifetime.session = nil
	lifetime.session_retained = true
	vm_lifetime_log(lifetime, "failed boot storage evidence retained")
}

@(private = "file")
vm_lifetime_ensure_session :: proc(lifetime: ^Vm_Lifetime) -> fat32session.Session_Error {
	if !lifetime.attach_storage {return {}}
	if vm_lifetime_session_ready(lifetime) {return {}}
	if lifetime.session != nil {
		return fat32session.error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"retained Machine session is not ready",
		)
	}
	session, open_error := fat32session.open_machine(
		lifetime.hard_drive_path,
		lifetime.machine_session_id,
		lifetime.session_adapter,
	)
	if open_error.code == .None {
		lifetime.session = session
		lifetime.session_retained = false
	}
	return open_error
}

@(private = "file")
vm_lifetime_boot :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Diagnostic {
	booted := false
	defer if !booted {vm_lifetime_shutdown_machine(lifetime)}
	if !vm_lifetime_machine_init(lifetime) {return .Machine_Init_Failed}
	lifetime.machine_generation += 1
	if lifetime.hardware_trace != nil {
		if !machine.machine_hardware_trace_attach(lifetime.m, lifetime.hardware_trace) {
			return .Hardware_Trace_Failed
		}
		lifetime.hardware_trace = nil
	} else if !machine.machine_set_hardware_trace(lifetime.m, true) {
		return .Hardware_Trace_Failed
	}
	if !lifetime.clock_running {machine.machine_clock_set_running(lifetime.m, false)}
	if lifetime.has_cmos {_ = machine.machine_cmos_import(lifetime.m, lifetime.cmos[:])}
	if lifetime.adapters.configure != nil &&
	   !lifetime.adapters.configure(lifetime.adapters.ctx, lifetime.m, lifetime.m.platform.cmos.ram[:]) {
		return .Machine_Configure_Failed
	}
	if lifetime.attach_storage {
		vm_lifetime_disk_attach(lifetime)
	}
	if len(lifetime.floppy) > 0 && !machine.machine_mount_floppy(lifetime.m, lifetime.floppy) {
		return .Media_Failed
	}
	if lifetime.optical_path != "" &&
	   !machine.machine_attach_cdrom(lifetime.m, lifetime.optical_path) {
		return .Media_Failed
	}
	if lifetime.audio_enabled {
		opened :=
			lifetime.adapters.audio_open(lifetime.adapters.ctx, &lifetime.audio, lifetime.m) if lifetime.adapters.audio_open != nil else host.host_audio_open(&lifetime.audio, machine.machine_audio_output(lifetime.m))
		if !opened {vm_lifetime_log(lifetime, "host audio unavailable")}
	}
	_ = host.host_audio_set_gain(&lifetime.audio, lifetime.volume_gain)
	vm_lifetime_guard_bind(lifetime)
	if lifetime.m.platform.bus.frozen {return .Machine_Configure_Failed}
	booted = true
	return .None
}

vm_lifetime_init :: proc(
	lifetime: ^Vm_Lifetime,
	config: Vm_Lifetime_Config,
	adapters := Vm_Lifetime_Adapters{},
) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state != .Uninitialized || config.ram_size <= 0 {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	lifetime^ = {
		state           = .Uninitialized,
		adapters        = adapters,
		ram_size        = config.ram_size,
		attach_storage  = config.attach_storage,
		session_adapter = config.session_adapter,
		cmos            = config.cmos,
		has_cmos        = config.has_cmos,
		audio_enabled   = config.audio_enabled,
		volume_gain     = clamp(config.volume_gain, 0, 1),
		clock_running   = config.clock_running,
	}
	if !config.session_adapter_set {
		lifetime.session_adapter = fat32session.DEFAULT_ADAPTER
	}
	lifetime.m = new(machine.Machine)
	lifetime.hard_drive_path = strings.clone(config.hard_drive_path)
	lifetime.machine_session_id = strings.clone(config.machine_session_id)
	lifetime.cmos_path = strings.clone(config.cmos_path)
	lifetime.floppy = slice.clone(config.floppy)
	lifetime.floppy_path = strings.clone(config.floppy_path)
	lifetime.optical_path = strings.clone(config.optical_path)
	if !vm_guard_init(&lifetime.guard) {
		free(lifetime.m)
		delete(lifetime.hard_drive_path)
		delete(lifetime.machine_session_id)
		delete(lifetime.cmos_path)
		delete(lifetime.floppy)
		delete(lifetime.floppy_path)
		delete(lifetime.optical_path)
		lifetime^ = {}
		return vm_lifetime_result(lifetime, false, .Guard_Init_Failed)
	}
	lifetime.guard_initialized = true
	lifetime.state = .Stopped
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_start :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state != .Stopped {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	open_error := vm_lifetime_ensure_session(lifetime)
	if open_error.code != .None {
		return vm_lifetime_result(lifetime, false, .Volume_Open_Failed, open_error)
	}
	diagnostic := vm_lifetime_boot(lifetime)
	if diagnostic != .None {
		vm_lifetime_release_failed_boot_session(lifetime)
		lifetime.state = .Recovery
		return vm_lifetime_result(lifetime, false, diagnostic)
	}
	lifetime.state = .Running
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_reset :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state != .Running {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	if lifetime.session != nil {
		_, barrier_error := vm_lifetime_barrier(lifetime, .Reset)
		if barrier_error.code != .None || !vm_lifetime_disk_detach(lifetime) {
			return vm_lifetime_result(lifetime, false, .Durability_Failed, barrier_error)
		}
	}
	vm_lifetime_shutdown_machine(lifetime)
	diagnostic := vm_lifetime_boot(lifetime)
	if diagnostic != .None {
		vm_lifetime_release_failed_boot_session(lifetime)
		lifetime.state = .Recovery
		return vm_lifetime_result(lifetime, false, diagnostic)
	}
	lifetime.state = .Running
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_stop :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state != .Running {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	disk_attached := lifetime.m != nil && lifetime.m.has_disk
	if lifetime.session != nil {
		_, barrier_error := vm_lifetime_barrier(lifetime, .Clean_Close)
		if barrier_error.code != .None || (disk_attached && !vm_lifetime_disk_detach(lifetime)) {
			return vm_lifetime_result(lifetime, false, .Durability_Failed, barrier_error)
		}
		close_error := vm_lifetime_close_session(lifetime, .Commit)
		if close_error.code != .None && close_error.outcome != .Completed {
			if disk_attached {
				vm_lifetime_disk_attach(lifetime)
			}
			return vm_lifetime_result(lifetime, false, .Clean_Close_Failed, close_error)
		}
		lifetime.session = nil
	}
	vm_lifetime_shutdown_machine(lifetime)
	lifetime.state = .Stopped
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_begin_storage_maintenance :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil {return vm_lifetime_result(lifetime, false, .Invalid_State)}
	if lifetime.state == .Running {
		result := vm_lifetime_stop(lifetime)
		if !result.completed {return result}
	}
	if lifetime.state != .Stopped {return vm_lifetime_result(lifetime, false, .Invalid_State)}
	lifetime.state = .Maintenance
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_end_storage_maintenance :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state != .Maintenance || lifetime.session != nil {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	lifetime.state = .Stopped
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_mount_removable :: proc(
	lifetime: ^Vm_Lifetime,
	media: Vm_Removable_Media,
	path: string,
	floppy: []u8 = nil,
) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state == .Uninitialized || lifetime.state == .Destroy_Failed {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	switch media {
	case .Floppy:
		candidate := slice.clone(floppy)
		if lifetime.state == .Running && !machine.machine_mount_floppy(lifetime.m, candidate) {
			delete(candidate)
			return vm_lifetime_result(lifetime, false, .Media_Failed)
		}
		delete(lifetime.floppy)
		delete(lifetime.floppy_path)
		lifetime.floppy = candidate
		lifetime.floppy_path = strings.clone(path)
	case .Optical:
		if lifetime.state == .Running && !machine.machine_mount_cdrom(lifetime.m, path) {
			return vm_lifetime_result(lifetime, false, .Media_Failed)
		}
		delete(lifetime.optical_path)
		lifetime.optical_path = strings.clone(path)
	}
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_eject_removable :: proc(
	lifetime: ^Vm_Lifetime,
	media: Vm_Removable_Media,
) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state == .Uninitialized || lifetime.state == .Destroy_Failed {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	switch media {
	case .Floppy:
		if lifetime.state == .Running {machine.machine_eject_floppy(lifetime.m)}
		delete(lifetime.floppy)
		delete(lifetime.floppy_path)
		lifetime.floppy = nil
		lifetime.floppy_path = ""
	case .Optical:
		if lifetime.state == .Running {machine.machine_eject_cdrom(lifetime.m)}
		delete(lifetime.optical_path)
		lifetime.optical_path = ""
	}
	return vm_lifetime_result(lifetime, true, .None)
}

vm_lifetime_running_machine :: proc(lifetime: ^Vm_Lifetime) -> (^machine.Machine, bool) {
	if lifetime == nil || lifetime.state != .Running || lifetime.m == nil {return nil, false}
	return lifetime.m, true
}

vm_lifetime_session_terminal_error :: proc(
	lifetime: ^Vm_Lifetime,
) -> (
	fat32session.Session_Error,
	bool,
) {
	if lifetime == nil || lifetime.session == nil {return {}, false}
	return fat32session.session_terminal_error(lifetime.session)
}

vm_lifetime_storage_observe :: proc(
	lifetime: ^Vm_Lifetime,
	probes: []fat32session.Probe,
) -> (
	fat32session.Observation_Batch,
	fat32session.Session_Error,
) {
	if lifetime == nil || lifetime.session == nil {
		return {}, fat32session.error_make(.Invalid_State, false, .Not_Started, 0, 0, "VM lifetime has no storage session")
	}
	return fat32session.observe(lifetime.session, probes, context.temp_allocator)
}

vm_lifetime_set_volume :: proc(lifetime: ^Vm_Lifetime, gain: f32) -> bool {
	if lifetime == nil {return false}
	lifetime.volume_gain = clamp(gain, 0, 1)
	return host.host_audio_set_gain(&lifetime.audio, lifetime.volume_gain)
}

vm_lifetime_set_clock_running :: proc(lifetime: ^Vm_Lifetime, running: bool) {
	if lifetime == nil {return}
	lifetime.clock_running = running
	if lifetime.state == .Running {machine.machine_clock_set_running(lifetime.m, running)}
}

vm_lifetime_storage_ready :: proc(lifetime: ^Vm_Lifetime) -> bool {
	return lifetime != nil && vm_lifetime_session_ready(lifetime)
}

vm_lifetime_storage_barrier :: proc(
	lifetime: ^Vm_Lifetime,
	reason: fat32session.Barrier_Reason,
) -> (
	fat32session.Barrier_Result,
	fat32session.Session_Error,
) {
	if lifetime == nil || lifetime.session == nil {
		return {}, fat32session.error_make(.Invalid_State, false, .Not_Started, 0, 0, "VM lifetime has no storage session")
	}
	return vm_lifetime_barrier(lifetime, reason)
}

vm_lifetime_warm_cpu_reset :: proc(lifetime: ^Vm_Lifetime) -> bool {
	if lifetime == nil || lifetime.state != .Running || lifetime.m == nil {return false}
	sync.lock(&lifetime.guard.mu)
	lifetime.guard.valid = false
	reset := machine.machine_cpu_reset(lifetime.m)
	lifetime.guard.valid = reset
	sync.unlock(&lifetime.guard.mu)
	if reset {machine.machine_rearm_wake(lifetime.m)}
	return reset
}

vm_lifetime_cmos_snapshot :: proc(lifetime: ^Vm_Lifetime) -> (profile.Cmos_Data, bool) {
	if lifetime == nil {return {}, false}
	if vm_lifetime_machine_live(lifetime) {
		return machine.machine_cmos_export(lifetime.m), true
	}
	return lifetime.cmos, lifetime.has_cmos
}

vm_lifetime_cmos_replace :: proc(
	lifetime: ^Vm_Lifetime,
	cmos: profile.Cmos_Data,
	have_cmos: bool,
) {
	if lifetime == nil {return}
	lifetime.cmos = cmos
	lifetime.has_cmos = have_cmos
}

vm_lifetime_media_path :: proc(lifetime: ^Vm_Lifetime, media: Vm_Removable_Media) -> string {
	if lifetime == nil {return ""}
	switch media {
	case .Floppy:
		return lifetime.floppy_path
	case .Optical:
		return lifetime.optical_path
	}
	return ""
}

vm_lifetime_kick :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime == nil {return}
	vm_guard_kick(&lifetime.guard)
}

vm_lifetime_flush_guard :: proc(lifetime: ^Vm_Lifetime) {
	if lifetime == nil || lifetime.m == nil {return}
	vm_guard_flush_wake_evidence(&lifetime.guard, lifetime.m)
}

vm_lifetime_quiesce_guard :: proc(lifetime: ^Vm_Lifetime) -> bool {
	if lifetime == nil {return false}
	vm_lifetime_flush_guard(lifetime)
	return vm_guard_quiesce(&lifetime.guard)
}

vm_lifetime_guard_failed :: proc(lifetime: ^Vm_Lifetime) -> bool {
	return lifetime != nil && vm_guard_failed(&lifetime.guard)
}

vm_lifetime_observation :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Observation {
	if lifetime == nil {return {}}
	return {
		state = lifetime.state,
		running = lifetime.state == .Running,
		maintenance = lifetime.state == .Maintenance,
		session_ready = vm_lifetime_session_ready(lifetime),
		session_retained = lifetime.session_retained || lifetime.session != nil,
		machine_generation = lifetime.machine_generation,
		cmos_retained_once = lifetime.cmos_retained_generation == lifetime.machine_generation &&
		lifetime.machine_generation != 0,
		hardware_trace_retained = lifetime.hardware_trace != nil,
		floppy_mounted = len(lifetime.floppy) > 0,
		optical_mounted = lifetime.optical_path != "",
		guard = vm_guard_stats(&lifetime.guard),
	}
}

vm_lifetime_destroy :: proc(lifetime: ^Vm_Lifetime) -> Vm_Lifetime_Result {
	if lifetime == nil || lifetime.state == .Uninitialized {
		return vm_lifetime_result(lifetime, false, .Invalid_State)
	}
	if lifetime.state == .Running {
		stopped := vm_lifetime_stop(lifetime)
		if !stopped.completed {return stopped}
	}
	if lifetime.session != nil {
		close_error := vm_lifetime_close_session(lifetime, .Commit)
		if close_error.code != .None && close_error.outcome != .Completed {
			return vm_lifetime_result(lifetime, false, .Clean_Close_Failed, close_error)
		}
		lifetime.session = nil
	}
	vm_lifetime_shutdown_machine(lifetime)
	guard_destroyed := true
	if lifetime.guard_initialized {
		guard_destroyed =
			lifetime.adapters.guard_destroy(lifetime.adapters.ctx, &lifetime.guard) if lifetime.adapters.guard_destroy != nil else vm_guard_destroy(&lifetime.guard)
	}
	if !guard_destroyed {
		lifetime.state = .Destroy_Failed
		return vm_lifetime_result(lifetime, false, .Guard_Destroy_Failed)
	}
	if lifetime.hardware_trace != nil {free(lifetime.hardware_trace)}
	if lifetime.m != nil {free(lifetime.m)}
	delete(lifetime.hard_drive_path)
	delete(lifetime.machine_session_id)
	delete(lifetime.cmos_path)
	delete(lifetime.floppy)
	delete(lifetime.floppy_path)
	delete(lifetime.optical_path)
	lifetime^ = {}
	return {completed = true, diagnostic = .None, state = .Uninitialized}
}
