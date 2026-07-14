// SPDX-License-Identifier: GPL-3.0-only
package main

import machine "machine"
import vga "vga"
import "core:sync"

Frame_Slot_State :: enum {
	Free,
	Writing,
	Ready,
	Reading,
}

Frame_Slot :: struct {
	state:   Frame_Slot_State,
	scanout: vga.Scanout_Descriptor,
}

Frame_Mailbox :: struct {
	mu:        sync.Mutex,
	slots:     [2]Frame_Slot,
	published: u64,
	has_frame: bool,
}

frame_mailbox_begin :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> (^Frame_Slot, bool) {
	if mailbox == nil {return nil, false}
	sync.lock(&mailbox.mu)
	if mailbox.has_frame && generation == mailbox.published {
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
		sync.unlock(&mailbox.mu)
		return nil, false
	}
	for &slot, i in mailbox.slots {
		if i != chosen && slot.state == .Ready {slot.state = .Free}
	}
	slot := &mailbox.slots[chosen]
	slot.state = .Writing
	sync.unlock(&mailbox.mu)
	return slot, true
}

frame_mailbox_commit :: proc(mailbox: ^Frame_Mailbox, slot: ^Frame_Slot, ready: bool) {
	if mailbox == nil || slot == nil {return}
	sync.lock(&mailbox.mu)
	if ready {
		slot.state = .Ready
		mailbox.published = slot.scanout.generation
		mailbox.has_frame = true
	} else {
		slot.state = .Free
	}
	sync.unlock(&mailbox.mu)
}

frame_mailbox_publish :: proc(mailbox: ^Frame_Mailbox, source: ^machine.Machine) -> bool {
	if mailbox == nil || source == nil {return false}
	generation := machine.machine_scanout_generation(source)
	slot, reserved := frame_mailbox_begin(mailbox, generation)
	if !reserved {return false}

	if !machine.machine_capture_scanout(source, &slot.scanout) {
		frame_mailbox_commit(mailbox, slot, false)
		return false
	}
	frame_mailbox_commit(mailbox, slot, true)
	return true
}

frame_mailbox_acquire :: proc(mailbox: ^Frame_Mailbox) -> ^Frame_Slot {
	sync.lock(&mailbox.mu)
	defer sync.unlock(&mailbox.mu)
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
	for &slot in mailbox.slots {
		if slot.state == .Ready {slot.state = .Free}
	}
	mailbox.published = 0
	mailbox.has_frame = false
	sync.unlock(&mailbox.mu)
}

frame_mailbox_destroy :: proc(mailbox: ^Frame_Mailbox) {
	if mailbox == nil {return}
	for &slot in mailbox.slots {
		vga.scanout_descriptor_destroy(&slot.scanout)
		slot = {}
	}
	mailbox^ = {}
}
