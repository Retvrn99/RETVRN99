// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:testing"

@(test)
acceptance_frame_crc_test_is_full_frame_and_device_independent :: proc(t: ^testing.T) {
	pixels := []u32{0xFF112233, 0xFF445566, 0xFF778899, 0xFFAABBCC}
	testing.expect_value(t, frame_crc32(pixels, 2, 2), u32(0x19EC7DF3))
	testing.expect_value(t, frame_crc32(pixels, 4, 1), u32(0x19EC7DF3))
	testing.expect_value(t, frame_crc32(pixels[:3], 2, 2), u32(0))
	testing.expect_value(t, frame_crc32(pixels, max(int), 2), u32(0))
}

@(test)
acceptance_frame_visual_hash_test_ignores_unsampled_caret_but_sees_page_change :: proc(
	t: ^testing.T,
) {
	pixels: [32 * 32]u32
	before := frame_visual_hash(pixels[:], 32, 32)
	pixels[1 * 32 + 1] = 0x00FF_FFFF
	testing.expect_value(t, frame_visual_hash(pixels[:], 32, 32), before)
	pixels[16 * 32 + 16] = 0x00FF_FFFF
	testing.expect(t, frame_visual_hash(pixels[:], 32, 32) != before)
}
