// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import "core:os"

Crash_Phase :: enum u8 {
	Machine_State_Prepared,
	Machine_Marker_Dirty,
	Wal_Appended,
	Image_Applied,
	Image_Synced,
	Checkpoint_Saved,
	Wal_Truncated,
	State_Clean,
	Edit_Owner_Prepared,
	Edit_Marker_Dirty,
	Edit_Adoption_Evidence,
	Edit_Adoption_Owner,
	Edit_Adoption_Staged,
	Edit_Owner_Applying,
	Edit_Intent_Durable,
	Edit_Image_Applied,
	Edit_Image_Synced,
	Edit_Apply_Ready,
	Edit_Discarded,
	Edit_Clean_Pending,
	Edit_Evidence_Retired,
	Edit_Marker_Clean,
	Edit_Completed,
	Edit_Cleanup,
}

crash_process_enabled: bool
crash_process_phase: Crash_Phase

crash_phase_name :: proc(phase: Crash_Phase) -> string {
	switch phase {
	case .Machine_State_Prepared:
		return "machine-state-prepared"
	case .Machine_Marker_Dirty:
		return "machine-marker-dirty"
	case .Wal_Appended:
		return "wal-appended"
	case .Image_Applied:
		return "image-applied"
	case .Image_Synced:
		return "image-synced"
	case .Checkpoint_Saved:
		return "checkpoint-saved"
	case .Wal_Truncated:
		return "wal-truncated"
	case .State_Clean:
		return "state-clean"
	case .Edit_Owner_Prepared:
		return "edit-owner-prepared"
	case .Edit_Marker_Dirty:
		return "edit-marker-dirty"
	case .Edit_Adoption_Evidence:
		return "edit-adoption-evidence"
	case .Edit_Adoption_Owner:
		return "edit-adoption-owner"
	case .Edit_Adoption_Staged:
		return "edit-adoption-staged"
	case .Edit_Owner_Applying:
		return "edit-owner-applying"
	case .Edit_Intent_Durable:
		return "edit-intent-durable"
	case .Edit_Image_Applied:
		return "edit-image-applied"
	case .Edit_Image_Synced:
		return "edit-image-synced"
	case .Edit_Apply_Ready:
		return "edit-apply-ready"
	case .Edit_Discarded:
		return "edit-discarded"
	case .Edit_Clean_Pending:
		return "edit-clean-pending"
	case .Edit_Evidence_Retired:
		return "edit-evidence-retired"
	case .Edit_Marker_Clean:
		return "edit-marker-clean"
	case .Edit_Completed:
		return "edit-completed"
	case .Edit_Cleanup:
		return "edit-cleanup"
	}
	return ""
}

enable_process_crash_injection :: proc(name: string) -> bool {
	for phase in Crash_Phase {
		if name != crash_phase_name(phase) {continue}
		crash_process_phase = phase
		crash_process_enabled = true
		return true
	}
	return false
}

crash_point :: proc(phase: Crash_Phase) {
	if crash_process_enabled && phase == crash_process_phase {os.exit(99)}
}
