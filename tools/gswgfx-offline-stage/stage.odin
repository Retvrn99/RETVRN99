// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:crypto/sha2"
import "core:os"
import "core:path/filepath"
import "core:strings"

GSWGFX_GUEST_DIRECTORY :: "GSWGFX"
GSWGFX_FILE_COUNT :: 2
GSWGFX_MANIFEST_HEADER :: "guest_directory\tfile_name\tsha256\tbytes"
GSWGFX_MANIFEST_MAX_BYTES :: 4096
GSWGFX_FILE_MAX_BYTES :: u64(64 * 1024 * 1024)
GSWGFX_PACKAGE_MAX_BYTES :: u64(65 * 1024 * 1024)

Gswgfx_Stage_File :: struct {
	name:          string,
	bytes:         u64,
	sha256:        [32]u8,
	manifest_seen: bool,
}

Gswgfx_Stage_Contract :: struct {
	files:       [GSWGFX_FILE_COUNT]Gswgfx_Stage_File,
	total_bytes: u64,
}

Gswgfx_Stage_Diagnostic :: enum u16 {
	None,
	Invalid_Arguments,
	Manifest_Invalid,
	Package_Directory_Unsafe,
	Package_Shape_Invalid,
	Package_File_Invalid,
	Package_Hash_Mismatch,
	Image_Open_Failed,
	Destination_Inspect_Failed,
	Destination_Exists,
	Import_Begin_Failed,
	Import_Failed,
	Imported_Package_Invalid,
	Apply_Failed,
}

Gswgfx_Stage_Result :: struct {
	diagnostic:    Gswgfx_Stage_Diagnostic,
	session_error: fat32session.Session_Error,
	transaction:   u64,
	total_bytes:   u64,
}

gswgfx_stage_diagnostic_text :: proc(diagnostic: Gswgfx_Stage_Diagnostic) -> string {
	switch diagnostic {
	case .None:
		return "none"
	case .Invalid_Arguments:
		return "invalid arguments"
	case .Manifest_Invalid:
		return "stage manifest is invalid"
	case .Package_Directory_Unsafe:
		return "package directory is not a safe ordinary directory"
	case .Package_Shape_Invalid:
		return "package directory is not the exact two-file GSWGFX set"
	case .Package_File_Invalid:
		return "package file size or type is invalid"
	case .Package_Hash_Mismatch:
		return "package file hash does not match the stage manifest"
	case .Image_Open_Failed:
		return "cannot open the stopped image"
	case .Destination_Inspect_Failed:
		return "cannot inspect the guest GSWGFX destination"
	case .Destination_Exists:
		return "guest GSWGFX destination already exists"
	case .Import_Begin_Failed:
		return "cannot begin the transactional GSWGFX import"
	case .Import_Failed:
		return "transactional GSWGFX import failed"
	case .Imported_Package_Invalid:
		return "imported GSWGFX tree failed exact verification"
	case .Apply_Failed:
		return "transactional image apply failed"
	}
	return "unknown failure"
}

gswgfx_stage_contract_default :: proc() -> Gswgfx_Stage_Contract {
	return {
		files = {
			{name = "GSWGFX.EXE"},
			{name = "GSWVBE.EXE"},
		},
	}
}

gswgfx_stage_file_index :: proc(contract: ^Gswgfx_Stage_Contract, name: string) -> int {
	if contract == nil {return -1}
	for file, index in contract.files {
		if file.name == name {return index}
	}
	return -1
}

gswgfx_stage_parse_u64 :: proc(value: string) -> (u64, bool) {
	if len(value) == 0 || len(value) > 1 && value[0] == '0' {return 0, false}
	result: u64
	for byte in value {
		if byte < '0' || byte > '9' {return 0, false}
		digit := u64(byte - '0')
		if result > (max(u64) - digit) / 10 {return 0, false}
		result = result * 10 + digit
	}
	return result, true
}

gswgfx_stage_hex_nibble :: proc(value: u8) -> (u8, bool) {
	if value >= '0' && value <= '9' {return value - '0', true}
	if value >= 'a' && value <= 'f' {return value - 'a' + 10, true}
	return 0, false
}

gswgfx_stage_parse_sha256 :: proc(value: string) -> ([32]u8, bool) {
	digest: [32]u8
	if len(value) != 64 {return digest, false}
	for index in 0 ..< 32 {
		high, high_ok := gswgfx_stage_hex_nibble(value[index * 2])
		low, low_ok := gswgfx_stage_hex_nibble(value[index * 2 + 1])
		if !high_ok || !low_ok {return {}, false}
		digest[index] = high << 4 | low
	}
	return digest, true
}

gswgfx_stage_read_manifest :: proc(path: string) -> ([]u8, bool) {
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error != nil {return nil, false}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular || info.size <= 0 || info.size > GSWGFX_MANIFEST_MAX_BYTES ||
	   !gswgfx_stage_platform_no_named_streams(path) {
		return nil, false
	}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil || len(data) != int(info.size) {
		delete(data)
		return nil, false
	}
	if data[len(data) - 1] != '\n' {delete(data); return nil, false}
	for byte in data {
		if byte == '\r' || byte == 0 || byte >= 0x80 ||
		   byte < 0x20 && byte != '\t' && byte != '\n' {
			delete(data)
			return nil, false
		}
	}
	return data, true
}

gswgfx_stage_parse_manifest :: proc(path: string, contract: ^Gswgfx_Stage_Contract) -> bool {
	if contract == nil {return false}
	data, read_ok := gswgfx_stage_read_manifest(path)
	if !read_ok {return false}
	defer delete(data)
	lines := strings.split(string(data), "\n", context.temp_allocator)
	defer delete(lines, context.temp_allocator)
	if len(lines) != GSWGFX_FILE_COUNT + 2 ||
	   lines[0] != GSWGFX_MANIFEST_HEADER ||
	   lines[len(lines) - 1] != "" {
		return false
	}
	for row in 0 ..< GSWGFX_FILE_COUNT {
		fields := strings.split(lines[row + 1], "\t", context.temp_allocator)
		if len(fields) != 4 {
			delete(fields, context.temp_allocator)
			return false
		}
		file := &contract.files[row]
		digest, digest_ok := gswgfx_stage_parse_sha256(fields[2])
		bytes, bytes_ok := gswgfx_stage_parse_u64(fields[3])
		valid :=
			fields[0] == GSWGFX_GUEST_DIRECTORY &&
			fields[1] == file.name &&
			!file.manifest_seen &&
			digest_ok &&
			bytes_ok &&
			bytes > 0 &&
			bytes <= GSWGFX_FILE_MAX_BYTES &&
			contract.total_bytes <= GSWGFX_PACKAGE_MAX_BYTES - bytes
		if valid {
			file.bytes = bytes
			file.sha256 = digest
			file.manifest_seen = true
			contract.total_bytes += bytes
		}
		delete(fields, context.temp_allocator)
		if !valid {return false}
	}
	return contract.files[0].manifest_seen && contract.files[1].manifest_seen
}

gswgfx_stage_hash_host_file :: proc(path: string, expected_bytes: u64) -> ([32]u8, bool) {
	digest: [32]u8
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error != nil {return digest, false}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular || info.size < 0 || u64(info.size) != expected_bytes ||
	   !gswgfx_stage_platform_no_named_streams(path) {
		return digest, false
	}
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return digest, false}
	defer os.close(file)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buffer: [64 * 1024]u8
	read_total: u64
	for read_total < expected_bytes {
		wanted := int(min(u64(len(buffer)), expected_bytes - read_total))
		count, read_error := os.read(file, buffer[:wanted])
		if count > 0 {
			sha2.update(&ctx, buffer[:count])
			read_total += u64(count)
		}
		if read_error != nil {
			if read_error == .EOF && read_total == expected_bytes {break}
			return digest, false
		}
		if count == 0 {return digest, false}
	}
	extra: [1]u8
	extra_count, extra_error := os.read(file, extra[:])
	if extra_count != 0 || extra_error != nil && extra_error != .EOF {return digest, false}
	sha2.final(&ctx, digest[:])
	return digest, true
}

gswgfx_stage_validate_host_package :: proc(
	package_directory: string,
	contract: ^Gswgfx_Stage_Contract,
) -> Gswgfx_Stage_Diagnostic {
	if contract == nil {return .Package_Directory_Unsafe}
	info, stat_error := os.lstat(package_directory, context.temp_allocator)
	if stat_error != nil {return .Package_Directory_Unsafe}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Directory || !gswgfx_stage_platform_no_named_streams(package_directory) {
		return .Package_Directory_Unsafe
	}
	directory, open_error := os.open(package_directory, {.Read})
	if open_error != nil {return .Package_Directory_Unsafe}
	entries, read_error := os.read_directory(directory, -1, context.temp_allocator)
	_ = os.close(directory)
	if read_error != nil {return .Package_Directory_Unsafe}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	if len(entries) != GSWGFX_FILE_COUNT {return .Package_Shape_Invalid}
	seen: [GSWGFX_FILE_COUNT]bool
	for entry in entries {
		index := gswgfx_stage_file_index(contract, entry.name)
		if index < 0 || seen[index] {return .Package_Shape_Invalid}
		seen[index] = true
		path, path_error := filepath.join({package_directory, entry.name}, context.temp_allocator)
		if path_error != nil {return .Package_File_Invalid}
		digest, hash_ok := gswgfx_stage_hash_host_file(path, contract.files[index].bytes)
		delete(path, context.temp_allocator)
		if !hash_ok {return .Package_File_Invalid}
		if digest != contract.files[index].sha256 {return .Package_Hash_Mismatch}
	}
	for present in seen {
		if !present {return .Package_Shape_Invalid}
	}
	return .None
}

gswgfx_stage_hash_guest_file :: proc(
	session: ^fat32session.Edit_Session,
	path: string,
	expected_bytes: u64,
) -> (
	[32]u8,
	fat32session.Session_Error,
	bool,
) {
	digest: [32]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	offset: u64
	for offset < expected_bytes {
		length := min(u64(fat32session.MAX_BLOCK_BYTES), expected_bytes - offset)
		read, read_error := fat32session.edit_read(session, path, offset, length)
		if read_error.code != .None {return digest, read_error, false}
		valid := read.offset == offset && read.total == expected_bytes &&
			u64(len(read.data)) == length
		if valid {sha2.update(&ctx, read.data)}
		fat32session.edit_read_destroy(&read)
		if !valid {return digest, {}, false}
		offset += length
	}
	sha2.final(&ctx, digest[:])
	return digest, {}, true
}

gswgfx_stage_verify_guest_directory :: proc(
	session: ^fat32session.Edit_Session,
	contract: ^Gswgfx_Stage_Contract,
) -> (
	bool,
	bool,
	fat32session.Session_Error,
) {
	stat, stat_error := fat32session.edit_stat(session, GSWGFX_GUEST_DIRECTORY)
	if stat_error.code != .None {return false, false, stat_error}
	if !stat.exists {return false, true, {}}
	if !stat.is_directory {return true, false, {}}
	seen: [GSWGFX_FILE_COUNT]bool
	entry_count := 0
	cursor: u64
	for {
		page, list_error := fat32session.edit_list(
			session,
			GSWGFX_GUEST_DIRECTORY,
			cursor,
			fat32session.EDIT_PAGE_ENTRY_LIMIT,
		)
		if list_error.code != .None {return true, false, list_error}
		for entry in page.entries {
			entry_count += 1
			index := gswgfx_stage_file_index(contract, entry.name)
			if index < 0 || seen[index] || entry.is_directory ||
			   entry.size != contract.files[index].bytes {
				fat32session.edit_page_destroy(&page)
				return true, false, {}
			}
			seen[index] = true
			path := strings.concatenate(
				{GSWGFX_GUEST_DIRECTORY, "/", entry.name},
				context.temp_allocator,
			)
			digest, read_error, hash_ok := gswgfx_stage_hash_guest_file(
				session,
				path,
				contract.files[index].bytes,
			)
			delete(path, context.temp_allocator)
			if read_error.code != .None {
				fat32session.edit_page_destroy(&page)
				return true, false, read_error
			}
			if !hash_ok || digest != contract.files[index].sha256 {
				fat32session.edit_page_destroy(&page)
				return true, false, {}
			}
		}
		has_more := page.has_more
		next_cursor := page.next_cursor
		fat32session.edit_page_destroy(&page)
		if !has_more {break}
		cursor = next_cursor
	}
	if entry_count != GSWGFX_FILE_COUNT {return true, false, {}}
	for present in seen {
		if !present {return true, false, {}}
	}
	return true, true, {}
}

gswgfx_stage_run_import_job :: proc(
	session: ^fat32session.Edit_Session,
) -> fat32session.Session_Error {
	for {
		progress, step_error := fat32session.edit_job_step(session)
		if step_error.code != .None {return step_error}
		switch progress.state {
		case .Complete:
			return {}
		case .Cancelled, .Failed:
			return fat32session.error_make(
				.Internal,
				false,
				.Not_Started,
				0,
				0,
				"GSWGFX tree import did not complete",
			)
		case .Pending, .Running:
		}
	}
}

gswgfx_stage_package_contract :: proc(
	image_path, package_directory: string,
	contract: ^Gswgfx_Stage_Contract,
	adapter := fat32session.Adapter_Kind.Process,
) -> Gswgfx_Stage_Result {
	if image_path == "" || package_directory == "" || contract == nil {
		return {diagnostic = .Invalid_Arguments}
	}
	host_diagnostic := gswgfx_stage_validate_host_package(package_directory, contract)
	if host_diagnostic != .None {return {diagnostic = host_diagnostic}}
	session, open_error := fat32session.open_edit(
		image_path,
		"gswgfx-offline-stage",
		0,
		adapter,
	)
	if open_error.code != .None {
		return {diagnostic = .Image_Open_Failed, session_error = open_error}
	}
	finish_attempted := false
	defer if session != nil {
		if finish_attempted {
			_ = fat32session.edit_close_retain(session)
		} else {
			_ = fat32session.edit_finish(session, false)
		}
	}
	transaction := fat32session.edit_transaction_id(session)
	destination, inspect_error := fat32session.edit_stat(session, GSWGFX_GUEST_DIRECTORY)
	if inspect_error.code != .None {
		return {
			diagnostic = .Destination_Inspect_Failed,
			session_error = inspect_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	if destination.exists {
		return {
			diagnostic = .Destination_Exists,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	begin_error := fat32session.edit_begin_import_tree(
		session,
		package_directory,
		GSWGFX_GUEST_DIRECTORY,
		false,
	)
	if begin_error.code != .None {
		return {
			diagnostic = .Import_Begin_Failed,
			session_error = begin_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	if import_error := gswgfx_stage_run_import_job(session); import_error.code != .None {
		return {
			diagnostic = .Import_Failed,
			session_error = import_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	imported_exists, imported_valid, verify_error :=
		gswgfx_stage_verify_guest_directory(session, contract)
	if verify_error.code != .None || !imported_exists || !imported_valid {
		return {
			diagnostic = .Imported_Package_Invalid,
			session_error = verify_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	finish_attempted = true
	apply_error := fat32session.edit_finish(session, true)
	if apply_error.code == .None || apply_error.outcome == .Completed {session = nil}
	if apply_error.code != .None {
		return {
			diagnostic = .Apply_Failed,
			session_error = apply_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	return {
		transaction = transaction,
		total_bytes = contract.total_bytes,
	}
}

stage_gswgfx_package :: proc(
	image_path, package_directory, manifest_path: string,
	adapter := fat32session.Adapter_Kind.Process,
) -> Gswgfx_Stage_Result {
	if image_path == "" || package_directory == "" || manifest_path == "" {
		return {diagnostic = .Invalid_Arguments}
	}
	contract := gswgfx_stage_contract_default()
	if !gswgfx_stage_parse_manifest(manifest_path, &contract) {
		return {diagnostic = .Manifest_Invalid}
	}
	return gswgfx_stage_package_contract(image_path, package_directory, &contract, adapter)
}
