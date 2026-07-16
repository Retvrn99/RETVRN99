// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32fs "../fat32fs"
import securehost "../securehost"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

MAX_TREE_DEPTH :: 64
MAX_HOST_PATH_BYTES :: 32 * 1024

Job_Kind :: enum u8 {
	None,
	Import_File,
	Import_Tree,
	Export_File,
	Remove_Tree,
}

Job_State :: enum u8 {
	Pending,
	Running,
	Complete,
	Cancelled,
	Failed,
}

Job_Progress :: struct {
	state:           Job_State,
	completed_bytes: u64,
	total_bytes:     u64,
	items_completed: u64,
}

@(private = "package")
Host_Object_Kind :: enum u8 {
	Regular,
	Directory,
}

@(private = "package")
Host_Object_Identity :: struct {
	valid:        bool,
	kind:         Host_Object_Kind,
	device:       u64,
	file_id:      [16]u8,
	size:         u64,
	write_token:  u64,
	change_token: u64,
}

@(private = "package")
host_identity_equal :: proc(left, right: Host_Object_Identity) -> bool {
	return(
		left.valid &&
		right.valid &&
		left.kind == right.kind &&
		left.device == right.device &&
		left.file_id == right.file_id &&
		left.size == right.size &&
		left.write_token == right.write_token &&
		left.change_token == right.change_token \
	)
}

@(private = "package")
Tree_Frame :: struct {
	host_path:  string,
	guest_path: string,
	file:       ^os.File,
	identity:   Host_Object_Identity,
	iterator:   os.Read_Directory_Iterator,
	active:     bool,
}

@(private = "package")
Delete_Frame :: struct {
	guest_path:   string,
	is_directory: bool,
	size:         u64,
}

Step_Job :: struct {
	kind:               Job_Kind,
	state:              Job_State,
	session:            ^Edit_Session,
	host_path:          string,
	guest_path:         string,
	active_host_path:   string,
	file:               ^os.File,
	export_file:        securehost.Created_File,
	source_identity:    Host_Object_Identity,
	writer:             fat32fs.File_Writer,
	reader:             fat32fs.File_Reader,
	total_bytes:        u64,
	completed_bytes:    u64,
	items_completed:    u64,
	buffer:             []u8,
	frames:             []Tree_Frame,
	frame_count:        int,
	delete_frames:      []Delete_Frame,
	delete_frame_count: int,
	tree_root_created:  bool,
	replace:            bool,
	staging_present:    bool,
	replace_target:     string,
	staging_guest_path: string,
	owns_job_slot:      bool,
	error:              Edit_Error,
}

@(private = "package")
step_job_acquire :: proc(session: ^Edit_Session) -> Edit_Error {
	if session == nil || session.impl == nil || session.impl.closed {
		return error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if session.impl.active_job {
		return error_make(.Invalid_State, "another FAT32 edit job is already active")
	}
	session.impl.active_job = true
	return {}
}

@(private = "package")
step_job_release_session :: proc(session: ^Edit_Session) {
	if session != nil && session.impl != nil {session.impl.active_job = false}
}

@(private = "package")
step_job_release :: proc(job: ^Step_Job) {
	if job == nil || !job.owns_job_slot {return}
	step_job_release_session(job.session)
	job.owns_job_slot = false
}

@(private = "package")
delete_frame_destroy :: proc(frame: ^Delete_Frame) {
	if frame == nil {return}
	delete(frame.guest_path)
	frame^ = {}
}

begin_remove_recursive :: proc(
	session: ^Edit_Session,
	guest_path: string,
) -> (
	Step_Job,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	if guest_path == "" {
		return {}, error_make(.Invalid_Path, "the FAT32 volume root cannot be removed")
	}
	acquire_error := step_job_acquire(session)
	if acquire_error.code != .None {return {}, acquire_error}
	claimed := true
	defer if claimed {step_job_release_session(session)}
	info, stat_error := fat32fs.stat(&session.impl.volume, guest_path)
	if stat_error.code != .None {return {}, error_from_fat32(stat_error)}
	if !info.exists {return {}, error_make(.Not_Found, "recursive-delete target does not exist")}
	job := Step_Job {
		kind               = .Remove_Tree,
		state              = .Pending,
		session            = session,
		delete_frames      = make([]Delete_Frame, MAX_TREE_DEPTH),
		delete_frame_count = 1,
		owns_job_slot      = true,
	}
	claimed = false
	job.guest_path = strings.clone(guest_path)
	job.delete_frames[0] = {
		guest_path   = strings.clone(guest_path),
		is_directory = info.is_directory,
		size         = info.size,
	}
	return job, {}
}

@(private = "package")
host_path_has_no_links :: proc(path: string, allow_missing_leaf: bool) -> bool {
	if path == "" || len(path) > MAX_HOST_PATH_BYTES {return false}
	absolute, absolute_error := os.get_absolute_path(path, context.temp_allocator)
	if absolute_error != nil {return false}
	current := absolute
	first := true
	for {
		exists, safe := platform_host_component_safe(current)
		if exists {
			if !safe {return false}
		} else if !(first && allow_missing_leaf) {
			return false
		}
		parent := filepath.dir(current)
		if parent == current {return true}
		current = parent
		first = false
	}
}

@(private = "package")
host_object_open :: proc(
	path: string,
	kind: Host_Object_Kind,
) -> (
	^os.File,
	Host_Object_Identity,
	bool,
) {
	if !host_path_has_no_links(path, false) {return nil, {}, false}
	expected, snapshot_ok := platform_host_snapshot(path, kind)
	if !snapshot_ok {return nil, {}, false}
	file, open_ok := platform_host_open(path, kind, expected)
	if !open_ok {return nil, {}, false}
	if !host_path_has_no_links(path, false) || !platform_host_verify_path(path, expected) {
		_ = os.close(file)
		return nil, {}, false
	}
	return file, expected, true
}

@(private = "package")
host_object_unchanged :: proc(
	file: ^os.File,
	path: string,
	expected: Host_Object_Identity,
) -> bool {
	return(
		file != nil &&
		path != "" &&
		platform_host_verify_open(file, expected) &&
		platform_host_verify_path(path, expected) \
	)
}

@(private = "package")
job_set_paths :: proc(job: ^Step_Job, host_path, guest_path: string) {
	job.host_path = strings.clone(host_path)
	job.guest_path = strings.clone(guest_path)
}

@(private = "package")
temporary_guest_path :: proc(
	destination: string,
	stage: bool,
	attempt: u32,
	allocator := context.allocator,
) -> string {
	name := stage ? fmt.tprintf("R99S%04x.TMP", attempt) : fmt.tprintf("R99B%04x.BAK", attempt)
	separator := strings.last_index_byte(destination, '/')
	if separator < 0 {return strings.clone(name, allocator)}
	return strings.concatenate({destination[:separator + 1], name}, allocator)
}

@(private = "package")
staged_file_begin :: proc(
	volume: ^fat32fs.Volume,
	destination: string,
	size: u64,
) -> (
	fat32fs.File_Writer,
	string,
	fat32fs.Error,
) {
	for attempt := u32(0); attempt < 0x1_0000; attempt += 1 {
		candidate := temporary_guest_path(destination, true, attempt)
		writer, writer_error := fat32fs.file_begin(volume, candidate, size)
		if writer_error.code == .None {return writer, candidate, {}}
		delete(candidate)
		if writer_error.code != .Name_Collision {return {}, "", writer_error}
	}
	return {}, "", fat32fs.Error_Make(.No_Space, "no FAT staging name is available")
}

@(private = "package")
staged_directory_begin :: proc(
	volume: ^fat32fs.Volume,
	destination: string,
) -> (
	string,
	fat32fs.Error,
) {
	for attempt := u32(0); attempt < 0x1_0000; attempt += 1 {
		candidate := temporary_guest_path(destination, true, attempt)
		mkdir_error := fat32fs.mkdir(volume, candidate)
		if mkdir_error.code == .None {return candidate, {}}
		delete(candidate)
		if mkdir_error.code != .Name_Collision {return "", mkdir_error}
	}
	return "", fat32fs.Error_Make(.No_Space, "no FAT directory staging name is available")
}

@(private = "package")
move_to_backup :: proc(
	volume: ^fat32fs.Volume,
	source, destination: string,
) -> (
	string,
	fat32fs.Error,
) {
	for attempt := u32(0); attempt < 0x1_0000; attempt += 1 {
		candidate := temporary_guest_path(destination, false, attempt)
		rename_error := fat32fs.rename(volume, source, candidate)
		if rename_error.code == .None {return candidate, {}}
		delete(candidate)
		if rename_error.code != .Name_Collision {return "", rename_error}
	}
	return "", fat32fs.Error_Make(.No_Space, "no FAT rollback name is available")
}

begin_import_file :: proc(
	session: ^Edit_Session,
	host_source, guest_destination: string,
	replace := false,
) -> (
	Step_Job,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	acquire_error := step_job_acquire(session)
	if acquire_error.code != .None {return {}, acquire_error}
	claimed := true
	defer if claimed {step_job_release_session(session)}
	file, source_identity, safe := host_object_open(host_source, .Regular)
	if !safe {
		return {}, error_make(.Host_Path_Unsafe, "import source is not a stable regular non-reparse file")
	}
	opened_size := source_identity.size
	destination_info, stat_error := fat32fs.stat(&session.impl.volume, guest_destination)
	if stat_error.code != .None {
		_ = os.close(file)
		return {}, error_from_fat32(stat_error)
	}
	replace_target := ""
	if destination_info.exists {
		if !replace {
			_ = os.close(file)
			return {}, error_make(.Name_Collision, "import destination already exists")
		}
		replace_target = strings.clone(guest_destination)
	} else if replace {
		collision_path, collided, collision_error := fat32fs.name_collision_path(
			&session.impl.volume,
			guest_destination,
		)
		defer delete(collision_path)
		if collision_error.code != .None {
			_ = os.close(file)
			return {}, error_from_fat32(collision_error)
		}
		if collided {replace_target = strings.clone(collision_path)}
	}
	writer: fat32fs.File_Writer
	staging_guest_path := ""
	writer_error: fat32fs.Error
	if replace {
		writer, staging_guest_path, writer_error = staged_file_begin(
			&session.impl.volume,
			guest_destination,
			opened_size,
		)
	} else {
		writer, writer_error = fat32fs.file_begin(
			&session.impl.volume,
			guest_destination,
			opened_size,
		)
	}
	if writer_error.code != .None {
		delete(replace_target)
		_ = os.close(file)
		return {}, error_from_fat32(writer_error)
	}
	job := Step_Job {
		kind               = .Import_File,
		state              = .Pending,
		session            = session,
		active_host_path   = strings.clone(host_source),
		file               = file,
		source_identity    = source_identity,
		writer             = writer,
		total_bytes        = opened_size,
		buffer             = make([]u8, MAX_TRANSFER_BYTES),
		replace            = replace,
		staging_present    = replace,
		replace_target     = replace_target,
		staging_guest_path = staging_guest_path,
		owns_job_slot      = true,
	}
	claimed = false
	job_set_paths(&job, host_source, guest_destination)
	return job, {}
}

begin_export_file :: proc(
	session: ^Edit_Session,
	guest_source, host_destination: string,
) -> (
	Step_Job,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Host_Path_Unsafe, "export destination exists or crosses a reparse path")
	}
	acquire_error := step_job_acquire(session)
	if acquire_error.code != .None {return {}, acquire_error}
	claimed := true
	defer if claimed {step_job_release_session(session)}
	reader, reader_error := fat32fs.file_reader_begin(&session.impl.volume, guest_source)
	if reader_error.code == .Not_Found || reader_error.code == .Is_Directory {
		return {}, error_make(.Invalid_Path, "export source is not a regular FAT file")
	}
	if reader_error.code != .None {return {}, error_from_fat32(reader_error)}
	created, create_ok := securehost.create_file_path(host_destination)
	if !create_ok {
		fat32fs.file_reader_close(&reader)
		return {}, error_make(.Host_Path_Unsafe, "export destination exists, is unsafe, or crosses a reparse path")
	}
	job := Step_Job {
		kind          = .Export_File,
		state         = .Pending,
		session       = session,
		export_file   = created,
		reader        = reader,
		total_bytes   = reader.total,
		buffer        = make([]u8, MAX_TRANSFER_BYTES),
		owns_job_slot = true,
	}
	claimed = false
	job_set_paths(&job, host_destination, guest_source)
	return job, {}
}

@(private = "package")
tree_frame_open :: proc(frame: ^Tree_Frame, host_path, guest_path: string) -> Edit_Error {
	if frame == nil {
		return error_make(.Host_Path_Unsafe, "tree import crosses a reparse path")
	}
	file, identity, open_ok := host_object_open(host_path, .Directory)
	if !open_ok {
		return error_make(
			.Host_Path_Unsafe,
			"import directory is unstable or crosses a reparse path",
		)
	}
	frame.host_path = strings.clone(host_path)
	frame.guest_path = strings.clone(guest_path)
	frame.file = file
	frame.identity = identity
	frame.iterator = os.read_directory_iterator_create(file)
	frame.active = true
	return {}
}

@(private = "package")
tree_frame_close :: proc(frame: ^Tree_Frame) {
	if frame == nil || !frame.active {return}
	os.read_directory_iterator_destroy(&frame.iterator)
	if frame.file != nil {_ = os.close(frame.file)}
	delete(frame.host_path)
	delete(frame.guest_path)
	frame^ = {}
}

begin_import_tree :: proc(
	session: ^Edit_Session,
	host_source, guest_destination: string,
	replace := false,
) -> (
	Step_Job,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return {}, error_make(.Host_Path_Unsafe, "tree import source is unavailable or crosses a reparse path")
	}
	acquire_error := step_job_acquire(session)
	if acquire_error.code != .None {return {}, acquire_error}
	claimed := true
	defer if claimed {step_job_release_session(session)}
	destination_info, fat_stat_error := fat32fs.stat(&session.impl.volume, guest_destination)
	if fat_stat_error.code != .None {return {}, error_from_fat32(fat_stat_error)}
	replace_target := ""
	if destination_info.exists {
		if !replace {
			return {}, error_make(.Name_Collision, "tree import destination already exists")
		}
		replace_target = strings.clone(guest_destination)
	} else if replace {
		collision_path, collided, collision_error := fat32fs.name_collision_path(
			&session.impl.volume,
			guest_destination,
		)
		defer delete(collision_path)
		if collision_error.code != .None {return {}, error_from_fat32(collision_error)}
		if collided {replace_target = strings.clone(collision_path)}
	}
	job := Step_Job {
		kind           = .Import_Tree,
		state          = .Pending,
		session        = session,
		buffer         = make([]u8, MAX_TRANSFER_BYTES),
		frames         = make([]Tree_Frame, MAX_TREE_DEPTH),
		replace        = replace,
		replace_target = replace_target,
		owns_job_slot  = true,
	}
	claimed = false
	job_set_paths(&job, host_source, guest_destination)
	root_guest_path := guest_destination
	if replace {
		staging_path, staging_error := staged_directory_begin(
			&session.impl.volume,
			guest_destination,
		)
		if staging_error.code != .None {
			job_destroy(&job)
			return {}, error_from_fat32(staging_error)
		}
		job.staging_guest_path = staging_path
		job.staging_present = true
		job.tree_root_created = true
		root_guest_path = job.staging_guest_path
	} else {
		mkdir_error := fat32fs.mkdir(&session.impl.volume, guest_destination)
		if mkdir_error.code != .None {
			job_destroy(&job)
			return {}, error_from_fat32(mkdir_error)
		}
		job.tree_root_created = true
	}
	frame_error := tree_frame_open(&job.frames[0], host_source, root_guest_path)
	if frame_error.code != .None {
		job_destroy(&job)
		return {}, frame_error
	}
	job.frame_count = 1
	return job, {}
}

@(private = "package")
job_close_file :: proc(job: ^Step_Job) {
	if job == nil {return}
	if job.file != nil {_ = os.close(job.file); job.file = nil}
	delete(job.active_host_path)
	job.active_host_path = ""
	job.source_identity = {}
}

@(private = "package")
job_fail :: proc(job: ^Step_Job, err: Edit_Error) -> Job_Progress {
	failure := err
	if job != nil {fat32fs.file_reader_close(&job.reader)}
	if job != nil && job.kind == .Export_File && job.export_file.file != nil {
		if !securehost.discard_created_file(&job.export_file) {
			failure = error_make(
				.IO,
				"export failed and its partial destination could not be retired safely",
				false,
				.Uncertain,
			)
		}
	}
	job.error = failure
	job.state = .Failed
	job_close_file(job)
	return job_progress(job)
}

@(private = "package")
job_finish_replace :: proc(job: ^Step_Job) -> Edit_Error {
	if job == nil || !job.replace || !job.staging_present {
		return error_make(.Invalid_State, "replacement staging state is unavailable")
	}
	volume := &job.session.impl.volume
	if job.replace_target == "" {
		rename_error := fat32fs.rename(volume, job.staging_guest_path, job.guest_path)
		if rename_error.code != .None {return error_from_fat32(rename_error)}
		job.staging_present = false
		return {}
	}
	backup_path, backup_error := move_to_backup(volume, job.replace_target, job.guest_path)
	if backup_error.code != .None {return error_from_fat32(backup_error)}
	rename_error := fat32fs.rename(volume, job.staging_guest_path, job.guest_path)
	if rename_error.code != .None {
		rollback_error := fat32fs.rename(volume, backup_path, job.replace_target)
		delete(backup_path)
		if rollback_error.code != .None {
			return error_make(
				.IO,
				"replacement swap failed and the original name could not be restored",
				false,
				.Uncertain,
			)
		}
		return error_make(
			error_from_fat32(rename_error).code,
			"replacement swap failed; the original file was restored",
			false,
			.Preserved,
		)
	}
	job.staging_present = false
	remove_error := fat32fs.remove_recursive(volume, backup_path)
	delete(backup_path)
	if remove_error.code != .None {
		return error_make(
			.IO,
			"replacement completed but its rollback copy could not be retired",
			false,
			.Uncertain,
		)
	}
	return {}
}

@(private = "package")
job_step_import_file :: proc(job: ^Step_Job, tree_child: bool) -> Job_Progress {
	if !host_object_unchanged(job.file, job.active_host_path, job.source_identity) {
		return job_fail(
			job,
			error_make(.Host_Path_Unsafe, "import source changed after its verified open"),
		)
	}
	remaining := job.total_bytes - job.completed_bytes
	wanted := int(min(u64(MAX_TRANSFER_BYTES), remaining))
	if wanted > 0 {
		count, read_error := os.read_at(job.file, job.buffer[:wanted], i64(job.completed_bytes))
		if read_error != nil && read_error != .EOF || count != wanted {
			return job_fail(job, error_make(.IO, "cannot read the import source"))
		}
		if !host_object_unchanged(job.file, job.active_host_path, job.source_identity) {
			return job_fail(
				job,
				error_make(.Host_Path_Unsafe, "import source changed while it was being read"),
			)
		}
		write_error := fat32fs.file_write(&job.writer, job.buffer[:count])
		if write_error.code != .None {return job_fail(job, error_from_fat32(write_error))}
		job.completed_bytes += u64(count)
		if !job.session.impl.overlay_device.flush(job.session.impl.overlay_device.ctx) {
			return job_fail(
				job,
				error_make(.Sync_Failed, "cannot preserve the import step", false, .Uncertain),
			)
		}
	}
	if job.completed_bytes == job.total_bytes {
		finish_error := fat32fs.file_finish(&job.writer)
		if finish_error.code != .None {return job_fail(job, error_from_fat32(finish_error))}
		if job.replace {
			replace_error := job_finish_replace(job)
			if replace_error.code != .None {return job_fail(job, replace_error)}
		}
		if !job.session.impl.overlay_device.flush(job.session.impl.overlay_device.ctx) {
			return job_fail(
				job,
				error_make(
					.Sync_Failed,
					"cannot preserve the completed import",
					false,
					.Uncertain,
				),
			)
		}
		job_close_file(job)
		job.items_completed += 1
		if tree_child {
			job.writer = {}
			job.total_bytes = 0
			job.completed_bytes = 0
		} else {
			job.state = .Complete
		}
	}
	return job_progress(job)
}

@(private = "package")
job_step_export_file :: proc(job: ^Step_Job) -> Job_Progress {
	remaining := job.total_bytes - job.completed_bytes
	wanted := int(min(u64(MAX_TRANSFER_BYTES), remaining))
	if wanted > 0 {
		count, read_error := fat32fs.file_reader_read(&job.reader, job.buffer[:wanted])
		if read_error.code != .None {return job_fail(job, error_from_fat32(read_error))}
		if count != wanted ||
		   !write_exact_at(job.export_file.file, job.buffer[:count], i64(job.completed_bytes)) {
			return job_fail(job, error_make(.IO, "cannot write the export destination"))
		}
		job.completed_bytes += u64(count)
	}
	if job.completed_bytes == job.total_bytes {
		if os.sync(job.export_file.file) !=
		   nil {return job_fail(job, error_make(.Sync_Failed, "cannot durably finish the exported file"))}
		if !securehost.close_created_file(&job.export_file) {
			fat32fs.file_reader_close(&job.reader)
			job.error = error_make(
				.Sync_Failed,
				"cannot close the durably written export destination",
				false,
				.Uncertain,
			)
			job.state = .Failed
			return job_progress(job)
		}
		fat32fs.file_reader_close(&job.reader)
		job.items_completed = 1
		job.state = .Complete
	}
	return job_progress(job)
}

@(private = "package")
job_step_import_tree :: proc(job: ^Step_Job) -> Job_Progress {
	if job.file != nil {return job_step_import_file(job, true)}
	if job.frame_count == 0 {
		if job.replace {
			replace_error := job_finish_replace(job)
			if replace_error.code != .None {return job_fail(job, replace_error)}
		}
		if !job.session.impl.overlay_device.flush(job.session.impl.overlay_device.ctx) {
			return job_fail(
				job,
				error_make(.Sync_Failed, "cannot preserve the imported tree", false, .Uncertain),
			)
		}
		job.state = .Complete
		return job_progress(job)
	}
	frame := &job.frames[job.frame_count - 1]
	if !host_object_unchanged(frame.file, frame.host_path, frame.identity) {
		return job_fail(
			job,
			error_make(.Host_Path_Unsafe, "tree import directory changed after its verified open"),
		)
	}
	info, _, ok := os.read_directory_iterator(&frame.iterator)
	if !ok {
		_, iterator_error := os.read_directory_iterator_error(&frame.iterator)
		if iterator_error !=
		   nil {return job_fail(job, error_make(.IO, "cannot enumerate an import directory"))}
		tree_frame_close(frame)
		job.frame_count -= 1
		return job_progress(job)
	}
	if !host_object_unchanged(frame.file, frame.host_path, frame.identity) {
		return job_fail(
			job,
			error_make(.Host_Path_Unsafe, "tree import directory changed during enumeration"),
		)
	}
	host_child, host_path_error := filepath.join({frame.host_path, info.name})
	if host_path_error !=
	   nil {return job_fail(job, error_make(.Invalid_Path, "cannot construct a host import path"))}
	defer delete(host_child)
	guest_child := strings.concatenate({frame.guest_path, "/", info.name})
	defer delete(guest_child)
	file, identity, file_ok := host_object_open(host_child, .Regular)
	if file_ok {
		writer, writer_error := fat32fs.file_begin(
			&job.session.impl.volume,
			guest_child,
			identity.size,
		)
		if writer_error.code != .None {
			_ = os.close(file)
			return job_fail(job, error_from_fat32(writer_error))
		}
		job.writer = writer
		job.file = file
		job.source_identity = identity
		job.active_host_path = strings.clone(host_child)
		job.total_bytes = identity.size
		job.completed_bytes = 0
		return job_progress(job)
	}
	if job.frame_count >= MAX_TREE_DEPTH {
		return job_fail(
			job,
			error_make(.Host_Path_Unsafe, "tree import exceeds the fixed directory-depth bound"),
		)
	}
	child_frame := &job.frames[job.frame_count]
	frame_error := tree_frame_open(child_frame, host_child, guest_child)
	if frame_error.code != .None {
		return job_fail(
			job,
			error_make(
				.Host_Path_Unsafe,
				"tree import encountered a reparse point or special file",
			),
		)
	}
	mkdir_error := fat32fs.mkdir(&job.session.impl.volume, guest_child)
	if mkdir_error.code != .None {
		tree_frame_close(child_frame)
		return job_fail(job, error_from_fat32(mkdir_error))
	}
	job.frame_count += 1
	job.items_completed += 1
	return job_progress(job)
}

@(private = "package")
job_step_remove_tree :: proc(job: ^Step_Job) -> Job_Progress {
	if job.delete_frame_count == 0 {
		job.total_bytes = job.completed_bytes
		job.state = .Complete
		return job_progress(job)
	}
	frame := &job.delete_frames[job.delete_frame_count - 1]
	if frame.is_directory {
		page, list_error := fat32fs.list(&job.session.impl.volume, frame.guest_path, 0, 1)
		if list_error.code != .None {return job_fail(job, error_from_fat32(list_error))}
		if len(page.entries) > 0 {
			if job.delete_frame_count >= MAX_TREE_DEPTH {
				fat32fs.page_destroy(&page)
				return job_fail(
					job,
					error_make(
						.Invalid_Path,
						"recursive delete exceeds the fixed directory-depth bound",
					),
				)
			}
			entry := &page.entries[0]
			child_path := strings.concatenate({frame.guest_path, "/", entry.name})
			job.delete_frames[job.delete_frame_count] = {
				guest_path   = child_path,
				is_directory = entry.is_directory,
				size         = entry.size,
			}
			job.delete_frame_count += 1
			fat32fs.page_destroy(&page)
			return job_progress(job)
		}
		fat32fs.page_destroy(&page)
	}
	remove_error := fat32fs.remove_recursive(&job.session.impl.volume, frame.guest_path)
	if remove_error.code != .None {return job_fail(job, error_from_fat32(remove_error))}
	job.completed_bytes += frame.size
	job.items_completed += 1
	delete_frame_destroy(frame)
	job.delete_frame_count -= 1
	if !job.session.impl.overlay_device.flush(job.session.impl.overlay_device.ctx) {
		return job_fail(
			job,
			error_make(
				.Sync_Failed,
				"cannot preserve the recursive-delete step",
				false,
				.Uncertain,
			),
		)
	}
	if job.delete_frame_count == 0 {
		job.total_bytes = job.completed_bytes
		job.state = .Complete
	}
	return job_progress(job)
}

job_step :: proc(job: ^Step_Job) -> Job_Progress {
	if job == nil {return {state = .Failed}}
	if job.state == .Complete ||
	   job.state == .Cancelled ||
	   job.state == .Failed {return job_progress(job)}
	if job.session == nil || job.session.impl == nil || job.session.impl.closed {
		return job_fail(job, error_make(.Invalid_State, "FAT32 edit session closed during a job"))
	}
	job.state = .Running
	#partial switch job.kind {
	case .Import_File:
		return job_step_import_file(job, false)
	case .Import_Tree:
		return job_step_import_tree(job)
	case .Export_File:
		return job_step_export_file(job)
	case .Remove_Tree:
		return job_step_remove_tree(job)
	case:
		return job_fail(job, error_make(.Invalid_State, "FAT32 step job has no operation"))
	}
}

job_cancel :: proc(job: ^Step_Job) -> Edit_Error {
	if job == nil || job.state == .Cancelled {return {}}
	if job.state ==
	   .Complete {return error_make(.Invalid_State, "completed FAT32 job cannot be cancelled")}
	cancel_error: Edit_Error
	fat32fs.file_reader_close(&job.reader)
	if job.writer.active {
		fat_error := fat32fs.file_cancel(&job.writer)
		if fat_error.code != .None {
			cancel_error = error_make(
				.IO,
				"cannot retire the partial FAT import",
				false,
				.Uncertain,
			)
		} else if job.replace && job.kind == .Import_File {
			job.staging_present = false
		}
	}
	if job.kind == .Export_File && job.export_file.file != nil {
		if !securehost.discard_created_file(&job.export_file) && cancel_error.code == .None {
			cancel_error = error_make(
				.IO,
				"cannot retire the partial host export safely",
				false,
				.Uncertain,
			)
		}
	} else {
		job_close_file(job)
	}
	for index in 0 ..< job.frame_count {tree_frame_close(&job.frames[index])}
	job.frame_count = 0
	if job.kind == .Import_Tree &&
	   job.tree_root_created &&
	   job.session != nil &&
	   job.session.impl != nil {
		root_path := job.guest_path
		if job.replace && job.staging_present {root_path = job.staging_guest_path}
		fat_error := fat32fs.remove_recursive(&job.session.impl.volume, root_path)
		if fat_error.code == .None && job.replace {job.staging_present = false}
		if fat_error.code != .None && cancel_error.code == .None {
			cancel_error = error_make(
				.IO,
				"cannot retire the partial FAT directory import",
				false,
				.Uncertain,
			)
		}
	}
	for index in 0 ..< job.delete_frame_count {
		delete_frame_destroy(&job.delete_frames[index])
	}
	job.delete_frame_count = 0
	if job.replace && job.staging_present && job.session != nil && job.session.impl != nil {
		fat_error := fat32fs.remove_recursive(&job.session.impl.volume, job.staging_guest_path)
		if fat_error.code == .None {
			job.staging_present = false
		} else if cancel_error.code == .None {
			cancel_error = error_make(
				.IO,
				"cannot retire the replacement staging file",
				false,
				.Uncertain,
			)
		}
	}
	if job.session != nil && job.session.impl != nil {_ = overlay_flush(job.session.impl)}
	job.state = .Cancelled
	step_job_release(job)
	if cancel_error.code != .None {return cancel_error}
	return Edit_Error{code = .Cancelled, outcome = .Preserved}
}

job_progress :: proc(job: ^Step_Job) -> Job_Progress {
	if job == nil {return {state = .Failed}}
	if job.state == .Complete {step_job_release(job)}
	return {
		state = job.state,
		completed_bytes = job.completed_bytes,
		total_bytes = job.total_bytes,
		items_completed = job.items_completed,
	}
}

job_error :: proc(job: ^Step_Job) -> Edit_Error {
	if job == nil {return error_make(.Invalid_Argument, "FAT32 job is unavailable")}
	return job.error
}

job_destroy :: proc(job: ^Step_Job) {
	if job == nil {return}
	if job.state == .Pending || job.state == .Running || job.state == .Failed {_ = job_cancel(job)}
	job_close_file(job)
	fat32fs.file_reader_close(&job.reader)
	step_job_release(job)
	for index in 0 ..< job.frame_count {tree_frame_close(&job.frames[index])}
	delete(job.host_path)
	delete(job.guest_path)
	delete(job.replace_target)
	delete(job.staging_guest_path)
	delete(job.buffer)
	delete(job.frames)
	for index in 0 ..< job.delete_frame_count {
		delete_frame_destroy(&job.delete_frames[index])
	}
	delete(job.delete_frames)
	job^ = {}
}
