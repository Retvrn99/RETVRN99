// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:bytes"
import "core:image/png"
import sdl3 "vendor:sdl3"

UI_ICON_COMPUTER_16_PNG := #load("../../assets/icons/chicago95/16/computer.png")
UI_ICON_HARD_DRIVE_16_PNG := #load("../../assets/icons/chicago95/16/hard-drive.png")
UI_ICON_DVD_ROM_16_PNG := #load("../../assets/icons/chicago95/16/optical-drive.png")
UI_ICON_FLOPPY_16_PNG := #load("../../assets/icons/chicago95/16/floppy-drive.png")
UI_ICON_FOLDER_16_PNG := #load("../../assets/icons/chicago95/16/folder.png")
UI_ICON_FOLDER_OPEN_16_PNG := #load("../../assets/icons/chicago95/16/folder-open.png")
UI_ICON_GENERIC_FILE_16_PNG := #load("../../assets/icons/chicago95/16/generic-file.png")
UI_ICON_TEXT_FILE_16_PNG := #load("../../assets/icons/chicago95/16/text-file.png")
UI_ICON_EXECUTABLE_16_PNG := #load("../../assets/icons/chicago95/16/executable.png")

UI_ICON_COMPUTER_32_PNG := #load("../../assets/icons/chicago95/32/computer.png")
UI_ICON_HARD_DRIVE_32_PNG := #load("../../assets/icons/chicago95/32/hard-drive.png")
UI_ICON_DVD_ROM_32_PNG := #load("../../assets/icons/chicago95/32/optical-drive.png")
UI_ICON_FLOPPY_32_PNG := #load("../../assets/icons/chicago95/32/floppy-drive.png")
UI_ICON_SETTINGS_32_PNG := #load("../../assets/icons/chicago95/32/settings.png")
UI_ICON_SOUND_32_PNG := #load("../../assets/icons/chicago95/32/sound.png")
UI_ICON_ERROR_32_PNG := #load("../../assets/icons/chicago95/32/error.png")
UI_ICON_WARNING_32_PNG := #load("../../assets/icons/chicago95/32/warning.png")

Ui_Icon_Role :: enum {
	Computer_16,
	Computer_32,
	Hard_Drive_16,
	Hard_Drive_32,
	Dvd_Rom_16,
	Dvd_Rom_32,
	Floppy_16,
	Floppy_32,
	Folder_16,
	Folder_Open_16,
	Generic_File_16,
	Text_File_16,
	Executable_16,
	Settings_32,
	Sound_32,
	Error_32,
	Warning_32,
}

Ui_Icon_Texture :: struct {
	texture: ^sdl3.Texture,
	width:   int,
	height:  int,
}

Ui_Icon_Textures :: struct {
	computer_16:     Ui_Icon_Texture,
	computer_32:     Ui_Icon_Texture,
	hard_drive_16:   Ui_Icon_Texture,
	hard_drive_32:   Ui_Icon_Texture,
	dvd_rom_16:      Ui_Icon_Texture,
	dvd_rom_32:      Ui_Icon_Texture,
	floppy_16:       Ui_Icon_Texture,
	floppy_32:       Ui_Icon_Texture,
	folder_16:       Ui_Icon_Texture,
	folder_open_16:  Ui_Icon_Texture,
	generic_file_16: Ui_Icon_Texture,
	text_file_16:    Ui_Icon_Texture,
	executable_16:   Ui_Icon_Texture,
	settings_32:     Ui_Icon_Texture,
	sound_32:        Ui_Icon_Texture,
	error_32:        Ui_Icon_Texture,
	warning_32:      Ui_Icon_Texture,
}

Storage_Icon_Texture :: Ui_Icon_Texture
Storage_Icon_Textures :: Ui_Icon_Textures

@(private = "file")
ui_icon_texture_load :: proc(renderer: ^sdl3.Renderer, encoded: []u8) -> (result: Ui_Icon_Texture, ok: bool) {
	if renderer == nil || len(encoded) == 0 {return {}, false}
	img, decode_error := png.load_from_bytes(encoded, {.alpha_add_if_missing})
	defer png.destroy(img)
	if decode_error != nil || img == nil || img.depth != 8 || img.channels != 4 {
		return {}, false
	}
	pixels := bytes.buffer_to_bytes(&img.pixels)
	texture := sdl3.CreateTexture(renderer, .RGBA32, .STATIC, i32(img.width), i32(img.height))
	if texture == nil {return {}, false}
	defer if !ok {sdl3.DestroyTexture(texture)}
	if !sdl3.UpdateTexture(texture, nil, raw_data(pixels), i32(img.width * img.channels)) ||
	   !sdl3.SetTextureBlendMode(texture, sdl3.BLENDMODE_BLEND) ||
	   !sdl3.SetTextureScaleMode(texture, .NEAREST) {
		return {}, false
	}
	return {texture = texture, width = img.width, height = img.height}, true
}

ui_icon_texture :: proc(textures: ^Ui_Icon_Textures, role: Ui_Icon_Role) -> Ui_Icon_Texture {
	if textures == nil {return {}}
	switch role {
	case .Computer_16:     return textures.computer_16
	case .Computer_32:     return textures.computer_32
	case .Hard_Drive_16:   return textures.hard_drive_16
	case .Hard_Drive_32:   return textures.hard_drive_32
	case .Dvd_Rom_16:      return textures.dvd_rom_16
	case .Dvd_Rom_32:      return textures.dvd_rom_32
	case .Floppy_16:       return textures.floppy_16
	case .Floppy_32:       return textures.floppy_32
	case .Folder_16:       return textures.folder_16
	case .Folder_Open_16:  return textures.folder_open_16
	case .Generic_File_16: return textures.generic_file_16
	case .Text_File_16:    return textures.text_file_16
	case .Executable_16:   return textures.executable_16
	case .Settings_32:     return textures.settings_32
	case .Sound_32:        return textures.sound_32
	case .Error_32:        return textures.error_32
	case .Warning_32:      return textures.warning_32
	}
	return {}
}

ui_icon_texture_destroy :: proc(icon: ^Ui_Icon_Texture) {
	if icon == nil {return}
	if icon.texture != nil {sdl3.DestroyTexture(icon.texture)}
	icon^ = {}
}

ui_icon_textures_destroy :: proc(textures: ^Ui_Icon_Textures) {
	if textures == nil {return}
	ui_icon_texture_destroy(&textures.computer_16)
	ui_icon_texture_destroy(&textures.computer_32)
	ui_icon_texture_destroy(&textures.hard_drive_16)
	ui_icon_texture_destroy(&textures.hard_drive_32)
	ui_icon_texture_destroy(&textures.dvd_rom_16)
	ui_icon_texture_destroy(&textures.dvd_rom_32)
	ui_icon_texture_destroy(&textures.floppy_16)
	ui_icon_texture_destroy(&textures.floppy_32)
	ui_icon_texture_destroy(&textures.folder_16)
	ui_icon_texture_destroy(&textures.folder_open_16)
	ui_icon_texture_destroy(&textures.generic_file_16)
	ui_icon_texture_destroy(&textures.text_file_16)
	ui_icon_texture_destroy(&textures.executable_16)
	ui_icon_texture_destroy(&textures.settings_32)
	ui_icon_texture_destroy(&textures.sound_32)
	ui_icon_texture_destroy(&textures.error_32)
	ui_icon_texture_destroy(&textures.warning_32)
	textures^ = {}
}

storage_icon_textures_destroy :: proc(textures: ^Storage_Icon_Textures) {
	ui_icon_textures_destroy(textures)
}

@(private = "file")
ui_icon_texture_assign :: proc(
	textures: ^Ui_Icon_Textures,
	destination: ^Ui_Icon_Texture,
	renderer: ^sdl3.Renderer,
	encoded: []u8,
) -> bool {
	icon, ok := ui_icon_texture_load(renderer, encoded)
	if !ok {
		ui_icon_textures_destroy(textures)
		return false
	}
	destination^ = icon
	return true
}

ui_icon_textures_init :: proc(textures: ^Ui_Icon_Textures, renderer: ^sdl3.Renderer) -> bool {
	if textures == nil || renderer == nil {return false}
	ui_icon_textures_destroy(textures)
	return(
		ui_icon_texture_assign(textures, &textures.computer_16, renderer, UI_ICON_COMPUTER_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.computer_32, renderer, UI_ICON_COMPUTER_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.hard_drive_16, renderer, UI_ICON_HARD_DRIVE_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.hard_drive_32, renderer, UI_ICON_HARD_DRIVE_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.dvd_rom_16, renderer, UI_ICON_DVD_ROM_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.dvd_rom_32, renderer, UI_ICON_DVD_ROM_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.floppy_16, renderer, UI_ICON_FLOPPY_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.floppy_32, renderer, UI_ICON_FLOPPY_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.folder_16, renderer, UI_ICON_FOLDER_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.folder_open_16, renderer, UI_ICON_FOLDER_OPEN_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.generic_file_16, renderer, UI_ICON_GENERIC_FILE_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.text_file_16, renderer, UI_ICON_TEXT_FILE_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.executable_16, renderer, UI_ICON_EXECUTABLE_16_PNG) &&
		ui_icon_texture_assign(textures, &textures.settings_32, renderer, UI_ICON_SETTINGS_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.sound_32, renderer, UI_ICON_SOUND_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.error_32, renderer, UI_ICON_ERROR_32_PNG) &&
		ui_icon_texture_assign(textures, &textures.warning_32, renderer, UI_ICON_WARNING_32_PNG)
	)
}

storage_icon_textures_init :: proc(
	textures: ^Storage_Icon_Textures,
	renderer: ^sdl3.Renderer,
) -> bool {
	return ui_icon_textures_init(textures, renderer)
}

ui_window_icon_apply :: proc(window: ^sdl3.Window) -> bool {
	if window == nil {return false}
	img, decode_error := png.load_from_bytes(UI_ICON_COMPUTER_32_PNG, {.alpha_add_if_missing})
	defer png.destroy(img)
	if decode_error != nil || img == nil || img.depth != 8 || img.channels != 4 {return false}
	pixels := bytes.buffer_to_bytes(&img.pixels)
	surface := sdl3.CreateSurfaceFrom(
		i32(img.width),
		i32(img.height),
		.RGBA32,
		raw_data(pixels),
		i32(img.width * img.channels),
	)
	if surface == nil {return false}
	defer sdl3.DestroySurface(surface)
	return sdl3.SetWindowIcon(window, surface)
}
