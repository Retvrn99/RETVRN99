// SPDX-License-Identifier: GPL-3.0-only
package acceptance

frame_crc32 :: proc(pixels: []u32, width, height: int) -> u32 {
	if width <= 0 || height <= 0 || width > max(int) / height {return 0}
	pixel_count := width * height
	if len(pixels) < pixel_count {return 0}
	crc := ~u32(0)
	for pixel in pixels[:pixel_count] {
		for shift := u32(0); shift < 32; shift += 8 {
			crc ~= (pixel >> shift) & 0xFF
			for _ in 0 ..< 8 {
				mask := u32(0) - (crc & 1)
				crc = (crc >> 1) ~ (0xEDB8_8320 & mask)
			}
		}
	}
	return ~crc
}
