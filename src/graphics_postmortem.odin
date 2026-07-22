// SPDX-License-Identifier: GPL-3.0-only
package main

import "base:runtime"
import "core:encoding/json"
import "core:sync"
import "core:thread"
import "core:time"
import "profile"

GRAPHICS_POSTMORTEM_SCHEMA_VERSION :: 2
GRAPHICS_POSTMORTEM_WRITE_INTERVAL :: time.Second
GRAPHICS_POSTMORTEM_PATH_MAX_BYTES :: 1024
GRAPHICS_POSTMORTEM_SESSION_MAX_BYTES :: 96
GRAPHICS_POSTMORTEM_DEVICE_MAX_BYTES :: 96
GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES :: 8192
GRAPHICS_POSTMORTEM_VM_MAX_BYTES :: 8192

Graphics_Postmortem_Provenance :: enum u8 {
	Unavailable,
	Measured,
	Derived,
}

Graphics_Postmortem_Host_Stage :: enum u8 {
	Unavailable,
	Capture,
	Mailbox,
	Render,
	Upload,
	Gpu_Drain,
	Compose,
	Present,
	Complete,
	Failed,
}

Graphics_Postmortem_Init_Diagnostic :: enum u8 {
	None,
	Invalid_Configuration,
	Field_Too_Large,
	Thread_Failed,
}

Graphics_Postmortem_Publish_Diagnostic :: enum u8 {
	None,
	Disabled,
	Invalid_Argument,
	Text_Too_Large,
	Stale_State,
}

Graphics_Postmortem_State :: struct {
	session_generation:                 u64,
	session_generation_provenance:      Graphics_Postmortem_Provenance,
	guest_device_generation:            u64,
	guest_device_generation_provenance: Graphics_Postmortem_Provenance,
	host_device_generation:             u64,
	host_device_generation_provenance:  Graphics_Postmortem_Provenance,
	frame_generation:                   u64,
	frame_generation_provenance:        Graphics_Postmortem_Provenance,
	host_stage:                         Graphics_Postmortem_Host_Stage,
	host_stage_provenance:              Graphics_Postmortem_Provenance,
}

Graphics_Postmortem_Path :: struct {
	data:   [GRAPHICS_POSTMORTEM_PATH_MAX_BYTES]u8,
	length: int,
}

Graphics_Postmortem_Session :: struct {
	data:   [GRAPHICS_POSTMORTEM_SESSION_MAX_BYTES]u8,
	length: int,
}

Graphics_Postmortem_Device :: struct {
	data:   [GRAPHICS_POSTMORTEM_DEVICE_MAX_BYTES]u8,
	length: int,
}

Graphics_Postmortem_Window :: struct {
	data:   [GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES]u8,
	length: int,
}

Graphics_Postmortem_Vm :: struct {
	data:   [GRAPHICS_POSTMORTEM_VM_MAX_BYTES]u8,
	length: int,
}

Graphics_Postmortem_Snapshot :: struct {
	schema_version:                     u32,
	revision:                           u64,
	session:                            Graphics_Postmortem_Session,
	session_provenance:                 Graphics_Postmortem_Provenance,
	device:                             Graphics_Postmortem_Device,
	device_provenance:                  Graphics_Postmortem_Provenance,
	session_generation:                 u64,
	session_generation_provenance:      Graphics_Postmortem_Provenance,
	guest_device_generation:            u64,
	guest_device_generation_provenance: Graphics_Postmortem_Provenance,
	host_device_generation:             u64,
	host_device_generation_provenance:  Graphics_Postmortem_Provenance,
	frame_generation:                   u64,
	frame_generation_provenance:        Graphics_Postmortem_Provenance,
	host_stage:                         Graphics_Postmortem_Host_Stage,
	host_stage_provenance:              Graphics_Postmortem_Provenance,
	window:                             Graphics_Postmortem_Window,
	window_provenance:                  Graphics_Postmortem_Provenance,
	window_frame_generation:            u64,
	window_frame_generation_provenance: Graphics_Postmortem_Provenance,
	vm:                                 Graphics_Postmortem_Vm,
	vm_provenance:                      Graphics_Postmortem_Provenance,
	vm_frame_generation:                u64,
	vm_frame_generation_provenance:     Graphics_Postmortem_Provenance,
}

Graphics_Postmortem_Status :: struct {
	enabled:              bool,
	worker_running:       bool,
	dirty:                bool,
	revision:             u64,
	persisted_revision:   u64,
	writes_attempted:     u64,
	writes_succeeded:     u64,
	writes_failed:        u64,
	last_save_diagnostic: profile.Graphics_Postmortem_Save_Diagnostic,
}

Graphics_Postmortem_Save_Sink :: #type proc(
	ctx: rawptr,
	path: string,
	payload: []u8,
) -> profile.Graphics_Postmortem_Save_Diagnostic

Graphics_Postmortem_Config :: struct {
	enabled:  bool,
	path:     string,
	session:  string,
	device:   string,
	sink:     Graphics_Postmortem_Save_Sink,
	sink_ctx: rawptr,
}

Graphics_Postmortem :: struct {
	mu:                   sync.Mutex,
	wake:                 sync.Cond,
	worker:               ^thread.Thread,
	sink:                 Graphics_Postmortem_Save_Sink,
	sink_ctx:             rawptr,
	path:                 Graphics_Postmortem_Path,
	latest:               Graphics_Postmortem_Snapshot,
	enabled:              bool,
	worker_running:       bool,
	stopping:             bool,
	dirty:                bool,
	last_attempt_started: time.Tick,
	persisted_revision:   u64,
	writes_attempted:     u64,
	writes_succeeded:     u64,
	writes_failed:        u64,
	last_save_diagnostic: profile.Graphics_Postmortem_Save_Diagnostic,
}

Graphics_Postmortem_Disk_Text :: struct {
	value:      string `json:"value"`,
	provenance: string `json:"provenance"`,
}

Graphics_Postmortem_Disk_Number :: struct {
	value:      u64 `json:"value"`,
	provenance: string `json:"provenance"`,
}

Graphics_Postmortem_Disk_Stage :: struct {
	value:      string `json:"value"`,
	provenance: string `json:"provenance"`,
}

Graphics_Postmortem_Disk :: struct {
	schema:                  u32 `json:"schema"`,
	revision:                u64 `json:"revision"`,
	session:                 Graphics_Postmortem_Disk_Text `json:"session"`,
	device:                  Graphics_Postmortem_Disk_Text `json:"device"`,
	session_generation:      Graphics_Postmortem_Disk_Number `json:"session_generation"`,
	guest_device_generation: Graphics_Postmortem_Disk_Number `json:"guest_device_generation"`,
	host_device_generation:  Graphics_Postmortem_Disk_Number `json:"host_device_generation"`,
	frame_generation:        Graphics_Postmortem_Disk_Number `json:"frame_generation"`,
	host_stage:              Graphics_Postmortem_Disk_Stage `json:"host_stage"`,
	window:                  Graphics_Postmortem_Disk_Text `json:"window"`,
	window_frame_generation: Graphics_Postmortem_Disk_Number `json:"window_frame_generation"`,
	vm:                      Graphics_Postmortem_Disk_Text `json:"vm"`,
	vm_frame_generation:     Graphics_Postmortem_Disk_Number `json:"vm_frame_generation"`,
}

@(private = "file")
graphics_postmortem_assign :: proc(buffer: []u8, length: ^int, value: string) -> bool {
	if length == nil || len(value) > len(buffer) {return false}
	copy(buffer, transmute([]u8)value)
	length^ = len(value)
	return true
}

@(private = "file")
graphics_postmortem_path_text :: proc(path: ^Graphics_Postmortem_Path) -> string {
	if path == nil || path.length <= 0 {return ""}
	return string(path.data[:path.length])
}

@(private = "file")
graphics_postmortem_session_text :: proc(value: ^Graphics_Postmortem_Session) -> string {
	if value == nil || value.length <= 0 {return ""}
	return string(value.data[:value.length])
}

@(private = "file")
graphics_postmortem_device_text :: proc(value: ^Graphics_Postmortem_Device) -> string {
	if value == nil || value.length <= 0 {return ""}
	return string(value.data[:value.length])
}

@(private = "file")
graphics_postmortem_window_text :: proc(value: ^Graphics_Postmortem_Window) -> string {
	if value == nil || value.length <= 0 {return ""}
	return string(value.data[:value.length])
}

@(private = "file")
graphics_postmortem_vm_text :: proc(value: ^Graphics_Postmortem_Vm) -> string {
	if value == nil || value.length <= 0 {return ""}
	return string(value.data[:value.length])
}

@(private = "file")
graphics_postmortem_payload_text_valid :: proc(value: string) -> bool {
	for byte in transmute([]u8)value {
		if byte == 0x09 || byte == 0x0a || byte == 0x0d {continue}
		if byte < 0x20 || byte > 0x7e {return false}
	}
	return true
}

@(private = "file")
graphics_postmortem_provenance_name :: proc(value: Graphics_Postmortem_Provenance) -> string {
	switch value {
	case .Unavailable:
		return "unavailable"
	case .Measured:
		return "measured"
	case .Derived:
		return "derived"
	}
	return "unavailable"
}

@(private = "file")
graphics_postmortem_stage_name :: proc(value: Graphics_Postmortem_Host_Stage) -> string {
	switch value {
	case .Unavailable:
		return "unavailable"
	case .Capture:
		return "capture"
	case .Mailbox:
		return "mailbox"
	case .Render:
		return "render"
	case .Upload:
		return "upload"
	case .Gpu_Drain:
		return "gpu-drain"
	case .Compose:
		return "compose"
	case .Present:
		return "present"
	case .Complete:
		return "complete"
	case .Failed:
		return "failed"
	}
	return "unavailable"
}

graphics_postmortem_format :: proc(snapshot: ^Graphics_Postmortem_Snapshot) -> ([]u8, bool) {
	if snapshot == nil {return nil, false}
	disk := Graphics_Postmortem_Disk {
		schema = snapshot.schema_version,
		revision = snapshot.revision,
		session = {
			value = graphics_postmortem_session_text(&snapshot.session),
			provenance = graphics_postmortem_provenance_name(snapshot.session_provenance),
		},
		device = {
			value = graphics_postmortem_device_text(&snapshot.device),
			provenance = graphics_postmortem_provenance_name(snapshot.device_provenance),
		},
		session_generation = {
			value = snapshot.session_generation,
			provenance = graphics_postmortem_provenance_name(
				snapshot.session_generation_provenance,
			),
		},
		guest_device_generation = {
			value = snapshot.guest_device_generation,
			provenance = graphics_postmortem_provenance_name(
				snapshot.guest_device_generation_provenance,
			),
		},
		host_device_generation = {
			value = snapshot.host_device_generation,
			provenance = graphics_postmortem_provenance_name(
				snapshot.host_device_generation_provenance,
			),
		},
		frame_generation = {
			value = snapshot.frame_generation,
			provenance = graphics_postmortem_provenance_name(snapshot.frame_generation_provenance),
		},
		host_stage = {
			value = graphics_postmortem_stage_name(snapshot.host_stage),
			provenance = graphics_postmortem_provenance_name(snapshot.host_stage_provenance),
		},
		window = {
			value = graphics_postmortem_window_text(&snapshot.window),
			provenance = graphics_postmortem_provenance_name(snapshot.window_provenance),
		},
		window_frame_generation = {
			value = snapshot.window_frame_generation,
			provenance = graphics_postmortem_provenance_name(
				snapshot.window_frame_generation_provenance,
			),
		},
		vm = {
			value = graphics_postmortem_vm_text(&snapshot.vm),
			provenance = graphics_postmortem_provenance_name(snapshot.vm_provenance),
		},
		vm_frame_generation = {
			value = snapshot.vm_frame_generation,
			provenance = graphics_postmortem_provenance_name(
				snapshot.vm_frame_generation_provenance,
			),
		},
	}
	payload, encode_error := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if encode_error != nil {return nil, false}
	if len(payload) > profile.GRAPHICS_POSTMORTEM_MAX_BYTES {
		delete(payload)
		return nil, false
	}
	return payload, true
}

@(private = "file")
graphics_postmortem_profile_sink :: proc(
	_: rawptr,
	path: string,
	payload: []u8,
) -> profile.Graphics_Postmortem_Save_Diagnostic {
	return profile.graphics_postmortem_save(path, payload)
}

@(private = "file")
graphics_postmortem_write :: proc(
	writer: ^Graphics_Postmortem,
	snapshot: ^Graphics_Postmortem_Snapshot,
) -> profile.Graphics_Postmortem_Save_Diagnostic {
	payload, encoded := graphics_postmortem_format(snapshot)
	if !encoded {return .Payload_Too_Large}
	defer delete(payload)
	sink := writer.sink
	if sink == nil {sink = graphics_postmortem_profile_sink}
	return sink(writer.sink_ctx, graphics_postmortem_path_text(&writer.path), payload)
}

@(private = "file")
graphics_postmortem_record_write :: proc(
	writer: ^Graphics_Postmortem,
	revision: u64,
	diagnostic: profile.Graphics_Postmortem_Save_Diagnostic,
) {
	writer.writes_attempted += 1
	writer.last_save_diagnostic = diagnostic
	if diagnostic == .None {
		writer.writes_succeeded += 1
		writer.persisted_revision = revision
	} else {
		writer.writes_failed += 1
		writer.dirty = true
	}
}

@(private = "file")
graphics_postmortem_worker_proc :: proc(writer: ^Graphics_Postmortem) {
	if writer == nil {return}
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	for {
		sync.lock(&writer.mu)
		for !writer.stopping {
			if !writer.dirty {
				sync.cond_wait(&writer.wake, &writer.mu)
				continue
			}
			elapsed := time.tick_since(writer.last_attempt_started)
			if elapsed >= GRAPHICS_POSTMORTEM_WRITE_INTERVAL {break}
			_ = sync.cond_wait_with_timeout(
				&writer.wake,
				&writer.mu,
				GRAPHICS_POSTMORTEM_WRITE_INTERVAL - elapsed,
			)
		}
		if writer.stopping {
			if !writer.dirty {
				writer.worker_running = false
				sync.unlock(&writer.mu)
				return
			}
			snapshot := writer.latest
			writer.dirty = false
			writer.last_attempt_started = time.tick_now()
			sync.unlock(&writer.mu)
			diagnostic := graphics_postmortem_write(writer, &snapshot)
			sync.lock(&writer.mu)
			graphics_postmortem_record_write(writer, snapshot.revision, diagnostic)
			writer.worker_running = false
			sync.unlock(&writer.mu)
			return
		}
		snapshot := writer.latest
		writer.dirty = false
		writer.last_attempt_started = time.tick_now()
		sync.unlock(&writer.mu)

		diagnostic := graphics_postmortem_write(writer, &snapshot)
		sync.lock(&writer.mu)
		graphics_postmortem_record_write(writer, snapshot.revision, diagnostic)
		if writer.latest.revision != snapshot.revision {writer.dirty = true}
		sync.unlock(&writer.mu)
	}
}

graphics_postmortem_init :: proc(
	writer: ^Graphics_Postmortem,
	config: Graphics_Postmortem_Config,
) -> Graphics_Postmortem_Init_Diagnostic {
	if writer == nil {return .Invalid_Configuration}
	writer^ = {}
	if !config.enabled {return .None}
	if config.path == "" {return .Invalid_Configuration}
	if !graphics_postmortem_assign(writer.path.data[:], &writer.path.length, config.path) ||
	   !graphics_postmortem_assign(
			   writer.latest.session.data[:],
			   &writer.latest.session.length,
			   config.session,
		   ) ||
	   !graphics_postmortem_assign(
			   writer.latest.device.data[:],
			   &writer.latest.device.length,
			   config.device,
		   ) {
		return .Field_Too_Large
	}
	writer.latest.schema_version = GRAPHICS_POSTMORTEM_SCHEMA_VERSION
	writer.latest.session_provenance = config.session == "" ? .Unavailable : .Derived
	writer.latest.device_provenance = config.device == "" ? .Unavailable : .Derived
	writer.latest.session_generation_provenance = .Unavailable
	writer.latest.guest_device_generation_provenance = .Unavailable
	writer.latest.host_device_generation_provenance = .Unavailable
	writer.latest.frame_generation_provenance = .Unavailable
	writer.latest.host_stage = .Unavailable
	writer.latest.host_stage_provenance = .Unavailable
	writer.latest.window_provenance = .Unavailable
	writer.latest.window_frame_generation_provenance = .Unavailable
	writer.latest.vm_provenance = .Unavailable
	writer.latest.vm_frame_generation_provenance = .Unavailable
	writer.sink = config.sink
	writer.sink_ctx = config.sink_ctx
	writer.enabled = true
	writer.worker_running = true
	writer.last_attempt_started = time.tick_now()
	writer.worker = thread.create_and_start_with_poly_data(writer, graphics_postmortem_worker_proc)
	if writer.worker == nil {
		writer.enabled = false
		writer.worker_running = false
		return .Thread_Failed
	}
	return .None
}

@(private = "file")
graphics_postmortem_next_revision :: proc(writer: ^Graphics_Postmortem) {
	writer.latest.revision += 1
	if writer.latest.revision == 0 {writer.latest.revision = 1}
	writer.dirty = true
}

graphics_postmortem_publish_state :: proc(
	writer: ^Graphics_Postmortem,
	state: Graphics_Postmortem_State,
) -> Graphics_Postmortem_Publish_Diagnostic {
	if writer == nil {return .Invalid_Argument}
	sync.lock(&writer.mu)
	if !writer.enabled || writer.stopping {
		sync.unlock(&writer.mu)
		return .Disabled
	}
	if state.frame_generation < writer.latest.frame_generation ||
	   (state.frame_generation == writer.latest.frame_generation &&
			   u8(state.host_stage) < u8(writer.latest.host_stage)) {
		sync.unlock(&writer.mu)
		return .Stale_State
	}
	writer.latest.session_generation = state.session_generation
	writer.latest.session_generation_provenance = state.session_generation_provenance
	writer.latest.guest_device_generation = state.guest_device_generation
	writer.latest.guest_device_generation_provenance = state.guest_device_generation_provenance
	writer.latest.host_device_generation = state.host_device_generation
	writer.latest.host_device_generation_provenance = state.host_device_generation_provenance
	writer.latest.frame_generation = state.frame_generation
	writer.latest.frame_generation_provenance = state.frame_generation_provenance
	writer.latest.host_stage = state.host_stage
	writer.latest.host_stage_provenance = state.host_stage_provenance
	graphics_postmortem_next_revision(writer)
	sync.unlock(&writer.mu)
	sync.cond_signal(&writer.wake)
	return .None
}

graphics_postmortem_measured_state :: proc(
	session_generation: u64,
	guest_device_generation: u64,
	host_device_generation: u64,
	frame_generation: u64,
	host_stage: Graphics_Postmortem_Host_Stage,
) -> Graphics_Postmortem_State {
	state := Graphics_Postmortem_State {
		session_generation = session_generation,
		session_generation_provenance = .Measured,
		guest_device_generation = guest_device_generation,
		guest_device_generation_provenance = .Measured,
		host_device_generation = host_device_generation,
		host_device_generation_provenance = .Measured,
		frame_generation = frame_generation,
		frame_generation_provenance = .Measured,
		host_stage = host_stage,
		host_stage_provenance = .Measured,
	}
	if state.session_generation == 0 {state.session_generation_provenance = .Unavailable}
	if state.guest_device_generation == 0 {
		state.guest_device_generation_provenance = .Unavailable
	}
	if state.host_device_generation == 0 {
		state.host_device_generation_provenance = .Unavailable
	}
	if state.frame_generation == 0 {state.frame_generation_provenance = .Unavailable}
	return state
}

graphics_postmortem_publish_window :: proc(
	writer: ^Graphics_Postmortem,
	text: string,
	frame_generation: u64,
	provenance := Graphics_Postmortem_Provenance.Derived,
	generation_provenance := Graphics_Postmortem_Provenance.Measured,
) -> Graphics_Postmortem_Publish_Diagnostic {
	if writer == nil {return .Invalid_Argument}
	sync.lock(&writer.mu)
	if !writer.enabled || writer.stopping {
		sync.unlock(&writer.mu)
		return .Disabled
	}
	if len(text) > GRAPHICS_POSTMORTEM_WINDOW_MAX_BYTES {
		sync.unlock(&writer.mu)
		return .Text_Too_Large
	}
	if !graphics_postmortem_payload_text_valid(text) {
		sync.unlock(&writer.mu)
		return .Invalid_Argument
	}
	if frame_generation != 0 &&
	   writer.latest.window_frame_generation != 0 &&
	   writer.latest.window_frame_generation_provenance != .Unavailable &&
	   frame_generation < writer.latest.window_frame_generation {
		sync.unlock(&writer.mu)
		return .Stale_State
	}
	_ = graphics_postmortem_assign(
		writer.latest.window.data[:],
		&writer.latest.window.length,
		text,
	)
	writer.latest.window_provenance = provenance
	writer.latest.window_frame_generation = frame_generation
	writer.latest.window_frame_generation_provenance =
		frame_generation == 0 ? .Unavailable : generation_provenance
	graphics_postmortem_next_revision(writer)
	sync.unlock(&writer.mu)
	sync.cond_signal(&writer.wake)
	return .None
}

graphics_postmortem_publish_vm :: proc(
	writer: ^Graphics_Postmortem,
	text: string,
	frame_generation: u64,
	provenance := Graphics_Postmortem_Provenance.Measured,
	generation_provenance := Graphics_Postmortem_Provenance.Measured,
) -> Graphics_Postmortem_Publish_Diagnostic {
	if writer == nil {return .Invalid_Argument}
	sync.lock(&writer.mu)
	if !writer.enabled || writer.stopping {
		sync.unlock(&writer.mu)
		return .Disabled
	}
	if len(text) > GRAPHICS_POSTMORTEM_VM_MAX_BYTES {
		sync.unlock(&writer.mu)
		return .Text_Too_Large
	}
	if !graphics_postmortem_payload_text_valid(text) {
		sync.unlock(&writer.mu)
		return .Invalid_Argument
	}
	if frame_generation != 0 &&
	   writer.latest.vm_frame_generation != 0 &&
	   writer.latest.vm_frame_generation_provenance != .Unavailable &&
	   frame_generation < writer.latest.vm_frame_generation {
		sync.unlock(&writer.mu)
		return .Stale_State
	}
	_ = graphics_postmortem_assign(writer.latest.vm.data[:], &writer.latest.vm.length, text)
	writer.latest.vm_provenance = provenance
	writer.latest.vm_frame_generation = frame_generation
	writer.latest.vm_frame_generation_provenance =
		frame_generation == 0 ? .Unavailable : generation_provenance
	graphics_postmortem_next_revision(writer)
	sync.unlock(&writer.mu)
	sync.cond_signal(&writer.wake)
	return .None
}

graphics_postmortem_snapshot :: proc(
	writer: ^Graphics_Postmortem,
) -> Graphics_Postmortem_Snapshot {
	if writer == nil {return {}}
	sync.lock(&writer.mu)
	defer sync.unlock(&writer.mu)
	return writer.latest
}

graphics_postmortem_status :: proc(writer: ^Graphics_Postmortem) -> Graphics_Postmortem_Status {
	if writer == nil {return {}}
	sync.lock(&writer.mu)
	defer sync.unlock(&writer.mu)
	return {
		enabled = writer.enabled,
		worker_running = writer.worker_running,
		dirty = writer.dirty,
		revision = writer.latest.revision,
		persisted_revision = writer.persisted_revision,
		writes_attempted = writer.writes_attempted,
		writes_succeeded = writer.writes_succeeded,
		writes_failed = writer.writes_failed,
		last_save_diagnostic = writer.last_save_diagnostic,
	}
}

graphics_postmortem_destroy :: proc(
	writer: ^Graphics_Postmortem,
) -> profile.Graphics_Postmortem_Save_Diagnostic {
	if writer == nil {return .None}
	sync.lock(&writer.mu)
	worker := writer.worker
	if worker == nil {
		writer.enabled = false
		diagnostic := writer.last_save_diagnostic
		sync.unlock(&writer.mu)
		return diagnostic
	}
	writer.stopping = true
	sync.unlock(&writer.mu)
	sync.cond_broadcast(&writer.wake)
	thread.destroy(worker)
	sync.lock(&writer.mu)
	writer.worker = nil
	writer.enabled = false
	diagnostic := writer.last_save_diagnostic
	sync.unlock(&writer.mu)
	return diagnostic
}
