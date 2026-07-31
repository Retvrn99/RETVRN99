// SPDX-License-Identifier: GPL-3.0-only
package videopresentation

import "core:time"
import host "../host"
import presentation "../presentation"
import vga "../vga"

Graphics_Frame_Consumer_Result :: struct {
	graphics_epoch:         Graphics_Frame_Epoch,
	graphics_epoch_pending: bool,
	postmortem_state:       Graphics_Postmortem_State,
	postmortem_state_valid: bool,
	event_applied:          bool,
	host_gpu_interval:      Graphics_Host_Gpu_Interval,
	selection:              Graphics_Presentation_Selection,
	epoch_current:          bool,
	completed_result:       Graphics_Frame_Result,
	telemetry_window:       Graphics_Telemetry_Window,
	telemetry_window_ready: bool,
	telemetry_window_text:  string,
	telemetry_log_admitted: bool,
}

@(private = "package")
Graphics_Legacy_Staged_Commit :: struct {
	adapter:   ^Video_Presentation_Host_Adapter,
	admission: host.Host_Presentation_Admission,
	staged:    host.Host_Presentation_Staged_Texture,
}

@(private = "package")
Graphics_Gsw_Staged_Commit :: struct {
	adapter:   ^Video_Presentation_Host_Adapter,
	admission: host.Host_Presentation_Admission,
	staged:    host.Host_Presentation_Staged_Texture,
}

@(private = "package")
Graphics_Gsw_Invalidation_Commit :: struct {
	adapter:      ^Video_Presentation_Host_Adapter,
	invalidation: presentation.Gsw_Invalidation,
	action:       presentation.Selector_Action,
}

@(private = "package")
Graphics_Gsw_Frame_Consume_Result :: struct {
	attempted:      bool,
	committed:      bool,
	failed:         bool,
	retry:          bool,
	graphics_epoch: Graphics_Frame_Epoch,
	epoch_pending:  bool,
}

@(private = "package")
Graphics_Frame_Record_Order :: enum u8 {
	Single,
	Legacy_First,
	Gsw_First,
	Invalid,
}

@(private = "package")
Graphics_Frame_Stage_Proc :: proc(
	ctx: rawptr,
	target: ^host.Host,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan,
) -> host.Host_Presentation_Staged_Texture

@(private = "package")
Graphics_Frame_Expand_Proc :: proc(
	ctx: rawptr,
	descriptor: ^vga.Scanout_Descriptor,
) -> ^vga.Display_Frame

@(private = "package")
Graphics_Frame_Consumer_Ops :: struct {
	ctx:           rawptr,
	expand_legacy: Graphics_Frame_Expand_Proc,
	expand_gsw:    Graphics_Frame_Expand_Proc,
	stage:         Graphics_Frame_Stage_Proc,
}

@(private = "package")
graphics_frame_expand_legacy_result :: proc(
	video: ^Video_Presentation,
	descriptor: ^vga.Scanout_Descriptor,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> Expansion_Result {
	if ops != nil && ops.expand_legacy != nil {
		frame := ops.expand_legacy(ops.ctx, descriptor)
		if frame == nil {return {}}
		return {status = .Ready, frame = frame}
	}
	return expand_legacy_result(&video.expansion, descriptor)
}

@(private = "package")
graphics_frame_expand_gsw :: proc(
	video: ^Video_Presentation,
	descriptor: ^vga.Scanout_Descriptor,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> ^vga.Display_Frame {
	if ops != nil && ops.expand_gsw != nil {return ops.expand_gsw(ops.ctx, descriptor)}
	return expand_gsw(&video.expansion, descriptor)
}

@(private = "package")
graphics_legacy_staged_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Legacy_Staged_Commit)(ctx)
	if commit == nil || commit.adapter == nil || commit.adapter.activate_legacy == nil {
		return false
	}
	return commit.adapter.activate_legacy(
		commit.adapter.ctx,
		&commit.admission,
		commit.staged,
	)
}

@(private = "package")
graphics_gsw_staged_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Gsw_Staged_Commit)(ctx)
	if commit == nil || commit.adapter == nil || commit.adapter.activate_gsw == nil {
		return false
	}
	return commit.adapter.activate_gsw(
		commit.adapter.ctx,
		&commit.admission,
		commit.staged,
	)
}

@(private = "package")
graphics_gsw_invalidation_commit :: proc(ctx: rawptr) -> bool {
	commit := (^Graphics_Gsw_Invalidation_Commit)(ctx)
	if commit == nil || commit.adapter == nil || commit.adapter.invalidate == nil {return false}
	commit.action = commit.adapter.invalidate(commit.adapter.ctx, commit.invalidation)
	return true
}

@(private = "package")
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

@(private = "package")
graphics_frame_stage :: proc(
	ops: ^Graphics_Frame_Consumer_Ops,
	adapter: ^Video_Presentation_Host_Adapter,
	admission: ^host.Host_Presentation_Admission,
	frame: ^vga.Display_Frame,
	capture_plan: ^vga.Scanout_Capture_Plan = nil,
) -> host.Host_Presentation_Staged_Texture {
	if adapter == nil {return {}}
	if ops != nil && ops.stage != nil {
		return ops.stage(ops.ctx, adapter.target, admission, frame, capture_plan)
	}
	if admission != nil && admission.kind == .Legacy {
		if adapter.stage_legacy == nil {return {}}
		return adapter.stage_legacy(adapter.ctx, admission, frame, capture_plan)
	}
	if adapter.stage_gsw == nil {return {}}
	return adapter.stage_gsw(adapter.ctx, admission, frame)
}

@(private = "package")
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

@(private = "package")
graphics_frame_consume_gsw_present :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter,
	frame_slot: ^Frame_Slot,
	descriptor: ^vga.Gsw_Presentation_Descriptor,
	postmortem_state: ^Graphics_Postmortem_State,
	postmortem_state_valid: bool,
	ops: ^Graphics_Frame_Consumer_Ops,
) -> Graphics_Gsw_Frame_Consume_Result {
	result: Graphics_Gsw_Frame_Consume_Result
	target := adapter != nil ? adapter.target : nil
	if video == nil ||
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
		   frame_mailbox_gsw_was_committed(video, descriptor.present) {
			_ = frame_mailbox_note_gsw_applied(video, descriptor.present)
			return result
		}
		still_current := frame_mailbox_graphics_epoch_current(video, &frame_slot.epoch)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			video,
			&frame_slot.epoch,
			still_current ? .Render_Failed : .Reset,
			time.tick_now(),
		)
		result.failed = true
		if postmortem_state_valid {
			postmortem_state.host_stage = .Failed
			_ = graphics_postmortem_publish_state(&video.postmortem, postmortem_state^)
		}
		return result
	}

	graphics_frame_epoch_render_begin(&frame_slot.epoch, .Gsw2d, time.tick_now())
	gsw_frame := graphics_frame_expand_gsw(video, &frame_slot.scanout, ops)
	graphics_frame_epoch_render_complete(&frame_slot.epoch, gsw_frame, time.tick_now())
	host.host_presentation_record_conversion(target, gsw_frame)
	if gsw_frame == nil {
		still_current := frame_mailbox_graphics_epoch_current(video, &frame_slot.epoch)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			video,
			&frame_slot.epoch,
			still_current ? .Render_Failed : .Reset,
			time.tick_now(),
		)
		result.failed = true
		result.retry = still_current
		if postmortem_state_valid {
			postmortem_state.host_stage = .Failed
			_ = graphics_postmortem_publish_state(&video.postmortem, postmortem_state^)
		}
		return result
	}

	if postmortem_state_valid {
		postmortem_state.host_stage = .Upload
		_ = graphics_postmortem_publish_state(&video.postmortem, postmortem_state^)
	}
	graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
	staged := graphics_frame_stage(ops, adapter, &gsw_admission, gsw_frame)
	commit := Graphics_Gsw_Staged_Commit {
		adapter   = adapter,
		admission = gsw_admission,
		staged    = staged,
	}
	commit_result := Frame_Mailbox_Current_Commit_Result.Invalid
	if staged.valid {
		commit_result = frame_mailbox_graphics_epoch_commit_current(
			video,
			&frame_slot.epoch,
			&commit,
			graphics_gsw_staged_commit,
		)
	}
	if commit_result == .Stale {
		host.host_presentation_note_stale_finalization(target)
	}
	if commit_result != .Committed && staged.in_place && staged.mutated {
		if adapter.retire != nil {_ = adapter.retire(adapter.ctx, staged)}
	}
	still_current := frame_mailbox_graphics_epoch_current(video, &frame_slot.epoch)
	graphics_frame_epoch_upload_complete(
		&frame_slot.epoch,
		staged.upload_bytes,
		staged.texture_recreated,
		time.tick_now(),
	)
	if commit_result == .Committed {
		_ = frame_mailbox_note_gsw_applied(video, descriptor.present)
		result.committed = true
		result.graphics_epoch = frame_slot.epoch
		result.epoch_pending = true
		return result
	}

	_ = frame_mailbox_graphics_epoch_complete_and_record(
		video,
		&frame_slot.epoch,
		still_current ? .Upload_Failed : .Reset,
		time.tick_now(),
	)
	result.failed = true
	result.retry = still_current
	if postmortem_state_valid {
		postmortem_state.host_stage = .Failed
		_ = graphics_postmortem_publish_state(&video.postmortem, postmortem_state^)
	}
	return result
}

@(private = "package")
graphics_frame_consume_with_adapter :: proc(
	video: ^Video_Presentation,
	adapter: ^Video_Presentation_Host_Adapter,
	trace_enabled: bool,
	last_vm_checkpoint: ^time.Tick,
	ops: ^Graphics_Frame_Consumer_Ops = nil,
) -> Graphics_Frame_Consumer_Result {
	target := adapter != nil ? adapter.target : nil
	if target == nil {return {}}
	graphics_epoch: Graphics_Frame_Epoch
	graphics_epoch_pending := false
	postmortem_state: Graphics_Postmortem_State
	postmortem_state_valid := false
	if frame_slot := frame_mailbox_acquire(video); frame_slot != nil {
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
					&video.postmortem,
					vm_text,
					frame_slot.epoch.sequence,
					.Measured,
				)
				delete(vm_text)
				last_vm_checkpoint^ = now
			}
		}
		if postmortem_state_valid {
			_ = graphics_postmortem_publish_state(&video.postmortem, postmortem_state)
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
			video,
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
				video,
				&frame_slot.epoch,
				result,
				time.tick_now(),
			)
			if postmortem_state_valid && result == .Render_Failed {
				postmortem_state.host_stage = .Failed
				_ = graphics_postmortem_publish_state(
					&video.postmortem,
					postmortem_state,
				)
			}
		} else {
			if record_order == .Gsw_First {
				gsw_result := graphics_frame_consume_gsw_present(
					video,
					adapter,
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
						video,
						frame_slot.scanout.legacy_update,
					)
					if legacy_admission.rejection == .Stale && legacy_already_committed {
						_ = frame_mailbox_note_legacy_applied(
							video,
							frame_slot.scanout.legacy_update,
						)
						if !gsw_transition {
							_ = frame_mailbox_graphics_epoch_complete_and_record(
								video,
								&frame_slot.epoch,
								.Superseded,
								time.tick_now(),
							)
						}
					} else {
						_ = frame_mailbox_graphics_epoch_complete_and_record(
							video,
							&frame_slot.epoch,
							.Render_Failed,
							time.tick_now(),
						)
						if postmortem_state_valid {
							postmortem_state.host_stage = .Failed
							_ = graphics_postmortem_publish_state(
								&video.postmortem,
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
			expanded := graphics_frame_expand_legacy_result(video, &frame_slot.scanout, ops)
			frame := expanded.frame
			graphics_frame_epoch_render_complete(&frame_slot.epoch, frame, time.tick_now())
			host.host_presentation_record_conversion(target, frame)
			if expanded.status == .Needs_Full_Baseline {
				_ = frame_mailbox_request_legacy_full_baseline(
					video,
					frame_slot.scanout.capture_plan,
				)
				if !graphics_epoch_pending {
					_ = frame_mailbox_graphics_epoch_complete_and_record(
						video,
						&frame_slot.epoch,
						.Superseded,
						time.tick_now(),
					)
				}
			} else if frame == nil {
				retry_latest = true
				if !graphics_epoch_pending {
					_ = frame_mailbox_graphics_epoch_complete_and_record(
						video,
						&frame_slot.epoch,
						.Render_Failed,
						time.tick_now(),
					)
				}
			} else if frame != nil {
				if postmortem_state_valid {
					postmortem_state.host_stage = .Upload
					_ = graphics_postmortem_publish_state(
						&video.postmortem,
						postmortem_state,
					)
				}
				graphics_frame_epoch_upload_begin(&frame_slot.epoch, time.tick_now())
				staged := graphics_frame_stage(
					ops,
					adapter,
					&legacy_admission,
					frame,
					&frame_slot.scanout.capture_plan,
				)
				needs_full_baseline := staged.status == .Needs_Full_Baseline
				if needs_full_baseline {
					_ = frame_mailbox_request_legacy_full_baseline(
						video,
						frame_slot.scanout.capture_plan,
					)
				}
				commit := Graphics_Legacy_Staged_Commit {
					adapter   = adapter,
					admission = legacy_admission,
					staged    = staged,
				}
				commit_result := Frame_Mailbox_Current_Commit_Result.Invalid
				if staged.valid && !needs_full_baseline {
					commit_result = frame_mailbox_graphics_epoch_commit_current(
						video,
						&frame_slot.epoch,
						&commit,
						graphics_legacy_staged_commit,
					)
				}
				if commit_result == .Stale {
					host.host_presentation_note_stale_finalization(target)
				}
				if commit_result != .Committed && staged.in_place && staged.mutated {
					if adapter.retire != nil {_ = adapter.retire(adapter.ctx, staged)}
				}
				committed := commit_result == .Committed
				still_current := frame_mailbox_graphics_epoch_current(
					video,
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
						video,
						frame_slot.scanout.legacy_update,
					)
					_ = frame_mailbox_complete_legacy_full_baseline(
						video,
						frame_slot.scanout.capture_plan,
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
				} else if needs_full_baseline {
					if !graphics_epoch_pending {
						_ = frame_mailbox_graphics_epoch_complete_and_record(
							video,
							&frame_slot.epoch,
							.Superseded,
							time.tick_now(),
						)
					}
				} else {
					retry_latest = retry_latest || still_current
					if !graphics_epoch_pending || !still_current {
						_ = frame_mailbox_graphics_epoch_complete_and_record(
							video,
							&frame_slot.epoch,
							still_current ? .Upload_Failed : .Reset,
							time.tick_now(),
						)
						graphics_epoch_pending = false
						if postmortem_state_valid {
							postmortem_state.host_stage = .Failed
							_ = graphics_postmortem_publish_state(
								&video.postmortem,
								postmortem_state,
							)
						}
					}
				}
			}
		}
		if current_before_render && !gsw_processed && frame_slot.epoch.result == .Incomplete {
			gsw_result := graphics_frame_consume_gsw_present(
				video,
				adapter,
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
				adapter      = adapter,
				invalidation = gsw_descriptor.invalidation,
			}
			commit_result := frame_mailbox_graphics_epoch_commit_current(
				video,
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
					video,
					&frame_slot.epoch,
					.Gpu_Work,
					time.tick_now(),
				)
				graphics_epoch_pending = false
			} else if commit_result == .Stale {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					video,
					&frame_slot.epoch,
					.Reset,
					time.tick_now(),
				)
				graphics_epoch_pending = false
			} else if !graphics_epoch_pending {
				_ = frame_mailbox_graphics_epoch_complete_and_record(
					video,
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
				video,
				&frame_slot.epoch,
				.Superseded,
				time.tick_now(),
			)
		}
		if retry_latest {
			_ = frame_mailbox_retry_latest(video, frame_slot)
		}
		frame_mailbox_release(video, frame_slot)
	}
	return {
		graphics_epoch = graphics_epoch,
		graphics_epoch_pending = graphics_epoch_pending,
		postmortem_state = postmortem_state,
		postmortem_state_valid = postmortem_state_valid,
	}
}

@(private = "package")
graphics_frame_consume :: proc(
	video: ^Video_Presentation,
	target: ^host.Host,
	trace_enabled: bool,
	last_vm_checkpoint: ^time.Tick,
	ops: ^Graphics_Frame_Consumer_Ops = nil,
) -> Graphics_Frame_Consumer_Result {
	adapter := video_presentation_host_adapter(target)
	return graphics_frame_consume_with_adapter(
		video,
		&adapter,
		trace_enabled,
		last_vm_checkpoint,
		ops,
	)
}
