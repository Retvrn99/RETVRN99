// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32edit "../fat32edit"
import fat32fs "../fat32fs"
import fat32image "../fat32image"
import "base:runtime"

Edit_Page :: fat32fs.Page
Edit_Stat :: fat32fs.Stat
Edit_Read_Result :: fat32fs.Read_Result
Edit_Job_Progress :: fat32edit.Job_Progress
Edit_Job_State :: fat32edit.Job_State
Edit_Apply_Progress :: fat32edit.Apply_Progress
Edit_Apply_State :: fat32edit.Apply_Job_State

EDIT_PAGE_ENTRY_LIMIT :: 64

Boot_Target :: struct {
	first_cluster: u32,
	lba:           u64,
}

Edit_Adoption_Result :: struct {
	image_identity: fat32image.Image_Id,
	staged:         bool,
}

Edit_Operations :: struct {
	ready:                proc(ctx: rawptr) -> bool,
	transaction_id:       proc(ctx: rawptr) -> u64,
	changed_sector_count: proc(ctx: rawptr) -> u64,
	list:                 proc(
		ctx: rawptr,
		path: string,
		cursor: u64,
		limit: int,
		allocator: runtime.Allocator,
	) -> (
		Edit_Page,
		Session_Error,
	),
	stat:                 proc(ctx: rawptr, path: string) -> (Edit_Stat, Session_Error),
	read:                 proc(
		ctx: rawptr,
		path: string,
		offset, length: u64,
		allocator: runtime.Allocator,
	) -> (
		Edit_Read_Result,
		Session_Error,
	),
	mkdir:                proc(ctx: rawptr, path: string) -> Session_Error,
	rename:               proc(ctx: rawptr, source, destination: string) -> Session_Error,
	remove_recursive:     proc(ctx: rawptr, path: string) -> Session_Error,
	begin_remove_recursive: proc(ctx: rawptr, path: string) -> Session_Error,
	begin_import_file:    proc(
		ctx: rawptr,
		host_source, guest_destination: string,
		replace: bool,
	) -> Session_Error,
	begin_import_tree:    proc(
		ctx: rawptr,
		host_source, guest_destination: string,
		replace: bool,
	) -> Session_Error,
	begin_export_file:    proc(
		ctx: rawptr,
		guest_source, host_destination: string,
	) -> Session_Error,
	job_step:             proc(ctx: rawptr) -> (Edit_Job_Progress, Session_Error),
	job_cancel:           proc(ctx: rawptr) -> Session_Error,
	adopt_image:          proc(ctx: rawptr) -> (Edit_Adoption_Result, Session_Error),
	patch_boot_loader:    proc(ctx: rawptr, io_sys_cluster: u32) -> (Boot_Target, Session_Error),
	restore_boot_loader:  proc(ctx: rawptr) -> Session_Error,
	begin_apply:          proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error),
	step_apply:           proc(ctx: rawptr) -> (Edit_Apply_Progress, Session_Error),
	cancel_apply:         proc(ctx: rawptr) -> Session_Error,
	apply:                proc(ctx: rawptr) -> Session_Error,
	discard:              proc(ctx: rawptr) -> Session_Error,
	close_retain:         proc(ctx: rawptr) -> Session_Error,
	destroy:              proc(ctx: rawptr),
}

Edit_Session :: struct {
	ctx:        rawptr,
	adapter:    Adapter_Kind,
	operations: Edit_Operations,
}

edit_ready :: proc(session: ^Edit_Session) -> bool {
	return(
		session != nil &&
		session.ctx != nil &&
		session.operations.ready != nil &&
		session.operations.ready(session.ctx) \
	)
}

edit_transaction_id :: proc(session: ^Edit_Session) -> u64 {
	if !edit_ready(session) || session.operations.transaction_id == nil {return 0}
	return session.operations.transaction_id(session.ctx)
}

edit_changed_sector_count :: proc(session: ^Edit_Session) -> u64 {
	if !edit_ready(session) || session.operations.changed_sector_count == nil {return 0}
	return session.operations.changed_sector_count(session.ctx)
}

edit_list :: proc(
	session: ^Edit_Session,
	path: string,
	cursor: u64,
	limit: int,
	allocator := context.allocator,
) -> (
	Edit_Page,
	Session_Error,
) {
	if !edit_ready(session) || session.operations.list == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")
	}
	if limit <= 0 || limit > EDIT_PAGE_ENTRY_LIMIT {
		return {}, error_make(
			.Invalid_Argument,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit page request exceeds its bound",
		)
	}
	return session.operations.list(session.ctx, path, cursor, limit, allocator)
}

edit_page_destroy :: proc(page: ^Edit_Page, allocator := context.allocator) {
	fat32fs.page_destroy(page, allocator)
}

edit_stat :: proc(session: ^Edit_Session, path: string) -> (Edit_Stat, Session_Error) {
	if !edit_ready(session) || session.operations.stat == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")
	}
	return session.operations.stat(session.ctx, path)
}

edit_read :: proc(
	session: ^Edit_Session,
	path: string,
	offset, length: u64,
	allocator := context.allocator,
) -> (
	Edit_Read_Result,
	Session_Error,
) {
	if !edit_ready(session) || session.operations.read == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")
	}
	return session.operations.read(session.ctx, path, offset, length, allocator)
}

edit_read_destroy :: proc(result: ^Edit_Read_Result, allocator := context.allocator) {
	fat32fs.read_result_destroy(result, allocator)
}

edit_mkdir :: proc(session: ^Edit_Session, path: string) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.mkdir ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.mkdir(session.ctx, path)
}

edit_rename :: proc(session: ^Edit_Session, source, destination: string) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.rename ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.rename(session.ctx, source, destination)
}

edit_remove_recursive :: proc(session: ^Edit_Session, path: string) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.remove_recursive ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.remove_recursive(session.ctx, path)
}

edit_begin_import_file :: proc(
	session: ^Edit_Session,
	host_source, guest_destination: string,
	replace := false,
) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.begin_import_file ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.begin_import_file(
		session.ctx,
		host_source,
		guest_destination,
		replace,
	)
}

edit_begin_import_tree :: proc(
	session: ^Edit_Session,
	host_source, guest_destination: string,
	replace := false,
) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.begin_import_tree ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.begin_import_tree(
		session.ctx,
		host_source,
		guest_destination,
		replace,
	)
}

edit_begin_export_file :: proc(
	session: ^Edit_Session,
	guest_source, host_destination: string,
) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.begin_export_file ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.begin_export_file(session.ctx, guest_source, host_destination)
}

edit_job_step :: proc(session: ^Edit_Session) -> (Edit_Job_Progress, Session_Error) {
	if !edit_ready(session) ||
	   session.operations.job_step ==
		   nil {return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.job_step(session.ctx)
}

edit_job_cancel :: proc(session: ^Edit_Session) -> Session_Error {
	if !edit_ready(session) ||
	   session.operations.job_cancel ==
		   nil {return error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session is closed")}
	return session.operations.job_cancel(session.ctx)
}

edit_patch_boot_loader :: proc(
	session: ^Edit_Session,
	io_sys_cluster: u32,
) -> (
	Boot_Target,
	Session_Error,
) {
	if !edit_ready(session) || session.operations.patch_boot_loader == nil {
		return {}, error_make(.Invalid_State, false, .Not_Started, 0, 0, "FAT32 Edit session cannot patch its boot loader")
	}
	return session.operations.patch_boot_loader(session.ctx, io_sys_cluster)
}

edit_restore_boot_loader :: proc(session: ^Edit_Session) -> Session_Error {
	if !edit_ready(session) || session.operations.restore_boot_loader == nil {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session cannot restore its boot loader",
		)
	}
	return session.operations.restore_boot_loader(session.ctx)
}

edit_adopt_image :: proc(session: ^Edit_Session) -> (Edit_Adoption_Result, Session_Error) {
	if !edit_ready(session) || session.operations.adopt_image == nil {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session cannot adopt the RETVRN99 boot layout",
		)
	}
	return session.operations.adopt_image(session.ctx)
}

edit_begin_remove_recursive :: proc(session: ^Edit_Session, path: string) -> Session_Error {
	if !edit_ready(session) || session.operations.begin_remove_recursive == nil {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session is closed",
		)
	}
	return session.operations.begin_remove_recursive(session.ctx, path)
}

edit_begin_apply :: proc(session: ^Edit_Session) -> (Edit_Apply_Progress, Session_Error) {
	if !edit_ready(session) || session.operations.begin_apply == nil {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session cannot begin Apply",
		)
	}
	return session.operations.begin_apply(session.ctx)
}

edit_step_apply :: proc(session: ^Edit_Session) -> (Edit_Apply_Progress, Session_Error) {
	if session == nil || session.ctx == nil || session.operations.step_apply == nil {
		return {}, error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply is unavailable",
		)
	}
	progress, err := session.operations.step_apply(session.ctx)
	if err.outcome == .Completed {edit_release_completed(session)}
	return progress, err
}

edit_cancel_apply :: proc(session: ^Edit_Session) -> Session_Error {
	if session == nil || session.ctx == nil || session.operations.cancel_apply == nil {
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit Apply is unavailable",
		)
	}
	return session.operations.cancel_apply(session.ctx)
}

edit_release_completed :: proc(session: ^Edit_Session) {
	if session == nil {return}
	if session.ctx != nil && session.operations.destroy != nil {
		session.operations.destroy(session.ctx)
	}
	session.ctx = nil
	free(session)
}

edit_finish :: proc(session: ^Edit_Session, apply_changes: bool) -> Session_Error {
	if session == nil {return {}}
	if !edit_ready(session) {
		if session.ctx != nil && session.operations.destroy != nil {
			session.operations.destroy(session.ctx)
			session.ctx = nil
		}
		free(session)
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session is closed",
		)
	}
	err :=
		apply_changes ? session.operations.apply(session.ctx) : session.operations.discard(session.ctx)
	if err.code != .None && err.outcome != .Completed {return err}
	if session.operations.destroy != nil {session.operations.destroy(session.ctx)}
	session.ctx = nil
	free(session)
	return err
}

edit_close_retain :: proc(session: ^Edit_Session) -> Session_Error {
	if session == nil {return {}}
	if session.ctx == nil {
		free(session)
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session is closed",
		)
	}
	if session.operations.close_retain == nil {
		if session.operations.destroy != nil {session.operations.destroy(session.ctx)}
		session.ctx = nil
		free(session)
		return error_make(
			.Invalid_State,
			false,
			.Not_Started,
			0,
			0,
			"FAT32 Edit session cannot be retained",
		)
	}
	err := session.operations.close_retain(session.ctx)
	if err.code != .None && err.outcome != .Completed {return err}
	if session.operations.destroy != nil {session.operations.destroy(session.ctx)}
	session.ctx = nil
	free(session)
	return err
}

open_edit :: proc(
	path, edit_session_id: string,
	requested_transaction_id: u64 = 0,
	adapter := DEFAULT_ADAPTER,
) -> (
	^Edit_Session,
	Session_Error,
) {
	switch adapter {
	case .In_Process:
		return open_edit_in_process(path, edit_session_id, requested_transaction_id)
	case .Process:
		return open_edit_process(path, edit_session_id, requested_transaction_id)
	}
	return nil, error_make(.Invalid_Argument, false, .Not_Started, 0, 0, "unknown FAT32 Adapter")
}
