// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:sync"
import "core:time"
import host "host"
import machine "machine"
import vga "vga"

Frame_Slot_State :: enum {
	Free,
	Writing,
	Ready,
	Reading,
}

Frame_Slot :: struct {
	state:           Frame_Slot_State,
	scanout:         vga.Scanout_Descriptor,
	epoch:           Graphics_Frame_Epoch,
	producer_sample: Graphics_Producer_Sample,
}

Frame_Mailbox :: struct {
	mu:                   sync.Mutex,
	slots:                [2]Frame_Slot,
	published:            u64,
	has_frame:            bool,
	next_epoch:           u64,
	lifecycle_generation: u64,
	telemetry:            Graphics_Telemetry,
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
		oldest := max(u64)
		for &slot, i in mailbox.slots {
			if slot.state == .Ready && slot.scanout.generation < oldest {
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
			   (newest_ready < 0 || ready.epoch.sequence > newest_sequence) {
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
	mailbox.next_epoch += 1
	if mailbox.next_epoch == 0 {mailbox.next_epoch = 1}
	slot.epoch = graphics_telemetry_begin_epoch(
		&mailbox.telemetry,
		mailbox.next_epoch,
		generation,
		now,
	)
	graphics_frame_epoch_transfer_input_producer_correlation(
		&slot.epoch,
		&coalesced_correlation,
	)
	slot.epoch.lifecycle_generation = mailbox.lifecycle_generation
	slot.producer_sample = producer_sample
	sync.unlock(&mailbox.mu)
	return slot, true
}

frame_mailbox_begin :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> (^Frame_Slot, bool) {
	return frame_mailbox_begin_at(mailbox, generation, time.tick_now(), {})
}

frame_mailbox_commit :: proc(mailbox: ^Frame_Mailbox, slot: ^Frame_Slot, ready: bool) {
	if mailbox == nil || slot == nil {return}
	sync.lock(&mailbox.mu)
	frame_mailbox_ensure_lifecycle_locked(mailbox)
	if ready {
		slot.state = .Ready
		mailbox.published = slot.scanout.generation
		mailbox.has_frame = true
	} else {
		slot.state = .Free
	}
	sync.unlock(&mailbox.mu)
}

frame_mailbox_publish_observed :: proc(
	mailbox: ^Frame_Mailbox,
	source: ^machine.Machine,
	session_generation: u64,
	vm: Graphics_Vm_Execution_Sample,
	postmortem: ^Graphics_Postmortem = nil,
) -> bool {
	if mailbox == nil || source == nil {return false}
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
	if !machine.machine_capture_scanout(source, &slot.scanout) {
		failed_at := time.tick_now()
		graphics_frame_epoch_capture_complete(&slot.epoch, 0, failed_at)
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
		frame_mailbox_commit(mailbox, slot, false)
		return false
	}
	graphics_frame_epoch_descriptor_copy(&slot.epoch, slot.scanout.copy_duration_ns)
	graphics_frame_epoch_capture_complete(&slot.epoch, slot.scanout.bytes_copied, time.tick_now())
	frame_mailbox_commit(mailbox, slot, true)
	if postmortem != nil {
		postmortem_state.host_stage = .Mailbox
		_ = graphics_postmortem_publish_state(postmortem, postmortem_state)
	}
	return true
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
		if slot.state == .Ready && (chosen < 0 || slot.scanout.generation > newest) {
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
	mailbox.has_frame = false
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
