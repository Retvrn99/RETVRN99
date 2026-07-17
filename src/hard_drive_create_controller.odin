// SPDX-License-Identifier: GPL-3.0-only
package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "fat32session"

Hard_Drive_Create_Worker_State :: enum u8 {
	Idle,
	Running,
	Complete,
}

Hard_Drive_Create_Worker_Result :: struct {
	ready:     bool,
	cancelled: bool,
	info:      fat32session.Image_Info,
	error:     fat32session.Session_Error,
}

Hard_Drive_Create_Worker :: struct {
	mu:                    sync.Mutex,
	allocator:             runtime.Allocator,
	thread:                ^thread.Thread,
	state:                 Hard_Drive_Create_Worker_State,
	path:                  string,
	capacity_gib:          u32,
	allow_full_allocation: bool,
	adapter:               fat32session.Adapter_Kind,
	cancel_requested:      bool,
	cancelled:             bool,
	info:                  fat32session.Image_Info,
	error:                 fat32session.Session_Error,
}

hard_drive_create_worker_proc :: proc(worker: ^Hard_Drive_Create_Worker) {
	if worker == nil {return}
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	info, create_error := fat32session.create_image(
		fat32session.Create_Image_Request {
			path                  = worker.path,
			capacity_gib          = worker.capacity_gib,
			allow_full_allocation = worker.allow_full_allocation,
		},
		worker.adapter,
		worker.allocator,
	)
	sync.lock(&worker.mu)
	cancel_requested := worker.cancel_requested
	sync.unlock(&worker.mu)
	cancelled := false
	if cancel_requested &&
	   (create_error.code == .None || create_error.outcome == .Completed) {
		fat32session.image_info_destroy(&info, worker.allocator)
		if os.remove(worker.path) == nil || !os.exists(worker.path) {
			cancelled = true
		} else {
			create_error = fat32session.error_make(
				.Image_IO,
				false,
				.Completed,
				0,
				0,
				"hard-drive creation completed, but cancellation could not remove the new image",
			)
		}
	} else if cancel_requested && create_error.code != .None {
		cancelled = true
	}
	sync.lock(&worker.mu)
	worker.info = info
	worker.error = create_error
	worker.cancelled = cancelled
	worker.state = .Complete
	sync.unlock(&worker.mu)
}

hard_drive_create_worker_begin :: proc(
	worker: ^Hard_Drive_Create_Worker,
	path: string,
	capacity_gib: u32,
	allow_full_allocation: bool,
	adapter := fat32session.DEFAULT_ADAPTER,
	allocator := context.allocator,
) -> bool {
	if worker == nil || path == "" || capacity_gib == 0 {return false}
	sync.lock(&worker.mu)
	if worker.state != .Idle || worker.thread != nil {
		sync.unlock(&worker.mu)
		return false
	}
	worker.allocator = allocator
	worker.path = strings.clone(path, allocator)
	worker.capacity_gib = capacity_gib
	worker.allow_full_allocation = allow_full_allocation
	worker.adapter = adapter
	worker.cancel_requested = false
	worker.cancelled = false
	worker.state = .Running
	sync.unlock(&worker.mu)
	worker.thread = thread.create_and_start_with_poly_data(worker, hard_drive_create_worker_proc)
	if worker.thread != nil {return true}
	sync.lock(&worker.mu)
	delete(worker.path, allocator)
	worker.path = ""
	worker.state = .Idle
	sync.unlock(&worker.mu)
	return false
}

hard_drive_create_worker_cancel :: proc(worker: ^Hard_Drive_Create_Worker) -> bool {
	if worker == nil {return false}
	sync.lock(&worker.mu)
	defer sync.unlock(&worker.mu)
	if worker.state == .Idle {return false}
	worker.cancel_requested = true
	return true
}

hard_drive_create_worker_poll :: proc(
	worker: ^Hard_Drive_Create_Worker,
) -> Hard_Drive_Create_Worker_Result {
	if worker == nil {return {}}
	sync.lock(&worker.mu)
	if worker.state != .Complete {
		sync.unlock(&worker.mu)
		return {}
	}
	result := Hard_Drive_Create_Worker_Result {
		ready     = true,
		cancelled = worker.cancelled,
		info      = worker.info,
		error     = worker.error,
	}
	late_cancel := worker.cancel_requested && !worker.cancelled
	worker.info = {}
	worker.error = {}
	worker.state = .Idle
	worker.cancelled = false
	worker.cancel_requested = false
	path := worker.path
	worker.path = ""
	worker_thread := worker.thread
	worker.thread = nil
	sync.unlock(&worker.mu)
	thread.destroy(worker_thread)
	if late_cancel {
		if result.error.code == .None || result.error.outcome == .Completed {
			fat32session.image_info_destroy(&result.info, worker.allocator)
			if os.remove(path) == nil || !os.exists(path) {
				result.cancelled = true
			} else {
				result.error = fat32session.error_make(
					.Image_IO,
					false,
					.Completed,
					0,
					0,
					"hard-drive creation completed, but cancellation could not remove the new image",
				)
			}
		} else {
			result.cancelled = true
		}
	}
	delete(path, worker.allocator)
	return result
}

hard_drive_create_worker_running :: proc(worker: ^Hard_Drive_Create_Worker) -> bool {
	if worker == nil {return false}
	sync.lock(&worker.mu)
	defer sync.unlock(&worker.mu)
	return worker.state == .Running
}

hard_drive_create_worker_destroy :: proc(worker: ^Hard_Drive_Create_Worker) {
	if worker == nil {return}
	_ = hard_drive_create_worker_cancel(worker)
	sync.lock(&worker.mu)
	worker_thread := worker.thread
	sync.unlock(&worker.mu)
	if worker_thread != nil {thread.destroy(worker_thread)}
	sync.lock(&worker.mu)
	worker.thread = nil
	fat32session.image_info_destroy(&worker.info, worker.allocator)
	delete(worker.path, worker.allocator)
	worker.path = ""
	worker.state = .Idle
	sync.unlock(&worker.mu)
}
