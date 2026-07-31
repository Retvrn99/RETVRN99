// SPDX-License-Identifier: GPL-3.0-only
package main

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "disk"
import "machine"
import "opticaldrive"
import "profile"

Media_Kind :: enum u8 {
	Floppy,
	Cdrom,
}

Media_Path_Status :: enum u8 {
	Empty,
	Present,
	Missing,
	Unavailable,
}

Mounted_Media_State :: struct {
	mounted:                bool,
	actual_path:            string,
	requested_path:         string,
	diagnostic:             string,
	unavailable:            bool,
	last_operation_ok:      bool,
	persist_last_operation: bool,
	generation:             u64,
}

media_path_status :: proc(path: string) -> Media_Path_Status {
	if path == "" {return .Empty}
	if letter, physical := opticaldrive.path_letter(path); physical {
		drives := opticaldrive.enumerate()
		return drives[int(letter - 'A')] ? .Present : .Missing
	}
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error == nil {
		os.file_info_delete(info, context.temp_allocator)
		return .Present
	}
	if stat_error == os.General_Error.Not_Exist {return .Missing}
	return .Unavailable
}

cdrom_path_supported :: proc(path: string) -> bool {
	image: disk.Disc_Image
	defer disk.disc_image_eject(&image)
	return disk.disc_image_mount(&image, path)
}

media_state_publish_result :: proc(
	s: ^Shared,
	kind: Media_Kind,
	success, mounted: bool,
	actual_path, requested_path, diagnostic: string,
	persist_on_success: bool,
) {
	if s == nil {return}
	actual_copy := strings.clone(actual_path)
	requested_copy := strings.clone(requested_path)
	diagnostic_copy := strings.clone(diagnostic)
	sync.lock(&s.mu)
	state := kind == .Floppy ? &s.floppy_media : &s.cdrom_media
	old_actual := state.actual_path
	old_requested := state.requested_path
	old_diagnostic := state.diagnostic
	if success {
		state.mounted = mounted
		state.actual_path = actual_copy
		state.requested_path = requested_copy
		state.diagnostic = diagnostic_copy
		state.unavailable = !mounted && requested_path != ""
	} else {
		delete(actual_copy)
		state.requested_path = requested_copy
		state.diagnostic = diagnostic_copy
		state.unavailable = !state.mounted && requested_path != ""
	}
	state.last_operation_ok = success
	state.persist_last_operation = success && persist_on_success
	state.generation += 1
	sync.unlock(&s.mu)
	if success {delete(old_actual)}
	delete(old_requested)
	delete(old_diagnostic)
}

media_state_snapshot :: proc(
	s: ^Shared,
	kind: Media_Kind,
	allocator := context.allocator,
) -> Mounted_Media_State {
	if s == nil {return {}}
	sync.lock(&s.mu)
	state := kind == .Floppy ? &s.floppy_media : &s.cdrom_media
	result := state^
	result.actual_path = strings.clone(state.actual_path, allocator)
	result.requested_path = strings.clone(state.requested_path, allocator)
	result.diagnostic = strings.clone(state.diagnostic, allocator)
	sync.unlock(&s.mu)
	return result
}

media_state_destroy :: proc(state: ^Mounted_Media_State, allocator := context.allocator) {
	if state == nil {return}
	delete(state.actual_path, allocator)
	delete(state.requested_path, allocator)
	delete(state.diagnostic, allocator)
	state^ = {}
}

shared_media_destroy :: proc(s: ^Shared, allocator := context.allocator) {
	if s == nil {return}
	sync.lock(&s.mu)
	floppy := s.floppy_media
	cdrom := s.cdrom_media
	s.floppy_media = {}
	s.cdrom_media = {}
	sync.unlock(&s.mu)
	media_state_destroy(&floppy, allocator)
	media_state_destroy(&cdrom, allocator)
}

media_settings_set_path :: proc(
	settings: ^profile.Settings,
	kind: Media_Kind,
	path: string,
	allocator := context.allocator,
) {
	if settings == nil {return}
	target := kind == .Floppy ? &settings.floppy_path : &settings.cdrom_path
	delete(target^, allocator)
	target^ = strings.clone(path, allocator)
}

media_settings_consume :: proc(
	settings: ^profile.Settings,
	kind: Media_Kind,
	state: ^Mounted_Media_State,
	seen_generation: ^u64,
) -> bool {
	if settings == nil || state == nil || seen_generation == nil {return false}
	if state.generation == seen_generation^ {return false}
	seen_generation^ = state.generation
	if !state.last_operation_ok || !state.persist_last_operation {return false}
	media_settings_set_path(settings, kind, state.actual_path)
	return true
}

media_settings_reconcile_missing :: proc(
	settings: ^profile.Settings,
	kind: Media_Kind,
) -> Media_Path_Status {
	if settings == nil {return .Empty}
	path := kind == .Floppy ? settings.floppy_path : settings.cdrom_path
	status := media_path_status(path)
	if status == .Missing {media_settings_set_path(settings, kind, "")}
	return status
}

gui_media_queue_before_start :: proc(
	s: ^Shared,
	settings: ^profile.Settings,
	install_locked: bool,
) -> bool {
	if s == nil || settings == nil || install_locked {return false}
	settings_changed := false
	for kind in Media_Kind {
		path := kind == .Floppy ? settings.floppy_path : settings.cdrom_path
		status := media_path_status(path)
		state := media_state_snapshot(s, kind, context.temp_allocator)
		switch status {
		case .Missing:
			media_settings_set_path(settings, kind, "")
			settings_changed = true
			if state.mounted || state.actual_path != "" {
				command := kind == .Floppy ? Command_Kind.Eject_Floppy : .Eject_Cdrom
				push_cmd(s, Command{kind = command})
			}
		case .Present, .Unavailable:
			if !state.mounted || state.actual_path != path {
				command := kind == .Floppy ? Command_Kind.Mount_Floppy : .Mount_Cdrom
				push_cmd(s, Command{kind = command, path = strings.clone(path)})
			}
		case .Empty:
			if state.mounted || state.actual_path != "" {
				command := kind == .Floppy ? Command_Kind.Eject_Floppy : .Eject_Cdrom
				push_cmd(s, Command{kind = command})
			}
		}
	}
	return settings_changed
}

vm_restore_user_media :: proc(c: ^Vm_Ctx, m: ^machine.Machine, machine_live: bool) {
	if c == nil || c.shared == nil {return}
	_ = vm_lifetime_eject_removable(&c.lifetime, .Floppy)
	_ = vm_lifetime_eject_removable(&c.lifetime, .Optical)

	floppy_status := media_path_status(c.user_floppy_path)
	if floppy_status == .Missing {
		delete(c.user_floppy)
		c.user_floppy = nil
		delete(c.user_floppy_path)
		c.user_floppy_path = ""
		publish_floppy_state(
			c.shared,
			false,
			"",
			"",
			"The saved floppy image no longer exists",
			true,
		)
	} else if c.user_floppy_path != "" {
		if len(c.user_floppy) == 0 {
			if image, read_error := os.read_entire_file_from_path(
				c.user_floppy_path,
				context.allocator,
			); read_error == nil && len(image) == 1_474_560 {
				c.user_floppy = image
			} else {
				delete(image)
			}
		}
		if len(c.user_floppy) == 1_474_560 {
			mounted := vm_lifetime_mount_removable(
				&c.lifetime,
				.Floppy,
				c.user_floppy_path,
				c.user_floppy,
			).completed
			if mounted {
				publish_floppy_state(c.shared, true, c.user_floppy_path)
			} else {
				publish_floppy_state(
					c.shared,
					false,
					"",
					c.user_floppy_path,
					"The saved floppy image could not be restored",
				)
			}
		} else {
			publish_floppy_state(
				c.shared,
				false,
				"",
				c.user_floppy_path,
				"The saved floppy image is temporarily unavailable or invalid",
			)
		}
	} else {
		publish_floppy_state(c.shared, false)
	}

	cdrom_status := media_path_status(c.user_cdrom_path)
	if cdrom_status == .Missing {
		delete(c.user_cdrom_path)
		c.user_cdrom_path = ""
		publish_cdrom_state(c.shared, false, "", "", "The saved disc image no longer exists", true)
	} else if c.user_cdrom_path != "" {
		mounted := vm_lifetime_mount_removable(
			&c.lifetime,
			.Optical,
			c.user_cdrom_path,
		).completed
		if mounted {
			publish_cdrom_state(c.shared, true, c.user_cdrom_path)
		} else {
			publish_cdrom_state(
				c.shared,
				false,
				"",
				c.user_cdrom_path,
				"The saved disc image could not be restored",
			)
		}
	} else {
		publish_cdrom_state(c.shared, false)
	}
}

media_clone_bytes :: proc(bytes: []u8, allocator := context.allocator) -> []u8 {
	if len(bytes) == 0 {return nil}
	result := make([]u8, len(bytes), allocator)
	copy(result, bytes)
	return result
}
