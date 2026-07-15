// SPDX-License-Identifier: GPL-3.0-only
package main

import "acceptance"
import "core:fmt"
import "machine"
import "profile"

Install_Session_Finish_Diagnostic :: enum {
	None,
	Invalid_State,
	Cmos_Save_Failed,
	Install_State_Save_Failed,
}

Install_Session_Finish_Result :: struct {
	cmos:                     profile.Cmos_Data,
	have_cmos:                bool,
	restored_boot_order:       bool,
	milestone:                profile.Install_Milestone,
	cmos_diagnostic:           profile.Cmos_Diagnostic,
	install_state_diagnostic:  profile.Install_State_Diagnostic,
}

install_session_finish_persist :: proc(
	paths: ^profile.Paths,
	state: ^profile.Install_State,
	current_cmos: profile.Cmos_Data,
	have_cmos: bool,
) -> (result: Install_Session_Finish_Result, diagnostic: Install_Session_Finish_Diagnostic) {
	result.have_cmos = have_cmos
	result.cmos = current_cmos
	if state != nil {result.milestone = state.milestone}
	if paths == nil || state == nil || !profile.install_state_active(state) {
		return result, .Invalid_State
	}

	result.restored_boot_order = have_cmos && state.saved_cmos_valid
	if result.restored_boot_order {
		result.cmos[0x38] = state.saved_cmos_38
		result.cmos[0x3D] = state.saved_cmos_3d
	}
	if have_cmos {
		result.cmos_diagnostic = profile.cmos_save(paths.cmos, result.cmos)
		if result.cmos_diagnostic != .None {return result, .Cmos_Save_Failed}
	}
	result.install_state_diagnostic = profile.install_state_save_inactive(paths.install_state)
	if result.install_state_diagnostic != .None {
		return result, .Install_State_Save_Failed
	}

	profile.install_state_destroy(state)
	return result, .None
}

install_session_finish :: proc(c: ^Vm_Ctx, m: ^machine.Machine) -> bool {
	if c == nil || m == nil || !profile.install_state_active(&c.install_state) {return false}

	live := vm_machine_live(c, m)
	current_cmos: profile.Cmos_Data
	have_cmos := false
	if live {
		current_cmos = machine.machine_cmos_export(m)
		have_cmos = true
	} else if c.has_cmos {
		current_cmos = c.cmos
		have_cmos = true
	}
	finish, diagnostic := install_session_finish_persist(
		&c.paths,
		&c.install_state,
		current_cmos,
		have_cmos,
	)
	if diagnostic != .None {
		switch diagnostic {
		case .Cmos_Save_Failed:
			vm_log(
				c.shared,
				fmt.tprintf(
					"Windows 98: cannot finish installation session; CMOS save failed (%v)",
					finish.cmos_diagnostic,
				),
			)
		case .Install_State_Save_Failed:
			vm_log(
				c.shared,
				fmt.tprintf(
					"Windows 98: cannot finish installation session; install state save failed (%v)",
					finish.install_state_diagnostic,
				),
			)
		case .Invalid_State, .None:
		}
		return false
	}

	if finish.have_cmos {
		copy(c.cmos[:], finish.cmos[:])
		c.has_cmos = true
	}
	if live {
		m.cmos.ram[0x38] = finish.cmos[0x38]
		m.cmos.ram[0x3D] = finish.cmos[0x3D]
		machine.machine_set_cpu_mode(m, c.cpu_mode)
	}
	publish_install_state(c.shared, false)
	if finish.restored_boot_order {
		vm_log(c.shared, "Windows 98: installation session finished; original boot order restored")
	} else if finish.have_cmos {
		vm_log(
			c.shared,
			"Windows 98: installation session finished; original boot order was unknown, current boot order retained",
		)
	} else {
		vm_log(
			c.shared,
			"Windows 98: installation session finished; no CMOS snapshot was available",
		)
	}
	return true
}

console_install_session_finish :: proc(
	paths: ^profile.Paths,
	state: ^profile.Install_State,
	m: ^machine.Machine,
	run_result: ^acceptance.Result,
) -> Install_Session_Finish_Diagnostic {
	if m == nil {return .Invalid_State}
	current_cmos := machine.machine_cmos_export(m)
	finish, diagnostic := install_session_finish_persist(paths, state, current_cmos, true)
	if run_result != nil && finish.milestone != .None {
		run_result.installation_milestone = console_install_milestone_name(finish.milestone)
	}
	if diagnostic != .None {return diagnostic}
	m.cmos.ram[0x38] = finish.cmos[0x38]
	m.cmos.ram[0x3D] = finish.cmos[0x3D]
	return .None
}

console_install_session_finish_failure :: proc(run_result: ^acceptance.Result) -> int {
	if run_result != nil {
		run_result.stop_reason = .Configuration_Error
		run_result.exit_code = 1
		run_result.last_progress_reason = "install_session_finish_failed"
	}
	return 1
}
