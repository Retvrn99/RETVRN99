// SPDX-License-Identifier: GPL-3.0-only
package win98media

import "core:os"
import "core:path/filepath"
import "core:testing"

Fixture_Options :: struct {
	second_edition: bool,
	unsafe_name:    bool,
	with_template:  bool,
}

Fixture_File :: struct {
	name: string,
	data: string,
	lba:  u32,
}

fixture_both_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 8)
	data[offset + 3] = u8(value)
}

fixture_both_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset + 0] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
	data[offset + 4] = u8(value >> 24)
	data[offset + 5] = u8(value >> 16)
	data[offset + 6] = u8(value >> 8)
	data[offset + 7] = u8(value)
}

fixture_record :: proc(data: []u8, offset: ^int, identifier: string, extent, size: u32, directory: bool) {
	length := 33 + len(identifier)
	if len(identifier) % 2 == 0 {
		length += 1
	}
	start := offset^
	data[start] = u8(length)
	fixture_both_u32(data, start + 2, extent)
	fixture_both_u32(data, start + 10, size)
	if directory {
		data[start + 25] = 2
	}
	fixture_both_u16(data, start + 28, 1)
	data[start + 32] = u8(len(identifier))
	copy(data[start + 33:start + 33 + len(identifier)], identifier)
	offset^ += length
}

fixture_directory_header :: proc(data: []u8, lba, parent_lba: u32) -> int {
	offset := int(lba) * ISO_BLOCK_SIZE
	fixture_record(data, &offset, "\x00", lba, ISO_BLOCK_SIZE, true)
	fixture_record(data, &offset, "\x01", parent_lba, ISO_BLOCK_SIZE, true)
	return offset
}

fixture_write_iso :: proc(path: string, options: Fixture_Options) -> os.Error {
	block_count :: 64
	image := make([]u8, block_count * ISO_BLOCK_SIZE)
	defer delete(image)

	pvd := image[16 * ISO_BLOCK_SIZE:17 * ISO_BLOCK_SIZE]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	copy(pvd[40:51], "WIN98SETEST")
	for i in 51 ..< 72 {
		pvd[i] = ' '
	}
	fixture_both_u32(pvd, 80, block_count)
	fixture_both_u16(pvd, 120, 1)
	fixture_both_u16(pvd, 124, 1)
	fixture_both_u16(pvd, 128, ISO_BLOCK_SIZE)
	root_offset := 156
	fixture_record(pvd, &root_offset, "\x00", 20, ISO_BLOCK_SIZE, true)
	terminator := image[17 * ISO_BLOCK_SIZE:18 * ISO_BLOCK_SIZE]
	terminator[0] = 255
	copy(terminator[1:6], "CD001")
	terminator[6] = 1

	root := fixture_directory_header(image, 20, 20)
	fixture_record(image, &root, "WIN98", 21, ISO_BLOCK_SIZE, true)
	fixture_record(image, &root, "TOOLS", 23, ISO_BLOCK_SIZE, true)

	files := make([dynamic]Fixture_File)
	defer delete(files)
	append(
		&files,
		Fixture_File{name = "PRECOPY1.CAB;1", data = "precopy1"},
		Fixture_File{name = "PRECOPY2.CAB;1", data = "precopy2"},
		Fixture_File{name = "BASE4.CAB;1", data = "base4"},
		Fixture_File{name = "OEMSETUP.EXE;1", data = "oem setup"},
		Fixture_File{name = "OEMSETUP.BIN;1", data = "oem binary"},
		Fixture_File{
			name = "INSTALAR.EXE;1",
			data = "MZ synthetic 4.10.2222 setup" if options.second_edition else "MZ synthetic 4.10.1998 setup",
		},
		Fixture_File{name = "INSTALAR.TXT;1", data = "instalacion"},
	)
	if options.unsafe_name {
		append(&files, Fixture_File{name = "..;1", data = "escape"})
	}
	for i in 0 ..< len(files) {
		files[i].lba = u32(30 + i)
	}

	win98 := fixture_directory_header(image, 21, 20)
	fixture_record(image, &win98, "OLS", 22, ISO_BLOCK_SIZE, true)
	for file in files {
		fixture_record(image, &win98, file.name, file.lba, u32(len(file.data)), false)
		start := int(file.lba) * ISO_BLOCK_SIZE
		copy(image[start:start + len(file.data)], file.data)
	}
	ols := fixture_directory_header(image, 22, 21)
	fixture_record(image, &ols, "INFO.TXT;1", 50, 11, false)
	copy(image[50 * ISO_BLOCK_SIZE:50 * ISO_BLOCK_SIZE + 11], "nested file")

	tools := fixture_directory_header(image, 23, 20)
	fixture_record(image, &tools, "SYSREC", 24, ISO_BLOCK_SIZE, true)
	sysrec := fixture_directory_header(image, 24, 23)
	if options.with_template {
		template := "[Setup]\r\nExpress=1"
		fixture_record(image, &sysrec, "MSBATCH.INF;1", 51, u32(len(template)), false)
		copy(image[51 * ISO_BLOCK_SIZE:51 * ISO_BLOCK_SIZE + len(template)], template)
	}
	return os.write_entire_file(path, image)
}

fixture_temp_directory :: proc(t: ^testing.T) -> string {
	base, base_error := os.temp_directory(context.allocator)
	testing.expect(t, base_error == nil)
	directory, directory_error := os.make_directory_temp(base, "retvrn99_installmedia_*", context.allocator)
	testing.expect(t, directory_error == nil)
	return directory
}

@(test)
test_inspect_localized_win98_se :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := fixture_temp_directory(t)
	defer os.remove_all(directory)
	iso_path, _ := filepath.join({directory, "spanish.iso"})
	testing.expect(t, fixture_write_iso(iso_path, {second_edition = true, with_template = true}) == nil)

	info, diagnostic := inspect(iso_path)
	testing.expect_value(t, diagnostic, Diagnostic.None)
	if diagnostic != .None {
		return
	}
	defer media_info_destroy(&info)
	testing.expect_value(t, info.volume_identifier, "WIN98SETEST")
	testing.expect_value(t, info.setup_executable, "INSTALAR.EXE")
	testing.expect(t, info.has_msbatch_template)
	testing.expect_value(t, info.logical_block_size, u32(ISO_BLOCK_SIZE))
	testing.expect_value(t, info.win98_file_count, u32(8))
}

@(test)
test_extract_win98_and_msbatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := fixture_temp_directory(t)
	defer os.remove_all(directory)
	iso_path, _ := filepath.join({directory, "media.iso"})
	testing.expect(t, fixture_write_iso(iso_path, {second_edition = true, with_template = true}) == nil)
	staging, _ := filepath.join({directory, "flat"})
	testing.expect_value(t, extract_win98(iso_path, staging), Diagnostic.None)

	setup_path, _ := filepath.join({staging, "INSTALAR.EXE"})
	setup, setup_error := os.read_entire_file(setup_path, context.allocator)
	testing.expect(t, setup_error == nil)
	testing.expect_value(t, string(setup), "MZ synthetic 4.10.2222 setup")
	nested_path, _ := filepath.join({staging, "OLS", "INFO.TXT"})
	nested, nested_error := os.read_entire_file(nested_path, context.allocator)
	testing.expect(t, nested_error == nil)
	testing.expect_value(t, string(nested), "nested file")

	template_path, _ := filepath.join({directory, "template", "MSBATCH.INF"})
	testing.expect_value(t, extract_msbatch_template(iso_path, template_path), Diagnostic.None)
	template, template_error := os.read_entire_file(template_path, context.allocator)
	testing.expect(t, template_error == nil)
	testing.expect_value(t, string(template), "[Setup]\r\nExpress=1")
}

@(test)
test_rejects_non_se_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := fixture_temp_directory(t)
	defer os.remove_all(directory)
	iso_path, _ := filepath.join({directory, "first-edition.iso"})
	testing.expect(t, fixture_write_iso(iso_path, {with_template = true}) == nil)
	_, diagnostic := inspect(iso_path)
	testing.expect_value(t, diagnostic, Diagnostic.Not_Windows_98_SE)
}

@(test)
test_rejects_unsafe_iso_component :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := fixture_temp_directory(t)
	defer os.remove_all(directory)
	iso_path, _ := filepath.join({directory, "unsafe.iso"})
	testing.expect(t, fixture_write_iso(iso_path, {second_edition = true, unsafe_name = true}) == nil)
	_, diagnostic := inspect(iso_path)
	testing.expect_value(t, diagnostic, Diagnostic.Unsafe_ISO_Path)
	staging, _ := filepath.join({directory, "flat"})
	testing.expect_value(t, extract_win98(iso_path, staging), Diagnostic.Unsafe_ISO_Path)
	testing.expect(t, !os.is_directory(staging))
}

@(test)
test_destination_and_template_diagnostics :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	directory := fixture_temp_directory(t)
	defer os.remove_all(directory)
	iso_path, _ := filepath.join({directory, "media.iso"})
	testing.expect(t, fixture_write_iso(iso_path, {second_edition = true}) == nil)
	staging, _ := filepath.join({directory, "flat"})
	testing.expect(t, os.make_directory(staging) == nil)
	testing.expect_value(t, extract_win98(iso_path, staging), Diagnostic.Destination_Exists)
	template_path, _ := filepath.join({directory, "MSBATCH.INF"})
	testing.expect_value(t, extract_msbatch_template(iso_path, template_path), Diagnostic.Template_Missing)
}
