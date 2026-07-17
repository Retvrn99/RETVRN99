#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

import "core:bytes"
import "core:os"
import "core:path/filepath"
import "core:testing"

CABINET_TEST_INF :: "[Version]\r\nSignature=\"$CHICAGO$\"\r\n"
CABINET_TEST_BINARY :: "RETVRN99-CABINET-FIXTURE"

Cabinet_Test_Fixture :: struct {
	root:    string,
	cabinet: string,
}

Cabinet_Chain_Test_Fixture :: struct {
	root:  string,
	early: []u8,
}

@(private)
cabinet_test_path :: proc(root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	return path, path_error == nil
}

@(private)
cabinet_test_fixture_create :: proc(t: ^testing.T) -> (Cabinet_Test_Fixture, bool) {
	root, root_error := os.make_directory_temp("", "retvrn99-cabinet-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return {}, false}
	input_inf, inf_path_ok := cabinet_test_path(root, "INPUT_A.TXT")
	input_binary, binary_path_ok := cabinet_test_path(root, "INPUT_B.TXT")
	ddf_path, ddf_path_ok := cabinet_test_path(root, "fixture.ddf")
	cabinet_path, cabinet_path_ok := cabinet_test_path(root, "FIXTURE.CAB")
	if !testing.expect(t, inf_path_ok && binary_path_ok && ddf_path_ok && cabinet_path_ok) {
		_ = os.remove_all(root)
		return {}, false
	}
	ddf :=
		".OPTION EXPLICIT\r\n" +
		".Set CabinetNameTemplate=FIXTURE.CAB\r\n" +
		".Set DiskDirectoryTemplate=.\r\n" +
		".Set CompressionType=LZX\r\n" +
		".Set CompressionMemory=15\r\n" +
		".Set Cabinet=on\r\n" +
		".Set Compress=on\r\n" +
		"INPUT_A.TXT MIXED.INF\r\n" +
		"INPUT_B.TXT SECOND.SYS\r\n"
	if !testing.expect_value(
		   t,
		   os.write_entire_file(input_inf, CABINET_TEST_INF),
		   os.Error(nil),
	   ) ||
	   !testing.expect_value(
			   t,
			   os.write_entire_file(input_binary, CABINET_TEST_BINARY),
			   os.Error(nil),
		   ) ||
	   !testing.expect_value(t, os.write_entire_file(ddf_path, ddf), os.Error(nil)) {
		_ = os.remove_all(root)
		return {}, false
	}
	state, stdout, stderr, launch_error := os.process_exec(
		os.Process_Desc {
			working_dir = root,
			command = []string{"makecab.exe", "/F", "fixture.ddf"},
		},
		context.temp_allocator,
	)
	_ = stdout
	if launch_error != nil {
		_ = os.remove_all(root)
		return {}, false
	}
	if !testing.expectf(
		   t,
		   state.exited && state.exit_code == 0,
		   "makecab fixture failed with exit %d: %s",
		   state.exit_code,
		   string(stderr),
	   ) ||
	   !testing.expect(t, os.is_file(cabinet_path)) {
		_ = os.remove_all(root)
		return {}, false
	}
	return {root = root, cabinet = cabinet_path}, true
}

@(private)
cabinet_test_fixture_destroy :: proc(fixture: ^Cabinet_Test_Fixture) {
	if fixture != nil && fixture.root != "" {_ = os.remove_all(fixture.root)}
}

@(private)
cabinet_chain_test_bytes :: proc(size: int, seed: u32) -> []u8 {
	result := make([]u8, size, context.temp_allocator)
	state := seed
	for &byte in result {
		state ~= state << 13
		state ~= state >> 17
		state ~= state << 5
		byte = u8(state >> 24)
	}
	return result
}

@(private)
cabinet_chain_test_fixture_create :: proc(t: ^testing.T) -> (Cabinet_Chain_Test_Fixture, bool) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-cabinet-chain-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return {}, false}
	early_input, early_ok := cabinet_test_path(root, "EARLY_INPUT.BIN")
	middle_input, middle_ok := cabinet_test_path(root, "MIDDLE_INPUT.BIN")
	later_input, later_ok := cabinet_test_path(root, "LATER_INPUT.TXT")
	ddf_path, ddf_ok := cabinet_test_path(root, "chain.ddf")
	if !testing.expect(t, early_ok && middle_ok && later_ok && ddf_ok) {
		_ = os.remove_all(root)
		return {}, false
	}
	early := cabinet_chain_test_bytes(45_000, 0x7A31_58C9)
	middle := cabinet_chain_test_bytes(25_000, 0x19B4_E20D)
	ddf :=
		".OPTION EXPLICIT\r\n" +
		".Set CabinetNameTemplate=CHAIN*.CAB\r\n" +
		".Set DiskDirectoryTemplate=.\r\n" +
		".Set DiskDirectory1=.\r\n" +
		".Set DiskDirectory2=.\r\n" +
		".Set DiskDirectory3=.\r\n" +
		".Set DiskDirectory4=.\r\n" +
		".Set MaxDiskSize=32768\r\n" +
		".Set FolderSizeThreshold=1000000\r\n" +
		".Set CompressionType=LZX\r\n" +
		".Set CompressionMemory=15\r\n" +
		".Set Cabinet=on\r\n" +
		".Set Compress=on\r\n" +
		"EARLY_INPUT.BIN EARLY.BIN\r\n" +
		".New Folder\r\n" +
		"MIDDLE_INPUT.BIN MIDDLE.BIN\r\n" +
		".New Folder\r\n" +
		"LATER_INPUT.TXT LATER.INF\r\n"
	if !testing.expect_value(t, os.write_entire_file(early_input, early), os.Error(nil)) ||
	   !testing.expect_value(t, os.write_entire_file(middle_input, middle), os.Error(nil)) ||
	   !testing.expect_value(
			   t,
			   os.write_entire_file(later_input, "later-target"),
			   os.Error(nil),
		   ) ||
	   !testing.expect_value(t, os.write_entire_file(ddf_path, ddf), os.Error(nil)) {
		_ = os.remove_all(root)
		return {}, false
	}
	state, stdout, stderr, launch_error := os.process_exec(
		os.Process_Desc{working_dir = root, command = []string{"makecab.exe", "/F", "chain.ddf"}},
		context.temp_allocator,
	)
	_ = stdout
	if launch_error != nil {
		_ = os.remove_all(root)
		return {}, false
	}
	chain_1, chain_1_ok := cabinet_test_path(root, "CHAIN1.CAB")
	chain_2, chain_2_ok := cabinet_test_path(root, "CHAIN2.CAB")
	chain_3, chain_3_ok := cabinet_test_path(root, "CHAIN3.CAB")
	if !testing.expectf(
		   t,
		   state.exited && state.exit_code == 0,
		   "makecab chain fixture failed with exit %d: %s",
		   state.exit_code,
		   string(stderr),
	   ) ||
	   !testing.expectf(
			   t,
			   chain_1_ok &&
			   chain_2_ok &&
			   chain_3_ok &&
			   os.is_file(chain_1) &&
			   os.is_file(chain_2) &&
			   os.is_file(chain_3),
			   "makecab chain fixture at %s did not produce three root cabinets; output: %s",
			   root,
			   string(stdout),
		   ) {
		_ = os.remove_all(root)
		return {}, false
	}
	return {root = root, early = early}, true
}

@(test)
cabinetextract_windows_test_fdi_extracts_exact_case_insensitive_targets :: proc(t: ^testing.T) {
	fixture, created := cabinet_test_fixture_create(t)
	if !created {return}
	defer cabinet_test_fixture_destroy(&fixture)
	inf_destination, inf_path_ok := cabinet_test_path(fixture.root, "OUT.INF")
	binary_destination, binary_path_ok := cabinet_test_path(fixture.root, "OUT.SYS")
	if !testing.expect(t, inf_path_ok && binary_path_ok) {return}
	requests := []Setup_Source_Extract_Request {
		{source_name = "mixed.inf", destination = inf_destination, max_output_bytes = 1024},
		{source_name = "SECOND.sys", destination = binary_destination, max_output_bytes = 1024},
	}
	diagnostic := setup_source_extract_files(fixture.root, "fixture.cab", requests)
	if !testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.None) {return}
	testing.expect_value(t, diagnostic.extracted_count, u16(2))
	testing.expect_value(t, diagnostic.cabinet_count, u16(1))
	inf, inf_error := os.read_entire_file(inf_destination, context.temp_allocator)
	binary, binary_error := os.read_entire_file(binary_destination, context.temp_allocator)
	testing.expect_value(t, inf_error, os.Error(nil))
	testing.expect_value(t, binary_error, os.Error(nil))
	testing.expect_value(t, string(inf), CABINET_TEST_INF)
	testing.expect_value(t, string(binary), CABINET_TEST_BINARY)
}

@(test)
cabinetextract_windows_test_spanned_target_advances_to_successor_cabinet :: proc(t: ^testing.T) {
	fixture, created := cabinet_chain_test_fixture_create(t)
	if !created {return}
	defer os.remove_all(fixture.root)
	early_destination, early_ok := cabinet_test_path(fixture.root, "EARLY-OUT.BIN")
	later_destination, later_ok := cabinet_test_path(fixture.root, "LATER-OUT.INF")
	if !testing.expect(t, early_ok && later_ok) {return}
	requests := []Setup_Source_Extract_Request {
		{source_name = "EARLY.BIN", destination = early_destination, max_output_bytes = 64 * 1024},
		{source_name = "LATER.INF", destination = later_destination, max_output_bytes = 1024},
	}
	diagnostic := setup_source_extract_files(fixture.root, "CHAIN1.CAB", requests)
	if !testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.None) {return}
	testing.expect_value(t, diagnostic.extracted_count, u16(2))
	testing.expect_value(t, diagnostic.cabinet_count, u16(2))
	early, early_error := os.read_entire_file(early_destination, context.temp_allocator)
	later, later_error := os.read_entire_file(later_destination, context.temp_allocator)
	testing.expect_value(t, early_error, os.Error(nil))
	testing.expect_value(t, later_error, os.Error(nil))
	testing.expect(t, bytes.equal(early, fixture.early))
	testing.expect_value(t, string(later), "later-target")
}

@(test)
cabinetextract_windows_test_fdi_enforces_output_limit_without_creating_target :: proc(
	t: ^testing.T,
) {
	fixture, created := cabinet_test_fixture_create(t)
	if !created {return}
	defer cabinet_test_fixture_destroy(&fixture)
	destination, path_ok := cabinet_test_path(fixture.root, "TOO-SMALL.INF")
	if !testing.expect(t, path_ok) {return}
	requests := []Setup_Source_Extract_Request {
		{source_name = "MIXED.INF", destination = destination, max_output_bytes = 4},
	}
	diagnostic := setup_source_extract_files(fixture.root, "FIXTURE.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Output_Limit_Exceeded)
	testing.expect_value(t, diagnostic.request_index, i32(0))
	testing.expect(t, !os.exists(destination))
}

@(test)
cabinetextract_windows_test_failure_cleans_completed_outputs :: proc(t: ^testing.T) {
	fixture, created := cabinet_test_fixture_create(t)
	if !created {return}
	defer cabinet_test_fixture_destroy(&fixture)
	first_destination, first_path_ok := cabinet_test_path(fixture.root, "FIRST.INF")
	missing_destination, missing_path_ok := cabinet_test_path(fixture.root, "MISSING.INF")
	if !testing.expect(t, first_path_ok && missing_path_ok) {return}
	requests := []Setup_Source_Extract_Request {
		{source_name = "MIXED.INF", destination = first_destination, max_output_bytes = 1024},
		{source_name = "MISSING.INF", destination = missing_destination, max_output_bytes = 1024},
	}
	diagnostic := setup_source_extract_files(fixture.root, "FIXTURE.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Target_Missing)
	testing.expect_value(t, diagnostic.request_index, i32(1))
	testing.expect(t, !diagnostic.cleanup_failed)
	testing.expect(t, !os.exists(first_destination) && !os.exists(missing_destination))
}

@(test)
cabinetextract_windows_test_destination_creation_is_exclusive :: proc(t: ^testing.T) {
	fixture, created := cabinet_test_fixture_create(t)
	if !created {return}
	defer cabinet_test_fixture_destroy(&fixture)
	destination, path_ok := cabinet_test_path(fixture.root, "EXISTS.INF")
	if !testing.expect(t, path_ok) ||
	   !testing.expect_value(t, os.write_entire_file(destination, "sentinel"), os.Error(nil)) {
		return
	}
	requests := []Setup_Source_Extract_Request {
		{source_name = "MIXED.INF", destination = destination, max_output_bytes = 1024},
	}
	diagnostic := setup_source_extract_files(fixture.root, "FIXTURE.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Destination_Exists)
	retained, read_error := os.read_entire_file(destination, context.temp_allocator)
	testing.expect_value(t, read_error, os.Error(nil))
	testing.expect_value(t, string(retained), "sentinel")
}

@(test)
cabinetextract_windows_test_optional_spanish_win98_precopy_set :: proc(t: ^testing.T) {
	setup_directory := "F:\\WIN98"
	precopy_1, path_1_ok := cabinet_test_path(setup_directory, "PRECOPY1.CAB")
	precopy_2, path_2_ok := cabinet_test_path(setup_directory, "PRECOPY2.CAB")
	if !path_1_ok || !path_2_ok || !os.is_file(precopy_1) || !os.is_file(precopy_2) {return}
	root, root_error := os.make_directory_temp("", "retvrn99-precopy-*", context.temp_allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	diskdrv, diskdrv_ok := cabinet_test_path(root, "DISKDRV.INF")
	mshdc, mshdc_ok := cabinet_test_path(root, "MSHDC.INF")
	if !testing.expect(t, diskdrv_ok && mshdc_ok) {return}
	requests := []Setup_Source_Extract_Request {
		{source_name = "diskdrv.inf", destination = diskdrv, max_output_bytes = 1024 * 1024},
		{source_name = "MSHDC.INF", destination = mshdc, max_output_bytes = 1024 * 1024},
	}
	diagnostic := setup_source_extract_files(setup_directory, "PRECOPY2.CAB", requests)
	if !testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.None) {return}
	testing.expect_value(t, diagnostic.extracted_count, u16(2))
	testing.expect_value(t, diagnostic.cabinet_count, u16(1))
	testing.expect(t, os.is_file(diskdrv) && os.is_file(mshdc))
}
