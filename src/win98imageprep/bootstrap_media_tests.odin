// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
bootstrap_media_test_extracts_fat12_seed_and_normalizes_placeholder :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_media_test_directory(t)
	defer os.remove_all(root)
	path, path_error := filepath.join({root, "boot.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	bootstrap_media_test_write_image(t, path, false)
	seed, diagnostic := image_boot_seed_extract(path)
	defer image_boot_seed_destroy(&seed)
	if !testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.None) {return}
	testing.expect_value(t, len(seed.data[0]), 700)
	testing.expect_value(t, seed.data[0][0], u8(0x49))
	testing.expect_value(t, seed.data[0][512], u8(0x69))
	testing.expect_value(t, string(seed.data[1]), BOOTSTRAP_MSDOS_SYS)
	testing.expect_value(t, len(seed.data[2]), 600)
	testing.expect_value(t, seed.data[2][0], u8(0x43))
	testing.expect_value(t, seed.data[2][512], u8(0x63))
}

@(test)
bootstrap_media_test_recognizes_msdos_placeholders :: proc(t: ^testing.T) {
	fixtures := [?]string{"; \r\n", ";\r\n", "; \n", ";\n", ";FORMAT", ";FORMAT\r\n", ";FORMAT\n"}
	for text in fixtures {
		testing.expect(t, boot_seed_msdos_placeholder(transmute([]u8)text))
	}
	custom := ";FORMAT USER"
	testing.expect(t, !boot_seed_msdos_placeholder(transmute([]u8)custom))
}

@(test)
bootstrap_media_test_rejects_cyclic_fat12_seed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	root := bootstrap_media_test_directory(t)
	defer os.remove_all(root)
	path, path_error := filepath.join({root, "cyclic.img"}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return}
	bootstrap_media_test_write_image(t, path, true)
	seed, diagnostic := image_boot_seed_extract(path)
	defer image_boot_seed_destroy(&seed)
	testing.expect_value(t, diagnostic, Bootstrap_Diagnostic.Boot_Image_Invalid)
	for data in seed.data {testing.expect_value(t, len(data), 0)}
}

@(test)
bootstrap_media_test_fallback_batch_is_language_neutral :: proc(t: ^testing.T) {
	batch := fallback_msbatch()
	testing.expect(t, strings.contains(batch, `Signature="$CHICAGO$"`))
	testing.expect(t, strings.contains(batch, `InstallDir="C:\WINDOWS"`))
	testing.expect(t, strings.contains(batch, "NoPrompt2Boot=1"))
	normalized, ok := normalize_msbatch(batch)
	defer delete(normalized)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(normalized, "OptionalComponents=0"))
	testing.expect(t, strings.contains(normalized, "NoPrompt2Boot=1"))
	testing.expect(t, !strings.contains(normalized, "NoPrompt2Boot=0"))
}

@(test)
bootstrap_media_test_launcher_restores_gui_and_one_shot_autoexec :: proc(t: ^testing.T) {
	launcher := image_launcher_text("INSTALAR.EXE", true, true)
	defer delete(launcher)
	testing.expect(t, strings.has_prefix(launcher, LAUNCHER_MARKER))
	testing.expect(t, strings.contains(launcher, "ECHO BootGUI=1>>C:\\MSDOS.SYS"))
	testing.expect(t, strings.contains(launcher, "IF EXIST C:\\GSWAUTO.PRV GOTO GSWAR"))
	testing.expect(t, strings.contains(launcher, "REN C:\\GSWAUTO.PRV AUTOEXEC.BAT"))
	restore := strings.index(launcher, "REN C:\\GSWAUTO.PRV AUTOEXEC.BAT")
	setup := strings.index(launcher, "INSTALAR.EXE MSBATCH.INF")
	testing.expect(t, restore >= 0 && setup > restore)
}

@(test)
bootstrap_media_test_launcher_hardware_diagnostics_are_explicit :: proc(t: ^testing.T) {
	launcher := image_launcher_text("SETUP.EXE", false, true, true)
	defer delete(launcher)
	testing.expect(t, !strings.contains(launcher, "BootGUI=1"))
	testing.expect(t, strings.contains(launcher, "/P G=3;L=3;P"))
	testing.expect(t, !strings.contains(launcher, ";I"))
	testing.expect(t, !strings.contains(launcher, ";S="))
}

@(private = "file")
bootstrap_media_test_directory :: proc(t: ^testing.T) -> string {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-bootstrap-media-*",
		context.temp_allocator,
	)
	testing.expect_value(t, root_error, os.Error(nil))
	return root
}

@(private = "file")
bootstrap_media_test_write_image :: proc(t: ^testing.T, path: string, cyclic_io: bool) {
	image := make([]u8, 1_474_560, context.temp_allocator)
	defer delete(image, context.temp_allocator)
	image[0], image[1], image[2] = 0xeb, 0x3c, 0x90
	copy(image[3:11], "GSWBOOT ")
	bootstrap_media_test_put16(image, 11, 512)
	image[13] = 1
	bootstrap_media_test_put16(image, 14, 1)
	image[16] = 2
	bootstrap_media_test_put16(image, 17, 224)
	bootstrap_media_test_put16(image, 19, 2880)
	image[21] = 0xf0
	bootstrap_media_test_put16(image, 22, 9)
	bootstrap_media_test_put16(image, 24, 18)
	bootstrap_media_test_put16(image, 26, 2)
	image[510], image[511] = 0x55, 0xaa
	fat_offsets := [?]int{512, 512 + 9 * 512}
	for fat_offset in fat_offsets {
		image[fat_offset], image[fat_offset + 1], image[fat_offset + 2] = 0xf0, 0xff, 0xff
		bootstrap_media_test_fat12_set(
			image[fat_offset:fat_offset + 9 * 512],
			2,
			cyclic_io ? 2 : 3,
		)
		bootstrap_media_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 3, 0xfff)
		bootstrap_media_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 4, 0xfff)
		bootstrap_media_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 5, 6)
		bootstrap_media_test_fat12_set(image[fat_offset:fat_offset + 9 * 512], 6, 0xfff)
	}
	root_offset := 19 * 512
	bootstrap_media_test_root_entry(image[root_offset:], "IO      SYS", 0x06, 2, 700)
	bootstrap_media_test_root_entry(image[root_offset + 32:], "MSDOS   SYS", 0x06, 4, 4)
	bootstrap_media_test_root_entry(image[root_offset + 64:], "COMMAND COM", 0x20, 5, 600)
	data_offset := 33 * 512
	for &value in image[data_offset:data_offset + 512] {value = 0x49}
	for &value in image[data_offset + 512:data_offset + 700] {value = 0x69}
	copy(image[data_offset + 2 * 512:data_offset + 2 * 512 + 4], "; \r\n")
	for &value in image[data_offset + 3 * 512:data_offset + 4 * 512] {value = 0x43}
	for &value in image[data_offset + 4 * 512:data_offset + 4 * 512 + 88] {value = 0x63}
	testing.expect_value(t, os.write_entire_file(path, image), os.Error(nil))
}

@(private = "file")
bootstrap_media_test_root_entry :: proc(
	entry: []u8,
	name: string,
	attributes: u8,
	cluster: u16,
	size: u32,
) {
	copy(entry[:11], name)
	entry[11] = attributes
	bootstrap_media_test_put16(entry, 26, cluster)
	bootstrap_media_test_put32(entry, 28, size)
}

@(private = "file")
bootstrap_media_test_fat12_set :: proc(fat: []u8, cluster, value: int) {
	offset := cluster + cluster / 2
	if (cluster & 1) == 0 {
		fat[offset] = u8(value & 0xff)
		fat[offset + 1] = (fat[offset + 1] & 0xf0) | u8((value >> 8) & 0x0f)
	} else {
		fat[offset] = (fat[offset] & 0x0f) | u8((value << 4) & 0xf0)
		fat[offset + 1] = u8((value >> 4) & 0xff)
	}
}

@(private = "file")
bootstrap_media_test_put16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private = "file")
bootstrap_media_test_put32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}
