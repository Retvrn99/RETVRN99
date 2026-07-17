// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32image "../fat32image"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

PREP_TEST_ISO_BLOCK_BYTES :: 2048
PREP_TEST_BOOT_BYTES :: 1_474_560

Prep_Test_Media_Options :: struct {
	embedded_boot: bool,
	setup_name:    string,
}

Prep_Test_ISO_File :: struct {
	name: string,
	data: string,
	lba:  u32,
}

prep_test_put_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

prep_test_put_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

prep_test_put_both_u16 :: proc(data: []u8, offset: int, value: u16) {
	prep_test_put_u16(data, offset, value)
	data[offset + 2] = u8(value >> 8)
	data[offset + 3] = u8(value)
}

prep_test_put_both_u32 :: proc(data: []u8, offset: int, value: u32) {
	prep_test_put_u32(data, offset, value)
	data[offset + 4] = u8(value >> 24)
	data[offset + 5] = u8(value >> 16)
	data[offset + 6] = u8(value >> 8)
	data[offset + 7] = u8(value)
}

prep_test_iso_record :: proc(
	data: []u8,
	offset: ^int,
	identifier: string,
	extent, size: u32,
	directory: bool,
) {
	length := 33 + len(identifier)
	if len(identifier) % 2 == 0 {length += 1}
	start := offset^
	data[start] = u8(length)
	prep_test_put_both_u32(data, start + 2, extent)
	prep_test_put_both_u32(data, start + 10, size)
	if directory {data[start + 25] = 2}
	prep_test_put_both_u16(data, start + 28, 1)
	data[start + 32] = u8(len(identifier))
	copy(data[start + 33:start + 33 + len(identifier)], identifier)
	offset^ += length
}

prep_test_directory_header :: proc(data: []u8, lba, parent_lba: u32) -> int {
	offset := int(lba) * PREP_TEST_ISO_BLOCK_BYTES
	prep_test_iso_record(data, &offset, "\x00", lba, PREP_TEST_ISO_BLOCK_BYTES, true)
	prep_test_iso_record(data, &offset, "\x01", parent_lba, PREP_TEST_ISO_BLOCK_BYTES, true)
	return offset
}

prep_test_fat12_set :: proc(fat: []u8, cluster, value: int) {
	offset := cluster + cluster / 2
	if cluster & 1 == 0 {
		fat[offset] = u8(value & 0xff)
		fat[offset + 1] = (fat[offset + 1] & 0xf0) | u8(value >> 8 & 0x0f)
	} else {
		fat[offset] = (fat[offset] & 0x0f) | u8(value << 4 & 0xf0)
		fat[offset + 1] = u8(value >> 4 & 0xff)
	}
}

prep_test_root_entry :: proc(entry: []u8, name: string, attributes: u8, cluster: u16, size: u32) {
	copy(entry[:11], name)
	entry[11] = attributes
	prep_test_put_u16(entry, 26, cluster)
	prep_test_put_u32(entry, 28, size)
}

prep_test_make_boot_image :: proc(data: []u8) -> bool {
	if len(data) != PREP_TEST_BOOT_BYTES {return false}
	for &byte in data {byte = 0}
	data[0], data[1], data[2] = 0xeb, 0x3c, 0x90
	copy(data[3:11], "GSWBOOT ")
	prep_test_put_u16(data, 11, 512)
	data[13] = 1
	prep_test_put_u16(data, 14, 1)
	data[16] = 2
	prep_test_put_u16(data, 17, 224)
	prep_test_put_u16(data, 19, 2880)
	data[21] = 0xf0
	prep_test_put_u16(data, 22, 9)
	prep_test_put_u16(data, 24, 18)
	prep_test_put_u16(data, 26, 2)
	data[510], data[511] = 0x55, 0xaa
	fat_offsets := [?]int{512, 512 + 9 * 512}
	for fat_offset in fat_offsets {
		fat := data[fat_offset:fat_offset + 9 * 512]
		fat[0], fat[1], fat[2] = 0xf0, 0xff, 0xff
		prep_test_fat12_set(fat, 2, 3)
		prep_test_fat12_set(fat, 3, 0xfff)
		prep_test_fat12_set(fat, 4, 0xfff)
		prep_test_fat12_set(fat, 5, 6)
		prep_test_fat12_set(fat, 6, 0xfff)
	}
	root_offset := 19 * 512
	prep_test_root_entry(data[root_offset:], "IO      SYS", 0x06, 2, 700)
	prep_test_root_entry(data[root_offset + 32:], "MSDOS   SYS", 0x06, 4, 4)
	prep_test_root_entry(data[root_offset + 64:], "COMMAND COM", 0x20, 5, 600)
	data_offset := 33 * 512
	for &byte in data[data_offset:data_offset + 512] {byte = 0x49}
	for &byte in data[data_offset + 512:data_offset + 700] {byte = 0x69}
	copy(data[data_offset + 2 * 512:data_offset + 2 * 512 + 4], "; \r\n")
	for &byte in data[data_offset + 3 * 512:data_offset + 4 * 512] {byte = 0x43}
	for &byte in data[data_offset + 4 * 512:data_offset + 4 * 512 + 88] {byte = 0x63}
	return true
}

prep_test_write_boot_image :: proc(path: string) -> bool {
	data := make([]u8, PREP_TEST_BOOT_BYTES, context.temp_allocator)
	if !prep_test_make_boot_image(data) {return false}
	return os.write_entire_file(path, data) == nil
}

prep_test_write_iso :: proc(path: string, options: Prep_Test_Media_Options) -> bool {
	block_count :: 800
	image := make([]u8, block_count * PREP_TEST_ISO_BLOCK_BYTES, context.temp_allocator)
	setup_name := options.setup_name
	if setup_name == "" {setup_name = "INSTALAR"}
	pvd := image[16 * PREP_TEST_ISO_BLOCK_BYTES:17 * PREP_TEST_ISO_BLOCK_BYTES]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	copy(pvd[40:51], "WIN98SETEST")
	for index in 51 ..< 72 {pvd[index] = ' '}
	prep_test_put_both_u32(pvd, 80, block_count)
	prep_test_put_both_u16(pvd, 120, 1)
	prep_test_put_both_u16(pvd, 124, 1)
	prep_test_put_both_u16(pvd, 128, PREP_TEST_ISO_BLOCK_BYTES)
	root_offset := 156
	prep_test_iso_record(pvd, &root_offset, "\x00", 20, PREP_TEST_ISO_BLOCK_BYTES, true)
	descriptor_lba := 17
	if options.embedded_boot {
		boot_record := image[17 * PREP_TEST_ISO_BLOCK_BYTES:18 * PREP_TEST_ISO_BLOCK_BYTES]
		boot_record[0] = 0
		copy(boot_record[1:6], "CD001")
		boot_record[6] = 1
		copy(boot_record[7:30], "EL TORITO SPECIFICATION")
		prep_test_put_u32(boot_record, 71, 60)
		catalog := image[60 * PREP_TEST_ISO_BLOCK_BYTES:61 * PREP_TEST_ISO_BLOCK_BYTES]
		catalog[0] = 1
		catalog[30], catalog[31] = 0x55, 0xaa
		sum: u16
		for index in 0 ..< 16 {
			sum += u16(catalog[index * 2]) | u16(catalog[index * 2 + 1]) << 8
		}
		checksum := -sum
		prep_test_put_u16(catalog, 28, checksum)
		entry := catalog[32:64]
		entry[0], entry[1] = 0x88, 2
		prep_test_put_u16(entry, 6, 1)
		prep_test_put_u32(entry, 8, 61)
		boot_start := 61 * PREP_TEST_ISO_BLOCK_BYTES
		if !prep_test_make_boot_image(image[boot_start:boot_start + PREP_TEST_BOOT_BYTES]) {
			return false
		}
		descriptor_lba = 18
	}
	terminator := image[descriptor_lba *
	PREP_TEST_ISO_BLOCK_BYTES:(descriptor_lba + 1) *
	PREP_TEST_ISO_BLOCK_BYTES]
	terminator[0] = 255
	copy(terminator[1:6], "CD001")
	terminator[6] = 1
	root := prep_test_directory_header(image, 20, 20)
	prep_test_iso_record(image, &root, "WIN98", 21, PREP_TEST_ISO_BLOCK_BYTES, true)
	prep_test_iso_record(image, &root, "TOOLS", 23, PREP_TEST_ISO_BLOCK_BYTES, true)
	files := [?]Prep_Test_ISO_File {
		{name = "PRECOPY1.CAB;1", data = "precopy1", lba = 30},
		{name = "PRECOPY2.CAB;1", data = "precopy2", lba = 31},
		{name = "BASE4.CAB;1", data = "base4", lba = 32},
		{name = "OEMSETUP.EXE;1", data = "oem setup", lba = 33},
		{name = "OEMSETUP.BIN;1", data = "oem binary", lba = 34},
		{name = "", data = "MZ synthetic 4.10.2222 setup", lba = 35},
		{name = "", data = "localized setup notes", lba = 36},
	}
	files[5].name = fmt.tprintf("%s.EXE;1", setup_name)
	files[6].name = fmt.tprintf("%s.TXT;1", setup_name)
	win98 := prep_test_directory_header(image, 21, 20)
	prep_test_iso_record(image, &win98, "OLS", 22, PREP_TEST_ISO_BLOCK_BYTES, true)
	for file in files {
		prep_test_iso_record(image, &win98, file.name, file.lba, u32(len(file.data)), false)
		start := int(file.lba) * PREP_TEST_ISO_BLOCK_BYTES
		copy(image[start:start + len(file.data)], file.data)
	}
	ols := prep_test_directory_header(image, 22, 21)
	prep_test_iso_record(image, &ols, "INFO.TXT;1", 50, 11, false)
	copy(image[50 * PREP_TEST_ISO_BLOCK_BYTES:50 * PREP_TEST_ISO_BLOCK_BYTES + 11], "nested file")
	tools := prep_test_directory_header(image, 23, 20)
	prep_test_iso_record(image, &tools, "SYSREC", 24, PREP_TEST_ISO_BLOCK_BYTES, true)
	sysrec := prep_test_directory_header(image, 24, 23)
	template := "[Setup]\r\nExpress=1"
	prep_test_iso_record(image, &sysrec, "MSBATCH.INF;1", 51, u32(len(template)), false)
	copy(
		image[51 * PREP_TEST_ISO_BLOCK_BYTES:51 * PREP_TEST_ISO_BLOCK_BYTES + len(template)],
		template,
	)
	return os.write_entire_file(path, image) == nil
}

Prep_Test_Environment :: struct {
	root:         string,
	scratch:      string,
	image_path:   string,
	iso_path:     string,
	floppy_path:  string,
	created_info: fat32image.Image_Info,
}

prep_test_environment :: proc(
	t: ^testing.T,
	options: Prep_Test_Media_Options,
) -> (
	Prep_Test_Environment,
	bool,
) {
	root, root_error := os.make_directory_temp("", "retvrn99-win98imageprep-*", context.allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return {}, false}
	environment := Prep_Test_Environment {
		root = root,
	}
	join_error: runtime.Allocator_Error
	environment.scratch, join_error = filepath.join({root, "bounded-scratch"})
	if join_error ==
	   nil {environment.image_path, join_error = filepath.join({root, "c_drive.img"})}
	if join_error ==
	   nil {environment.iso_path, join_error = filepath.join({root, "windows98.iso"})}
	if join_error == nil {environment.floppy_path, join_error = filepath.join({root, "boot.img"})}
	if !testing.expect(t, join_error == nil) {
		prep_test_environment_destroy(&environment)
		return {}, false
	}
	if !testing.expect(t, prep_test_write_iso(environment.iso_path, options)) {
		prep_test_environment_destroy(&environment)
		return {}, false
	}
	if !testing.expect(t, prep_test_write_boot_image(environment.floppy_path)) {
		prep_test_environment_destroy(&environment)
		return {}, false
	}
	create_error: fat32image.Image_Error
	environment.created_info, create_error = fat32image.create(
		{path = environment.image_path, capacity_gib = 1},
	)
	if !testing.expect_value(t, create_error.code, fat32image.Error_Code.None) {
		prep_test_environment_destroy(&environment)
		return {}, false
	}
	return environment, true
}

prep_test_environment_destroy :: proc(environment: ^Prep_Test_Environment) {
	if environment == nil {return}
	fat32image.info_destroy(&environment.created_info)
	if environment.root != "" {_ = os.remove_all(environment.root)}
	delete(environment.root)
	delete(environment.scratch)
	delete(environment.image_path)
	delete(environment.iso_path)
	delete(environment.floppy_path)
	environment^ = {}
}
