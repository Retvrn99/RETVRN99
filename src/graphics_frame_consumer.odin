// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:time"
import "host"
import presentation "presentation"
import "vga"

Graphics_Frame_Consumer_Result :: struct {
	graphics_epoch:         Graphics_Frame_Epoch,
	graphics_epoch_pending: bool,
	postmortem_state:       Graphics_Postmortem_State,
	postmortem_state_valid: bool,
}

Graphics_Legacy_Staged_Commit :: struct {
	target:    ^host.Host,
	admission: host.Host_Presentation_Admission,
	staged:    host.Host_Presentation_Staged_Texture,
}

Graphics_Gsw_Staged_Commit :: struct {
	target:    ^host.Host,
	admission: host.Host_Presentation_Admission,
	staged:    host.Host_Presentation_Staged_Texture,
}

Graphics_Gsw_Invalidation_Commit :: struct {
	target:       ^host.Host,
	invalidation: presentation.Gsw_Invalidation,
	action:       presentation.Selector_Action,
}

graphics_legacy_staged_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Legacy_Staged_Commit)(ctx)
	if commit == nil {return false}
	return host.host_presentation_commit_legacy_staged(
		commit.target,
		&commit.admission,
		commit.staged,
	)
}

graphics_gsw_staged_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Gsw_Staged_Commit)(ctx)
	if commit == nil {return false}
	return host.host_presentation_commit_gsw_snapshot_staged(
		commit.target,
		&commit.admission,
		commit.staged,
	)
}

graphics_gsw_invalidation_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Gsw_Invalidation_Commit)(ctx)
	if commit == nil {return false}
	commit.action = host.host_presentation_apply_invalidation(commit.target, commit.invalidation)
	return true
}

graphics_frame_consume :: proc(
	shared: ^Shared,
	target: ^host.Host,
	trace_enabled: bool,
	last_vm_checkpoint: ^time.Tick,
) -> Graphics_Frame_Consumer_Result {
	graphics_epoch: Graphics_Frame_Epoch
	graphics_epoch_pending := false
	postmortem_state: Graphics_Postmortem_State
	postmortem_state_valid := false
	if frame_slot := frame_mailbox_acquire(&shared.frames); frame_slot != nil {
		gsw_descriptor := &frame_slot.scanout.gsw_presentation
		host.host_presentation_record_descriptor_copy(target, frame_slot.scanout.bytes_copied)
		gsw_transition := gsw_descriptor.present_valid || gsw_descriptor.invalidation_valid
		legacy_refreshed := false
		if trace_enabled {
			postmortem_state = graphics_postmortem_measured_state(
				frame_slot.producer_sample.session_generation,
				frame_slot.producer_sample.machine.gsw3d.device_generation,
				host.host_gsw3d_observability_snapshot(target).device_generation,
				frame_slot.epoch.sequence,
				.Render,
			)
			postmortem_state_valid = true
		}
		if trace_enabled && frame_slot.producer_sample.valid {
			now := time.tick_now()
			if last_vm_checkpoint^ == (time.Tick{}) ||
			   time.tick_diff(last_vm_checkpoint^, now) >= time.Second {
				vm_text := graphics_producer_sample_text(frame_slot.producer_sample)
				_ = graphics_postmortem_publish_vm(
					&shared.graphics_postmortem,
					vm_text,
					frame_slot.epoch.sequence,
					.Measured,
				)
				delete(vm_text)
				last_vm_checkpoint^ = now
			}
		}
		if postmortem_state_valid {
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state)
		}
		paired_invalidation :=
			gsw_descriptor.invalidation_valid &&
			host.host_presentation_invalidation_matches_active(target, gsw_descriptor.invalidation)
		legacy_admission := host.host_presentation_admit_legacy(
			target,
			frame_slot.scanout.legacy_update,
			paired_invalidation,
		)
		current_before_render := frame_mailbox_graphics_epoch_current(
			&shared.frames,
			&frame_slot.epoch,
		)
		if !current_before_render || (!legacy_admission.valid && !gsw_transition) {
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				&shared.frames,
				&frame_slot.epoch,
				current_before_render ? .Render_Failed : .Reset,
				time.tick_now(),
			)
			if postmortem_state_valid {
				postmortem_state.host_stage = .Failed
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
		} else if legacy_admission.valid {
			graphics_frame_epoch_render_begin(&frame_slot.epoch, .Legacy_Scanout, time.tick_now())
			frame := vga.scanout_descriptor_render(&frame_slot.scanout)
			graphics_frame_epoch_render_complete(&frame_slot.epoch, frame, time.tick_now())
			host.host_presentation_record_conversion(target, frame)
			if frame == nil && !gsw_transition {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&frame_slot.epoch,
					.Render_Failed,
					time.tick_now(),
				)
			} else if frame != nil {
				if postmortem_state_valid {
					postmortem_state.host_stage = .Upload
					_ = graphics_postmortem_publish_state(
						&shared.graphics_postmortem,
						postmortem_state,
					)
				}
				graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
				staged := host.host_presentation_stage_legacy(target, &legacy_admission, frame)
				commit := Graphics_Legacy_Staged_Commit {
					target    = target,
					admission = legacy_admission,
					staged    = staged,
				}
				commit_result := Frame_Mailbox_Current_Commit_Result.Invalid
				if staged.valid {
					commit_result = frame_mailbox_graphics_epoch_commit_current(
						&shared.frames,
						&frame_slot.epoch,
						&commit,
						graphics_legacy_staged_commit,
					)
				}
				if commit_result == .Stale {
					host.host_presentation_note_stale_finalization(target)
				}
				committed := commit_result == .Committed
				still_current := frame_mailbox_graphics_epoch_current(
					&shared.frames,
					&frame_slot.epoch,
				)
				graphics_frame_epoch_upload_complete(
					&frame_slot.epoch,
					staged.valid,
					staged.texture_recreated,
					time.tick_now(),
				)
				if committed {
					disposition := graphics_legacy_upload_disposition(
						legacy_admission.result.action,
						gsw_transition,
					)
					if disposition == .Visible {
						graphics_epoch = frame_slot.epoch
						graphics_epoch_pending = true
					} else if disposition == .Refresh_Terminal ||
					   disposition == .Refresh_Deferred {
						legacy_refreshed = true
					}
				} else if !gsw_transition || !still_current {
					_ = frame_mailbox_graphics_epoch_complete_and_record(
						&shared.frames,
						&frame_slot.epoch,
						still_current ? .Upload_Failed : .Reset,
						time.tick_now(),
					)
					if postmortem_state_valid {
						postmortem_state.host_stage = .Failed
						_ = graphics_postmortem_publish_state(
							&shared.graphics_postmortem,
							postmortem_state,
						)
					}
				}
			}
		}
		if current_before_render &&
		   gsw_descriptor.present_valid &&
		   frame_slot.epoch.result == .Incomplete {
			gsw_admission := host.host_presentation_admit_gsw(
				target,
				gsw_descriptor.present,
				u64(len(gsw_descriptor.source)),
			)
			if gsw_admission.valid {
				graphics_frame_epoch_render_begin(&frame_slot.epoch, .Gsw2d, time.tick_now())
				gsw_frame := vga.scanout_descriptor_render_gsw(&frame_slot.scanout)
				graphics_frame_epoch_render_complete(&frame_slot.epoch, gsw_frame, time.tick_now())
				host.host_presentation_record_conversion(target, gsw_frame)
				if gsw_frame == nil {
					_ = frame_mailbox_graphics_epoch_complete_and_record(
						&shared.frames,
						&frame_slot.epoch,
						.Render_Failed,
						time.tick_now(),
					)
					graphics_epoch_pending = false
					if postmortem_state_valid {
						postmortem_state.host_stage = .Failed
						_ = graphics_postmortem_publish_state(
							&shared.graphics_postmortem,
							postmortem_state,
						)
					}
				} else {
					if postmortem_state_valid {
						postmortem_state.host_stage = .Upload
						_ = graphics_postmortem_publish_state(
							&shared.graphics_postmortem,
							postmortem_state,
						)
					}
					graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
					staged := host.host_presentation_stage_gsw_snapshot(
						target,
						&gsw_admission,
						gsw_frame,
					)
					commit := Graphics_Gsw_Staged_Commit {
						target    = target,
						admission = gsw_admission,
						staged    = staged,
					}
					commit_result := Frame_Mailbox_Current_Commit_Result.Invalid
					if staged.valid {
						commit_result = frame_mailbox_graphics_epoch_commit_current(
							&shared.frames,
							&frame_slot.epoch,
							&commit,
							graphics_gsw_staged_commit,
						)
					}
					if commit_result == .Stale {
						host.host_presentation_note_stale_finalization(target)
					}
					committed := commit_result == .Committed
					still_current := frame_mailbox_graphics_epoch_current(
						&shared.frames,
						&frame_slot.epoch,
					)
					graphics_frame_epoch_upload_complete(
						&frame_slot.epoch,
						staged.valid,
						staged.texture_recreated,
						time.tick_now(),
					)
					if committed {
						legacy_refreshed = false
						graphics_epoch = frame_slot.epoch
						graphics_epoch_pending = true
					} else {
						_ = frame_mailbox_graphics_epoch_complete_and_record(
							&shared.frames,
							&frame_slot.epoch,
							still_current ? .Upload_Failed : .Reset,
							time.tick_now(),
						)
						graphics_epoch_pending = false
						if postmortem_state_valid {
							postmortem_state.host_stage = .Failed
							_ = graphics_postmortem_publish_state(
								&shared.graphics_postmortem,
								postmortem_state,
							)
						}
					}
				}
			} else if !graphics_epoch_pending {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&frame_slot.epoch,
					.Superseded,
					time.tick_now(),
				)
			}
		}
		if current_before_render &&
		   gsw_descriptor.invalidation_valid &&
		   frame_slot.epoch.result == .Incomplete {
			commit := Graphics_Gsw_Invalidation_Commit {
				target       = target,
				invalidation = gsw_descriptor.invalidation,
			}
			commit_result := frame_mailbox_graphics_epoch_commit_current(
				&shared.frames,
				&frame_slot.epoch,
				&commit,
				graphics_gsw_invalidation_commit,
			)
			action := commit.action
			if commit_result == .Stale {
				host.host_presentation_note_stale_finalization(target)
			}
			if action == .Restore_Legacy {
				legacy_refreshed = false
				frame_slot.epoch.source = .Legacy_Scanout
				graphics_epoch = frame_slot.epoch
				graphics_epoch_pending = true
			} else if action == .Clear {
				legacy_refreshed = false
				frame_slot.epoch.source = .Gsw2d
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&frame_slot.epoch,
					.Gpu_Work,
					time.tick_now(),
				)
				graphics_epoch_pending = false
			} else if commit_result == .Stale {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&frame_slot.epoch,
					.Reset,
					time.tick_now(),
				)
				graphics_epoch_pending = false
			} else if !graphics_epoch_pending {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					&shared.frames,
					&frame_slot.epoch,
					.Superseded,
					time.tick_now(),
				)
			}
		}
		if legacy_refreshed && frame_slot.epoch.result == .Incomplete {
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				&shared.frames,
				&frame_slot.epoch,
				.Superseded,
				time.tick_now(),
			)
		}
		frame_mailbox_release(&shared.frames, frame_slot)
	}
	return {
		graphics_epoch = graphics_epoch,
		graphics_epoch_pending = graphics_epoch_pending,
		postmortem_state = postmortem_state,
		postmortem_state_valid = postmortem_state_valid,
	}
}
