// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32image "../fat32image"
import fat32session "../fat32session"
import win98media "../win98media"

MAX_STAGING_BYTES :: u64(768 * 1024 * 1024)
MAX_STAGING_FILES :: u32(65_536)
MAX_ERROR_TEXT_BYTES :: 512

OWNER_FILE_NAME :: "GSWPREP.OWN"
PAYLOAD_PATH :: "GSWSETUP"
LAUNCHER_PATH :: "GSWSETUP.BAT"
AUTOEXEC_PATH :: "AUTOEXEC.BAT"
AUTOEXEC_BACKUP_PATH :: "GSWAUTO.PRV"

Boot_Source :: enum u8 {
	Required,
	Embedded,
	Provided,
	Existing_DOS,
}

Disk_State :: enum u8 {
	Empty,
	Existing_DOS,
	Partial_DOS,
	Existing_Windows,
	Prepared,
}

Cancel_Point :: enum u8 {
	Media_Inspected,
	Edit_Opened,
	Boot_Seed_Staged,
	Setup_Extracted,
	DOS_Imported,
	Payload_Imported,
	Launcher_Imported,
	Boot_Loader_Staged,
	Before_Apply,
	Abandon_Removing,
	Abandon_Before_Apply,
}

Cancellation :: struct {
	ctx:   rawptr,
	check: proc(ctx: rawptr, point: Cancel_Point) -> bool,
}

Progress_Phase :: enum u8 {
	Import,
	Remove,
	Apply,
}

Progress_State :: enum u8 {
	Pending,
	Running,
	Complete,
	Cancelled,
	Failed,
}

Progress_Action :: enum u8 {
	Continue,
	Cancel,
}

Progress_Update :: struct {
	phase:           Progress_Phase,
	point:           Cancel_Point,
	state:           Progress_State,
	completed_bytes: u64,
	total_bytes:     u64,
	items_completed: u64,
	completed_units: u64,
	total_units:     u64,
	applied_sectors: u64,
	total_sectors:   u64,
	cancellable:     bool,
}

Progress_Hook :: struct {
	ctx:    rawptr,
	update: proc(ctx: rawptr, progress: Progress_Update) -> Progress_Action,
}

Preparation_Binding :: struct {
	image_identity:      fat32image.Image_Id,
	edit_transaction_id: u64,
	boot_target:         Boot_Target,
}

Binding_Hook :: struct {
	ctx:     rawptr,
	persist: proc(ctx: rawptr, binding: Preparation_Binding) -> bool,
}

cancelled :: proc(cancellation: Cancellation, point: Cancel_Point) -> bool {
	return cancellation.check != nil && cancellation.check(cancellation.ctx, point)
}

Prepare_Options :: struct {
	desktop_probe:        bool,
	hardware_diagnostics: bool,
	setup_source_overlay: Setup_Source_Overlay,
	host_locale:          Host_Locale,
}

Host_Locale :: struct {
	language: string,
	country:  string,
}

Inspect_Request :: struct {
	image_path:               string,
	iso_path:                 string,
	boot_floppy_path:         string,
	edit_session_id:          string,
	requested_transaction_id: u64,
}

Prepare_Request :: struct {
	image_path:               string,
	iso_path:                 string,
	boot_floppy_path:         string,
	scratch_parent:           string,
	edit_session_id:          string,
	requested_transaction_id: u64,
	options:                  Prepare_Options,
	cancellation:             Cancellation,
	progress:                 Progress_Hook,
	binding_hook:             Binding_Hook,
}

Abandon_Request :: struct {
	image_path:                 string,
	edit_session_id:            string,
	preparation_transaction_id: u64,
	allow_consumed_content:     bool,
	cancellation:               Cancellation,
	progress:                   Progress_Hook,
}

Verify_Binding_Request :: struct {
	image_path:                 string,
	edit_session_id:            string,
	expected_image_identity:    fat32image.Image_Id,
	preparation_transaction_id: u64,
	allow_consumed_content:     bool,
}

Boot_Target :: struct {
	first_cluster: u32,
	lba:           u64,
}

Inspection :: struct {
	media_info:              win98media.Media_Info,
	image_identity:          fat32image.Image_Id,
	boot_source:             Boot_Source,
	disk_state:              Disk_State,
	prepared_transaction_id: u64,
	boot_target:             Boot_Target,
	pending_edit:            bool,
}

inspection_destroy :: proc(inspection: ^Inspection) {
	if inspection == nil {return}
	win98media.media_info_destroy(&inspection.media_info)
	inspection^ = {}
}

Prepare_Result :: struct {
	media_info:          win98media.Media_Info,
	image_identity:      fat32image.Image_Id,
	edit_transaction_id: u64,
	boot_source:         Boot_Source,
	boot_target:         Boot_Target,
	used_existing_dos:   bool,
	recovered:           bool,
}

prepare_result_destroy :: proc(result: ^Prepare_Result) {
	if result == nil {return}
	win98media.media_info_destroy(&result.media_info)
	result^ = {}
}

Abandon_Result :: struct {
	image_identity:      fat32image.Image_Id,
	edit_transaction_id: u64,
}

Error_Code :: enum u16 {
	None,
	Invalid_Argument,
	Media_Rejected,
	Image_Rejected,
	Image_Not_Enrolled,
	Image_Not_RETVRN99,
	Boot_Floppy_Required,
	Boot_Floppy_Invalid,
	Existing_Windows,
	Partial_DOS,
	Already_Prepared,
	Not_Prepared,
	Ownership_Mismatch,
	Image_Identity_Mismatch,
	Transaction_Mismatch,
	Staging_Limit,
	Scratch_Failed,
	Extraction_Failed,
	Edit_Failed,
	Apply_Failed,
	Binding_Failed,
	Cancelled,
	Recovery_Failed,
	Internal,
}

Error :: struct {
	code:              Error_Code,
	media_diagnostic:  win98media.Diagnostic,
	driver_diagnostic: Driver_Package_Diagnostic,
	tlb_diagnostic:    TLB_Overlay_Result,
	boot_diagnostic:   Bootstrap_Diagnostic,
	session_error:     fat32session.Session_Error,
	diagnostic:        [MAX_ERROR_TEXT_BYTES]u8,
	diagnostic_length: u16,
}

error_text :: proc(err: ^Error) -> string {
	if err == nil || err.diagnostic_length == 0 {return ""}
	return string(err.diagnostic[:int(err.diagnostic_length)])
}

error_make :: proc(code: Error_Code, diagnostic: string) -> Error {
	result := Error {
		code = code,
	}
	count := min(len(diagnostic), MAX_ERROR_TEXT_BYTES)
	copy(result.diagnostic[:count], transmute([]u8)diagnostic)
	result.diagnostic_length = u16(count)
	return result
}
