// SPDX-License-Identifier: GPL-3.0-only
package main

import "cabinetextract"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"
import "fat32image"
import "fat32session"
import "profile"
import "win98imageprep"

INSTALL_ADOPTION_ISO_BLOCK_BYTES :: 2048

Install_Adoption_ISO_File :: struct {
	name: string,
	data: string,
	lba:  u32,
}

@(private = "file")
install_adoption_setup_overlay_extract :: proc(
	_: rawptr,
	_: string,
	first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	if first_cabinet == win98imageprep.TLB_VMM32_FIRST_CABINET {
		if len(requests) != 1 || requests[0].source_name != win98imageprep.TLB_VMM32_NAME {
			return {code = .Target_Missing, request_index = 0}
		}
		data := install_adoption_tlb_w3()
		if os.write_entire_file(requests[0].destination, data) != nil {
			return {code = .Output_Write_Failed, request_index = 0}
		}
		return {extracted_count = 1, request_index = -1}
	}
	if first_cabinet != "PRECOPY2.CAB" {
		return {code = .Unsafe_Cabinet_Name, request_index = -1}
	}
	for request, index in requests {
		data := ""
		switch request.source_name {
		case "MSHDC.INF":
			data = "[ESDI_AddReg]\r\nHKR,,Existing,0,1\r\n"
		case "DISKDRV.INF":
			data = "[DiskReg]\r\nHKR,,Existing,0,1\r\n"
		case:
			return {code = .Target_Missing, request_index = i32(index)}
		}
		if os.write_entire_file(request.destination, data) != nil {
			return {code = .Output_Write_Failed, request_index = i32(index)}
		}
	}
	return {extracted_count = u16(len(requests)), request_index = -1}
}

@(private = "file")
install_adoption_prepare_options :: proc() -> win98imageprep.Prepare_Options {
	options := guided_install_prepare_options()
	options.setup_source_overlay = {
		extract = install_adoption_setup_overlay_extract,
	}
	return options
}

@(private = "file")
install_adoption_put_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

@(private = "file")
install_adoption_put_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

@(private = "file")
install_adoption_tlb_w3 :: proc() -> []u8 {
	PE_OFFSET :: 128
	SIGNATURE_OFFSET :: 512
	data := make([]u8, 2048, context.temp_allocator)
	data[0], data[1] = 'M', 'Z'
	install_adoption_put_u32(data, 60, PE_OFFSET)
	data[PE_OFFSET], data[PE_OFFSET + 1] = 'W', '3'
	install_adoption_put_u16(data, PE_OFFSET + 4, 1)
	copy(
		data[SIGNATURE_OFFSET:SIGNATURE_OFFSET + len(win98imageprep.TLB_UPDATED_V1_ORIGINAL)],
		win98imageprep.TLB_UPDATED_V1_ORIGINAL[:],
	)
	return data
}

@(private = "file")
install_adoption_put_both_u16 :: proc(data: []u8, offset: int, value: u16) {
	install_adoption_put_u16(data, offset, value)
	data[offset + 2] = u8(value >> 8)
	data[offset + 3] = u8(value)
}

@(private = "file")
install_adoption_put_both_u32 :: proc(data: []u8, offset: int, value: u32) {
	install_adoption_put_u32(data, offset, value)
	data[offset + 4] = u8(value >> 24)
	data[offset + 5] = u8(value >> 16)
	data[offset + 6] = u8(value >> 8)
	data[offset + 7] = u8(value)
}

@(private = "file")
install_adoption_iso_record :: proc(
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
	install_adoption_put_both_u32(data, start + 2, extent)
	install_adoption_put_both_u32(data, start + 10, size)
	if directory {data[start + 25] = 2}
	install_adoption_put_both_u16(data, start + 28, 1)
	data[start + 32] = u8(len(identifier))
	copy(data[start + 33:start + 33 + len(identifier)], identifier)
	offset^ += length
}

@(private = "file")
install_adoption_directory_header :: proc(data: []u8, lba, parent_lba: u32) -> int {
	offset := int(lba) * INSTALL_ADOPTION_ISO_BLOCK_BYTES
	install_adoption_iso_record(data, &offset, "\x00", lba, INSTALL_ADOPTION_ISO_BLOCK_BYTES, true)
	install_adoption_iso_record(
		data,
		&offset,
		"\x01",
		parent_lba,
		INSTALL_ADOPTION_ISO_BLOCK_BYTES,
		true,
	)
	return offset
}

@(private = "file")
install_adoption_write_iso :: proc(path: string) -> bool {
	block_count :: 800
	image := make([]u8, block_count * INSTALL_ADOPTION_ISO_BLOCK_BYTES, context.temp_allocator)
	pvd := image[16 * INSTALL_ADOPTION_ISO_BLOCK_BYTES:17 * INSTALL_ADOPTION_ISO_BLOCK_BYTES]
	pvd[0] = 1
	copy(pvd[1:6], "CD001")
	pvd[6] = 1
	copy(pvd[40:51], "WIN98SETEST")
	for index in 51 ..< 72 {pvd[index] = ' '}
	install_adoption_put_both_u32(pvd, 80, block_count)
	install_adoption_put_both_u16(pvd, 120, 1)
	install_adoption_put_both_u16(pvd, 124, 1)
	install_adoption_put_both_u16(pvd, 128, INSTALL_ADOPTION_ISO_BLOCK_BYTES)
	root_offset := 156
	install_adoption_iso_record(
		pvd,
		&root_offset,
		"\x00",
		20,
		INSTALL_ADOPTION_ISO_BLOCK_BYTES,
		true,
	)
	terminator := image[17 *
	INSTALL_ADOPTION_ISO_BLOCK_BYTES:18 *
	INSTALL_ADOPTION_ISO_BLOCK_BYTES]
	terminator[0] = 255
	copy(terminator[1:6], "CD001")
	terminator[6] = 1
	root := install_adoption_directory_header(image, 20, 20)
	install_adoption_iso_record(image, &root, "WIN98", 21, INSTALL_ADOPTION_ISO_BLOCK_BYTES, true)
	install_adoption_iso_record(image, &root, "TOOLS", 23, INSTALL_ADOPTION_ISO_BLOCK_BYTES, true)
	files := [?]Install_Adoption_ISO_File {
		{name = "PRECOPY1.CAB;1", data = "precopy1", lba = 30},
		{name = "PRECOPY2.CAB;1", data = "precopy2", lba = 31},
		{name = "BASE4.CAB;1", data = "base4", lba = 32},
		{name = "OEMSETUP.EXE;1", data = "oem setup", lba = 33},
		{name = "OEMSETUP.BIN;1", data = "oem binary", lba = 34},
		{name = "INSTALAR.EXE;1", data = "MZ synthetic 4.10.2222 setup", lba = 35},
		{name = "INSTALAR.TXT;1", data = "localized setup notes", lba = 36},
	}
	win98 := install_adoption_directory_header(image, 21, 20)
	install_adoption_iso_record(image, &win98, "OLS", 22, INSTALL_ADOPTION_ISO_BLOCK_BYTES, true)
	for file in files {
		install_adoption_iso_record(image, &win98, file.name, file.lba, u32(len(file.data)), false)
		start := int(file.lba) * INSTALL_ADOPTION_ISO_BLOCK_BYTES
		copy(image[start:start + len(file.data)], file.data)
	}
	ols := install_adoption_directory_header(image, 22, 21)
	install_adoption_iso_record(image, &ols, "INFO.TXT;1", 50, 11, false)
	copy(image[50 * INSTALL_ADOPTION_ISO_BLOCK_BYTES:], "nested file")
	tools := install_adoption_directory_header(image, 23, 20)
	install_adoption_iso_record(
		image,
		&tools,
		"SYSREC",
		24,
		INSTALL_ADOPTION_ISO_BLOCK_BYTES,
		true,
	)
	sysrec := install_adoption_directory_header(image, 24, 23)
	template := "[Setup]\r\nExpress=1"
	install_adoption_iso_record(image, &sysrec, "MSBATCH.INF;1", 51, u32(len(template)), false)
	copy(image[51 * INSTALL_ADOPTION_ISO_BLOCK_BYTES:], template)
	return os.write_entire_file(path, image) == nil
}

@(private = "file")
install_adoption_import_file :: proc(
	t: ^testing.T,
	session: ^fat32session.Edit_Session,
	host_path, guest_path, data: string,
) -> bool {
	if !testing.expect_value(
		t,
		os.write_entire_file(host_path, data),
		os.Error(nil),
	) {return false}
	begin_error := fat32session.edit_begin_import_file(session, host_path, guest_path)
	if !testing.expect_value(t, begin_error.code, fat32session.Error_Code.None) {return false}
	for {
		progress, step_error := fat32session.edit_job_step(session)
		if !testing.expect_value(t, step_error.code, fat32session.Error_Code.None) {return false}
		if progress.state == .Complete {return true}
	}
}

@(private = "file")
install_adoption_seed_dos :: proc(t: ^testing.T, root, image_path: string) -> bool {
	session, open_error := fat32session.open_edit(
		image_path,
		"guided-adoption-seed",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return false}
	names := [?]string{"IO.SYS", "MSDOS.SYS", "COMMAND.COM"}
	for name, index in names {
		host_path, path_error := filepath.join(
			{root, strings.to_lower(name)},
			context.temp_allocator,
		)
		if !testing.expect(t, path_error == nil) ||
		   !install_adoption_import_file(
				   t,
				   session,
				   host_path,
				   name,
				   index == 0 ? "IO system" : "DOS system",
			   ) {
			_ = fat32session.edit_finish(session, false)
			return false
		}
	}
	apply_error := fat32session.edit_finish(session, true)
	return testing.expect_value(t, apply_error.code, fat32session.Error_Code.None)
}

@(private = "file")
install_adoption_sector_io :: proc(file: ^os.File, sector: u64, data: []u8, write: bool) -> bool {
	offset := i64(sector * fat32image.SECTOR_BYTES)
	total := 0
	for total < len(data) {
		count: int
		io_error: os.Error
		if write {
			count, io_error = os.write_at(file, data[total:], offset + i64(total))
		} else {
			count, io_error = os.read_at(file, data[total:], offset + i64(total))
		}
		if io_error != nil || count <= 0 {return false}
		total += count
	}
	return true
}

@(private = "file")
install_adoption_externalize :: proc(
	t: ^testing.T,
	image_path: string,
	info: ^fat32session.Image_Info,
) -> (
	original: [fat32image.SECTOR_BYTES]u8,
	ok: bool,
) {
	file, open_error := os.open(image_path, {.Read, .Write})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	defer os.close(file)
	if !install_adoption_sector_io(file, u64(info.partition_lba), original[:], false) {return}
	backup := u16(original[50]) | u16(original[51]) << 8
	copy(original[3:11], "MSDOS5.0")
	copy(original[71:82], "NO NAME    ")
	for &octet in original[90:510] {octet = 0}
	original[90], original[91] = 0xfa, 0xf4
	marker: [fat32image.SECTOR_BYTES]u8
	ok =
		install_adoption_sector_io(file, u64(info.partition_lba), original[:], true) &&
		install_adoption_sector_io(
			file,
			u64(info.partition_lba) + u64(backup),
			original[:],
			true,
		) &&
		install_adoption_sector_io(file, u64(info.marker_sector), marker[:], true) &&
		os.sync(file) == nil
	return
}

@(test)
guided_install_test_compatible_external_image_is_adopted_with_preparation_transaction :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	image_path, image_path_error := filepath.join({root, "external.img"})
	iso_path, iso_path_error := filepath.join({root, "windows98.iso"})
	install_root, install_root_error := filepath.join({root, "install"})
	state_path, state_path_error := filepath.join({root, "install-state.json"})
	if !testing.expect(
		t,
		image_path_error == nil &&
		iso_path_error == nil &&
		install_root_error == nil &&
		state_path_error == nil,
	) {return}
	if !testing.expect(t, install_adoption_write_iso(iso_path)) {return}
	created, create_error := fat32session.create_image(
		{path = image_path, capacity_gib = 1},
		.In_Process,
	)
	if !testing.expect_value(t, create_error.code, fat32session.Error_Code.None) {return}
	defer fat32session.image_info_destroy(&created)
	if !install_adoption_seed_dos(t, root, image_path) {return}
	external_vbr, external_ok := install_adoption_externalize(t, image_path, &created)
	if !testing.expect(t, external_ok) {return}
	compatible, compatible_error := fat32session.validate_image(image_path, .In_Process)
	if !testing.expect_value(t, compatible_error.code, fat32session.Error_Code.None) {return}
	testing.expect(t, !compatible.enrolled && !compatible.retvrn99_format && !compatible.dirty)
	fat32session.image_info_destroy(&compatible)

	model: Guided_Install_Model
	defer guided_install_destroy(&model)
	_ = guided_install_open(&model, image_path)
	action := guided_install_inspect(&model, iso_path, "", .In_Process)
	if !testing.expect_value(t, action.kind, Guided_Install_Action_Kind.None) ||
	   !testing.expect_value(t, model.phase, Guided_Install_Phase.Summary) {
		return
	}
	testing.expect_value(t, model.inspection.boot_source, win98imageprep.Boot_Source.Existing_DOS)
	still_external, summary_error := fat32session.validate_image(image_path, .In_Process)
	if !testing.expect_value(t, summary_error.code, fat32session.Error_Code.None) {return}
	testing.expect(
		t,
		!still_external.enrolled && !still_external.retvrn99_format && !still_external.dirty,
	)
	fat32session.image_info_destroy(&still_external)

	paths := profile.Paths {
		install       = install_root,
		install_state = state_path,
	}
	state: profile.Install_State
	defer profile.install_state_destroy(&state)
	flow := install_image_prepare(
		&paths,
		&state,
		image_path,
		iso_path,
		"",
		nil,
		false,
		install_adoption_prepare_options(),
		{},
		.In_Process,
	)
	defer install_image_flow_result_destroy(&flow)
	if !testing.expect_value(t, flow.error.code, win98imageprep.Error_Code.None) {return}
	testing.expect_value(t, state.phase, profile.Install_Phase.Launch_Pending)
	testing.expect(t, profile.install_state_bound(&state))
	testing.expect_value(
		t,
		state.image_identity,
		profile.Install_Image_Identity(flow.preparation.image_identity),
	)
	testing.expect_value(t, state.edit_transaction_id, flow.preparation.edit_transaction_id)

	adopted, adopted_error := fat32session.validate_image(image_path, .In_Process)
	if !testing.expect_value(t, adopted_error.code, fat32session.Error_Code.None) {return}
	defer fat32session.image_info_destroy(&adopted)
	testing.expect(t, adopted.enrolled && adopted.retvrn99_format && !adopted.dirty)
	file, open_error := os.open(image_path, {.Read})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	adopted_vbr: [fat32image.SECTOR_BYTES]u8
	read_ok := install_adoption_sector_io(file, u64(adopted.partition_lba), adopted_vbr[:], false)
	close_error := os.close(file)
	if !testing.expect(t, read_ok) || !testing.expect_value(t, close_error, os.Error(nil)) {return}
	testing.expect(t, slice.equal(adopted_vbr[11:67], external_vbr[11:67]))
	testing.expect_value(t, string(adopted_vbr[3:11]), "MSWIN4.1")
	testing.expect_value(t, string(adopted_vbr[71:82]), "RETVRN99   ")
	loaded, load_error := profile.install_state_load(state_path)
	defer profile.install_state_destroy(&loaded)
	testing.expect_value(t, load_error, profile.Install_State_Diagnostic.None)
	testing.expect_value(t, loaded.image_identity, state.image_identity)
	testing.expect_value(t, loaded.edit_transaction_id, state.edit_transaction_id)
}

@(test)
install_image_flow_test_unbound_dirty_image_is_rejected_before_install_binding :: proc(
	t: ^testing.T,
) {
	context.allocator = context.temp_allocator
	root := install_test_directory(t)
	defer os.remove_all(root)
	image_path, image_path_error := filepath.join({root, "dirty.img"})
	state_path, state_path_error := filepath.join({root, "install-state.json"})
	if !testing.expect(t, image_path_error == nil && state_path_error == nil) {return}
	created, create_error := fat32session.create_image(
		{path = image_path, capacity_gib = 1},
		.In_Process,
	)
	if !testing.expect_value(t, create_error.code, fat32session.Error_Code.None) {return}
	fat32session.image_info_destroy(&created)
	session, open_error := fat32session.open_edit(image_path, "unbound-dirty", 0, .In_Process)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	retain_error := fat32session.edit_close_retain(session)
	if !testing.expect_value(t, retain_error.code, fat32session.Error_Code.None) {return}
	state: profile.Install_State
	paths := profile.Paths {
		install_state = state_path,
	}
	flow := install_image_prepare(
		&paths,
		&state,
		image_path,
		"unused.iso",
		"",
		nil,
		false,
		{},
		{},
		.In_Process,
	)
	defer install_image_flow_result_destroy(&flow)
	testing.expect_value(t, flow.error.code, win98imageprep.Error_Code.Recovery_Failed)
	testing.expect(t, flow.state_retained)
	testing.expect(t, !profile.install_state_active(&state))
	testing.expect(t, !os.exists(state_path))
}
