// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

INSTALL_STATE_VERSION :: 4
INSTALL_STATE_VERSION_V3 :: 3
INSTALL_STATE_VERSION_V2 :: 2
INSTALL_STATE_VERSION_V1 :: 1

Install_Image_Identity :: [16]u8

Install_Phase :: enum {
	None,
	Preparing,
	Launch_Pending,
	Setup_Running,
}

Install_Milestone :: enum {
	None,
	DOS_Setup,
	First_Reboot,
	Hardware_Detection,
}

Install_State :: struct {
	phase:               Install_Phase,
	milestone:           Install_Milestone,
	source_path:         string,
	image_path:          string,
	image_identity:      Install_Image_Identity,
	edit_transaction_id: u64,
	reset_count:         u32,
	saved_cmos_valid:    bool,
	saved_cmos_38:       u8,
	saved_cmos_3d:       u8,
}

Install_State_Diagnostic :: enum {
	None,
	Missing,
	Read_Failed,
	Malformed,
	Unsupported_Version,
	Unknown_Phase,
	Unknown_Milestone,
	Invalid_State,
	Unbound_Active,
	Invalid_Image_Path,
	Malformed_Image_Identity,
	Invalid_Edit_Transaction,
	Encode_Failed,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

Install_State_Recovery_Diagnostic :: enum {
	None,
	Not_Required,
	Read_Failed,
	Evidence_Path_Failed,
	Evidence_Write_Failed,
	Evidence_Verification_Failed,
	Source_Changed,
	Clear_Failed,
}

Install_Binding_Diagnostic :: enum {
	None,
	Inactive_Unbound,
	Binding_Required,
	Invalid_Image_Path,
	Invalid_Image_Identity,
	Invalid_Edit_Transaction,
	Image_Path_Mismatch,
	Image_Identity_Mismatch,
	Stale_Edit_Transaction,
	Active_Rebind_Rejected,
}

install_state_active :: proc(state: ^Install_State) -> bool {
	return state != nil && state.phase != .None
}

install_state_recovery_required :: proc(diagnostic: Install_State_Diagnostic) -> bool {
	return diagnostic != .None && diagnostic != .Missing
}

install_state_bound :: proc(state: ^Install_State) -> bool {
	return(
		state != nil &&
		len(state.image_path) > 0 &&
		filepath.is_abs(state.image_path) &&
		install_image_identity_valid(state.image_identity) &&
		state.edit_transaction_id != 0 \
	)
}

install_state_bind :: proc(
	state: ^Install_State,
	image_path: string,
	image_identity: Install_Image_Identity,
	edit_transaction_id: u64,
	allocator := context.allocator,
) -> Install_Binding_Diagnostic {
	if state == nil || len(image_path) == 0 {return .Invalid_Image_Path}
	normalized, valid_path := settings_normalize_hard_drive_path(image_path, allocator)
	if !valid_path || len(normalized) == 0 {return .Invalid_Image_Path}
	defer if normalized != "" {delete(normalized, allocator)}
	if !install_image_identity_valid(image_identity) {return .Invalid_Image_Identity}
	if edit_transaction_id == 0 {return .Invalid_Edit_Transaction}
	if install_state_active(state) {
		if install_state_bound(state) &&
		   install_state_paths_equal(state.image_path, normalized) &&
		   state.image_identity == image_identity &&
		   state.edit_transaction_id == edit_transaction_id {
			return .None
		}
		return .Active_Rebind_Rejected
	}
	delete(state.image_path, allocator)
	state.image_path = normalized
	normalized = ""
	state.image_identity = image_identity
	state.edit_transaction_id = edit_transaction_id
	return .None
}

install_state_verify_binding :: proc(
	state: ^Install_State,
	image_path: string,
	image_identity: Install_Image_Identity,
	edit_transaction_id: u64,
	allocator := context.allocator,
) -> Install_Binding_Diagnostic {
	if state == nil {return .Binding_Required}
	if !install_state_bound(state) {
		return install_state_active(state) ? .Binding_Required : .Inactive_Unbound
	}
	if len(image_path) == 0 {return .Invalid_Image_Path}
	normalized, valid_path := settings_normalize_hard_drive_path(image_path, allocator)
	if !valid_path || len(normalized) == 0 {return .Invalid_Image_Path}
	defer delete(normalized, allocator)
	if !install_image_identity_valid(image_identity) {return .Invalid_Image_Identity}
	if edit_transaction_id == 0 {return .Invalid_Edit_Transaction}
	if !install_state_paths_equal(state.image_path, normalized) {return .Image_Path_Mismatch}
	if state.image_identity != image_identity {return .Image_Identity_Mismatch}
	if state.edit_transaction_id != edit_transaction_id {return .Stale_Edit_Transaction}
	return .None
}

install_state_clear_binding :: proc(
	state: ^Install_State,
	allocator := context.allocator,
) -> Install_Binding_Diagnostic {
	if state == nil {return .Inactive_Unbound}
	if install_state_active(state) {return .Active_Rebind_Rejected}
	delete(state.image_path, allocator)
	state.image_path = ""
	state.image_identity = {}
	state.edit_transaction_id = 0
	return .None
}

install_state_milestone_reached :: proc(
	state: ^Install_State,
	milestone: Install_Milestone,
) -> bool {
	if state == nil || state.phase != .Setup_Running || milestone == .None {return false}
	normalized := install_state_normalized_milestone(state)
	if _, known := install_milestone_serialize(normalized); !known {return false}
	return int(normalized) >= int(milestone)
}

install_state_advance_milestone :: proc(
	state: ^Install_State,
	milestone: Install_Milestone,
) -> bool {
	if state == nil || state.phase != .Setup_Running || milestone == .None {return false}
	if _, known := install_milestone_serialize(milestone); !known {return false}
	if int(milestone) < int(state.milestone) {return false}
	if !install_state_fields_valid(state.phase, milestone, state.source_path, state.reset_count) {
		return false
	}
	state.milestone = milestone
	return true
}

install_state_destroy :: proc(state: ^Install_State, allocator := context.allocator) {
	if state == nil {return}
	delete(state.source_path, allocator)
	delete(state.image_path, allocator)
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
		delete(disk.milestone)
		delete(disk.source_path)
		delete(disk.image_path)
		delete(disk.image_identity)
	}
	if jerr := json.unmarshal(data, &disk); jerr != nil {return {}, .Malformed}
	if disk.version != INSTALL_STATE_VERSION &&
	   disk.version != INSTALL_STATE_VERSION_V3 &&
	   disk.version != INSTALL_STATE_VERSION_V2 &&
	   disk.version != INSTALL_STATE_VERSION_V1 {
		return {}, .Unsupported_Version
	}
	phase, known := install_phase_parse(disk.phase)
	if !known {return {}, .Unknown_Phase}
	milestone: Install_Milestone
	if disk.version == INSTALL_STATE_VERSION || disk.version == INSTALL_STATE_VERSION_V3 {
		milestone, known = install_milestone_parse(disk.milestone)
		if !known {return {}, .Unknown_Milestone}
	} else {
		milestone = install_state_legacy_milestone(phase, disk.reset_count)
	}
	if !install_state_fields_valid(phase, milestone, disk.source_path, disk.reset_count) {
		return {}, .Invalid_State
	}
	saved_cmos_valid := disk.saved_cmos_valid
	if disk.version == INSTALL_STATE_VERSION_V1 {
		saved_cmos_valid = disk.saved_cmos_38 != 0 || disk.saved_cmos_3d != 0
	}
	state := Install_State {
		phase            = phase,
		milestone        = milestone,
		source_path      = strings.clone(disk.source_path),
		reset_count      = disk.reset_count,
		saved_cmos_valid = saved_cmos_valid,
		saved_cmos_38    = disk.saved_cmos_38,
		saved_cmos_3d    = disk.saved_cmos_3d,
	}
	if disk.version != INSTALL_STATE_VERSION {
		if install_state_active(&state) {
			install_state_destroy(&state)
			return {}, .Unbound_Active
		}
		return state, .None
	}

	binding_present :=
		len(disk.image_path) > 0 || len(disk.image_identity) > 0 || disk.edit_transaction_id != 0
	if !binding_present {
		if install_state_active(&state) {
			install_state_destroy(&state)
			return {}, .Unbound_Active
		}
		return state, .None
	}
	if len(disk.image_path) == 0 || !filepath.is_abs(disk.image_path) {
		install_state_destroy(&state)
		return {}, .Invalid_Image_Path
	}
	normalized_path, valid_path := settings_normalize_hard_drive_path(disk.image_path)
	if !valid_path || len(normalized_path) == 0 {
		install_state_destroy(&state)
		return {}, .Invalid_Image_Path
	}
	identity, valid_identity := install_image_identity_parse(disk.image_identity)
	if !valid_identity {
		delete(normalized_path)
		install_state_destroy(&state)
		return {}, .Malformed_Image_Identity
	}
	if disk.edit_transaction_id == 0 {
		delete(normalized_path)
		install_state_destroy(&state)
		return {}, .Invalid_Edit_Transaction
	}
	state.image_path = normalized_path
	state.image_identity = identity
	state.edit_transaction_id = disk.edit_transaction_id
	return state, .None
}

install_state_save :: proc(path: string, state: ^Install_State) -> Install_State_Diagnostic {
	if state == nil {return .Invalid_State}
	phase, known := install_phase_serialize(state.phase)
	if !known {return .Unknown_Phase}
	milestone := install_state_normalized_milestone(state)
	milestone_name, milestone_known := install_milestone_serialize(milestone)
	if !milestone_known {return .Unknown_Milestone}
	if !install_state_fields_valid(state.phase, milestone, state.source_path, state.reset_count) {
		return .Invalid_State
	}
	binding_present :=
		len(state.image_path) > 0 ||
		install_image_identity_valid(state.image_identity) ||
		state.edit_transaction_id != 0
	if install_state_active(state) && !install_state_bound(state) {return .Unbound_Active}
	if binding_present && !install_state_bound(state) {return .Invalid_State}

	normalized_path := ""
	identity_text := ""
	identity_storage: [32]u8
	if install_state_bound(state) {
		valid_path: bool
		normalized_path, valid_path = settings_normalize_hard_drive_path(state.image_path)
		if !valid_path || len(normalized_path) == 0 {return .Invalid_Image_Path}
		defer delete(normalized_path)
		identity_storage = install_image_identity_serialize(state.image_identity)
		identity_text = string(identity_storage[:])
	}
	disk := Disk_Install_State {
		version             = INSTALL_STATE_VERSION,
		phase               = phase,
		milestone           = milestone_name,
		source_path         = state.source_path,
		image_path          = normalized_path,
		image_identity      = identity_text,
		edit_transaction_id = state.edit_transaction_id,
		reset_count         = state.reset_count,
		saved_cmos_valid    = state.saved_cmos_valid,
		saved_cmos_38       = state.saved_cmos_38,
		saved_cmos_3d       = state.saved_cmos_3d,
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

install_state_abandon_invalid :: proc(
	path: string,
	diagnostic: Install_State_Diagnostic,
	allocator := context.allocator,
) -> (
	evidence_path: string,
	recovery_diagnostic: Install_State_Recovery_Diagnostic,
) {
	if !install_state_recovery_required(diagnostic) {return "", .Not_Required}
	payload, read_error := os.read_entire_file(path, allocator)
	if read_error != nil {return "", .Read_Failed}
	defer delete(payload, allocator)

	path_ok: bool
	evidence_path, path_ok = install_state_evidence_path(path, allocator)
	if !path_ok {return "", .Evidence_Path_Failed}
	write_diagnostic := atomic_replace(evidence_path, payload, "install-state-evidence")
	if write_diagnostic != .None {
		delete(evidence_path, allocator)
		return "", .Evidence_Write_Failed
	}

	retained, retained_error := os.read_entire_file(evidence_path, allocator)
	if retained_error != nil || !slice.equal(payload, retained) {
		delete(retained, allocator)
		return evidence_path, .Evidence_Verification_Failed
	}
	delete(retained, allocator)

	current, current_error := os.read_entire_file(path, allocator)
	if current_error != nil || !slice.equal(payload, current) {
		delete(current, allocator)
		return evidence_path, .Source_Changed
	}
	delete(current, allocator)
	if install_state_save_inactive(path) != .None {
		return evidence_path, .Clear_Failed
	}
	return evidence_path, .None
}

@(private)
Disk_Install_State :: struct {
	version:             int `json:"version"`,
	phase:               string `json:"phase"`,
	milestone:           string `json:"milestone"`,
	source_path:         string `json:"source_path"`,
	reset_count:         u32 `json:"reset_count"`,
	saved_cmos_valid:    bool `json:"saved_cmos_valid"`,
	saved_cmos_38:       u8 `json:"saved_cmos_38"`,
	saved_cmos_3d:       u8 `json:"saved_cmos_3d"`,
	image_path:          string `json:"image_path"`,
	image_identity:      string `json:"image_identity"`,
	edit_transaction_id: u64 `json:"edit_transaction_id"`,
}

@(private = "file")
install_state_evidence_path :: proc(
	path: string,
	allocator := context.allocator,
) -> (string, bool) {
	directory := filepath.dir(path)
	base := filepath.base(path)
	for attempt in 0 ..< 1024 {
		name := fmt.tprintf("%s.retained-%d-%d.json", base, os.get_pid(), attempt)
		candidate, path_error := filepath.join({directory, name}, allocator)
		if path_error != nil {return "", false}
		if !os.exists(candidate) {return candidate, true}
		delete(candidate, allocator)
	}
	return "", false
}

@(private = "file")
install_state_paths_equal :: proc(left, right: string) -> bool {
	when ODIN_OS == .Windows {
		return strings.equal_fold(left, right)
	} else {
		return left == right
	}
}

@(private = "file")
install_image_identity_valid :: proc(identity: Install_Image_Identity) -> bool {
	for octet in identity {
		if octet != 0 {return true}
	}
	return false
}

@(private = "file")
install_image_identity_parse :: proc(text: string) -> (Install_Image_Identity, bool) {
	identity: Install_Image_Identity
	if len(text) != 32 {return identity, false}
	for index in 0 ..< 16 {
		high, high_valid := install_hex_lower_value(text[index * 2])
		low, low_valid := install_hex_lower_value(text[index * 2 + 1])
		if !high_valid || !low_valid {return {}, false}
		identity[index] = high << 4 | low
	}
	return identity, install_image_identity_valid(identity)
}

@(private = "file")
install_image_identity_serialize :: proc(identity: Install_Image_Identity) -> [32]u8 {
	result: [32]u8
	digits := "0123456789abcdef"
	for octet, index in identity {
		result[index * 2] = digits[octet >> 4]
		result[index * 2 + 1] = digits[octet & 0x0F]
	}
	return result
}

@(private = "file")
install_hex_lower_value :: proc(value: u8) -> (u8, bool) {
	if value >= '0' && value <= '9' {return value - '0', true}
	if value >= 'a' && value <= 'f' {return value - 'a' + 10, true}
	return 0, false
}

@(private = "file")
install_state_legacy_milestone :: proc(
	phase: Install_Phase,
	reset_count: u32,
) -> Install_Milestone {
	if phase != .Setup_Running {return .None}
	return reset_count == 0 ? .DOS_Setup : .First_Reboot
}

@(private = "file")
install_state_normalized_milestone :: proc(state: ^Install_State) -> Install_Milestone {
	if state == nil {return .None}
	if state.phase == .Setup_Running {
		inferred := install_state_legacy_milestone(state.phase, state.reset_count)
		if int(state.milestone) < int(inferred) {return inferred}
	}
	return state.milestone
}

@(private = "file")
install_state_fields_valid :: proc(
	phase: Install_Phase,
	milestone: Install_Milestone,
	source_path: string,
	reset_count: u32,
) -> bool {
	switch phase {
	case .None:
		return milestone == .None && source_path == "" && reset_count == 0
	case .Preparing, .Launch_Pending:
		return milestone == .None && source_path != ""
	case .Setup_Running:
		if source_path == "" || milestone == .None {return false}
		if milestone == .DOS_Setup {return reset_count == 0}
		if milestone >= .First_Reboot {return reset_count > 0}
		return true
	}
	return false
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

@(private = "file")
install_milestone_parse :: proc(name: string) -> (Install_Milestone, bool) {
	switch name {
	case "none":
		return .None, true
	case "dos_setup":
		return .DOS_Setup, true
	case "first_reboot":
		return .First_Reboot, true
	case "hardware_detection":
		return .Hardware_Detection, true
	}
	return .None, false
}

@(private = "file")
install_milestone_serialize :: proc(milestone: Install_Milestone) -> (string, bool) {
	switch milestone {
	case .None:
		return "none", true
	case .DOS_Setup:
		return "dos_setup", true
	case .First_Reboot:
		return "first_reboot", true
	case .Hardware_Detection:
		return "hardware_detection", true
	}
	return "", false
}
