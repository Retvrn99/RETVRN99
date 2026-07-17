// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import companionio "../companionio"
import disk "../disk"
import fat32fs "../fat32fs"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

open :: proc(
	base: disk.Block_Device,
	state_directory: string,
	requested_transaction_id: u64 = 0,
	apply_sink: Apply_Sink = {},
) -> (
	Edit_Session,
	Edit_Error,
) {
	if base.ctx == nil ||
	   base.sector_count == 0 ||
	   base.read == nil ||
	   base.write == nil ||
	   base.flush == nil ||
	   state_directory == "" ||
	   base.sector_count > u64(max(i64)) / SECTOR_BYTES {
		return {}, error_make(.Invalid_Argument, "edit session requires a writable bounded block device and companion directory")
	}
	sink := apply_sink
	if sink.ctx == nil {sink = {
			ctx   = base.ctx,
			write = base.write,
			flush = base.flush,
		}}
	if sink.ctx == nil || sink.write == nil || sink.flush == nil {
		return {}, error_make(.Invalid_Argument, "edit session requires a durable Apply sink")
	}
	recovery_error := recover_apply(base, state_directory, sink)
	if recovery_error.code != .None {return {}, recovery_error}
	impl := new(Edit_Impl)
	impl.base = base
	impl.apply_sink = sink
	impl.state_directory = strings.clone(state_directory)
	boundary_status: companionio.Status
	impl.state_boundary, boundary_status = companionio.open_path(state_directory, true)
	if boundary_status != .None {
		close_impl(impl, false)
		return {}, error_make(.Open_Failed, "cannot bind the FAT32 companion directory")
	}
	edit_directory, path_error := filepath.join({state_directory, "edit"})
	impl.edit_directory = edit_directory
	if path_error != nil {
		close_impl(impl, false)
		return {}, error_make(.Open_Failed, "cannot construct the FAT32 edit companion directory")
	}
	impl.edit_boundary, boundary_status = companionio.open_child(
		&impl.state_boundary,
		"edit",
		true,
	)
	if boundary_status != .None {
		close_impl(impl, false)
		return {}, error_make(.Open_Failed, "cannot create or bind the FAT32 edit companion directory")
	}
	if !companionio.sync_directory(&impl.edit_boundary) ||
	   !companionio.sync_directory(&impl.state_boundary) {
		close_impl(impl, false)
		return {}, error_make(.Sync_Failed, "cannot durably create the FAT32 edit companion directory")
	}
	impl.overlay_path, path_error = filepath.join({impl.edit_directory, "overlay.bin"})
	if path_error ==
	   nil {impl.bitmap_path, path_error = filepath.join({impl.edit_directory, "presence.bin"})}
	if path_error ==
	   nil {impl.intent_path, path_error = filepath.join({impl.edit_directory, "apply.intent"})}
	if path_error ==
	   nil {impl.meta_path, path_error = filepath.join({impl.edit_directory, "edit.meta"})}
	if path_error != nil {
		close_impl(impl, false)
		return {}, error_make(.Open_Failed, "cannot construct FAT32 edit companion paths")
	}
	logical_bytes := i64(base.sector_count * SECTOR_BYTES)
	impl.bitmap_bytes = (base.sector_count + 7) / 8
	overlay_exists, overlay_safe, _ := companionio.probe_file(&impl.edit_boundary, "overlay.bin")
	bitmap_exists, bitmap_safe, _ := companionio.probe_file(&impl.edit_boundary, "presence.bin")
	if !overlay_safe || !bitmap_safe {
		close_impl(impl, false)
		return {}, error_make(.State_Corrupt, "FAT32 edit storage contains an unsafe child")
	}
	impl.overlay_file, _, _ = companionio.open_file(
		&impl.edit_boundary,
		"overlay.bin",
		{.Read, .Write, .Create, .Sync},
	)
	impl.bitmap_file, _, _ = companionio.open_file(
		&impl.edit_boundary,
		"presence.bin",
		{.Read, .Write, .Create, .Sync},
	)
	if impl.overlay_file == nil ||
	   impl.bitmap_file == nil ||
	   !platform_prepare_sparse(impl.overlay_file) {
		close_impl(impl, false)
		return {}, error_make(.Open_Failed, "cannot open a sparse FAT32 edit overlay")
	}
	meta_error := open_edit_meta(
		impl,
		requested_transaction_id,
		u64(time.now()._nsec) ~ u64(uintptr(impl)),
	)
	if meta_error.code != .None {
		close_impl(impl, false)
		return {}, meta_error
	}
	if !companionio.sync_directory(&impl.edit_boundary) {
		close_impl(impl, false)
		return {}, error_make(.Sync_Failed, "cannot durably create FAT32 edit state")
	}
	if !overlay_exists {
		if os.truncate(impl.overlay_file, logical_bytes) != nil {
			close_impl(impl, false)
			return {}, error_make(.Open_Failed, "cannot size the sparse FAT32 edit overlay")
		}
	} else {
		size, size_error := os.file_size(impl.overlay_file)
		if size_error != nil || size != logical_bytes {
			close_impl(impl, false)
			return {}, error_make(.State_Corrupt, "FAT32 edit overlay size disagrees with the image")
		}
	}
	if !bitmap_exists {
		if os.truncate(impl.bitmap_file, i64(impl.bitmap_bytes)) != nil {
			close_impl(impl, false)
			return {}, error_make(.Open_Failed, "cannot size the FAT32 edit presence bitmap")
		}
	} else {
		size, size_error := os.file_size(impl.bitmap_file)
		if size_error != nil || size != i64(impl.bitmap_bytes) {
			close_impl(impl, false)
			return {}, error_make(.State_Corrupt, "FAT32 edit bitmap size disagrees with the image")
		}
	}
	if !overlay_count_dirty(impl) {
		close_impl(impl, false)
		return {}, error_make(.State_Corrupt, "cannot scan the FAT32 edit presence bitmap")
	}
	impl.overlay_device = {
		ctx          = impl,
		sector_count = base.sector_count,
		read         = overlay_read,
		write        = overlay_write,
		flush        = overlay_flush,
	}
	volume, fat_error := fat32fs.open(impl.overlay_device)
	if fat_error.code != .None {
		close_impl(impl, false)
		return {}, error_from_fat32(fat_error)
	}
	impl.volume = volume
	return Edit_Session{impl = impl}, {}
}

close_retain :: proc(session: ^Edit_Session) -> Edit_Error {
	if session == nil || session.impl == nil {return {}}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit session has an active job")
	}
	if !overlay_flush(session.impl) {
		return error_make(.Sync_Failed, "cannot preserve pending FAT32 edits", false, .Uncertain)
	}
	close_impl(session.impl, false)
	session.impl = nil
	return {}
}

@(private = "package")
close_impl :: proc(impl: ^Edit_Impl, remove_edit_directory: bool) -> bool {
	if impl == nil {return true}
	impl.closed = true
	if impl.overlay_file != nil {_ = os.close(impl.overlay_file); impl.overlay_file = nil}
	if impl.bitmap_file != nil {_ = os.close(impl.bitmap_file); impl.bitmap_file = nil}
	removed := true
	if remove_edit_directory && impl.edit_directory != "" {
		edit_names := [?]string{"overlay.bin", "presence.bin", "apply.intent", "edit.meta"}
		for name in edit_names {
			if !companionio.remove_file(&impl.edit_boundary, name) {removed = false}
		}
		if removed && !companionio.retire_directory(&impl.state_boundary, &impl.edit_boundary) {
			removed = false
		}
	}
	companionio.close_directory(&impl.edit_boundary)
	companionio.close_directory(&impl.state_boundary)
	delete(impl.state_directory)
	delete(impl.edit_directory)
	delete(impl.overlay_path)
	delete(impl.bitmap_path)
	delete(impl.intent_path)
	delete(impl.meta_path)
	free(impl)
	return removed
}

list :: proc(
	session: ^Edit_Session,
	path: string,
	cursor: u64,
	limit: int,
	allocator := context.allocator,
) -> (
	fat32fs.Page,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	page, fat_error := fat32fs.list(&session.impl.volume, path, cursor, limit, allocator)
	return page, error_from_fat32(fat_error)
}

stat :: proc(session: ^Edit_Session, path: string) -> (fat32fs.Stat, Edit_Error) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	info, fat_error := fat32fs.stat(&session.impl.volume, path)
	return info, error_from_fat32(fat_error)
}

read_range :: proc(
	session: ^Edit_Session,
	path: string,
	offset, length: u64,
	allocator := context.allocator,
) -> (
	fat32fs.Read_Result,
	Edit_Error,
) {
	if session == nil ||
	   session.impl == nil ||
	   session.impl.closed ||
	   length > MAX_TRANSFER_BYTES {
		return {}, error_make(.Invalid_Argument, "FAT32 edit read is closed or exceeds 128 KiB")
	}
	result, fat_error := fat32fs.read_range(&session.impl.volume, path, offset, length, allocator)
	return result, error_from_fat32(fat_error)
}

mkdir :: proc(session: ^Edit_Session, path: string) -> Edit_Error {
	if session == nil || session.impl == nil || session.impl.closed {
		return error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit mutation is blocked by an active job")
	}
	fat_error := fat32fs.mkdir(&session.impl.volume, path)
	if fat_error.code != .None {return error_from_fat32(fat_error)}
	if !overlay_flush(
		session.impl,
	) {return error_make(.Sync_Failed, "cannot preserve the directory edit", false, .Uncertain)}
	return {}
}

rename :: proc(session: ^Edit_Session, source, destination: string) -> Edit_Error {
	if session == nil || session.impl == nil || session.impl.closed {
		return error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit mutation is blocked by an active job")
	}
	fat_error := fat32fs.rename(&session.impl.volume, source, destination)
	if fat_error.code != .None {return error_from_fat32(fat_error)}
	if !overlay_flush(
		session.impl,
	) {return error_make(.Sync_Failed, "cannot preserve the rename edit", false, .Uncertain)}
	return {}
}

remove_recursive :: proc(session: ^Edit_Session, path: string) -> Edit_Error {
	if session == nil || session.impl == nil || session.impl.closed {
		return error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit mutation is blocked by an active job")
	}
	fat_error := fat32fs.remove_recursive(&session.impl.volume, path)
	if fat_error.code != .None {return error_from_fat32(fat_error)}
	if !overlay_flush(
		session.impl,
	) {return error_make(.Sync_Failed, "cannot preserve the recursive-delete edit", false, .Uncertain)}
	return {}
}

stage_boot_loader_pair :: proc(
	session: ^Edit_Session,
	primary_lba, backup_lba: u64,
	primary, backup: []u8,
) -> Edit_Error {
	if session == nil ||
	   session.impl == nil ||
	   session.impl.closed ||
	   len(primary) != SECTOR_BYTES ||
	   len(backup) != SECTOR_BYTES ||
	   primary_lba == backup_lba ||
	   primary_lba >= session.impl.base.sector_count ||
	   backup_lba >= session.impl.base.sector_count {
		return error_make(.Invalid_Argument, "FAT32 boot-loader patch request is invalid")
	}
	if session.impl.active_job {
		return error_make(.Invalid_State, "FAT32 edit mutation is blocked by an active job")
	}
	device := session.impl.overlay_device
	if !device.write(device.ctx, backup_lba, backup) ||
	   !device.write(device.ctx, primary_lba, primary) {
		return error_make(.IO, "cannot stage both FAT32 boot-loader sectors", false, .Uncertain)
	}
	if !device.flush(device.ctx) {
		return error_make(
			.Sync_Failed,
			"cannot preserve the staged FAT32 boot-loader patch",
			false,
			.Uncertain,
		)
	}
	return {}
}

stage_fsinfo_pair :: proc(
	session: ^Edit_Session,
	primary_lba, backup_lba: u64,
	primary, backup: []u8,
) -> Edit_Error {
	return stage_boot_loader_pair(session, primary_lba, backup_lba, primary, backup)
}
