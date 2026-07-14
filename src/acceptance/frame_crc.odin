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

frame_visual_hash :: proc(pixels: []u32, width, height: int) -> u64 {
	if width <= 0 || height <= 0 || width > max(int) / height {return 0}
	if len(pixels) < width * height {return 0}
	hash: u64 = 0xCBF2_9CE4_8422_2325
	hash = (hash ~ u64(width)) * 0x0000_0100_0000_01B3
	hash = (hash ~ u64(height)) * 0x0000_0100_0000_01B3
	for y := 0; y < height; y += 16 {
		for x := 0; x < width; x += 16 {
			pixel := pixels[y * width + x] & 0x00F0_F0F0
			hash = (hash ~ u64(pixel)) * 0x0000_0100_0000_01B3
		}
	}
	return hash
}
