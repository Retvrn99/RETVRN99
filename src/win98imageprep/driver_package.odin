// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import cabinetextract "../cabinetextract"
import "core:os"
import "core:path/filepath"

Setup_Source_Overlay_Extract_Proc :: #type proc(
	ctx: rawptr,
	setup_directory, first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic

Setup_Source_Overlay :: struct {
	ctx:     rawptr,
	extract: Setup_Source_Overlay_Extract_Proc,
}

Driver_Package_Stage_Result :: struct {
	diagnostic:        Driver_Package_Diagnostic,
	source_diagnostic: cabinetextract.Setup_Source_Extract_Diagnostic,
	file_index:        i32,
}

driver_bundle_stage_early_setup :: proc(
	setup_directory, workspace_directory: string,
	overlay: Setup_Source_Overlay = {},
) -> Driver_Package_Stage_Result {
	return driver_package_stage(
		stock_dma_driver_manifest(),
		setup_directory,
		workspace_directory,
		overlay,
	)
}

@(private)
driver_package_stage :: proc(
	manifest: Driver_Package_Manifest,
	setup_directory, workspace_directory: string,
	overlay: Setup_Source_Overlay = {},
) -> Driver_Package_Stage_Result {
	validation := driver_manifest_validate(manifest)
	if validation != .None {return {diagnostic = validation, file_index = -1}}
	switch manifest.mode {
	case .Stock_Overlay:
		return driver_stock_overlay_stage(manifest, setup_directory, workspace_directory, overlay)
	case .PnP_Driver:
		return {diagnostic = .Package_Content_Unavailable, file_index = -1}
	case .Early_Setup, .Post_Setup_Component:
		return {diagnostic = .Unsupported_Mode, file_index = -1}
	}
	return {diagnostic = .Unsupported_Mode, file_index = -1}
}

@(private)
driver_stock_overlay_stage :: proc(
	manifest: Driver_Package_Manifest,
	setup_directory, workspace_directory: string,
	overlay: Setup_Source_Overlay,
) -> Driver_Package_Stage_Result {
	if setup_directory == "" ||
	   workspace_directory == "" ||
	   !filepath.is_abs(setup_directory) ||
	   !filepath.is_abs(workspace_directory) {
		return {diagnostic = .Invalid_Manifest, file_index = -1}
	}
	temp_directory, join_error := filepath.join({workspace_directory, "driver-overlay"})
	if join_error != nil {return {diagnostic = .Destination_Write_Failed, file_index = -1}}
	defer delete(temp_directory)
	if _, stat_error := os.lstat(temp_directory, context.temp_allocator); stat_error == nil {
		return {diagnostic = .Destination_Exists, file_index = -1}
	} else if stat_error != os.General_Error.Not_Exist {
		return {diagnostic = .Destination_Write_Failed, file_index = -1}
	}
	if os.make_directory(temp_directory) != nil {
		return {diagnostic = .Destination_Write_Failed, file_index = -1}
	}
	defer os.remove_all(temp_directory)
	source_directory, source_join_error := filepath.join({temp_directory, "source"})
	patched_directory, patched_join_error := filepath.join({temp_directory, "patched"})
	backup_directory, backup_join_error := filepath.join({temp_directory, "backup"})
	defer delete(source_directory)
	defer delete(patched_directory)
	defer delete(backup_directory)
	if source_join_error != nil ||
	   patched_join_error != nil ||
	   backup_join_error != nil ||
	   os.make_directory(source_directory) != nil ||
	   os.make_directory(patched_directory) != nil ||
	   os.make_directory(backup_directory) != nil {
		return {diagnostic = .Destination_Write_Failed, file_index = -1}
	}

	requests := make(
		[]cabinetextract.Setup_Source_Extract_Request,
		len(manifest.files),
		context.temp_allocator,
	)
	request_count := 0
	extracted_paths := make([]string, len(manifest.files), context.temp_allocator)
	input_paths := make([]string, len(manifest.files), context.temp_allocator)
	patched_paths := make([]string, len(manifest.files), context.temp_allocator)
	backup_paths := make([]string, len(manifest.files), context.temp_allocator)
	destination_paths := make([]string, len(manifest.files), context.temp_allocator)
	destination_existed := make([]bool, len(manifest.files), context.temp_allocator)
	defer {
		for path in extracted_paths {delete(path, context.temp_allocator)}
		for path in patched_paths {delete(path, context.temp_allocator)}
		for path in backup_paths {delete(path, context.temp_allocator)}
		for path in destination_paths {delete(path, context.temp_allocator)}
	}
	for file, index in manifest.files {
		extracted, extracted_error := filepath.join(
			{source_directory, file.source_name},
			context.temp_allocator,
		)
		patched, patched_error := filepath.join(
			{patched_directory, file.destination_name},
			context.temp_allocator,
		)
		backup, backup_error := filepath.join(
			{backup_directory, file.destination_name},
			context.temp_allocator,
		)
		destination, destination_error := filepath.join(
			{setup_directory, file.destination_name},
			context.temp_allocator,
		)
		if extracted_error != nil ||
		   patched_error != nil ||
		   backup_error != nil ||
		   destination_error != nil {
			return {diagnostic = .Destination_Write_Failed, file_index = i32(index)}
		}
		extracted_paths[index] = extracted
		patched_paths[index] = patched
		backup_paths[index] = backup
		destination_paths[index] = destination
		if _, stat_error := os.lstat(destination, context.temp_allocator); stat_error == nil {
			destination_existed[index] = true
			input_paths[index] = destination
		} else if stat_error == os.General_Error.Not_Exist {
			input_paths[index] = extracted
			requests[request_count] = {
				source_name      = file.source_name,
				destination      = extracted,
				max_output_bytes = file.max_output_bytes,
			}
			request_count += 1
		} else {
			return {diagnostic = .Destination_Write_Failed, file_index = i32(index)}
		}
	}

	if request_count > 0 {
		extract := overlay.extract
		if extract == nil {extract = driver_default_setup_source_extract}
		source_diagnostic := extract(
			overlay.ctx,
			setup_directory,
			manifest.first_cabinet,
			requests[:request_count],
		)
		if source_diagnostic.code != .None {
			return {
				diagnostic = .Source_Extraction_Failed,
				source_diagnostic = source_diagnostic,
				file_index = source_diagnostic.request_index,
			}
		}
	}

	for file, index in manifest.files {
		data, read_error := os.read_entire_file(input_paths[index], context.temp_allocator)
		if read_error != nil || u64(len(data)) > file.max_output_bytes {
			return {diagnostic = .Source_Extraction_Failed, file_index = i32(index)}
		}
		patched, patch_diagnostic := driver_inf_patch_dma_defaults(
			string(data),
			file.patch_section,
		)
		if patch_diagnostic != .None || u64(len(patched)) > file.max_output_bytes {
			delete(patched)
			return {diagnostic = .INF_Patch_Failed, file_index = i32(index)}
		}
		write_diagnostic := driver_package_write_exclusive(patched_paths[index], patched)
		delete(patched)
		if write_diagnostic != .None {
			return {diagnostic = write_diagnostic, file_index = i32(index)}
		}
	}
	installed := make([]bool, len(manifest.files), context.temp_allocator)
	backup_moved := make([]bool, len(manifest.files), context.temp_allocator)
	committed := false
	defer {
		if !committed {
			for index := len(manifest.files) - 1; index >= 0; index -= 1 {
				if installed[index] {_ = os.remove(destination_paths[index])}
				if backup_moved[index] {_ = os.rename(backup_paths[index], destination_paths[index])}
			}
		}
	}
	for _, index in manifest.files {
		if destination_existed[index] {
			if os.rename(destination_paths[index], backup_paths[index]) != nil {
				return {diagnostic = .Destination_Write_Failed, file_index = i32(index)}
			}
			backup_moved[index] = true
		}
		if os.rename(patched_paths[index], destination_paths[index]) != nil {
			return {diagnostic = .Destination_Write_Failed, file_index = i32(index)}
		}
		installed[index] = true
	}
	committed = true
	return {file_index = -1}
}

@(private)
driver_default_setup_source_extract :: proc(
	_: rawptr,
	setup_directory, first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	return cabinetextract.setup_source_extract_files(setup_directory, first_cabinet, requests)
}

@(private)
driver_package_write_exclusive :: proc(path, data: string) -> Driver_Package_Diagnostic {
	if _, stat_error := os.lstat(path, context.temp_allocator); stat_error == nil {
		return .Destination_Exists
	} else if stat_error != os.General_Error.Not_Exist {
		return .Destination_Write_Failed
	}
	file, open_error := os.open(path, {.Write, .Create, .Excl})
	if open_error != nil {
		return .Destination_Write_Failed
	}
	remove_on_failure := true
	defer {
		if file != nil {_ = os.close(file)}
		if remove_on_failure {_ = os.remove(path)}
	}
	written := 0
	for written < len(data) {
		amount, write_error := os.write(file, transmute([]u8)data[written:])
		if write_error != nil || amount <= 0 {return .Destination_Write_Failed}
		written += amount
	}
	if os.close(file) != nil {
		file = nil
		return .Destination_Write_Failed
	}
	file = nil
	remove_on_failure = false
	return .None
}
