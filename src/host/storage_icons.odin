// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:bytes"
import "core:image/png"
import sdl3 "vendor:sdl3"

STORAGE_ICON_FLOPPY_PNG := #load("../../assets/icons/floppy.png")
STORAGE_ICON_HARD_DRIVE_PNG := #load("../../assets/icons/hdd.png")
STORAGE_ICON_DVD_ROM_PNG := #load("../../assets/icons/dvdrom.png")

Storage_Icon_Texture :: struct {
	texture: ^sdl3.Texture,
	width:   int,
	height:  int,
}

Storage_Icon_Textures :: struct {
	floppy:     Storage_Icon_Texture,
	hard_drive: Storage_Icon_Texture,
	dvd_rom:    Storage_Icon_Texture,
}

Storage_Icon_Alpha_Bounds :: struct {
	x:      int,
	y:      int,
	width:  int,
	height: int,
}

storage_icon_alpha_bounds :: proc(
	pixels: []u8,
	width, height, channels: int,
) -> (
	Storage_Icon_Alpha_Bounds,
	bool,
) {
	if width <= 0 || height <= 0 || channels < 2 || len(pixels) < width * height * channels {
		return {}, false
	}
	alpha_index := channels - 1
	min_x, min_y := width, height
	max_x, max_y := -1, -1
	for y in 0 ..< height {
		for x in 0 ..< width {
			if pixels[(y * width + x) * channels + alpha_index] == 0 {continue}
			min_x = min(min_x, x)
			min_y = min(min_y, y)
			max_x = max(max_x, x)
			max_y = max(max_y, y)
		}
	}
	if max_x < min_x || max_y < min_y {return {}, false}
	return {x = min_x, y = min_y, width = max_x - min_x + 1, height = max_y - min_y + 1}, true
}

storage_icon_square_bounds :: proc(
	content: Storage_Icon_Alpha_Bounds,
	canvas_width, canvas_height: int,
) -> (
	Storage_Icon_Alpha_Bounds,
	bool,
) {
	size := max(content.width, content.height)
	if size <= 0 ||
	   canvas_width < size ||
	   canvas_height < size ||
	   content.x < 0 ||
	   content.y < 0 ||
	   content.x + content.width > canvas_width ||
	   content.y + content.height > canvas_height {
		return {}, false
	}
	x := content.x + (content.width - size) / 2
	y := content.y + (content.height - size) / 2
	x = clamp(x, 0, canvas_width - size)
	y = clamp(y, 0, canvas_height - size)
	return {x = x, y = y, width = size, height = size}, true
}

@(private = "file")
storage_icon_texture_load :: proc(
	renderer: ^sdl3.Renderer,
	encoded: []u8,
) -> (
	result: Storage_Icon_Texture,
	ok: bool,
) {
	if renderer == nil || len(encoded) == 0 {return {}, false}
	img, decode_error := png.load_from_bytes(encoded, {.alpha_add_if_missing})
	defer png.destroy(img)
	if decode_error != nil || img == nil || img.depth != 8 || img.channels != 4 {
		return {}, false
	}
	pixels := bytes.buffer_to_bytes(&img.pixels)
	content_bounds, content_ok := storage_icon_alpha_bounds(
		pixels,
		img.width,
		img.height,
		img.channels,
	)
	if !content_ok {return {}, false}
	bounds, bounds_ok := storage_icon_square_bounds(content_bounds, img.width, img.height)
	if !bounds_ok {return {}, false}

	texture := sdl3.CreateTexture(
		renderer,
		.RGBA32,
		.STATIC,
		i32(bounds.width),
		i32(bounds.height),
	)
	if texture == nil {return {}, false}
	defer if !ok {sdl3.DestroyTexture(texture)}

	first_pixel := (bounds.y * img.width + bounds.x) * img.channels
	if !sdl3.UpdateTexture(
		   texture,
		   nil,
		   raw_data(pixels[first_pixel:]),
		   i32(img.width * img.channels),
	   ) ||
	   !sdl3.SetTextureBlendMode(texture, sdl3.BLENDMODE_BLEND) ||
	   !sdl3.SetTextureScaleMode(texture, .NEAREST) {
		return {}, false
	}
	return {texture = texture, width = bounds.width, height = bounds.height}, true
}

storage_icon_textures_destroy :: proc(textures: ^Storage_Icon_Textures) {
	if textures == nil {return}
	if textures.floppy.texture != nil {sdl3.DestroyTexture(textures.floppy.texture)}
	if textures.hard_drive.texture != nil {sdl3.DestroyTexture(textures.hard_drive.texture)}
	if textures.dvd_rom.texture != nil {sdl3.DestroyTexture(textures.dvd_rom.texture)}
	textures^ = {}
}

storage_icon_textures_init :: proc(
	textures: ^Storage_Icon_Textures,
	renderer: ^sdl3.Renderer,
) -> bool {
	if textures == nil || renderer == nil {return false}
	storage_icon_textures_destroy(textures)
	floppy, floppy_ok := storage_icon_texture_load(renderer, STORAGE_ICON_FLOPPY_PNG)
	if !floppy_ok {return false}
	textures.floppy = floppy
	hard_drive, hard_drive_ok := storage_icon_texture_load(renderer, STORAGE_ICON_HARD_DRIVE_PNG)
	if !hard_drive_ok {
		storage_icon_textures_destroy(textures)
		return false
	}
	textures.hard_drive = hard_drive
	dvd_rom, dvd_rom_ok := storage_icon_texture_load(renderer, STORAGE_ICON_DVD_ROM_PNG)
	if !dvd_rom_ok {
		storage_icon_textures_destroy(textures)
		return false
	}
	textures.dvd_rom = dvd_rom
	return true
}
