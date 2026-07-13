// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:encoding/json"
import "core:os"
import "core:strings"

INSTALL_STATE_VERSION :: 2
INSTALL_STATE_VERSION_LEGACY :: 1

Install_Phase :: enum {
	None,
	Preparing,
	Launch_Pending,
	Setup_Running,
}

Install_State :: struct {
	phase:            Install_Phase,
	source_path:      string,
	reset_count:      u32,
	saved_cmos_valid: bool,
	saved_cmos_38:    u8,
	saved_cmos_3d:    u8,
}

Install_State_Diagnostic :: enum {
	None,
	Missing,
	Read_Failed,
	Malformed,
	Unsupported_Version,
	Unknown_Phase,
	Invalid_State,
	Encode_Failed,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

install_state_active :: proc(state: ^Install_State) -> bool {
	return state != nil && state.phase != .None
}

install_state_destroy :: proc(state: ^Install_State, allocator := context.allocator) {
	if state == nil {return}
	delete(state.source_path, allocator)
	state^ = {}
}

install_state_load :: proc(path: string) -> (Install_State, Install_State_Diagnostic) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		if rerr == os.General_Error.Not_Exist {return {}, .Missing}
		return {}, .Read_Failed
	}
	defer delete(data)

	disk: Disk_Install_State
	defer {
		delete(disk.phase)
		delete(disk.source_path)
	}
	if jerr := json.unmarshal(data, &disk); jerr != nil {return {}, .Malformed}
	if disk.version != INSTALL_STATE_VERSION && disk.version != INSTALL_STATE_VERSION_LEGACY {
		return {}, .Unsupported_Version
	}
	phase, known := install_phase_parse(disk.phase)
	if !known {return {}, .Unknown_Phase}
	if phase != .None && disk.source_path == "" {return {}, .Invalid_State}
	saved_cmos_valid := disk.saved_cmos_valid
	if disk.version == INSTALL_STATE_VERSION_LEGACY {
		saved_cmos_valid = disk.saved_cmos_38 != 0 || disk.saved_cmos_3d != 0
	}
	return Install_State {
			phase = phase,
			source_path = strings.clone(disk.source_path),
			reset_count = disk.reset_count,
			saved_cmos_valid = saved_cmos_valid,
			saved_cmos_38 = disk.saved_cmos_38,
			saved_cmos_3d = disk.saved_cmos_3d,
		},
		.None
}

install_state_save :: proc(path: string, state: ^Install_State) -> Install_State_Diagnostic {
	if state == nil || (state.phase != .None && state.source_path == "") {
		return .Invalid_State
	}
	phase, known := install_phase_serialize(state.phase)
	if !known {return .Unknown_Phase}
	disk := Disk_Install_State {
		version          = INSTALL_STATE_VERSION,
		phase            = phase,
		source_path      = state.source_path,
		reset_count      = state.reset_count,
		saved_cmos_valid = state.saved_cmos_valid,
		saved_cmos_38    = state.saved_cmos_38,
		saved_cmos_3d    = state.saved_cmos_3d,
	}
	data, jerr := json.marshal(disk, {pretty = true, use_spaces = true, spaces = 2})
	if jerr != nil {return .Encode_Failed}
	defer delete(data)
	switch atomic_replace(path, data, "install-state") {
	case .None:
		return .None
	case .Create_Directory_Failed:
		return .Create_Directory_Failed
	case .Temporary_Path_Failed:
		return .Temporary_Path_Failed
	case .Write_Failed:
		return .Write_Failed
	case .Replace_Failed:
		return .Replace_Failed
	}
	return .Write_Failed
}

install_state_save_inactive :: proc(path: string) -> Install_State_Diagnostic {
	state: Install_State
	return install_state_save(path, &state)
}

@(private)
Disk_Install_State :: struct {
	version:          int `json:"version"`,
	phase:            string `json:"phase"`,
	source_path:      string `json:"source_path"`,
	reset_count:      u32 `json:"reset_count"`,
	saved_cmos_valid: bool `json:"saved_cmos_valid"`,
	saved_cmos_38:    u8 `json:"saved_cmos_38"`,
	saved_cmos_3d:    u8 `json:"saved_cmos_3d"`,
}

@(private = "file")
install_phase_parse :: proc(name: string) -> (Install_Phase, bool) {
	switch name {
	case "none":
		return .None, true
	case "preparing":
		return .Preparing, true
	case "launch_pending":
		return .Launch_Pending, true
	case "setup_running":
		return .Setup_Running, true
	}
	return .None, false
}

@(private = "file")
install_phase_serialize :: proc(phase: Install_Phase) -> (string, bool) {
	switch phase {
	case .None:
		return "none", true
	case .Preparing:
		return "preparing", true
	case .Launch_Pending:
		return "launch_pending", true
	case .Setup_Running:
		return "setup_running", true
	}
	return "", false
}
