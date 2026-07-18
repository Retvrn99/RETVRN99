// SPDX-License-Identifier: GPL-3.0-only
package main

import imgui "../vendor_local/imgui"
import "core:strings"
import "host"

QUICK_INSTALL_KEY_CAPACITY :: 30

Quick_Install_Profile :: enum {
	Normal,
	Minimal,
}

Quick_Install_Action_Kind :: enum {
	None,
	Request_ISO,
	Close,
}

Quick_Install_Action :: struct {
	kind: Quick_Install_Action_Kind,
}

Quick_Install_Model :: struct {
	visible:          bool,
	image_path:       string,
	iso_path:         string,
	builder_override: string,
	profile:          Quick_Install_Profile,
	product_key:      [QUICK_INSTALL_KEY_CAPACITY]u8,
	diagnostic:       string,
}

quick_install_destroy :: proc(model: ^Quick_Install_Model) {
	if model == nil {return}
	delete(model.image_path)
	delete(model.iso_path)
	delete(model.builder_override)
	delete(model.diagnostic)
	model^ = {}
}

quick_install_open :: proc(
	model: ^Quick_Install_Model,
	image_path, builder_override: string,
) -> bool {
	if model == nil || image_path == "" {return false}
	quick_install_destroy(model)
	model.visible = true
	model.image_path = strings.clone(image_path)
	model.builder_override = strings.clone(builder_override)
	return true
}

quick_install_iso_dialog :: proc() -> host.Hard_Drive_Dialog_Request {
	return {
		kind = .Open_File,
		purpose = .Quick_Install_ISO,
		title = "Select a Windows 98 SE installation CD",
		filter_name = "Windows 98 SE CD image",
		filter_pattern = "iso",
	}
}

quick_install_accept_iso :: proc(model: ^Quick_Install_Model, path: string) {
	if model == nil || !model.visible || path == "" {return}
	delete(model.iso_path)
	delete(model.diagnostic)
	model.iso_path = strings.clone(path)
	model.diagnostic = ""
}

quick_install_dialog_error :: proc(model: ^Quick_Install_Model, diagnostic: string) {
	if model == nil || !model.visible {return}
	delete(model.diagnostic)
	model.diagnostic = strings.clone(diagnostic)
}

quick_install_key_text :: proc(model: ^Quick_Install_Model) -> string {
	if model == nil {return ""}
	length := 0
	for length < len(model.product_key) && model.product_key[length] != 0 {
		length += 1
	}
	return string(model.product_key[:length])
}

quick_install_key_syntax_valid :: proc(value: string) -> bool {
	if len(value) != 29 {return false}
	for octet, index in value {
		if index == 5 || index == 11 || index == 17 || index == 23 {
			if octet != '-' {return false}
			continue
		}
		if !((octet >= '0' && octet <= '9') ||
			   (octet >= 'A' && octet <= 'Z') ||
			   (octet >= 'a' && octet <= 'z')) {
			return false
		}
	}
	return true
}

quick_install_draw :: proc(model: ^Quick_Install_Model) -> Quick_Install_Action {
	action: Quick_Install_Action
	if model == nil || !model.visible {return action}
	viewport := imgui.GetMainViewport()
	center := imgui.Vec2 {
		viewport.Pos.x + viewport.Size.x * 0.5,
		viewport.Pos.y + viewport.Size.y * 0.5,
	}
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	open := true
	if !host.win98_begin_window(
		"Quick Install Windows 98 SE (Experimental)",
		&open,
		{.AlwaysAutoResize, .NoCollapse, .NoSavedSettings},
	) {
		imgui.End()
		return action
	}

	guided_install_text("This experimental path needs around 2 GiB of temporary free space.")
	guided_install_text(
		"A media-specific requirement will be calculated before any download or disk change.",
	)
	imgui.Separator()
	guided_install_text("Windows 98 SE installation CD")
	if model.iso_path == "" {
		guided_install_text("No ISO selected.")
	} else {
		guided_install_text(model.iso_path)
	}
	if imgui.Button("Choose ISO...") {action.kind = .Request_ISO}

	imgui.Separator()
	guided_install_text("Installation profile")
	if imgui.RadioButton("Normal", model.profile == .Normal) {model.profile = .Normal}
	imgui.SameLine()
	if imgui.RadioButton("Minimal", model.profile == .Minimal) {model.profile = .Minimal}

	imgui.Separator()
	imgui.SetNextItemWidth(260)
	_ = imgui.InputText(
		"Product key",
		cstring(&model.product_key[0]),
		uint(len(model.product_key)),
		{.Password, .CharsNoBlank, .NoUndoRedo},
	)
	guided_install_text(
		"The key stays in process memory and is never passed in arguments or logs.",
	)
	key_valid := quick_install_key_syntax_valid(quick_install_key_text(model))
	if quick_install_key_text(model) != "" && !key_valid {
		guided_install_text("Expected five groups of five letters or digits.")
	}

	imgui.Separator()
	if model.builder_override == "" {
		guided_install_text(
			"Builder source: compatible signed release (not enabled during Phase 0)",
		)
	} else {
		guided_install_text("Builder source: explicit local developer override")
		guided_install_text(model.builder_override)
	}
	if model.diagnostic != "" {guided_install_text(model.diagnostic)}
	ready := model.iso_path != "" && key_valid
	imgui.BeginDisabled(!ready)
	if imgui.Button("Validate Experimental Install") {
		quick_install_dialog_error(
			model,
			"Phase 0 is fail-closed: the clean-room Setup/registry compiler gate has not passed yet.",
		)
	}
	imgui.EndDisabled()
	imgui.SameLine()
	if imgui.Button("Cancel") {action.kind = .Close}
	if !open {action.kind = .Close}
	imgui.End()
	return action
}
