// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "vga"

frame_mailbox_test_frame :: proc(pixels: []u32, width, height: int, generation: u64) -> vga.Display_Frame {
	return vga.Display_Frame {
		width = width,
		height = height,
		aspect_width = 4,
		aspect_height = 3,
		generation = generation,
		content_generation = generation,
		pixels = pixels,
	}
}

@(test)
frame_mailbox_test_reader_never_reused_by_writer :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	one := [4]u32{1, 2, 3, 4}
	frame := frame_mailbox_test_frame(one[:], 2, 2, 1)
	frame_mailbox_publish(&mailbox, &frame)
	reading := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, reading != nil) {return}
	if reading == nil {return}
	testing.expect_value(t, reading.frame.generation, u64(1))

	two := [4]u32{5, 6, 7, 8}
	frame = frame_mailbox_test_frame(two[:], 2, 2, 2)
	frame_mailbox_publish(&mailbox, &frame)
	newest := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, newest != nil) {return}
	if newest == nil {return}
	testing.expect(t, newest != reading)
	testing.expect_value(t, reading.state, Frame_Slot_State.Reading)
	testing.expect_value(t, newest.frame.generation, u64(2))
	testing.expect_value(t, newest.frame.pixels[0], u32(5))
	frame_mailbox_release(&mailbox, reading)
	frame_mailbox_release(&mailbox, newest)
}

@(test)
frame_mailbox_test_reset_accepts_restarted_generation :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	pixel := [1]u32{10}
	frame := frame_mailbox_test_frame(pixel[:], 1, 1, 10)
	frame_mailbox_publish(&mailbox, &frame)
	frame_mailbox_reset(&mailbox)
	pixel[0] = 20
	frame = frame_mailbox_test_frame(pixel[:], 1, 1, 0)
	frame_mailbox_publish(&mailbox, &frame)
	slot := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, slot != nil) {return}
	if slot == nil {return}
	testing.expect_value(t, slot.frame.generation, u64(0))
	testing.expect_value(t, slot.frame.pixels[0], u32(20))
	frame_mailbox_release(&mailbox, slot)
}

@(test)
frame_mailbox_test_dimension_change_retains_storage :: proc(t: ^testing.T) {
	mailbox: Frame_Mailbox
	defer frame_mailbox_destroy(&mailbox)
	large := [8]u32{1, 2, 3, 4, 5, 6, 7, 8}
	frame := frame_mailbox_test_frame(large[:], 4, 2, 1)
	frame_mailbox_publish(&mailbox, &frame)
	slot := frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, slot != nil) {return}
	if slot == nil {return}
	capacity := len(slot.pixels)
	frame_mailbox_release(&mailbox, slot)

	small := [1]u32{9}
	frame = frame_mailbox_test_frame(small[:], 1, 1, 2)
	frame_mailbox_publish(&mailbox, &frame)
	slot = frame_mailbox_acquire(&mailbox)
	if !testing.expect(t, slot != nil) {return}
	if slot == nil {return}
	testing.expect_value(t, len(slot.pixels), capacity)
	testing.expect_value(t, len(slot.frame.pixels), 1)
	testing.expect_value(t, slot.frame.pixels[0], u32(9))
	frame_mailbox_release(&mailbox, slot)
}
