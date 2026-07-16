// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:fmt"
import "core:os"
import "fat32session"
import "profile"
import "win98imageprep"

Install_Image_Boot_Diagnostic :: enum u8 {
	None,
	Install_State_Invalid,
	Preparing,
	Selected_Image_Required,
	Binding_Required,
	Image_Path_Mismatch,
	Image_Identity_Mismatch,
	Edit_Transaction_Mismatch,
	Image_Unavailable,
	Preparation_Missing,
	Preparation_Mismatch,
}

Install_Image_Boot_Result :: struct {
	allowed:            bool,
	diagnostic:         Install_Image_Boot_Diagnostic,
	state_diagnostic:   profile.Install_State_Diagnostic,
	binding_diagnostic: profile.Install_Binding_Diagnostic,
	preparation_error:  win98imageprep.Error,
}

Install_Image_Binding_Verifier :: proc(
	request: win98imageprep.Verify_Binding_Request,
	adapter: fat32session.Adapter_Kind,
) -> (win98imageprep.Preparation_Binding, win98imageprep.Error)

install_state_boot_allowed :: proc(state: ^profile.Install_State) -> bool {
	return state != nil && state.phase != .Preparing &&
	       (!profile.install_state_active(state) || profile.install_state_bound(state))
}

install_state_storage_locked :: proc(
	state: ^profile.Install_State,
	diagnostic: profile.Install_State_Diagnostic,
) -> bool {
	return profile.install_state_active(state) ||
	       profile.install_state_recovery_required(diagnostic)
}

install_image_boot_gate :: proc(
	state: ^profile.Install_State,
	selected_image_path: string,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> Install_Image_Boot_Result {
	return install_image_boot_gate_with_verifier(
		state,
		selected_image_path,
		adapter,
		win98imageprep.verify_preparation_binding,
	)
}

install_image_boot_gate_loaded :: proc(
	state: ^profile.Install_State,
	selected_image_path: string,
	state_diagnostic: profile.Install_State_Diagnostic,
	adapter := fat32session.DEFAULT_ADAPTER,
) -> Install_Image_Boot_Result {
	if state_diagnostic != .None && state_diagnostic != .Missing {
		return {
			diagnostic       = .Install_State_Invalid,
			state_diagnostic = state_diagnostic,
		}
	}
	return install_image_boot_gate(state, selected_image_path, adapter)
}

install_image_boot_gate_with_verifier :: proc(
	state: ^profile.Install_State,
	selected_image_path: string,
	adapter: fat32session.Adapter_Kind,
	verify: Install_Image_Binding_Verifier,
) -> Install_Image_Boot_Result {
	if state == nil {return {diagnostic = .Binding_Required}}
	if !profile.install_state_active(state) {return {allowed = true}}
	if state.phase == .Preparing {return {diagnostic = .Preparing}}
	if selected_image_path == "" {
		return {diagnostic = .Selected_Image_Required}
	}
	if verify == nil {return {diagnostic = .Binding_Required}}
	binding_diagnostic := profile.install_state_verify_binding(
		state,
		selected_image_path,
		state.image_identity,
		state.edit_transaction_id,
	)
	if binding_diagnostic != .None {
		diagnostic := Install_Image_Boot_Diagnostic.Binding_Required
		#partial switch binding_diagnostic {
		case .Image_Path_Mismatch, .Invalid_Image_Path:
			diagnostic = .Image_Path_Mismatch
		case .Image_Identity_Mismatch, .Invalid_Image_Identity:
			diagnostic = .Image_Identity_Mismatch
		case .Stale_Edit_Transaction, .Invalid_Edit_Transaction:
			diagnostic = .Edit_Transaction_Mismatch
		}
		return {
			diagnostic         = diagnostic,
			binding_diagnostic = binding_diagnostic,
		}
	}
	session_id := fmt.tprintf(
		"install-gate-%d-%d",
		os.get_pid(),
		state.edit_transaction_id,
	)
	binding, preparation_error := verify(
		win98imageprep.Verify_Binding_Request {
			image_path                 = selected_image_path,
			edit_session_id            = session_id,
			expected_image_identity    = state.image_identity,
			preparation_transaction_id = state.edit_transaction_id,
			allow_consumed_content     = state.phase == .Setup_Running,
		},
		adapter,
	)
	if preparation_error.code != .None {
		diagnostic := Install_Image_Boot_Diagnostic.Preparation_Mismatch
		if preparation_error.code == .Image_Identity_Mismatch {
			diagnostic = .Image_Identity_Mismatch
		} else if preparation_error.code == .Transaction_Mismatch {
			diagnostic = .Edit_Transaction_Mismatch
		} else if preparation_error.code == .Not_Prepared {
			diagnostic = .Preparation_Missing
		} else if preparation_error.code == .Image_Rejected ||
		          preparation_error.code == .Edit_Failed {
			diagnostic = .Image_Unavailable
		}
		return {
			diagnostic        = diagnostic,
			preparation_error = preparation_error,
		}
	}
	binding_diagnostic = profile.install_state_verify_binding(
		state,
		selected_image_path,
		binding.image_identity,
		binding.edit_transaction_id,
	)
	if binding_diagnostic != .None {
		diagnostic := Install_Image_Boot_Diagnostic.Preparation_Mismatch
		if binding_diagnostic == .Image_Identity_Mismatch {
			diagnostic = .Image_Identity_Mismatch
		} else if binding_diagnostic == .Stale_Edit_Transaction {
			diagnostic = .Edit_Transaction_Mismatch
		}
		return {
			diagnostic         = diagnostic,
			binding_diagnostic = binding_diagnostic,
		}
	}
	return {allowed = true}
}

install_image_boot_diagnostic_text :: proc(result: ^Install_Image_Boot_Result) -> string {
	if result == nil {return "Windows 98 installation storage validation failed"}
	if result.preparation_error.code != .None {
		text := win98imageprep.error_text(&result.preparation_error)
		if text != "" {return text}
	}
	switch result.diagnostic {
	case .None:
		return ""
	case .Install_State_Invalid:
		return "the persisted Windows 98 installation state is invalid or unbound"
	case .Preparing:
		return "Windows 98 preparation must be retried or abandoned"
	case .Selected_Image_Required:
		return "the active Windows 98 installation has no selected hard drive"
	case .Binding_Required:
		return "the active Windows 98 installation has no valid image binding"
	case .Image_Path_Mismatch:
		return "the selected hard drive is not the image bound to this Windows 98 installation"
	case .Image_Identity_Mismatch:
		return "the selected hard drive identity does not match this Windows 98 installation"
	case .Edit_Transaction_Mismatch:
		return "the prepared hard-drive transaction is stale"
	case .Image_Unavailable:
		return "the image-bound Windows 98 installation storage is unavailable"
	case .Preparation_Missing:
		return "the selected hard drive no longer contains the prepared Windows 98 installation"
	case .Preparation_Mismatch:
		return "the selected hard drive preparation does not match this Windows 98 installation"
	}
	return "Windows 98 installation storage validation failed"
}
