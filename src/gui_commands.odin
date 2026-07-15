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
		return false
	}
	append(&s.cmds, cmd)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
	return true
}

command_queue_destroy :: proc(s: ^Shared) {
	if s == nil {return}
	sync.lock(&s.mu)
	for cmd in s.cmds {delete(cmd.path)}
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
	vm_guard_kick(s.guard)
}

release_held_keys :: proc(s: ^Shared, keyboard: ^host.Host_Keyboard) {
	sync.lock(&s.mu)
	_ = host.host_input_release_held_keys(&s.input, keyboard)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_motion :: proc(s: ^Shared, dx, dy: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_motion(&s.input, dx, dy, buttons)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_buttons :: proc(s: ^Shared, buttons: u8, durable_release: bool = false) {
	sync.lock(&s.mu)
	_ = host.host_input_push_buttons(&s.input, buttons, durable_release)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}

push_mouse_wheel :: proc(s: ^Shared, wheel: i32, buttons: u8) {
	sync.lock(&s.mu)
	_ = host.host_input_push_wheel(&s.input, wheel, buttons)
	sync.unlock(&s.mu)
	vm_guard_kick(s.guard)
}
