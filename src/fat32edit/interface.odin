// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import companionio "../companionio"
import disk "../disk"
import fat32fs "../fat32fs"
import "core:os"

SECTOR_BYTES :: 512
MAX_TRANSFER_BYTES :: 128 * 1024
BITMAP_CACHE_BYTES :: 4 * 1024
MAX_ERROR_TEXT_BYTES :: 384

Error_Code :: enum u16 {
	None,
	Invalid_Argument,
	Invalid_State,
	Invalid_Path,
	Not_Found,
	Name_Collision,
	No_Space,
	Host_Path_Unsafe,
	Open_Failed,
	IO,
	Sync_Failed,
	State_Corrupt,
	Fat32,
	Cancelled,
	Internal,
}

Operation_Outcome :: enum u8 {
	Not_Started,
	Preserved,
	Applied,
	Uncertain,
}

Edit_Error :: struct {
	code:              Error_Code,
	retryable:         bool,
	outcome:           Operation_Outcome,
	diagnostic:        [MAX_ERROR_TEXT_BYTES]u8,
	diagnostic_length: u16,
}

Edit_Session :: struct {
	impl: ^Edit_Impl,
}

Apply_Phase :: enum u8 {
	Intent_Durable,
	Image_Applied,
	Image_Synced,
}

Apply_Sink :: struct {
	ctx:   rawptr,
	write: proc(ctx: rawptr, lba: u64, data: []u8) -> bool,
	flush: proc(ctx: rawptr) -> bool,
	phase: proc(ctx: rawptr, phase: Apply_Phase),
}

Apply_Job_State :: enum u8 {
	Ready,
	Applying,
	Complete,
	Cancelled,
	Failed,
}

Apply_Progress :: struct {
	state:           Apply_Job_State,
	completed_units: u64,
	total_units:     u64,
	applied_sectors: u64,
	total_sectors:   u64,
	cancellable:     bool,
}

Apply_Job :: struct {
	session:          ^Edit_Session,
	state:            Apply_Job_State,
	irreversible:     bool,
	scan_lba:         u64,
	applied_sectors:  u64,
	expected_sectors: u64,
	scan_buffer:      []u8,
	data_buffer:      []u8,
	error:            Edit_Error,
	owns_job_slot:    bool,
}

@(private = "package")
Edit_Impl :: struct {
	base:               disk.Block_Device,
	apply_sink:         Apply_Sink,
	overlay_device:     disk.Block_Device,
	state_directory:    string,
	edit_directory:     string,
	state_boundary:     companionio.Directory,
	edit_boundary:      companionio.Directory,
	overlay_path:       string,
	bitmap_path:        string,
	intent_path:        string,
	meta_path:          string,
	transaction_id:     u64,
	overlay_file:       ^os.File,
	bitmap_file:        ^os.File,
	bitmap_cache:       [BITMAP_CACHE_BYTES]u8,
	bitmap_cache_page:  u64,
	bitmap_cache_used:  int,
	bitmap_cache_valid: bool,
	bitmap_cache_dirty: bool,
	bitmap_bytes:       u64,
	dirty_sectors:      u64,
	volume:             fat32fs.Volume,
	active_job:         bool,
	closed:             bool,
}

error_ok :: proc(err: ^Edit_Error) -> bool {
	return err == nil || err.code == .None
}

error_text :: proc(err: ^Edit_Error) -> string {
	if err == nil || err.diagnostic_length == 0 {return ""}
	return string(err.diagnostic[:int(err.diagnostic_length)])
}

has_changes :: proc(session: ^Edit_Session) -> bool {
	return(
		session != nil &&
		session.impl != nil &&
		!session.impl.closed &&
		session.impl.dirty_sectors > 0 \
	)
}

changed_sector_count :: proc(session: ^Edit_Session) -> u64 {
	if session == nil || session.impl == nil || session.impl.closed {return 0}
	return session.impl.dirty_sectors
}

transaction_id :: proc(session: ^Edit_Session) -> u64 {
	if session == nil || session.impl == nil || session.impl.closed {return 0}
	return session.impl.transaction_id
}
