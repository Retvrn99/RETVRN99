// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:crypto/sha2"
import "core:os"
import "core:path/filepath"
import "core:strings"

GSW_VGA_PACKAGE_ID :: "gsw-vga"
GSW_VGA_PRIOR_PACKAGE_ID :: "gsw-vga-prior-only"
GSW_VGA_HARDWARE_ID :: `PCI\VEN_FFFE&DEV_0002`
GSW_VGA_GUEST_DIRECTORY :: "GSW-VGA"
GSW_VGA_FILE_COUNT :: 5
GSW_VGA_TSV_MAX_BYTES :: 1024 * 1024
GSW_VGA_TSV_MAX_LINES :: 512
GSW_VGA_TSV_MAX_ROWS :: 128
GSW_VGA_TSV_MAX_LINE_BYTES :: 16 * 1024
GSW_VGA_FILE_MAX_BYTES :: u64(256 * 1024 * 1024)
GSW_VGA_PACKAGE_MAX_BYTES :: u64(512 * 1024 * 1024)

GSW_VGA_MANIFEST_HEADER :: "package_id\tsource_relative_path\tdestination_relative_path\tkind\tsha256\tbytes\thardware_id\trun_once_order"
GSW_VGA_INVENTORY_HEADER :: "package_id\tdestination_relative_path\tkind\thardware_id\trun_once_order"
GSW_VGA_PRIOR_MANIFEST_HEADER :: "package_id\tdestination_relative_path\tsha256\tbytes"

Stage_File_Kind :: enum u8 {
	Invalid,
	INF,
	Binary,
}

Stage_File :: struct {
	name:             string,
	source_path:      string,
	destination_path: string,
	kind:             Stage_File_Kind,
	bytes:            u64,
	sha256:           [32]u8,
	manifest_seen:    bool,
	inventory_seen:   bool,
}

Stage_Contract :: struct {
	files:       [GSW_VGA_FILE_COUNT]Stage_File,
	total_bytes: u64,
}

Stage_Diagnostic :: enum u16 {
	None,
	Invalid_Arguments,
	Manifest_Invalid,
	Inventory_Invalid,
	Manifest_Inventory_Mismatch,
	Current_Manifest_Unreviewed,
	Package_Directory_Unsafe,
	Package_Shape_Invalid,
	Package_File_Invalid,
	Package_Hash_Mismatch,
	Prior_Manifest_Invalid,
	Image_Open_Failed,
	Destination_Inspect_Failed,
	Unexpected_Prior_Directory,
	Import_Begin_Failed,
	Import_Failed,
	Imported_Package_Invalid,
	Apply_Failed,
}

Stage_Prior_Kind :: enum u8 {
	Absent,
	Current,
	Reviewed_Legacy,
}

Stage_Result :: struct {
	diagnostic:     Stage_Diagnostic,
	session_error:  fat32session.Session_Error,
	transaction:    u64,
	total_bytes:    u64,
	prior_verified: bool,
	prior_kind:     Stage_Prior_Kind,
}

stage_diagnostic_text :: proc(diagnostic: Stage_Diagnostic) -> string {
	switch diagnostic {
	case .None:
		return "none"
	case .Invalid_Arguments:
		return "invalid arguments"
	case .Manifest_Invalid:
		return "payload manifest is invalid"
	case .Inventory_Invalid:
		return "payload inventory is invalid"
	case .Manifest_Inventory_Mismatch:
		return "manifest does not match the reviewed inventory"
	case .Current_Manifest_Unreviewed:
		return "payload manifest does not match the pinned current GSW-VGA package"
	case .Package_Directory_Unsafe:
		return "package directory is not a safe regular directory"
	case .Package_Shape_Invalid:
		return "package directory is not the exact five-file GSW-VGA set"
	case .Package_File_Invalid:
		return "package file size or type is invalid"
	case .Package_Hash_Mismatch:
		return "package file hash does not match the manifest"
	case .Prior_Manifest_Invalid:
		return "reviewed prior-only manifest is invalid"
	case .Image_Open_Failed:
		return "cannot open the stopped image"
	case .Destination_Inspect_Failed:
		return "cannot inspect the guest staging directory"
	case .Unexpected_Prior_Directory:
		return "guest GSW-VGA directory has unexpected prior content"
	case .Import_Begin_Failed:
		return "cannot begin the transactional tree import"
	case .Import_Failed:
		return "transactional tree import failed"
	case .Imported_Package_Invalid:
		return "imported guest package failed post-import verification"
	case .Apply_Failed:
		return "transactional image apply failed"
	}
	return "unknown failure"
}

stage_prior_kind_text :: proc(kind: Stage_Prior_Kind) -> string {
	switch kind {
	case .Absent:
		return "absent"
	case .Current:
		return "current"
	case .Reviewed_Legacy:
		return "reviewed-legacy"
	}
	return "unknown"
}

stage_contract_default :: proc() -> Stage_Contract {
	return {
		files = {
			{
				name = "gswmini.inf",
				source_path = `vmdisp9x-gsw\gswmini.inf`,
				destination_path = `GSW-VGA\gswmini.inf`,
				kind = .INF,
			},
			{
				name = "gswmini.drv",
				source_path = `vmdisp9x-gsw\gswmini.drv`,
				destination_path = `GSW-VGA\gswmini.drv`,
				kind = .Binary,
			},
			{
				name = "gswmini.vxd",
				source_path = `vmdisp9x-gsw\gswmini.vxd`,
				destination_path = `GSW-VGA\gswmini.vxd`,
				kind = .Binary,
			},
			{
				name = "gswhal9x.dll",
				source_path = `vmhal9x-gsw\gswhal9x.dll`,
				destination_path = `GSW-VGA\gswhal9x.dll`,
				kind = .Binary,
			},
			{
				name = "gswdd32.dll",
				source_path = `vmhal9x-gsw\gswdd32.dll`,
				destination_path = `GSW-VGA\gswdd32.dll`,
				kind = .Binary,
			},
		},
	}
}

stage_file_kind_text :: proc(kind: Stage_File_Kind) -> string {
	switch kind {
	case .INF:
		return "INF"
	case .Binary:
		return "Binary"
	case .Invalid:
		return ""
	}
	return ""
}

stage_file_index_for_destination :: proc(contract: ^Stage_Contract, value: string) -> int {
	if contract == nil {return -1}
	for file, index in contract.files {
		if value == file.destination_path {return index}
	}
	return -1
}

stage_file_index_for_name :: proc(contract: ^Stage_Contract, value: string) -> int {
	if contract == nil {return -1}
	for file, index in contract.files {
		if value == file.name {return index}
	}
	return -1
}

stage_parse_u64_decimal :: proc(value: string) -> (u64, bool) {
	if len(value) == 0 {return 0, false}
	result: u64
	for byte in value {
		if byte < '0' || byte > '9' {return 0, false}
		digit := u64(byte - '0')
		if result > (max(u64) - digit) / 10 {return 0, false}
		result = result * 10 + digit
	}
	return result, true
}

stage_hex_nibble :: proc(value: u8) -> (u8, bool) {
	if value >= '0' && value <= '9' {return value - '0', true}
	if value >= 'a' && value <= 'f' {return value - 'a' + 10, true}
	return 0, false
}

stage_parse_sha256 :: proc(value: string) -> ([32]u8, bool) {
	digest: [32]u8
	if len(value) != 64 {return digest, false}
	for index in 0 ..< 32 {
		high, high_ok := stage_hex_nibble(value[index * 2])
		low, low_ok := stage_hex_nibble(value[index * 2 + 1])
		if !high_ok || !low_ok {return {}, false}
		digest[index] = high << 4 | low
	}
	return digest, true
}

stage_read_tsv :: proc(path: string) -> ([]u8, bool) {
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error != nil {return nil, false}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular || info.size <= 0 || info.size > GSW_VGA_TSV_MAX_BYTES {
		return nil, false
	}
	data, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil || len(data) != int(info.size) {delete(data); return nil, false}
	if len(data) < 1 ||
	   data[len(data) - 1] != '\n' ||
	   len(data) >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf {
		delete(data)
		return nil, false
	}
	for byte in data {
		if byte == 0 ||
		   byte >= 0x80 ||
		   byte < 0x20 && byte != '\t' && byte != '\r' && byte != '\n' {
			delete(data)
			return nil, false
		}
	}
	return data, true
}

stage_parse_manifest :: proc(path: string, contract: ^Stage_Contract) -> bool {
	data, read_ok := stage_read_tsv(path)
	if !read_ok {return false}
	defer delete(data)
	header_seen := false
	physical_lines := 0
	rows := 0
	rest := string(data)
	for raw_line in strings.split_lines_iterator(&rest) {
		physical_lines += 1
		if physical_lines > GSW_VGA_TSV_MAX_LINES || len(raw_line) > GSW_VGA_TSV_MAX_LINE_BYTES {
			return false
		}
		line := raw_line
		if strings.has_suffix(line, "\r") {line = line[:len(line) - 1]}
		if strings.contains(line, "\r") {return false}
		if line == "" || strings.has_prefix(line, "#") {continue}
		if !header_seen {
			if line != GSW_VGA_MANIFEST_HEADER {return false}
			header_seen = true
			continue
		}
		rows += 1
		if rows > GSW_VGA_TSV_MAX_ROWS {return false}
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != 8 {delete(fields, context.temp_allocator); return false}
		if fields[0] != GSW_VGA_PACKAGE_ID {
			delete(fields, context.temp_allocator)
			continue
		}
		index := stage_file_index_for_destination(contract, fields[2])
		if index < 0 {
			delete(fields, context.temp_allocator)
			return false
		}
		file := &contract.files[index]
		bytes, bytes_ok := stage_parse_u64_decimal(fields[5])
		digest, digest_ok := stage_parse_sha256(fields[4])
		valid :=
			!file.manifest_seen &&
			fields[1] == file.source_path &&
			fields[3] == stage_file_kind_text(file.kind) &&
			digest_ok &&
			bytes_ok &&
			bytes > 0 &&
			bytes <= GSW_VGA_FILE_MAX_BYTES &&
			fields[6] == GSW_VGA_HARDWARE_ID &&
			fields[7] == "0" &&
			contract.total_bytes <= GSW_VGA_PACKAGE_MAX_BYTES - bytes
		if valid {
			file.bytes = bytes
			file.sha256 = digest
			file.manifest_seen = true
			contract.total_bytes += bytes
		}
		delete(fields, context.temp_allocator)
		if !valid {return false}
	}
	if !header_seen {return false}
	for file in contract.files {
		if !file.manifest_seen {return false}
	}
	return true
}

stage_reviewed_current_contract :: proc() -> Stage_Contract {
	contract := stage_contract_default()
	bytes := [GSW_VGA_FILE_COUNT]u64{3210, 16988, 39341, 46080, 32256}
	hashes := [GSW_VGA_FILE_COUNT]string {
		"5b954dc86a1c4e2e4e06c7fd16f3ea8c93991e485f1bae5512121c371d39b8ea",
		"2fccc72676e9ec67b0abe7f7db8ce266dc081d39e7722848579d79f550cea6e0",
		"61edea1973a7ce17fde3725d930c75495dd1ce2eeeb87fa799b8289cf534d876",
		"918b943a7ab49ef9568004c0c2a0d4591e75ac44ca3eeab9b8acb0d75d0a98a8",
		"bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4",
	}
	for index in 0 ..< GSW_VGA_FILE_COUNT {
		digest, digest_ok := stage_parse_sha256(hashes[index])
		if !digest_ok {return {}}
		contract.files[index].bytes = bytes[index]
		contract.files[index].sha256 = digest
		contract.files[index].manifest_seen = true
		contract.files[index].inventory_seen = true
		contract.total_bytes += bytes[index]
	}
	return contract
}

stage_reviewed_prior_contract :: proc() -> Stage_Contract {
	contract := stage_contract_default()
	bytes := [GSW_VGA_FILE_COUNT]u64{3210, 16944, 39341, 46080, 32256}
	hashes := [GSW_VGA_FILE_COUNT]string {
		"5aa3b3a078ce3fb42ee80d1dec71f96b486a98e8c95bd085f8f7c9ede32e4e34",
		"f1aa9a233ddf1af937acdd149db589a1834016d15431bbcdfcf5ac081414db73",
		"61edea1973a7ce17fde3725d930c75495dd1ce2eeeb87fa799b8289cf534d876",
		"918b943a7ab49ef9568004c0c2a0d4591e75ac44ca3eeab9b8acb0d75d0a98a8",
		"bfb72b4641e8e45e5ec90eb5c30e44aa4fac64fc37164c3429f428717d3964b4",
	}
	for index in 0 ..< GSW_VGA_FILE_COUNT {
		digest, digest_ok := stage_parse_sha256(hashes[index])
		if !digest_ok {return {}}
		contract.files[index].bytes = bytes[index]
		contract.files[index].sha256 = digest
		contract.files[index].manifest_seen = true
		contract.total_bytes += bytes[index]
	}
	return contract
}

stage_contract_identity_matches :: proc(contract, reviewed: ^Stage_Contract) -> bool {
	if contract == nil || reviewed == nil || contract.total_bytes != reviewed.total_bytes {
		return false
	}
	for file, index in contract.files {
		if !file.manifest_seen ||
		   file.bytes != reviewed.files[index].bytes ||
		   file.sha256 != reviewed.files[index].sha256 {
			return false
		}
	}
	return true
}

stage_parse_reviewed_prior_manifest :: proc(path: string, contract: ^Stage_Contract) -> bool {
	if contract == nil {return false}
	data, read_ok := stage_read_tsv(path)
	if !read_ok {return false}
	defer delete(data)
	header_seen := false
	physical_lines := 0
	rows := 0
	rest := string(data)
	for raw_line in strings.split_lines_iterator(&rest) {
		physical_lines += 1
		if physical_lines > GSW_VGA_TSV_MAX_LINES || len(raw_line) > GSW_VGA_TSV_MAX_LINE_BYTES {
			return false
		}
		line := raw_line
		if strings.has_suffix(line, "\r") {line = line[:len(line) - 1]}
		if strings.contains(line, "\r") {return false}
		if line == "" || strings.has_prefix(line, "#") {continue}
		if !header_seen {
			if line != GSW_VGA_PRIOR_MANIFEST_HEADER {return false}
			header_seen = true
			continue
		}
		rows += 1
		if rows > GSW_VGA_FILE_COUNT {return false}
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != 4 {
			delete(fields, context.temp_allocator)
			return false
		}
		index := stage_file_index_for_destination(contract, fields[1])
		bytes, bytes_ok := stage_parse_u64_decimal(fields[3])
		digest, digest_ok := stage_parse_sha256(fields[2])
		valid :=
			fields[0] == GSW_VGA_PRIOR_PACKAGE_ID &&
			index >= 0 &&
			bytes_ok &&
			bytes > 0 &&
			bytes <= GSW_VGA_FILE_MAX_BYTES &&
			digest_ok
		if valid {
			file := &contract.files[index]
			valid =
				!file.manifest_seen &&
				fields[1] == file.destination_path &&
				contract.total_bytes <= GSW_VGA_PACKAGE_MAX_BYTES - bytes
			if valid {
				file.bytes = bytes
				file.sha256 = digest
				file.manifest_seen = true
				contract.total_bytes += bytes
			}
		}
		delete(fields, context.temp_allocator)
		if !valid {return false}
	}
	if !header_seen || rows != GSW_VGA_FILE_COUNT {return false}
	reviewed := stage_reviewed_prior_contract()
	return stage_contract_identity_matches(contract, &reviewed)
}

stage_parse_inventory :: proc(path: string, contract: ^Stage_Contract) -> bool {
	data, read_ok := stage_read_tsv(path)
	if !read_ok {return false}
	defer delete(data)
	header_seen := false
	physical_lines := 0
	rows := 0
	rest := string(data)
	for raw_line in strings.split_lines_iterator(&rest) {
		physical_lines += 1
		if physical_lines > GSW_VGA_TSV_MAX_LINES || len(raw_line) > GSW_VGA_TSV_MAX_LINE_BYTES {
			return false
		}
		line := raw_line
		if strings.has_suffix(line, "\r") {line = line[:len(line) - 1]}
		if strings.contains(line, "\r") {return false}
		if line == "" || strings.has_prefix(line, "#") {continue}
		if !header_seen {
			if line != GSW_VGA_INVENTORY_HEADER {return false}
			header_seen = true
			continue
		}
		rows += 1
		if rows > GSW_VGA_TSV_MAX_ROWS {return false}
		fields := strings.split(line, "\t", context.temp_allocator)
		if len(fields) != 5 {delete(fields, context.temp_allocator); return false}
		if fields[0] != GSW_VGA_PACKAGE_ID {
			delete(fields, context.temp_allocator)
			continue
		}
		index := stage_file_index_for_destination(contract, fields[1])
		if index < 0 {
			delete(fields, context.temp_allocator)
			return false
		}
		file := &contract.files[index]
		valid :=
			!file.inventory_seen &&
			fields[2] == stage_file_kind_text(file.kind) &&
			fields[3] == GSW_VGA_HARDWARE_ID &&
			fields[4] == "0"
		if valid {file.inventory_seen = true}
		delete(fields, context.temp_allocator)
		if !valid {return false}
	}
	if !header_seen {return false}
	for file in contract.files {
		if !file.manifest_seen || !file.inventory_seen {return false}
	}
	return true
}

stage_hash_host_file :: proc(path: string, expected_bytes: u64) -> ([32]u8, bool) {
	digest: [32]u8
	info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error != nil {return digest, false}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular ||
	   info.size < 0 ||
	   u64(info.size) != expected_bytes {return digest, false}
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

stage_validate_host_package :: proc(
	package_directory: string,
	contract: ^Stage_Contract,
) -> Stage_Diagnostic {
	info, stat_error := os.lstat(package_directory, context.temp_allocator)
	if stat_error != nil {return .Package_Directory_Unsafe}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Directory {return .Package_Directory_Unsafe}
	directory, open_error := os.open(package_directory, {.Read})
	if open_error != nil {return .Package_Directory_Unsafe}
	entries, read_error := os.read_directory(directory, -1, context.temp_allocator)
	_ = os.close(directory)
	if read_error != nil {return .Package_Directory_Unsafe}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	if len(entries) != GSW_VGA_FILE_COUNT {return .Package_Shape_Invalid}
	seen: [GSW_VGA_FILE_COUNT]bool
	for entry in entries {
		index := stage_file_index_for_name(contract, entry.name)
		if index < 0 || seen[index] {return .Package_Shape_Invalid}
		seen[index] = true
		path, path_error := filepath.join({package_directory, entry.name}, context.temp_allocator)
		if path_error != nil {return .Package_File_Invalid}
		digest, hash_ok := stage_hash_host_file(path, contract.files[index].bytes)
		delete(path, context.temp_allocator)
		if !hash_ok {return .Package_File_Invalid}
		if digest != contract.files[index].sha256 {return .Package_Hash_Mismatch}
	}
	for present in seen {
		if !present {return .Package_Shape_Invalid}
	}
	return .None
}

stage_hash_guest_file :: proc(
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
		valid :=
			read.offset == offset && read.total == expected_bytes && u64(len(read.data)) == length
		if valid {sha2.update(&ctx, read.data)}
		fat32session.edit_read_destroy(&read)
		if !valid {return digest, {}, false}
		offset += length
	}
	sha2.final(&ctx, digest[:])
	return digest, {}, true
}

stage_verify_guest_directory :: proc(
	session: ^fat32session.Edit_Session,
	contract: ^Stage_Contract,
) -> (
	bool,
	bool,
	fat32session.Session_Error,
) {
	stat, stat_error := fat32session.edit_stat(session, GSW_VGA_GUEST_DIRECTORY)
	if stat_error.code != .None {return false, false, stat_error}
	if !stat.exists {return false, true, {}}
	if !stat.is_directory {return true, false, {}}
	seen: [GSW_VGA_FILE_COUNT]bool
	entry_count := 0
	cursor: u64
	for {
		page, list_error := fat32session.edit_list(
			session,
			GSW_VGA_GUEST_DIRECTORY,
			cursor,
			fat32session.EDIT_PAGE_ENTRY_LIMIT,
		)
		if list_error.code != .None {return true, false, list_error}
		for entry in page.entries {
			entry_count += 1
			index := stage_file_index_for_name(contract, entry.name)
			if index < 0 ||
			   seen[index] ||
			   entry.is_directory ||
			   entry.size != contract.files[index].bytes {
				fat32session.edit_page_destroy(&page)
				return true, false, {}
			}
			seen[index] = true
			path := strings.concatenate(
				{GSW_VGA_GUEST_DIRECTORY, "/", entry.name},
				context.temp_allocator,
			)
			digest, read_error, hash_ok := stage_hash_guest_file(
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
	if entry_count != GSW_VGA_FILE_COUNT {return true, false, {}}
	for present in seen {
		if !present {return true, false, {}}
	}
	return true, true, {}
}

stage_classify_guest_directory :: proc(
	session: ^fat32session.Edit_Session,
	current, reviewed_prior: ^Stage_Contract,
) -> (
	Stage_Prior_Kind,
	bool,
	fat32session.Session_Error,
) {
	current_exists, current_valid, current_error := stage_verify_guest_directory(session, current)
	if current_error.code != .None {return .Absent, false, current_error}
	if !current_exists {return .Absent, true, {}}
	if current_valid {return .Current, true, {}}
	prior_exists, prior_valid, prior_error := stage_verify_guest_directory(session, reviewed_prior)
	if prior_error.code != .None {return .Absent, false, prior_error}
	if prior_exists && prior_valid {return .Reviewed_Legacy, true, {}}
	return .Absent, false, {}
}

stage_run_import_job :: proc(session: ^fat32session.Edit_Session) -> fat32session.Session_Error {
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
				"GSW-VGA tree import did not complete",
			)
		case .Pending, .Running:
		}
	}
}

stage_gsw_vga_package_contracts :: proc(
	image_path, package_directory: string,
	contract, prior_contract: ^Stage_Contract,
	adapter := fat32session.Adapter_Kind.Process,
) -> Stage_Result {
	if image_path == "" || package_directory == "" || contract == nil || prior_contract == nil {
		return {diagnostic = .Invalid_Arguments}
	}
	host_diagnostic := stage_validate_host_package(package_directory, contract)
	if host_diagnostic != .None {return {diagnostic = host_diagnostic}}

	session, open_error := fat32session.open_edit(image_path, "gsw-vga-offline-stage", 0, adapter)
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
	prior_kind, prior_valid, inspect_error := stage_classify_guest_directory(
		session,
		contract,
		prior_contract,
	)
	if inspect_error.code != .None {
		return {
			diagnostic = .Destination_Inspect_Failed,
			session_error = inspect_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	if !prior_valid {
		return {
			diagnostic = .Unexpected_Prior_Directory,
			transaction = transaction,
			total_bytes = contract.total_bytes,
		}
	}
	prior_exists := prior_kind != .Absent
	begin_error := fat32session.edit_begin_import_tree(
		session,
		package_directory,
		GSW_VGA_GUEST_DIRECTORY,
		prior_exists,
	)
	if begin_error.code != .None {
		return {
			diagnostic = .Import_Begin_Failed,
			session_error = begin_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
			prior_verified = prior_exists,
			prior_kind = prior_kind,
		}
	}
	if import_error := stage_run_import_job(session); import_error.code != .None {
		return {
			diagnostic = .Import_Failed,
			session_error = import_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
			prior_verified = prior_exists,
			prior_kind = prior_kind,
		}
	}
	imported_exists, imported_valid, verify_error := stage_verify_guest_directory(
		session,
		contract,
	)
	if verify_error.code != .None || !imported_exists || !imported_valid {
		return {
			diagnostic = .Imported_Package_Invalid,
			session_error = verify_error,
			transaction = transaction,
			total_bytes = contract.total_bytes,
			prior_verified = prior_exists,
			prior_kind = prior_kind,
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
			prior_verified = prior_exists,
			prior_kind = prior_kind,
		}
	}
	return {
		transaction = transaction,
		total_bytes = contract.total_bytes,
		prior_verified = prior_exists,
		prior_kind = prior_kind,
	}
}

stage_gsw_vga_package :: proc(
	image_path, package_directory, manifest_path, inventory_path, prior_manifest_path: string,
	adapter := fat32session.Adapter_Kind.Process,
) -> Stage_Result {
	if image_path == "" ||
	   package_directory == "" ||
	   manifest_path == "" ||
	   inventory_path == "" ||
	   prior_manifest_path == "" {
		return {diagnostic = .Invalid_Arguments}
	}
	contract := stage_contract_default()
	if !stage_parse_manifest(manifest_path, &contract) {return {diagnostic = .Manifest_Invalid}}
	if !stage_parse_inventory(inventory_path, &contract) {return {diagnostic = .Inventory_Invalid}}
	for file in contract.files {
		if !file.manifest_seen || !file.inventory_seen {
			return {diagnostic = .Manifest_Inventory_Mismatch}
		}
	}
	reviewed_current := stage_reviewed_current_contract()
	if !stage_contract_identity_matches(&contract, &reviewed_current) {
		return {diagnostic = .Current_Manifest_Unreviewed}
	}
	prior_contract := stage_contract_default()
	if !stage_parse_reviewed_prior_manifest(prior_manifest_path, &prior_contract) {
		return {diagnostic = .Prior_Manifest_Invalid}
	}
	return stage_gsw_vga_package_contracts(
		image_path,
		package_directory,
		&contract,
		&prior_contract,
		adapter,
	)
}
