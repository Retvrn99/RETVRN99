// SPDX-License-Identifier: GPL-3.0-only
package main

import "profile"

Install_Reset_Transaction :: struct {
	pending:                   bool,
	state_changed:             bool,
	previous_phase:            profile.Install_Phase,
	previous_milestone:        profile.Install_Milestone,
	previous_reset_count:      u32,
	previous_saved_cmos_valid: bool,
	previous_saved_cmos_38:    u8,
	previous_saved_cmos_3d:    u8,
}

install_reset_transaction_stage :: proc(
	state: ^profile.Install_State,
) -> (Install_Reset_Transaction, bool) {
	if state == nil {return {}, false}
	transaction := Install_Reset_Transaction {
		pending = true,
		state_changed = profile.install_state_active(state),
		previous_phase = state.phase,
		previous_milestone = state.milestone,
		previous_reset_count = state.reset_count,
		previous_saved_cmos_valid = state.saved_cmos_valid,
		previous_saved_cmos_38 = state.saved_cmos_38,
		previous_saved_cmos_3d = state.saved_cmos_3d,
	}
	if !transaction.state_changed {return transaction, true}
	if state.reset_count == 0xFFFF_FFFF {return {}, false}
	state.reset_count += 1
	if state.phase == .Setup_Running && state.milestone < .First_Reboot {
		if !profile.install_state_advance_milestone(state, .First_Reboot) {
			install_reset_transaction_restore(state, &transaction)
			return {}, false
		}
	}
	return transaction, true
}

install_reset_transaction_restore :: proc(
	state: ^profile.Install_State,
	transaction: ^Install_Reset_Transaction,
) {
	if state == nil || transaction == nil || !transaction.pending {return}
	if transaction.state_changed {
		state.phase = transaction.previous_phase
		state.milestone = transaction.previous_milestone
		state.reset_count = transaction.previous_reset_count
		state.saved_cmos_valid = transaction.previous_saved_cmos_valid
		state.saved_cmos_38 = transaction.previous_saved_cmos_38
		state.saved_cmos_3d = transaction.previous_saved_cmos_3d
	}
	transaction.pending = false
}

install_reset_transaction_rollback :: proc(
	path: string,
	state: ^profile.Install_State,
	transaction: ^Install_Reset_Transaction,
) -> profile.Install_State_Diagnostic {
	if state == nil || transaction == nil || !transaction.pending {
		return .Invalid_State
	}
	changed := transaction.state_changed
	install_reset_transaction_restore(state, transaction)
	if !changed {return .None}
	return profile.install_state_save(path, state)
}

install_reset_transaction_commit :: proc(transaction: ^Install_Reset_Transaction) -> bool {
	if transaction == nil || !transaction.pending {return false}
	transaction.pending = false
	return true
}
