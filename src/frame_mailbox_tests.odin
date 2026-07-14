// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"

frame_mailbox_test_publish_generation :: proc(mailbox: ^Frame_Mailbox, generation: u64) -> bool {
	slot, reserved := frame_mailbox_begin(mailbox, generation)
	if !reserved {return false}
	slot.scanout.generation = generation
	frame_mailbox_commit(mailbox, slot, true)
	return true
}

@(test)
frame_mailbox_test_reader_never_reused_by_writer :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 1))
	reading := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, reading != nil) {return}
	testing.expect_value(t, reading.scanout.generation, u64(1))

	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 2))
	newest := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, newest != nil) {return}
	testing.expect(t, newest != reading)
	testing.expect_value(t, reading.state, Frame_Slot_State.Reading)
	testing.expect_value(t, newest.scanout.generation, u64(2))
	frame_mailbox_release(&mailbox, reading)
	frame_mailbox_release(&mailbox, newest)
}

@(test)
frame_mailbox_test_reset_accepts_restarted_generation :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 10))
	frame_mailbox_reset(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 0))
	slot := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, slot != nil) {return}
	testing.expect_value(t, slot.scanout.generation, u64(0))
	frame_mailbox_release(&mailbox, slot)
}

@(test)
frame_mailbox_test_ready_frames_coalesce_to_latest :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 1))
	testing.expect(t, frame_mailbox_test_publish_generation(&mailbox, 2))
	newest := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, newest != nil) {return}
	testing.expect_value(t, newest.scanout.generation, u64(2))
	testing.expect(t, !frame_mailbox_test_publish_generation(&mailbox, 2))
	frame_mailbox_release(&mailbox, newest)
}
