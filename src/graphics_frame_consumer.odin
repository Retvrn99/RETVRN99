// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:time"
import "host"
import presentation "presentation"
import "vga"
import "videopresentation"

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

Graphics_Gsw_Frame_Consume_Result :: struct {
	attempted:      bool,
	committed:      bool,
	failed:         bool,
	retry:          bool,
	graphics_epoch: Graphics_Frame_Epoch,
	epoch_pending:  bool,
}

Graphics_Frame_Record_Order :: enum u8 {
	Single,
	Legacy_First,
	Gsw_First,
	Invalid,
}

Graphics_Frame_Stage_Proc :: proc(
	ctx: rawptr,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> host.Host_Presentation_Staged_Texture

Graphics_Frame_Expand_Proc :: proc(
	ctx: rawptr,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame

Graphics_Frame_Consumer_Ops :: struct {
	ctx:           rawptr,
	expand_legacy: Graphics_Frame_Expand_Proc,
	expand_gsw:    Graphics_Frame_Expand_Proc,
	stage:         Graphics_Frame_Stage_Proc,
}

graphics_frame_expand_legacy :: proc(
	shared: ^Shared,
	descriptor: ^vga.Scanout_Descriptor,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> ^vga.Display_Frame {
	if ops != nil && ops.expand_legacy != nil {
		return ops.expand_legacy(ops.ctx, descriptor)
	}
	return videopresentation.expand_legacy(&shared.frames.expansion, descriptor)
}

graphics_frame_expand_gsw :: proc(
	shared: ^Shared,
	descriptor: ^vga.Scanout_Descriptor,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> ^vga.Display_Frame {
	if ops != nil && ops.expand_gsw != nil {return ops.expand_gsw(ops.ctx, descriptor)}
	return videopresentation.expand_gsw(&shared.frames.expansion, descriptor)
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

graphics_gsw_restoration_source :: proc(
	action: presentation.Selector_Action,
) -> (
	Graphics_Frame_Source,
	bool,
) {
	#partial switch action {
	case .Restore_Legacy:
		return .Legacy_Scanout, true
	case .Restore_Gsw:
		return .Gsw2d, true
	case:
		return {}, false
	}
}

graphics_frame_stage :: proc(
	ops: ^Graphics_Frame_Consumer_Ops,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
) -> host.Host_Presentation_Staged_Texture {
	if ops != nil && ops.stage != nil {
		return ops.stage(ops.ctx, target, admission, frame)
	}
	if admission != nil && admission.kind == .Legacy {
		return host.host_presentation_stage_legacy(target, admission, frame)
	}
	return host.host_presentation_stage_gsw_snapshot(target, admission, frame)
}

graphics_frame_consumer_record_order :: proc(
	descriptor: ^vga.Scanout_Descriptor,
) -> Graphics_Frame_Record_Order {
	if descriptor == nil {return .Invalid}
	if !descriptor.gsw_presentation.present_valid {return .Single}
	legacy_sequence := descriptor.legacy_update.header.sequence
	gsw_sequence := descriptor.gsw_presentation.present.header.sequence
	if legacy_sequence == 0 {return .Single}
	switch presentation.generation_order(gsw_sequence, legacy_sequence) {
	case .Older:
		return .Gsw_First
	case .Newer:
		return .Legacy_First
	case .Same, .Invalid, .Ambiguous:
		return .Invalid
	}
	return .Invalid
}

graphics_frame_consume_gsw_present :: proc(
	shared: ^Shared,
	target: ^host.Host,
	frame_slot: ^Frame_Slot,
	descriptor: ^vga.Gsw_Presentation_Descriptor,
	postmortem_state: ^Graphics_Postmortem_State,
	postmortem_state_valid: bool,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> Graphics_Gsw_Frame_Consume_Result {
	result: Graphics_Gsw_Frame_Consume_Result
	if shared == nil ||
	   target == nil ||
	   frame_slot == nil ||
	   descriptor == nil ||
	   !descriptor.present_valid ||
	   frame_slot.epoch.result != .Incomplete {
		return result
	}
	result.attempted = true
	gsw_admission := host.host_presentation_admit_gsw(
		target,
		descriptor.present,
		u64(len(descriptor.source)),
		descriptor.full_reason,
	)
	if !gsw_admission.valid {
		if gsw_admission.rejection == .Stale &&
		   frame_mailbox_gsw_was_committed(&shared.frames, descriptor.present) {
			_ = frame_mailbox_note_gsw_applied(&shared.frames, descriptor.present)
			return result
		}
		still_current := frame_mailbox_graphics_epoch_current(&shared.frames, &frame_slot.epoch)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			&shared.frames,
			&frame_slot.epoch,
			still_current ? .Render_Failed : .Reset,
			time.tick_now(),
		)
		result.failed = true
		if postmortem_state_valid {
			postmortem_state.host_stage = .Failed
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state^)
		}
		return result
	}

	graphics_frame_epoch_render_begin(&frame_slot.epoch, .Gsw2d, time.tick_now())
	gsw_frame := graphics_frame_expand_gsw(shared, &frame_slot.scanout, ops)
	graphics_frame_epoch_render_complete(&frame_slot.epoch, gsw_frame, time.tick_now())
	host.host_presentation_record_conversion(target, gsw_frame)
	if gsw_frame == nil {
		still_current := frame_mailbox_graphics_epoch_current(&shared.frames, &frame_slot.epoch)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			&shared.frames,
			&frame_slot.epoch,
			still_current ? .Render_Failed : .Reset,
			time.tick_now(),
		)
		result.failed = true
		result.retry = still_current
		if postmortem_state_valid {
			postmortem_state.host_stage = .Failed
			_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state^)
		}
		return result
	}

	if postmortem_state_valid {
		postmortem_state.host_stage = .Upload
		_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state^)
	}
	graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
	staged := graphics_frame_stage(ops, target, &gsw_admission, gsw_frame)
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
	if commit_result != .Committed && staged.in_place && staged.mutated {
		_ = host.host_presentation_retire_mutated(target, staged)
	}
	still_current := frame_mailbox_graphics_epoch_current(&shared.frames, &frame_slot.epoch)
	graphics_frame_epoch_upload_complete(
		&frame_slot.epoch,
		staged.upload_bytes,
		staged.texture_recreated,
		time.tick_now(),
	)
	if commit_result == .Committed {
		_ = frame_mailbox_note_gsw_applied(&shared.frames, descriptor.present)
		result.committed = true
		result.graphics_epoch = frame_slot.epoch
		result.epoch_pending = true
		return result
	}

	_ = frame_mailbox_graphics_epoch_complete_and_record(
		&shared.frames,
		&frame_slot.epoch,
		still_current ? .Upload_Failed : .Reset,
		time.tick_now(),
	)
	result.failed = true
	result.retry = still_current
	if postmortem_state_valid {
		postmortem_state.host_stage = .Failed
		_ = graphics_postmortem_publish_state(&shared.graphics_postmortem, postmortem_state^)
	}
	return result
}

graphics_frame_consume :: proc(
	shared: ^Shared,
	target: ^host.Host,
	trace_enabled: bool,
	last_vm_checkpoint: ^time.Tick,
	ops: ^Graphics_Frame_Consumer_Ops = nil,
) -> Graphics_Frame_Consumer_Result {
	graphics_epoch: Graphics_Frame_Epoch
	graphics_epoch_pending := false
	postmortem_state: Graphics_Postmortem_State
	postmortem_state_valid := false
	if frame_slot := frame_mailbox_acquire(&shared.frames); frame_slot != nil {
		gsw_descriptor := &frame_slot.scanout.gsw_presentation
		host.host_presentation_record_descriptor_copy(target, frame_slot.scanout.bytes_copied)
		gsw_transition := gsw_descriptor.present_valid || gsw_descriptor.invalidation_valid
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
		has_legacy_update := frame_slot.scanout.legacy_update.header.sequence != 0
		retry_latest := false
		gsw_processed := false
		record_order := graphics_frame_consumer_record_order(&frame_slot.scanout)
		legacy_admission: host.Host_Presentation_Admission
		current_before_render := frame_mailbox_graphics_epoch_current(
			&shared.frames,
			&frame_slot.epoch,
		)
		if !current_before_render ||
		   (!has_legacy_update && !gsw_transition) ||
		   record_order == .Invalid {
			result := Graphics_Frame_Result.Superseded
			if !current_before_render {
				result = .Reset
			} else if record_order == .Invalid {
				result = .Render_Failed
			}
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				&shared.frames,
				&frame_slot.epoch,
				result,
				time.tick_now(),
			)
			if postmortem_state_valid && result == .Render_Failed {
				postmortem_state.host_stage = .Failed
				_ = graphics_postmortem_publish_state(
					&shared.graphics_postmortem,
					postmortem_state,
				)
			}
		} else {
			if record_order == .Gsw_First {
				gsw_result := graphics_frame_consume_gsw_present(
					shared,
					target,
					frame_slot,
					gsw_descriptor,
					&postmortem_state,
					postmortem_state_valid,
					ops,
				)
				gsw_processed = gsw_result.attempted
				retry_latest = retry_latest || gsw_result.retry
				if gsw_result.committed {
					graphics_epoch = gsw_result.graphics_epoch
					graphics_epoch_pending = gsw_result.epoch_pending
				} else if gsw_result.failed {
					graphics_epoch_pending = false
				}
			}
			if has_legacy_update && frame_slot.epoch.result == .Incomplete {
				legacy_admission = host.host_presentation_admit_legacy(
					target,
					frame_slot.scanout.legacy_update,
					paired_invalidation,
				)
				if !legacy_admission.valid {
					legacy_already_committed := frame_mailbox_legacy_was_committed(
						&shared.frames,
						frame_slot.scanout.legacy_update,
					)
					if legacy_admission.rejection == .Stale && legacy_already_committed {
						_ = frame_mailbox_note_legacy_applied(
							&shared.frames,
							frame_slot.scanout.legacy_update,
						)
						if !gsw_transition {
							_ = frame_mailbox_graphics_epoch_complete_and_record(
								&shared.frames,
								&frame_slot.epoch,
								.Superseded,
								time.tick_now(),
							)
						}
					} else {
						_ = frame_mailbox_graphics_epoch_complete_and_record(
							&shared.frames,
							&frame_slot.epoch,
							.Render_Failed,
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
		}
		if current_before_render &&
		   legacy_admission.valid &&
		   frame_slot.epoch.result == .Incomplete {
			graphics_frame_epoch_render_begin(&frame_slot.epoch, .Legacy_Scanout, time.tick_now())
			frame := graphics_frame_expand_legacy(shared, &frame_slot.scanout, ops)
			graphics_frame_epoch_render_complete(&frame_slot.epoch, frame, time.tick_now())
			host.host_presentation_record_conversion(target, frame)
			if frame == nil {
				retry_latest = true
				if !graphics_epoch_pending {
					_ = frame_mailbox_graphics_epoch_complete_and_record(
						&shared.frames,
						&frame_slot.epoch,
						.Render_Failed,
						time.tick_now(),
					)
				}
			} else if frame != nil {
				if postmortem_state_valid {
					postmortem_state.host_stage = .Upload
					_ = graphics_postmortem_publish_state(
						&shared.graphics_postmortem,
						postmortem_state,
					)
				}
				graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
				staged := graphics_frame_stage(ops, target, &legacy_admission, frame)
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
				if commit_result != .Committed && staged.in_place && staged.mutated {
					_ = host.host_presentation_retire_mutated(target, staged)
				}
				committed := commit_result == .Committed
				still_current := frame_mailbox_graphics_epoch_current(
					&shared.frames,
					&frame_slot.epoch,
				)
				graphics_frame_epoch_upload_complete(
					&frame_slot.epoch,
					staged.upload_bytes,
					staged.texture_recreated,
					time.tick_now(),
				)
				if committed {
					_ = frame_mailbox_note_legacy_applied(
						&shared.frames,
						frame_slot.scanout.legacy_update,
					)
					disposition := graphics_legacy_upload_disposition(
						legacy_admission.result.action,
						gsw_transition,
					)
					if disposition == .Visible {
						graphics_epoch = frame_slot.epoch
						graphics_epoch_pending = true
					} else if graphics_epoch_pending {
						visible_source := graphics_epoch.source
						visible_kind := graphics_epoch.kind
						visible_width := graphics_epoch.width
						visible_height := graphics_epoch.height
						graphics_epoch = frame_slot.epoch
						graphics_epoch.source = visible_source
						graphics_epoch.kind = visible_kind
						graphics_epoch.width = visible_width
						graphics_epoch.height = visible_height
					}
				} else {
					retry_latest = retry_latest || still_current
					if !graphics_epoch_pending || !still_current {
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
			}
		}
		if current_before_render && !gsw_processed && frame_slot.epoch.result == .Incomplete {
			gsw_result := graphics_frame_consume_gsw_present(
				shared,
				target,
				frame_slot,
				gsw_descriptor,
				&postmortem_state,
				postmortem_state_valid,
				ops,
			)
			gsw_processed = gsw_result.attempted
			retry_latest = retry_latest || gsw_result.retry
			if gsw_result.committed {
				graphics_epoch = gsw_result.graphics_epoch
				graphics_epoch_pending = gsw_result.epoch_pending
			} else if gsw_result.failed {
				graphics_epoch_pending = false
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
			if restored_source, restored := graphics_gsw_restoration_source(action); restored {
				frame_slot.epoch.source = restored_source
				graphics_epoch = frame_slot.epoch
				graphics_epoch_pending = true
			} else if action == .Clear {
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
		if graphics_epoch_pending && frame_slot.epoch.result != .Incomplete {
			graphics_epoch_pending = false
		}
		if !graphics_epoch_pending && frame_slot.epoch.result == .Incomplete {
			_ = frame_mailbox_graphics_epoch_complete_and_record(
				&shared.frames,
				&frame_slot.epoch,
				.Superseded,
				time.tick_now(),
			)
		}
		if retry_latest {
			_ = frame_mailbox_retry_latest(&shared.frames, frame_slot)
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
