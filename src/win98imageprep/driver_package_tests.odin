// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import cabinetextract "../cabinetextract"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Driver_Test_Overlay_Context :: struct {
	calls:          int,
	request_count:  int,
	first_cabinet:  string,
	bad_second_inf: bool,
}

driver_test_overlay_extract :: proc(
	ctx: rawptr,
	_: string,
	first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	state := (^Driver_Test_Overlay_Context)(ctx)
	if state == nil {return {code = .Invalid_Argument, request_index = -1}}
	state.calls += 1
	state.request_count = len(requests)
	state.first_cabinet = strings.clone(first_cabinet)
	for request, index in requests {
		data := ""
		if request.source_name == "MSHDC.INF" {
			data = "; CAB MSHDC localized \x80\r\n" + "[ESDI_AddReg]\r\nHKR,,Existing,0,1\r\n"
		} else if request.source_name == "DISKDRV.INF" {
			if state.bad_second_inf {
				data = "[WrongSection]\r\nHKR,,Existing,0,1\r\n"
			} else {
				data = "; CAB DISKDRV localized \x81\r\n" + "[DiskReg]\r\nHKR,,Existing,0,1\r\n"
			}
		} else {
			return {code = .Target_Missing, request_index = i32(index)}
		}
		if os.write_entire_file(request.destination, data) != nil {
			return {code = .Output_Write_Failed, request_index = i32(index)}
		}
	}
	return {extracted_count = u16(len(requests)), request_index = -1}
}

driver_test_overlay_context_destroy :: proc(ctx: ^Driver_Test_Overlay_Context) {
	if ctx == nil {return}
	delete(ctx.first_cabinet)
	ctx^ = {}
}

@(test)
test_stock_dma_driver_manifest_is_exact_and_valid :: proc(t: ^testing.T) {
	manifest := stock_dma_driver_manifest()
	testing.expect_value(t, driver_manifest_validate(manifest), Driver_Package_Diagnostic.None)
	testing.expect_value(t, manifest.mode, Driver_Package_Mode.Stock_Overlay)
	testing.expect_value(t, manifest.first_cabinet, "PRECOPY2.CAB")
	testing.expect_value(t, len(manifest.files), 2)
	testing.expect_value(t, manifest.files[0].source_name, "MSHDC.INF")
	testing.expect_value(t, manifest.files[0].destination_name, "MSHDC.INF")
	testing.expect_value(t, manifest.files[0].patch_section, "ESDI_AddReg")
	testing.expect_value(t, manifest.files[1].source_name, "DISKDRV.INF")
	testing.expect_value(t, manifest.files[1].destination_name, "DISKDRV.INF")
	testing.expect_value(t, manifest.files[1].patch_section, "DiskReg")
}

@(test)
test_stock_dma_driver_manifest_rejects_mutation :: proc(t: ^testing.T) {
	manifest := stock_dma_driver_manifest()
	files := STOCK_DMA_FILES
	manifest.files = files[:]
	files[0].destination_name = "OTHER.INF"
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
	files = STOCK_DMA_FILES
	manifest.files = files[:]
	files[1].patch_section = "DiskReg2"
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
}

@(test)
test_oem_pnp_manifest_seam_validates_complete_typed_package :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_1234&DEV_5678"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWTEST.INF",
			destination_name = "GSWTEST.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWTEST.VXD",
			destination_name = "GSWTEST.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := Driver_Package_Manifest {
		package_id   = "gsw-test-device",
		mode         = .PnP_Driver,
		device_class = .System,
		hardware_ids = hardware_ids[:],
		files        = files[:],
	}
	testing.expect_value(t, driver_manifest_validate(manifest), Driver_Package_Diagnostic.None)

	manifest.first_cabinet = "DRIVER11.CAB"
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
}

@(test)
test_oem_pnp_manifest_rejects_missing_binary_and_unsafe_paths :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_1234&DEV_5678"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWTEST.INF",
			destination_name = "GSWTEST.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
	}
	manifest := Driver_Package_Manifest {
		package_id   = "gsw-test-device",
		mode         = .PnP_Driver,
		device_class = .System,
		hardware_ids = hardware_ids[:],
		files        = files[:],
	}
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
	files[0].source_name = "..\\GSWTEST.INF"
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
}

@(test)
test_stock_driver_bundle_extracts_patches_and_commits_both_loose_infs :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-driver-bundle-*", context.allocator)
	testing.expect(t, root_error == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	setup, setup_error := filepath.join({root, "setup"}, context.temp_allocator)
	testing.expect(t, setup_error == nil)
	testing.expect(t, os.make_directory(setup) == nil)
	ctx: Driver_Test_Overlay_Context
	defer driver_test_overlay_context_destroy(&ctx)
	result := driver_bundle_stage_early_setup(
		setup,
		root,
		{ctx = &ctx, extract = driver_test_overlay_extract},
	)
	testing.expect_value(t, result.diagnostic, Driver_Package_Diagnostic.None)
	testing.expect_value(t, ctx.calls, 1)
	testing.expect_value(t, ctx.request_count, 2)
	testing.expect_value(t, ctx.first_cabinet, "PRECOPY2.CAB")
	files := [?][2]string{{"MSHDC.INF", "ESDI_AddReg"}, {"DISKDRV.INF", "DiskReg"}}
	for file in files {
		path, path_error := filepath.join({setup, file[0]}, context.temp_allocator)
		testing.expect(t, path_error == nil)
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, read_error == nil)
		testing.expect(t, driver_inf_dma_defaults_valid(string(data), file[1]))
	}
	workspace, workspace_error := filepath.join({root, "driver-overlay"}, context.temp_allocator)
	testing.expect(t, workspace_error == nil)
	_, workspace_stat_error := os.lstat(workspace, context.temp_allocator)
	testing.expect(t, workspace_stat_error == os.General_Error.Not_Exist)
}

@(test)
test_stock_driver_bundle_patches_authoritative_loose_infs_without_cab :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-driver-loose-*", context.allocator)
	testing.expect(t, root_error == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	setup, setup_error := filepath.join({root, "setup"}, context.temp_allocator)
	testing.expect(t, setup_error == nil)
	testing.expect(t, os.make_directory(setup) == nil)
	mshdc, _ := filepath.join({setup, "MSHDC.INF"}, context.temp_allocator)
	diskdrv, _ := filepath.join({setup, "DISKDRV.INF"}, context.temp_allocator)
	testing.expect(
		t,
		os.write_entire_file(
			mshdc,
			"; authoritative OEM MSHDC \x80\r\n[ESDI_AddReg]\r\nHKR,,Keep,0,1\r\n",
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(
			diskdrv,
			"; authoritative OEM DISKDRV \x81\r\n[DiskReg]\r\nHKR,,Keep,0,1\r\n",
		) ==
		nil,
	)
	ctx: Driver_Test_Overlay_Context
	defer driver_test_overlay_context_destroy(&ctx)
	result := driver_bundle_stage_early_setup(
		setup,
		root,
		{ctx = &ctx, extract = driver_test_overlay_extract},
	)
	testing.expect_value(t, result.diagnostic, Driver_Package_Diagnostic.None)
	testing.expect_value(t, ctx.calls, 0)
	patched_mshdc, mshdc_error := os.read_entire_file(mshdc, context.temp_allocator)
	patched_diskdrv, diskdrv_error := os.read_entire_file(diskdrv, context.temp_allocator)
	testing.expect(t, mshdc_error == nil && diskdrv_error == nil)
	testing.expect(t, strings.contains(string(patched_mshdc), "; authoritative OEM MSHDC \x80"))
	testing.expect(
		t,
		strings.contains(string(patched_diskdrv), "; authoritative OEM DISKDRV \x81"),
	)
	testing.expect(t, driver_inf_dma_defaults_valid(string(patched_mshdc), "ESDI_AddReg"))
	testing.expect(t, driver_inf_dma_defaults_valid(string(patched_diskdrv), "DiskReg"))
}

@(test)
test_stock_driver_bundle_does_not_commit_mixed_patch_failure :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "retvrn99-driver-rollback-*", context.allocator)
	testing.expect(t, root_error == nil)
	defer {
		_ = os.remove_all(root)
		delete(root)
	}
	setup, setup_error := filepath.join({root, "setup"}, context.temp_allocator)
	testing.expect(t, setup_error == nil)
	testing.expect(t, os.make_directory(setup) == nil)
	ctx := Driver_Test_Overlay_Context {
		bad_second_inf = true,
	}
	defer driver_test_overlay_context_destroy(&ctx)
	result := driver_bundle_stage_early_setup(
		setup,
		root,
		{ctx = &ctx, extract = driver_test_overlay_extract},
	)
	testing.expect_value(t, result.diagnostic, Driver_Package_Diagnostic.INF_Patch_Failed)
	names := [?]string{"MSHDC.INF", "DISKDRV.INF"}
	for name in names {
		path, _ := filepath.join({setup, name}, context.temp_allocator)
		_, stat_error := os.lstat(path, context.temp_allocator)
		testing.expect(t, stat_error == os.General_Error.Not_Exist)
	}
}

@(test)
test_pnp_manifest_rejects_unsorted_and_short_alias_colliding_files :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_1234&DEV_5678"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWTEST.INF",
			destination_name = "GSWTEST.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "LONGFILEONE.VXD",
			destination_name = "LONGFILEONE.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
		{
			source_name = "LONGFILETWO.VXD",
			destination_name = "LONGFILETWO.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := Driver_Package_Manifest {
		package_id   = "gsw-test-device",
		mode         = .PnP_Driver,
		device_class = .System,
		hardware_ids = hardware_ids[:],
		files        = files[:],
	}
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
	files[1].source_name = "ZZZ.VXD"
	files[1].destination_name = "ZZZ.VXD"
	files[2].source_name = "AAA.VXD"
	files[2].destination_name = "AAA.VXD"
	testing.expect_value(
		t,
		driver_manifest_validate(manifest),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
}

@(test)
test_reserved_bundle_modes_fail_explicitly :: proc(t: ^testing.T) {
	files := [?]Driver_Package_File {
		{
			source_name = "COMPONENT.INF",
			destination_name = "COMPONENT.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
	}
	early := Driver_Package_Manifest {
		package_id = "early-component",
		mode       = .Early_Setup,
		files      = files[:],
	}
	testing.expect_value(
		t,
		driver_manifest_validate(early),
		Driver_Package_Diagnostic.Unsupported_Mode,
	)
	post := Driver_Package_Manifest {
		package_id      = "post-component",
		mode            = .Post_Setup_Component,
		files           = files[:],
		install_section = "RETVRN99.Install",
	}
	testing.expect_value(
		t,
		driver_manifest_validate(post),
		Driver_Package_Diagnostic.Unsupported_Mode,
	)
	hardware_ids := [?]string{"PCI\\VEN_FFFE&DEV_0002"}
	post.hardware_ids = hardware_ids[:]
	testing.expect_value(
		t,
		driver_manifest_validate(post),
		Driver_Package_Diagnostic.Invalid_Manifest,
	)
}

@(test)
test_driver_inf_patch_preserves_localized_bytes_crlf_and_dos_eof :: proc(t: ^testing.T) {
	localized :: "\x80\x81\xa1\xfe"
	original :=
		"; localized=" +
		localized +
		"\r\n" +
		"[Version]\r\nSignature=\"$CHICAGO$\"\r\n\r\n" +
		"[ESDI_AddReg]\r\n" +
		"HKR,,Unrelated,0,\"" +
		localized +
		"\"\r\n" +
		"HKR, , IDEDmaDrive0, 3, 00 ; stale\r\n" +
		"HKR,,IDEDMADrive2,3,01\r\n\r\n" +
		"[Strings]\r\nDescription=\"" +
		localized +
		"\"\r\n" +
		"\x1aOEM TRAILER " +
		localized
	patched, diagnostic := driver_inf_patch_dma_defaults(original, "ESDI_AddReg")
	defer delete(patched)
	testing.expect_value(t, diagnostic, Driver_INF_Diagnostic.None)
	testing.expect(t, strings.has_prefix(patched, "; localized=" + localized + "\r\n"))
	testing.expect(t, strings.has_suffix(patched, "\x1aOEM TRAILER " + localized))
	testing.expect(t, strings.contains(patched, `HKR,,Unrelated,0,"` + localized + `"`))
	testing.expect(t, strings.contains(patched, `Description="` + localized + `"`))
	testing.expect(t, !strings.contains(patched, "3, 00"))
	testing.expect(t, driver_inf_dma_defaults_valid(patched, "ESDI_AddReg"))
	driver_test_expect_exact_dma_lines(t, patched)

	second, second_diagnostic := driver_inf_patch_dma_defaults(patched, "ESDI_AddReg")
	defer delete(second)
	testing.expect_value(t, second_diagnostic, Driver_INF_Diagnostic.None)
	testing.expect_value(t, second, patched)
}

@(test)
test_driver_inf_patch_preserves_lf_and_missing_final_newline :: proc(t: ^testing.T) {
	original :=
		"[Version]\nSignature=\"$CHICAGO$\"\n" +
		"[DiskReg]\nHKR,,Keep,0,1\n" +
		"[Strings]\nDescription=Disk"
	patched, diagnostic := driver_inf_patch_dma_defaults(original, "DiskReg")
	defer delete(patched)
	testing.expect_value(t, diagnostic, Driver_INF_Diagnostic.None)
	testing.expect(t, !strings.contains(patched, "\r"))
	testing.expect(t, !strings.has_suffix(patched, "\n"))
	testing.expect(t, driver_inf_dma_defaults_valid(patched, "DiskReg"))
	strings_header := strings.index(patched, "[Strings]")
	dma_last := strings.index(patched, "HKR,,IDEDMADrive3,3,01")
	testing.expect(t, dma_last >= 0 && strings_header > dma_last)
}

@(test)
test_driver_inf_patch_rejects_missing_or_duplicate_section :: proc(t: ^testing.T) {
	missing, missing_diagnostic := driver_inf_patch_dma_defaults(
		"[Version]\r\nSignature=\"$CHICAGO$\"\r\n",
		"DiskReg",
	)
	testing.expect_value(t, missing_diagnostic, Driver_INF_Diagnostic.Section_Missing)
	testing.expect_value(t, missing, "")

	duplicate, duplicate_diagnostic := driver_inf_patch_dma_defaults(
		"[DiskReg]\r\nHKR,,A,0,1\r\n[DiskReg]\r\nHKR,,B,0,1\r\n",
		"DiskReg",
	)
	testing.expect_value(t, duplicate_diagnostic, Driver_INF_Diagnostic.Section_Ambiguous)
	testing.expect_value(t, duplicate, "")
}

@(private = "file")
driver_test_expect_exact_dma_lines :: proc(t: ^testing.T, value: string) {
	for index in 0 ..< DRIVER_DMA_VALUE_COUNT {
		line := driver_inf_dma_line(index)
		first := strings.index(value, line)
		testing.expect(t, first >= 0)
		if first >= 0 {
			second := strings.index(value[first + len(line):], line)
			testing.expect(t, second < 0)
		}
	}
}
