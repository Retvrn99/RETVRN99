// SPDX-License-Identifier: GPL-3.0-only
package main

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sync"
import "host"
import sdl3 "vendor:sdl3"

Pending_Mount :: struct {
	mu:        sync.Mutex,
	allocator: runtime.Allocator,
	path:      string,
	has:       bool,
	dialogs:   int,
	detached:  bool,
}

PENDING_HARD_DRIVE_PATH_BYTES :: 32768
PENDING_HARD_DRIVE_FILTER_BYTES :: 256
PENDING_HARD_DRIVE_MAX_RESULTS :: 4096

Pending_Hard_Drive_Dialog :: struct {
	mu:               sync.Mutex,
	allocator:        runtime.Allocator,
	paths:            [dynamic]string,
	diagnostic:       string,
	purpose:          host.Hard_Drive_Dialog_Purpose,
	has:              bool,
	dialogs:          int,
	detached:         bool,
	default_location: [PENDING_HARD_DRIVE_PATH_BYTES]u8,
	filter_name:      [PENDING_HARD_DRIVE_FILTER_BYTES]u8,
	filter_pattern:   [PENDING_HARD_DRIVE_FILTER_BYTES]u8,
	filter:           sdl3.DialogFileFilter,
}

pending_hard_drive_dialog_filter_valid :: proc(pattern: string) -> bool {
	if pattern == "" || pattern == "*" {return true}
	has_extension_byte := false
	for byte in transmute([]u8)pattern {
		if byte == ';' {
			if !has_extension_byte {return false}
			has_extension_byte = false
			continue
		}
		allowed :=
			(byte >= 'a' && byte <= 'z') ||
			(byte >= 'A' && byte <= 'Z') ||
			(byte >= '0' && byte <= '9') ||
			byte == '-' ||
			byte == '_' ||
			byte == '.'
		if !allowed {return false}
		has_extension_byte = true
	}
	return has_extension_byte
}

pending_hard_drive_dialog_error_set :: proc(
	pending: ^Pending_Hard_Drive_Dialog,
	diagnostic: string,
) {
	delete(pending.diagnostic, pending.allocator)
	message := diagnostic
	if message == "" {message = "The native file dialog failed."}
	pending.diagnostic = strings.clone(message, pending.allocator)
	pending.has = true
}

pending_mount_create :: proc() -> ^Pending_Mount {
	allocator := context.allocator
	p := new(Pending_Mount, allocator)
	p.allocator = allocator
	return p
}

pending_mount_show :: proc(p: ^Pending_Mount, window: ^sdl3.Window) {
	if p == nil {return}
	sync.lock(&p.mu)
	if p.detached {
		sync.unlock(&p.mu)
		return
	}
	p.dialogs += 1
	sync.unlock(&p.mu)
	sdl3.ShowOpenFileDialog(mount_dialog_cb, p, window, nil, 0, nil, false)
}

mount_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	p := (^Pending_Mount)(userdata)
	if p == nil {return}
	sync.lock(&p.mu)
	if !p.detached && filelist != nil && filelist[0] != nil {
		delete(p.path, p.allocator)
		p.path = strings.clone(string(filelist[0]), p.allocator)
		p.has = true
	}
	if p.dialogs > 0 {p.dialogs -= 1}
	free_after := p.detached && p.dialogs == 0
	sync.unlock(&p.mu)
	if free_after {free(p, p.allocator)}
}

pending_take :: proc(p: ^Pending_Mount) -> (string, bool) {
	sync.lock(&p.mu)
	defer sync.unlock(&p.mu)
	if !p.has {return "", false}
	p.has = false
	path := p.path
	p.path = ""
	return path, true
}

pending_mount_release :: proc(p: ^Pending_Mount) {
	if p == nil {return}
	sync.lock(&p.mu)
	p.detached = true
	delete(p.path, p.allocator)
	p.path = ""
	p.has = false
	free_now := p.dialogs == 0
	sync.unlock(&p.mu)
	if free_now {free(p, p.allocator)}
}

pending_hard_drive_dialog_create :: proc() -> ^Pending_Hard_Drive_Dialog {
	allocator := context.allocator
	pending := new(Pending_Hard_Drive_Dialog, allocator)
	pending.allocator = allocator
	return pending
}

pending_hard_drive_dialog_buffer_set :: proc(buffer: []u8, value: string) -> bool {
	if len(buffer) == 0 || len(value) >= len(buffer) {return false}
	for &byte in buffer {byte = 0}
	copy(buffer, transmute([]u8)value)
	return true
}

pending_hard_drive_dialog_show :: proc(
	pending: ^Pending_Hard_Drive_Dialog,
	window: ^sdl3.Window,
	request: host.Hard_Drive_Dialog_Request,
) -> bool {
	if pending == nil || request.kind == .None {return false}
	sync.lock(&pending.mu)
	if pending.detached || pending.dialogs > 0 || pending.has {
		sync.unlock(&pending.mu)
		return false
	}
	if !pending_hard_drive_dialog_filter_valid(request.filter_pattern) {
		pending.purpose = request.purpose
		pending_hard_drive_dialog_error_set(pending, "The file dialog filter is invalid.")
		sync.unlock(&pending.mu)
		return true
	}
	if !pending_hard_drive_dialog_buffer_set(
		   pending.default_location[:],
		   request.suggested_path,
	   ) ||
	   !pending_hard_drive_dialog_buffer_set(pending.filter_name[:], request.filter_name) ||
	   !pending_hard_drive_dialog_buffer_set(pending.filter_pattern[:], request.filter_pattern) {
		pending.purpose = request.purpose
		pending_hard_drive_dialog_error_set(pending, "The file dialog request is too large.")
		sync.unlock(&pending.mu)
		return true
	}
	pending.purpose = request.purpose
	pending.has = false
	delete(pending.diagnostic, pending.allocator)
	pending.diagnostic = ""
	pending.dialogs = 1
	pending.filter = {
		name    = cstring(&pending.filter_name[0]),
		pattern = cstring(&pending.filter_pattern[0]),
	}
	default_location: cstring = nil
	if request.suggested_path != "" {
		default_location = cstring(&pending.default_location[0])
	}
	filters: [^]sdl3.DialogFileFilter = nil
	filter_count: c.int
	if request.filter_pattern != "" {
		filters = &pending.filter
		filter_count = 1
	}
	sync.unlock(&pending.mu)
	switch request.kind {
	case .Open_File, .Open_Files:
		sdl3.ShowOpenFileDialog(
			pending_hard_drive_dialog_cb,
			pending,
			window,
			filters,
			filter_count,
			default_location,
			request.kind == .Open_Files || request.allow_multiple,
		)
	case .Save_File:
		sdl3.ShowSaveFileDialog(
			pending_hard_drive_dialog_cb,
			pending,
			window,
			filters,
			filter_count,
			default_location,
		)
	case .Select_Folder:
		sdl3.ShowOpenFolderDialog(
			pending_hard_drive_dialog_cb,
			pending,
			window,
			default_location,
			false,
		)
	case .None:
	}
	return true
}

pending_hard_drive_dialog_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: c.int) {
	context = runtime.default_context()
	pending := (^Pending_Hard_Drive_Dialog)(userdata)
	if pending == nil {return}
	sync.lock(&pending.mu)
	if !pending.detached {
		for path in pending.paths {delete(path, pending.allocator)}
		delete(pending.paths)
		pending.paths = make([dynamic]string, pending.allocator)
		delete(pending.diagnostic, pending.allocator)
		pending.diagnostic = ""
		if filelist == nil {
			error_text := ""
			if error_value := sdl3.GetError(); error_value != nil {
				error_text = string(error_value)
			}
			pending_hard_drive_dialog_error_set(pending, error_text)
		} else {
			for index in 0 ..< PENDING_HARD_DRIVE_MAX_RESULTS {
				if filelist[index] == nil {break}
				append(&pending.paths, strings.clone(string(filelist[index]), pending.allocator))
			}
			pending.has = true
		}
	}
	if pending.dialogs > 0 {pending.dialogs -= 1}
	free_after := pending.detached && pending.dialogs == 0
	sync.unlock(&pending.mu)
	if free_after {free(pending, pending.allocator)}
}

pending_hard_drive_dialog_take :: proc(
	pending: ^Pending_Hard_Drive_Dialog,
) -> (
	host.Hard_Drive_Dialog_Result,
	bool,
) {
	if pending == nil {return {}, false}
	sync.lock(&pending.mu)
	defer sync.unlock(&pending.mu)
	if !pending.has {return {}, false}
	result := host.Hard_Drive_Dialog_Result {
		purpose    = pending.purpose,
		accepted   = len(pending.paths) > 0 && pending.diagnostic == "",
		failed     = pending.diagnostic != "",
		paths      = pending.paths[:],
		diagnostic = pending.diagnostic,
	}
	pending.paths = nil
	pending.diagnostic = ""
	pending.has = false
	pending.purpose = .None
	return result, true
}

pending_hard_drive_dialog_active :: proc(pending: ^Pending_Hard_Drive_Dialog) -> bool {
	if pending == nil {return false}
	sync.lock(&pending.mu)
	defer sync.unlock(&pending.mu)
	return pending.dialogs > 0 || pending.has
}

pending_hard_drive_dialog_result_destroy :: proc(
	result: ^host.Hard_Drive_Dialog_Result,
	allocator := context.allocator,
) {
	if result == nil {return}
	for path in result.paths {delete(path, allocator)}
	delete(result.paths, allocator)
	delete(result.diagnostic, allocator)
	result^ = {}
}

pending_hard_drive_dialog_release :: proc(pending: ^Pending_Hard_Drive_Dialog) {
	if pending == nil {return}
	sync.lock(&pending.mu)
	pending.detached = true
	for path in pending.paths {delete(path, pending.allocator)}
	delete(pending.paths)
	pending.paths = nil
	delete(pending.diagnostic, pending.allocator)
	pending.diagnostic = ""
	pending.has = false
	free_now := pending.dialogs == 0
	sync.unlock(&pending.mu)
	if free_now {free(pending, pending.allocator)}
}

set_running :: proc(s: ^Shared, v: bool) {
	sync.lock(&s.mu)
	s.running = v
	sync.unlock(&s.mu)
}

push_cmd :: proc(s: ^Shared, cmd: Command) -> bool {
	sync.lock(&s.mu)
	if !s.running {
		sync.unlock(&s.mu)
		delete(cmd.path)
		delete(cmd.boot_path)
		delete(cmd.locale_language)
		delete(cmd.locale_country)
		return false
	}
	append(&s.cmds, cmd)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
	return true
}

command_queue_destroy :: proc(s: ^Shared) {
	if s == nil {return}
	sync.lock(&s.mu)
	for cmd in s.cmds {
		delete(cmd.path)
		delete(cmd.boot_path)
		delete(cmd.locale_language)
		delete(cmd.locale_country)
	}
	delete(s.cmds)
	s.cmds = nil
	sync.unlock(&s.mu)
}

push_host_key :: proc(
	s: ^Shared,
	keyboard: ^host.Host_Keyboard,
	scancode: sdl3.Scancode,
	down: bool,
) {
	sync.lock(&s.mu)
	_ = host.host_input_push_key(&s.input, keyboard, scancode, down, false)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
}

release_held_keys :: proc(s: ^Shared, keyboard: ^host.Host_Keyboard) {
	sync.lock(&s.mu)
	_ = host.host_input_release_held_keys(&s.input, keyboard)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
}

push_mouse_motion :: proc(s: ^Shared, dx, dy: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_motion(&s.input, dx, dy, buttons)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
}

push_mouse_buttons :: proc(s: ^Shared, buttons: u8, durable_release: bool = false) {
	sync.lock(&s.mu)
	_ = host.host_input_push_buttons(&s.input, buttons, durable_release)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
}

push_mouse_wheel :: proc(s: ^Shared, wheel: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_wheel(&s.input, wheel, buttons)
	sync.unlock(&s.mu)
	vm_lifetime_kick(s.lifetime)
}
