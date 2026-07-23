// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:sync"
import "core:time"
import host "host"
import machine "machine"
import contract "presentation"
import vga "vga"

Frame_Slot_State :: enum {
	Free,
	Writing,
	Ready,
	Reading,
}

Frame_Slot :: struct {
	state:                         Frame_Slot_State,
	reserved_lifecycle_generation: u64,
	scanout:                       vga.Scanout_Descriptor,
	epoch:                         Graphics_Frame_Epoch,
	producer_sample:               Graphics_Producer_Sample,
}

Frame_Mailbox_Legacy_Ack :: struct {
	valid:                bool,
	lifecycle_generation: u64,
	sequence:             u64,
	mode_generation:      u64,
	surface_id:           u64,
	surface_generation:   u64,
}

Frame_Mailbox_Gsw_Ack :: struct {
	valid:                bool,
	lifecycle_generation: u64,
	sequence:             u64,
	device_generation:    u64,
	surface_id:           u64,
	surface_generation:   u64,
}

Frame_Mailbox_Legacy_Commit :: struct {
	valid:  bool,
	update: contract.Legacy_Frame_Update,
}

Frame_Mailbox_Gsw_Commit :: struct {
	valid:   bool,
	present: contract.Gsw_Present,
}

Frame_Mailbox :: struct {
	mu:                   sync.Mutex,
	slots:                [2]Frame_Slot,
	published:            u64,
	published_epoch:      u64,
	has_frame:            bool,
	next_epoch:           u64,
	lifecycle_generation: u64,
	telemetry:            Graphics_Telemetry,
	legacy_ack:           Frame_Mailbox_Legacy_Ack,
	gsw_ack:              Frame_Mailbox_Gsw_Ack,
	legacy_committed:     Frame_Mailbox_Legacy_Commit,
	gsw_committed:        Frame_Mailbox_Gsw_Commit,
}

Frame_Mailbox_Current_Commit_Proc :: proc(ctx: rawptr) -> bool

Frame_Mailbox_Current_Commit_Result :: enum u8 {
	Invalid,
	Stale,
	Rejected,
	Committed,
}

@(private = "file")
frame_mailbox_ensure_lifecycle_locked :: proc(mailbox: ^Frame_Mailbox) {
	if mailbox != nil && mailbox.lifecycle_generation == 0 {
		mailbox.lifecycle_generation = 1
	}
}

@(private = "file")
frame_mailbox_advance_lifecycle_locked :: proc(mailbox: ^Frame_Mailbox) {
	if mailbox == nil {return}
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	mailbox.lifecycle_generation += 1
	if mailbox.lifecycle_generation == 0 {mailbox.lifecycle_generation = 1}
}

@(private = "package")
frame_mailbox_begin_at :: proc(
	mailbox: ^Frame_Mailbox,
	generation: u64,
	now: time.Tick,
	producer_sample: Graphics_Producer_Sample,
) -> (
	^Frame_Slot,
	bool,
) {
	if mailbox == nil {return nil, false}
	sync.lock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	graphics_telemetry_note_publish_attempt(&mailbox.telemetry, now)
	graphics_telemetry_note_producer(&mailbox.telemetry, producer_sample, now)
	if mailbox.has_frame && generation == mailbox.published {
		graphics_telemetry_note_unchanged(&mailbox.telemetry, now)
		sync.unlock(&mailbox.mu)
		return nil, false
	}

	chosen := -1
	for &slot, i in mailbox.slots {
		if slot.state == .Free {chosen = i; break}
	}
	if chosen < 0 {
		oldest: u64
		for &slot, i in mailbox.slots {
			if slot.state == .Ready &&
			   (chosen < 0 ||
					   contract.generation_order(slot.scanout.generation, oldest) == .Older) {
				oldest = slot.scanout.generation
				chosen = i
			}
		}
	}
	if chosen < 0 {
		graphics_telemetry_note_blocked(&mailbox.telemetry, now)
		sync.unlock(&mailbox.mu)
		return nil, false
	}
	coalesced_correlation: Graphics_Frame_Epoch
	for {
		newest_ready := -1
		newest_sequence: u64
		for &ready, i in mailbox.slots {
			if ready.state == .Ready &&
			   (newest_ready < 0 ||
					   contract.generation_order(ready.epoch.sequence, newest_sequence) ==
						   .Newer) {
				newest_ready = i
				newest_sequence = ready.epoch.sequence
			}
		}
		if newest_ready < 0 {break}
		ready := &mailbox.slots[newest_ready]
		graphics_frame_epoch_transfer_input_producer_correlation(
			&coalesced_correlation,
			&ready.epoch,
		)
		graphics_frame_epoch_complete(&ready.epoch, .Coalesced, now)
		graphics_telemetry_record(&mailbox.telemetry, ready.epoch)
		ready.state = .Free
	}
	slot := &mailbox.slots[chosen]
	slot.state = .Writing
	slot.reserved_lifecycle_generation = mailbox.lifecycle_generation
	mailbox.next_epoch += 1
	if mailbox.next_epoch == 0 {mailbox.next_epoch = 1}
	slot.epoch = graphics_telemetry_begin_epoch(
		&mailbox.telemetry,
		mailbox.next_epoch,
		generation,
		now,
	)
	graphics_frame_epoch_transfer_input_producer_correlation(&slot.epoch, &coalesced_correlation)
	slot.epoch.lifecycle_generation = mailbox.lifecycle_generation
	slot.producer_sample = producer_sample
	sync.unlock(&mailbox.mu)
	return slot, true
}

frame_mailbox_begin :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> (^Frame_Slot, bool) {
	return frame_mailbox_begin_at(mailbox, generation, time.tick_now(), {})
}

frame_mailbox_commit :: proc(mailbox: ^Frame_Mailbox, slot: ^Frame_Slot, ready: bool) -> bool {
	if mailbox == nil || slot == nil {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if slot.state != .Writing {return false}
	if slot.reserved_lifecycle_generation != mailbox.lifecycle_generation {
		if slot.epoch.result == .Incomplete && slot.epoch.sequence != 0 {
			graphics_frame_epoch_complete(&slot.epoch, .Reset, time.tick_now())
			graphics_telemetry_record(&mailbox.telemetry, slot.epoch)
		}
		slot.state = .Free
		return false
	}
	if ready {
		slot.state = .Ready
		mailbox.published = slot.scanout.generation
		mailbox.published_epoch = slot.epoch.sequence
		mailbox.has_frame = true
		return true
	} else {
		slot.state = .Free
	}
	return false
}

frame_mailbox_publish_observed :: proc(
	mailbox: ^Frame_Mailbox,
	source: ^machine.Machine,
	session_generation: u64,
	vm: Graphics_Vm_Execution_Sample,
	postmortem: ^Graphics_Postmortem = nil,
) -> bool {
	if mailbox == nil || source == nil {return false}
	if ack, valid := frame_mailbox_take_legacy_ack(mailbox); valid {
		_ = machine.machine_acknowledge_legacy_scanout(
			source,
			{
				header = {
					sequence = ack.sequence,
					mode_generation = ack.mode_generation,
					surface = {id = ack.surface_id, generation = ack.surface_generation},
				},
			},
		)
	}
	if ack, valid := frame_mailbox_take_gsw_ack(mailbox); valid {
		_ = machine.machine_acknowledge_gsw_scanout(
			source,
			{
				header = {
					sequence = ack.sequence,
					device_generation = ack.device_generation,
					surface = {id = ack.surface_id, generation = ack.surface_generation},
				},
			},
		)
	}
	started := time.tick_now()
	generation := machine.machine_scanout_generation(source)
	producer_sample := graphics_producer_sample(source, session_generation, vm)
	slot, reserved := frame_mailbox_begin_at(mailbox, generation, started, producer_sample)
	if !reserved {return false}
	postmortem_state := graphics_postmortem_measured_state(
		producer_sample.session_generation,
		producer_sample.machine.gsw3d.device_generation,
		0,
		slot.epoch.sequence,
		.Capture,
	)
	if postmortem != nil {
		_ = graphics_postmortem_publish_state(postmortem, postmortem_state)
	}

	graphics_frame_epoch_capture_begin(&slot.epoch, time.tick_now())
	if !machine.machine_capture_scanout(
		source,
		&slot.scanout,
		slot.reserved_lifecycle_generation,
	) {
		failed_at := time.tick_now()
		graphics_frame_epoch_descriptor_copy(&slot.epoch, slot.scanout.copy_duration_ns)
		graphics_frame_epoch_capture_complete(&slot.epoch, slot.scanout.bytes_copied, failed_at)
		_ = frame_mailbox_graphics_epoch_complete_and_record(
			mailbox,
			&slot.epoch,
			.Capture_Failed,
			failed_at,
		)
		if postmortem != nil {
			postmortem_state.host_stage = .Failed
			_ = graphics_postmortem_publish_state(postmortem, postmortem_state)
		}
		_ = frame_mailbox_commit(mailbox, slot, false)
		return false
	}
	slot.scanout.legacy_update.header.lifecycle_generation = slot.reserved_lifecycle_generation
	graphics_frame_epoch_descriptor_copy(&slot.epoch, slot.scanout.copy_duration_ns)
	graphics_frame_epoch_capture_complete(&slot.epoch, slot.scanout.bytes_copied, time.tick_now())
	committed := frame_mailbox_commit(mailbox, slot, true)
	if postmortem != nil {
		postmortem_state.host_stage = committed ? .Mailbox : .Failed
		_ = graphics_postmortem_publish_state(postmortem, postmortem_state)
	}
	return committed
}

frame_mailbox_publish :: proc(mailbox: ^Frame_Mailbox, source: ^machine.Machine) -> bool {
	return frame_mailbox_publish_observed(mailbox, source, 0, {})
}

frame_mailbox_acquire :: proc(mailbox: ^Frame_Mailbox) -> ^Frame_Slot {
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	chosen := -1
	newest: u64
	for &slot, i in mailbox.slots {
		if slot.state == .Ready &&
		   (chosen < 0 || contract.generation_order(slot.scanout.generation, newest) == .Newer) {
			chosen = i
			newest = slot.scanout.generation
		}
	}
	if chosen < 0 {return nil}
	mailbox.slots[chosen].state = .Reading
	return &mailbox.slots[chosen]
}

frame_mailbox_release :: proc(mailbox: ^Frame_Mailbox, slot: ^Frame_Slot) {
	if slot == nil {return}
	sync.lock(&mailbox.mu)
	if slot.state == .Reading {slot.state = .Free}
	sync.unlock(&mailbox.mu)
}

frame_mailbox_retry_latest :: proc(mailbox: ^Frame_Mailbox, slot: ^Frame_Slot) -> bool {
	if mailbox == nil || slot == nil {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if slot.state != .Reading ||
	   slot.reserved_lifecycle_generation != mailbox.lifecycle_generation ||
	   slot.epoch.lifecycle_generation != mailbox.lifecycle_generation ||
	   !mailbox.has_frame ||
	   mailbox.published != slot.scanout.generation ||
	   mailbox.published_epoch != slot.epoch.sequence {
		return false
	}
	mailbox.published = 0
	mailbox.published_epoch = 0
	mailbox.has_frame = false
	return true
}

frame_mailbox_note_legacy_applied :: proc(
	mailbox: ^Frame_Mailbox,
	update: contract.Legacy_Frame_Update,
) -> bool {
	if mailbox == nil || update.header.sequence == 0 {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if update.header.lifecycle_generation != mailbox.lifecycle_generation {return false}
	mailbox.legacy_ack = {
		valid                = true,
		lifecycle_generation = update.header.lifecycle_generation,
		sequence             = update.header.sequence,
		mode_generation      = update.header.mode_generation,
		surface_id           = update.header.surface.id,
		surface_generation   = update.header.surface.generation,
	}
	mailbox.legacy_committed = {
		valid  = true,
		update = update,
	}
	return true
}

frame_mailbox_legacy_was_committed :: proc(
	mailbox: ^Frame_Mailbox,
	update: contract.Legacy_Frame_Update,
) -> bool {
	if mailbox == nil {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	committed := mailbox.legacy_committed
	return(
		committed.valid &&
		committed.update.header.lifecycle_generation == mailbox.lifecycle_generation &&
		contract.legacy_frame_update_equal(committed.update, update) \
	)
}

@(private = "package")
frame_mailbox_take_legacy_ack :: proc(
	mailbox: ^Frame_Mailbox,
) -> (
	Frame_Mailbox_Legacy_Ack,
	bool,
) {
	if mailbox == nil {return {}, false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	ack := mailbox.legacy_ack
	mailbox.legacy_ack = {}
	return ack, ack.valid && ack.lifecycle_generation == mailbox.lifecycle_generation
}

frame_mailbox_note_gsw_applied :: proc(
	mailbox: ^Frame_Mailbox,
	present: contract.Gsw_Present,
) -> bool {
	if mailbox == nil || present.header.sequence == 0 {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if present.header.lifecycle_generation != mailbox.lifecycle_generation {return false}
	mailbox.gsw_ack = {
		valid                = true,
		lifecycle_generation = present.header.lifecycle_generation,
		sequence             = present.header.sequence,
		device_generation    = present.header.device_generation,
		surface_id           = present.header.surface.id,
		surface_generation   = present.header.surface.generation,
	}
	mailbox.gsw_committed = {
		valid   = true,
		present = present,
	}
	return true
}

frame_mailbox_gsw_was_committed :: proc(
	mailbox: ^Frame_Mailbox,
	present: contract.Gsw_Present,
) -> bool {
	if mailbox == nil {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	committed := mailbox.gsw_committed
	return(
		committed.valid &&
		committed.present.header.lifecycle_generation == mailbox.lifecycle_generation &&
		contract.gsw_present_equal(committed.present, present) \
	)
}

@(private = "package")
frame_mailbox_take_gsw_ack :: proc(mailbox: ^Frame_Mailbox) -> (Frame_Mailbox_Gsw_Ack, bool) {
	if mailbox == nil {return {}, false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	ack := mailbox.gsw_ack
	mailbox.gsw_ack = {}
	return ack, ack.valid && ack.lifecycle_generation == mailbox.lifecycle_generation
}

frame_mailbox_reset :: proc(mailbox: ^Frame_Mailbox) {
	sync.lock(&mailbox.mu)
	now := time.tick_now()
	frame_mailbox_advance_lifecycle_locked(mailbox)
	for &slot in mailbox.slots {
		if slot.state == .Ready {
			graphics_frame_epoch_complete(&slot.epoch, .Reset, now)
			graphics_telemetry_record(&mailbox.telemetry, slot.epoch)
			slot.state = .Free
		}
	}
	mailbox.published = 0
	mailbox.published_epoch = 0
	mailbox.has_frame = false
	mailbox.legacy_ack = {}
	mailbox.gsw_ack = {}
	mailbox.legacy_committed = {}
	mailbox.gsw_committed = {}
	mailbox.next_epoch += 1
	if mailbox.next_epoch == 0 {mailbox.next_epoch = 1}
	reset_epoch := graphics_telemetry_begin_epoch(&mailbox.telemetry, mailbox.next_epoch, 0, now)
	reset_epoch.lifecycle_generation = mailbox.lifecycle_generation
	graphics_frame_epoch_complete(&reset_epoch, .Reset, now)
	graphics_telemetry_record(&mailbox.telemetry, reset_epoch)
	graphics_telemetry_reset_attribution(&mailbox.telemetry)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_init :: proc(mailbox: ^Frame_Mailbox, trace_enabled: bool) {
	if mailbox == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_init(&mailbox.telemetry, trace_enabled)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_record :: proc(
	mailbox: ^Frame_Mailbox,
	epoch: Graphics_Frame_Epoch,
) {
	if mailbox == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_record(&mailbox.telemetry, epoch)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_epoch_complete_and_record :: proc(
	mailbox: ^Frame_Mailbox,
	epoch: ^Graphics_Frame_Epoch,
	intended: Graphics_Frame_Result,
	completed: time.Tick,
) -> Graphics_Frame_Result {
	if mailbox == nil || epoch == nil {return .Incomplete}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	result := intended
	if epoch.lifecycle_generation != mailbox.lifecycle_generation {result = .Reset}
	graphics_frame_epoch_complete(epoch, result, completed)
	graphics_telemetry_record(&mailbox.telemetry, epoch^)
	return result
}

frame_mailbox_graphics_telemetry_note_input :: proc(
	mailbox: ^Frame_Mailbox,
	events, residence_ns, max_residence_ns: u64,
	now: time.Tick,
	oldest_queued_at: time.Tick = {},
) {
	if mailbox == nil || events == 0 {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_note_input(
		&mailbox.telemetry,
		events,
		residence_ns,
		max_residence_ns,
		now,
		oldest_queued_at,
	)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_note_host_gpu :: proc(
	mailbox: ^Frame_Mailbox,
	sample: host.Host_Gsw3d_Observability_Snapshot,
	now: time.Tick,
) -> Graphics_Host_Gpu_Interval {
	if mailbox == nil {return {}}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	return graphics_telemetry_note_host_gpu(&mailbox.telemetry, sample, now)
}

frame_mailbox_graphics_telemetry_note_gpu_drain :: proc(
	mailbox: ^Frame_Mailbox,
	started, ended: time.Tick,
	executed, failed: int,
	budget: u64,
) {
	if mailbox == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_note_gpu_drain(&mailbox.telemetry, started, ended, executed, failed, budget)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_note_compose :: proc(
	mailbox: ^Frame_Mailbox,
	started, ended: time.Tick,
) {
	if mailbox == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_note_compose(&mailbox.telemetry, started, ended)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_note_present :: proc(
	mailbox: ^Frame_Mailbox,
	started, ended: time.Tick,
) {
	if mailbox == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_note_present(&mailbox.telemetry, started, ended)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_attach_pending_host_gpu :: proc(
	mailbox: ^Frame_Mailbox,
	epoch: ^Graphics_Frame_Epoch,
) {
	if mailbox == nil || epoch == nil {return}
	sync.lock(&mailbox.mu)
	graphics_telemetry_attach_pending_host_gpu(&mailbox.telemetry, epoch)
	sync.unlock(&mailbox.mu)
}

frame_mailbox_graphics_telemetry_begin_host_epoch :: proc(
	mailbox: ^Frame_Mailbox,
	now: time.Tick,
) -> Graphics_Frame_Epoch {
	if mailbox == nil {return {}}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	mailbox.next_epoch += 1
	if mailbox.next_epoch == 0 {mailbox.next_epoch = 1}
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	epoch := graphics_telemetry_begin_epoch(&mailbox.telemetry, mailbox.next_epoch, 0, now)
	epoch.source = .Gsw3d
	epoch.lifecycle_generation = mailbox.lifecycle_generation
	return epoch
}

frame_mailbox_graphics_epoch_current :: proc(
	mailbox: ^Frame_Mailbox,
	epoch: ^Graphics_Frame_Epoch,
) -> bool {
	if mailbox == nil || epoch == nil {return false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	return epoch.lifecycle_generation == mailbox.lifecycle_generation
}

frame_mailbox_graphics_epoch_commit_current :: proc(
	mailbox: ^Frame_Mailbox,
	epoch: ^Graphics_Frame_Epoch,
	ctx: rawptr,
	commit: Frame_Mailbox_Current_Commit_Proc,
) -> Frame_Mailbox_Current_Commit_Result {
	if mailbox == nil || epoch == nil || commit == nil {return .Invalid}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if epoch.lifecycle_generation != mailbox.lifecycle_generation {return .Stale}
	if !commit(ctx) {return .Rejected}
	return .Committed
}

frame_mailbox_lifecycle_generation :: proc(mailbox: ^Frame_Mailbox) -> u64 {
	if mailbox == nil {return 0}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	return mailbox.lifecycle_generation
}

frame_mailbox_graphics_telemetry_take_window :: proc(
	mailbox: ^Frame_Mailbox,
	now: time.Tick,
) -> (
	Graphics_Telemetry_Window,
	bool,
) {
	if mailbox == nil {return {}, false}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	return graphics_telemetry_take_window(&mailbox.telemetry, now)
}

frame_mailbox_graphics_telemetry_snapshot :: proc(
	mailbox: ^Frame_Mailbox,
	now: time.Tick,
) -> Graphics_Telemetry_Snapshot {
	if mailbox == nil {return {}}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	return graphics_telemetry_snapshot(&mailbox.telemetry, now)
}

frame_mailbox_graphics_trace_text :: proc(mailbox: ^Frame_Mailbox) -> string {
	if mailbox == nil {return ""}
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
	return graphics_telemetry_trace_text(&mailbox.telemetry)
}

frame_mailbox_destroy :: proc(mailbox: ^Frame_Mailbox) {
	if mailbox == nil {return}
	for &slot in mailbox.slots {
		vga.scanout_descriptor_destroy(&slot.scanout)
		slot = {}
	}
	graphics_telemetry_destroy(&mailbox.telemetry)
	mailbox^ = {}
}
