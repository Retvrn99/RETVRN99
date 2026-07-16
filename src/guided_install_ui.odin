// SPDX-License-Identifier: GPL-3.0-only
package main

import imgui "../vendor_local/imgui"
import "core:fmt"
import "core:os"
import "core:strings"
import "fat32session"
import "host"
import "win98imageprep"

Guided_Install_Phase :: enum {
	Closed,
	Awaiting_ISO,
	Awaiting_Boot_Floppy,
	Summary,
	Preparing,
	Error,
}

Guided_Install_Action_Kind :: enum {
	None,
	Request_ISO,
	Request_Boot_Floppy,
	Prepare,
	Cancel_Prepare,
	Close,
}

Guided_Install_Action :: struct {
	kind:      Guided_Install_Action_Kind,
	iso_path:  string,
	boot_path: string,
}

Guided_Install_Model :: struct {
	phase:                 Guided_Install_Phase,
	image_path:            string,
	iso_path:              string,
	boot_path:             string,
	inspection:            win98imageprep.Inspection,
	diagnostic:            string,
	completion_generation: u64,
}

guided_install_prepare_options :: proc(
	host_locale: win98imageprep.Host_Locale = {},
) -> win98imageprep.Prepare_Options {
	return {desktop_probe = true, hardware_diagnostics = false, host_locale = host_locale}
}

guided_install_destroy :: proc(model: ^Guided_Install_Model) {
	if model == nil {return}
	delete(model.image_path)
	delete(model.iso_path)
	delete(model.boot_path)
	delete(model.diagnostic)
	win98imageprep.inspection_destroy(&model.inspection)
	model^ = {}
}

guided_install_open :: proc(model: ^Guided_Install_Model, image_path: string) -> bool {
	if model == nil || image_path == "" {return false}
	guided_install_destroy(model)
	model.phase = .Awaiting_ISO
	model.image_path = strings.clone(image_path)
	return true
}

guided_install_iso_dialog :: proc() -> host.Hard_Drive_Dialog_Request {
	return {
		kind = .Open_File,
		purpose = .Install_ISO,
		title = "Select Windows 98 installation media",
		filter_name = "Windows 98 CD image",
		filter_pattern = "iso",
	}
}

guided_install_boot_dialog :: proc() -> host.Hard_Drive_Dialog_Request {
	return {
		kind = .Open_File,
		purpose = .Install_Boot_Floppy,
		title = "Select matching Windows 98 boot floppy",
		filter_name = "1.44 MB floppy image",
		filter_pattern = "img",
	}
}

guided_install_dialog_error :: proc(model: ^Guided_Install_Model, diagnostic: string) {
	if model == nil || (model.phase != .Awaiting_ISO && model.phase != .Awaiting_Boot_Floppy) {
		return
	}
	delete(model.diagnostic)
	model.diagnostic = strings.clone(diagnostic)
}

guided_install_inspect :: proc(
	model: ^Guided_Install_Model,
	iso_path, boot_path: string,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> Guided_Install_Action {
	if model == nil || model.image_path == "" || iso_path == "" {return {}}
	owned_iso := strings.clone(iso_path)
	owned_boot := strings.clone(boot_path)
	win98imageprep.inspection_destroy(&model.inspection)
	delete(model.iso_path)
	delete(model.boot_path)
	delete(model.diagnostic)
	model.iso_path = owned_iso
	model.boot_path = owned_boot
	model.diagnostic = ""
	session_id := fmt.tprintf(
		"install-inspect-%d-%d",
		os.get_pid(),
		install_image_transaction_id(),
	)
	inspection, inspect_error := win98imageprep.inspect(
		win98imageprep.Inspect_Request {
			image_path = model.image_path,
			iso_path = model.iso_path,
			boot_floppy_path = model.boot_path,
			edit_session_id = session_id,
		},
		adapter,
	)
	model.inspection = inspection
	if inspect_error.code == .Boot_Floppy_Required {
		model.phase = .Awaiting_Boot_Floppy
		return {kind = .Request_Boot_Floppy}
	}
	if inspect_error.code != .None {
		model.phase = .Error
		model.diagnostic = strings.clone(
			fmt.tprintf(
				"Installation media check failed (%v): %s",
				inspect_error.code,
				win98imageprep.error_text(&inspect_error),
			),
		)
		return {}
	}
	model.phase = .Summary
	return {}
}

guided_install_dialog_cancel :: proc(model: ^Guided_Install_Model) {
	guided_install_destroy(model)
}

guided_install_prepare_started :: proc(model: ^Guided_Install_Model, generation: u64) {
	if model == nil {return}
	model.phase = .Preparing
	model.completion_generation = generation
}

guided_install_status_update :: proc(
	model: ^Guided_Install_Model,
	status: Install_Prepare_Status,
) {
	if model == nil ||
	   model.phase != .Preparing ||
	   status.generation == model.completion_generation {
		return
	}
	if status.succeeded {
		guided_install_destroy(model)
		return
	}
	model.phase = .Error
	delete(model.diagnostic)
	model.diagnostic = strings.clone(status.message)
}

guided_install_boot_source_text :: proc(source: win98imageprep.Boot_Source) -> string {
	switch source {
	case .Embedded:
		return "Embedded 1.44 MB boot image"
	case .Provided:
		return "Selected 1.44 MB boot-floppy image"
	case .Existing_DOS:
		return "Existing DOS 7.1 system files"
	case .Required:
		return "Matching boot-floppy image required"
	}
	return "Unknown"
}

guided_install_text :: proc(value: string) {
	if value == "" {
		imgui.TextUnformatted("")
		return
	}
	data := raw_data(value)
	imgui.TextUnformatted(cstring(data), cstring(data[len(value):]))
}

guided_install_draw :: proc(
	model: ^Guided_Install_Model,
	status: Install_Prepare_Status,
) -> Guided_Install_Action {
	if model == nil || model.phase == .Closed {return {}}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	open := true
	if !imgui.Begin(
		"Install Windows 98",
		&open,
		{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
	) {
		imgui.End()
		return {}
	}
	action: Guided_Install_Action
	switch model.phase {
	case .Awaiting_ISO:
		guided_install_text("Choose a Windows 98 Second Edition ISO to continue.")
		guided_install_text(
			"The selected image will not be modified until the final confirmation.",
		)
		if model.diagnostic != "" {guided_install_text(model.diagnostic)}
		if imgui.Button("Choose ISO...") {action.kind = .Request_ISO}
		imgui.SameLine()
		if imgui.Button("Cancel") {action.kind = .Close}
	case .Awaiting_Boot_Floppy:
		guided_install_text("This retail CD does not contain a boot image.")
		guided_install_text("Choose a matching Windows 98 1.44 MB FAT12 boot-floppy image.")
		if model.diagnostic != "" {guided_install_text(model.diagnostic)}
		if imgui.Button("Choose Boot Floppy...") {action.kind = .Request_Boot_Floppy}
		imgui.SameLine()
		if imgui.Button("Cancel") {action.kind = .Close}
	case .Summary:
		guided_install_text("Ready to prepare Windows 98 Setup")
		imgui.Separator()
		guided_install_text(fmt.tprintf("Hard drive: %s", model.image_path))
		guided_install_text(fmt.tprintf("Installation media: %s", model.iso_path))
		guided_install_text(
			fmt.tprintf("Volume: %s", model.inspection.media_info.volume_identifier),
		)
		guided_install_text(
			fmt.tprintf(
				"Setup files: %d (%d bytes)",
				model.inspection.media_info.win98_file_count,
				model.inspection.media_info.win98_total_bytes,
			),
		)
		guided_install_text(
			fmt.tprintf(
				"Boot source: %s",
				guided_install_boot_source_text(model.inspection.boot_source),
			),
		)
		imgui.Separator()
		guided_install_text(
			"Setup files and the direct launcher will be committed in one disk transaction.",
		)
		if imgui.Button("Install") {
			action = {
				kind      = .Prepare,
				iso_path  = model.iso_path,
				boot_path = model.boot_path,
			}
		}
		imgui.SameLine()
		if imgui.Button("Cancel") {action.kind = .Close}
	case .Preparing:
		guided_install_text("Preparing the hard-drive image...")
		guided_install_text(status.message)
		guided_install_text("You may cancel between bounded preparation steps.")
		if imgui.Button("Cancel") {action.kind = .Cancel_Prepare}
	case .Error:
		guided_install_text(model.diagnostic)
		guided_install_text("The hard drive remains blocked if recovery evidence was retained.")
		if imgui.Button("Close") {action.kind = .Close}
	case .Closed:
	}
	if !open && model.phase != .Preparing {action.kind = .Close}
	imgui.End()
	return action
}
