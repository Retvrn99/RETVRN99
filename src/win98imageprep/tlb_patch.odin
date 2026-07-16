// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import cabinetextract "../cabinetextract"
import "base:runtime"
import "core:os"
import "core:path/filepath"

TLB_VMM32_NAME :: "VMM32.VXD"
TLB_VMM32_FIRST_CABINET :: "BASE4.CAB"
TLB_VMM32_SOURCE_MAX_BYTES :: u64(16 * 1024 * 1024)
TLB_VMM32_OUTPUT_MAX_BYTES :: u64(32 * 1024 * 1024)
TLB_W4_CHUNK_BYTES :: 8192
TLB_WX_HEADER_BYTES :: 16

TLB_Overlay_Code :: enum u16 {
	None,
	Invalid_Argument,
	Workspace_Exists,
	Source_Extraction_Failed,
	Source_Read_Failed,
	Source_Unsafe,
	Source_Changed,
	Source_Too_Large,
	Unsupported_Container,
	Invalid_Container,
	Output_Too_Large,
	Decompression_Failed,
	Signature_Missing,
	Signature_Ambiguous,
	Destination_Exists,
	Destination_Changed,
	Destination_Write_Failed,
}

TLB_Patch_State :: enum u8 {
	Applied,
	Already_Applied,
}

TLB_Patch_Variant :: enum u8 {
	Updated_V1,
	Updated_V2,
	Old_Upgrade_V1,
	Old_Upgrade_V2,
	Simple_V1,
	Simple_V2,
}

TLB_Overlay_Result :: struct {
	diagnostic:        TLB_Overlay_Code,
	source_diagnostic: cabinetextract.Setup_Source_Extract_Diagnostic,
	state:             TLB_Patch_State,
	variant:           TLB_Patch_Variant,
}

TLB_File_Identity :: struct {
	device:  u64,
	file_id: u128,
}

TLB_Patch_Definition :: struct {
	variant:     TLB_Patch_Variant,
	original:    []u8,
	check_mask:  []u8,
	patched:     []u8,
	modify_mask: []u8,
}

TLB_Publication_Status :: enum u8 {
	Published,
	Conflict,
	Failed,
}

TLB_Publish_No_Replace_Proc :: proc(
	ctx: rawptr,
	source, destination: string,
) -> TLB_Publication_Status

TLB_Publish_Replace_Proc :: proc(
	ctx: rawptr,
	source, destination: string,
	expected: TLB_File_Identity,
) -> TLB_Publication_Status

TLB_Captured_Publish_Hook_Proc :: proc(
	ctx: rawptr,
	source, captured, destination: string,
)

TLB_Publication_Adapter :: struct {
	ctx:        rawptr,
	no_replace: TLB_Publish_No_Replace_Proc,
	replace:    TLB_Publish_Replace_Proc,
}

@(private)
tlb_u16 :: proc(data: []u8, offset: int) -> u16 {
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private)
tlb_u32 :: proc(data: []u8, offset: int) -> u32 {
	return u32(data[offset]) |
	       u32(data[offset + 1]) << 8 |
	       u32(data[offset + 2]) << 16 |
	       u32(data[offset + 3]) << 24
}

@(private)
tlb_clone_bytes :: proc(data: []u8, allocator: runtime.Allocator) -> []u8 {
	result := make([]u8, len(data), allocator)
	copy(result, data)
	return result
}

@(private)
tlb_w3_valid :: proc(data: []u8, pe_offset: int) -> bool {
	if pe_offset < 64 || pe_offset > len(data) - TLB_WX_HEADER_BYTES {return false}
	if data[pe_offset] != 'W' || data[pe_offset + 1] != '3' {return false}
	count := int(tlb_u16(data, pe_offset + 4))
	return count > 0 && count <= 4096 && pe_offset + TLB_WX_HEADER_BYTES + count * 16 <= len(data)
}

@(private)
tlb_ds_read_bits :: proc(data: []u8, bit_position: ^int, count: int) -> (u32, bool) {
	if bit_position == nil || count < 0 || count > 32 || bit_position^ > len(data) * 8 - count {
		return 0, false
	}
	result: u32
	for index in 0 ..< count {
		position := bit_position^ + index
		result |= u32(data[position / 8] >> u8(position & 7) & 1) << u32(index)
	}
	bit_position^ += count
	return result, true
}

@(private)
tlb_ds_count :: proc(buffer: ^u32, bits: ^int) -> (int, bool) {
	if buffer == nil || bits == nil {return 0, false}
	value := buffer^
	zeroes := 0
	for zeroes < 9 && value & 1 == 0 {
		value >>= 1
		zeroes += 1
	}
	needed := 1 + zeroes * 2
	if zeroes == 9 || bits^ < needed {return 0, false}
	value >>= 1
	mask := u32(1 << u32(zeroes)) - 1
	count := int(u32(1 << u32(zeroes)) + (value & mask) + 1)
	value >>= u32(zeroes)
	buffer^ = value
	bits^ -= needed
	return count, true
}

@(private)
tlb_ds_decompress :: proc(source, destination: []u8) -> (int, bool) {
	position := 0
	bit_position := 0
	buffer: u32
	buffer_bits := 0
	for position < len(destination) {
		if buffer_bits < 32 {
			incoming, read := tlb_ds_read_bits(source, &bit_position, 32 - buffer_bits)
			if !read {return 0, false}
			buffer |= incoming << u32(buffer_bits)
			buffer_bits = 32
		}
		copy_distance := 0
		copy_count := 0
		switch buffer & 3 {
		case 1:
			destination[position] = 0x80 | u8(buffer >> 2 & 0x7f)
			position += 1
			buffer >>= 9
			buffer_bits -= 9
			continue
		case 2:
			destination[position] = u8(buffer >> 2 & 0x7f)
			position += 1
			buffer >>= 9
			buffer_bits -= 9
			continue
		case 0:
			copy_distance = int(buffer >> 2 & 0x3f)
			buffer >>= 8
			buffer_bits -= 8
			if copy_distance == 0 {return position, true}
			count_ok: bool
			copy_count, count_ok = tlb_ds_count(&buffer, &buffer_bits)
			if !count_ok {return 0, false}
		case 3:
			if buffer & 7 == 3 {
				copy_distance = int(buffer >> 3 & 0xff) + 64
				buffer >>= 11
				buffer_bits -= 11
			} else {
				copy_distance = int(buffer >> 3 & 0xfff) + 320
				buffer >>= 15
				buffer_bits -= 15
				if copy_distance == 4415 {continue}
			}
			count_ok: bool
			copy_count, count_ok = tlb_ds_count(&buffer, &buffer_bits)
			if !count_ok {return 0, false}
		}
		if copy_distance <= 0 || copy_distance > position || copy_count <= 0 ||
		   copy_count > len(destination) - position {
			return 0, false
		}
		for _ in 0 ..< copy_count {
			destination[position] = destination[position - copy_distance]
			position += 1
		}
	}
	return position, true
}

@(private)
tlb_w4_to_w3 :: proc(
	source: []u8,
	pe_offset: int,
	allocator: runtime.Allocator,
) -> ([]u8, TLB_Overlay_Code) {
	if pe_offset > len(source) - TLB_WX_HEADER_BYTES {return nil, .Invalid_Container}
	chunk_size := int(tlb_u16(source, pe_offset + 4))
	chunk_count := int(tlb_u16(source, pe_offset + 6))
	table_offset := pe_offset + TLB_WX_HEADER_BYTES
	if chunk_size != TLB_W4_CHUNK_BYTES ||
	   chunk_count <= 0 ||
	   source[pe_offset + 8] != 'D' ||
	   source[pe_offset + 9] != 'S' ||
	   chunk_count > (len(source) - table_offset) / 4 {
		return nil, .Invalid_Container
	}
	output_limit := u64(pe_offset) + u64(chunk_count) * u64(chunk_size)
	if output_limit > TLB_VMM32_OUTPUT_MAX_BYTES {return nil, .Output_Too_Large}
	table_end := table_offset + chunk_count * 4
	output := make([]u8, int(output_limit), allocator)
	copy(output[:pe_offset], source[:pe_offset])
	output_position := pe_offset
	for chunk_index in 0 ..< chunk_count {
		start := int(tlb_u32(source, table_offset + chunk_index * 4))
		end := len(source)
		if chunk_index + 1 < chunk_count {
			end = int(tlb_u32(source, table_offset + (chunk_index + 1) * 4))
		}
		if start < table_end || end <= start || end > len(source) || end - start > chunk_size {
			delete(output, allocator)
			return nil, .Invalid_Container
		}
		written := 0
		if end - start == chunk_size {
			copy(output[output_position:output_position + chunk_size], source[start:end])
			written = chunk_size
		} else {
			ok: bool
			written, ok = tlb_ds_decompress(
				source[start:end],
				output[output_position:output_position + chunk_size],
			)
			if !ok || written == 0 || chunk_index + 1 < chunk_count && written != chunk_size {
				delete(output, allocator)
				return nil, .Decompression_Failed
			}
		}
		output_position += written
	}
	return output[:output_position], .None
}

@(private)
tlb_normalize_w3 :: proc(
	source: []u8,
	allocator: runtime.Allocator,
) -> ([]u8, TLB_Overlay_Code) {
	if u64(len(source)) > TLB_VMM32_SOURCE_MAX_BYTES {return nil, .Source_Too_Large}
	if len(source) < 64 || source[0] != 'M' || source[1] != 'Z' {return nil, .Unsupported_Container}
	pe_offset_u32 := tlb_u32(source, 60)
	pe_offset := int(pe_offset_u32)
	if pe_offset < 64 || pe_offset > len(source) - TLB_WX_HEADER_BYTES {
		return nil, .Invalid_Container
	}
	if source[pe_offset] == 'W' && source[pe_offset + 1] == '3' {
		if !tlb_w3_valid(source, pe_offset) {return nil, .Invalid_Container}
		return tlb_clone_bytes(source, allocator), .None
	}
	if source[pe_offset] == 'L' && source[pe_offset + 1] == 'E' && pe_offset > 0x400 {
		w3_offset := pe_offset - 0x400
		if tlb_w3_valid(source, w3_offset) {
			return tlb_clone_bytes(source, allocator), .None
		}
	}
	if source[pe_offset] != 'W' || source[pe_offset + 1] != '4' {
		return nil, .Unsupported_Container
	}
	result, diagnostic := tlb_w4_to_w3(source, pe_offset, allocator)
	if diagnostic != .None {return nil, diagnostic}
	if !tlb_w3_valid(result, pe_offset) {
		delete(result, allocator)
		return nil, .Invalid_Container
	}
	return result, .None
}

@(private)
tlb_signature_checked :: proc(mask: []u8, index: int) -> bool {
	return index >= 0 &&
	       index / 8 < len(mask) &&
	       mask[index / 8] & (u8(0x80) >> u8(index & 7)) != 0
}

@(private)
tlb_signature_match :: proc(
	data: []u8,
	offset: int,
	signature, mask: []u8,
) -> bool {
	if len(signature) == 0 ||
	   len(mask) < (len(signature) + 7) / 8 ||
	   offset < 0 ||
	   offset > len(data) - len(signature) {
		return false
	}
	for value, index in signature {
		if tlb_signature_checked(mask, index) && data[offset + index] != value {return false}
	}
	return true
}

@(private)
tlb_patch_definitions :: proc() -> [6]TLB_Patch_Definition {
	return {
		{
			variant = .Updated_V1,
			original = TLB_UPDATED_V1_ORIGINAL[:],
			check_mask = TLB_UPDATED_V1_CHECK[:],
			patched = TLB_UPDATED_V1_PATCHED[:],
			modify_mask = TLB_UPDATED_V1_MODIFY[:],
		},
		{
			variant = .Updated_V2,
			original = TLB_UPDATED_V2_ORIGINAL[:],
			check_mask = TLB_UPDATED_V2_CHECK[:],
			patched = TLB_UPDATED_V2_PATCHED[:],
			modify_mask = TLB_UPDATED_V2_MODIFY[:],
		},
		{
			variant = .Old_Upgrade_V1,
			original = TLB_OLD_UPGRADE_V1_ORIGINAL[:],
			check_mask = TLB_OLD_UPGRADE_V1_CHECK[:],
			patched = TLB_OLD_UPGRADE_V1_PATCHED[:],
			modify_mask = TLB_OLD_UPGRADE_V1_MODIFY[:],
		},
		{
			variant = .Old_Upgrade_V2,
			original = TLB_OLD_UPGRADE_V2_ORIGINAL[:],
			check_mask = TLB_OLD_UPGRADE_V2_CHECK[:],
			patched = TLB_OLD_UPGRADE_V2_PATCHED[:],
			modify_mask = TLB_OLD_UPGRADE_V2_MODIFY[:],
		},
		{
			variant = .Simple_V1,
			original = TLB_SIMPLE_V1_ORIGINAL[:],
			check_mask = TLB_SIMPLE_V1_CHECK[:],
			patched = TLB_SIMPLE_V1_PATCHED[:],
			modify_mask = TLB_SIMPLE_V1_MODIFY[:],
		},
		{
			variant = .Simple_V2,
			original = TLB_SIMPLE_V2_ORIGINAL[:],
			check_mask = TLB_SIMPLE_V2_CHECK[:],
			patched = TLB_SIMPLE_V2_PATCHED[:],
			modify_mask = TLB_SIMPLE_V2_MODIFY[:],
		},
	}
}

tlb_vmm32_transform :: proc(
	source: []u8,
	allocator := context.allocator,
) -> (
	[]u8,
	TLB_Patch_State,
	TLB_Patch_Variant,
	TLB_Overlay_Code,
) {
	data, diagnostic := tlb_normalize_w3(source, allocator)
	if diagnostic != .None {return nil, {}, {}, diagnostic}
	definitions := tlb_patch_definitions()
	match_offset := -1
	match_definition := TLB_Patch_Definition {}
	match_state := TLB_Patch_State.Applied
	for offset in 0 ..< len(data) {
		matched_here := false
		for definition in definitions {
			if offset > len(data) - len(definition.original) {continue}
			if tlb_signature_match(data, offset, definition.original, definition.check_mask) {
				match_definition = definition
				match_state = .Applied
				matched_here = true
				break
			}
			if tlb_signature_match(data, offset, definition.patched, definition.check_mask) {
				match_definition = definition
				match_state = .Already_Applied
				matched_here = true
				break
			}
		}
		if !matched_here {continue}
		if match_offset >= 0 {
			delete(data, allocator)
			return nil, {}, {}, .Signature_Ambiguous
		}
		match_offset = offset
	}
	if match_offset < 0 {
		delete(data, allocator)
		return nil, {}, {}, .Signature_Missing
	}
	if match_state == .Applied {
		for index in 0 ..< len(match_definition.patched) {
			if tlb_signature_checked(match_definition.modify_mask, index) {
				data[match_offset + index] = match_definition.patched[index]
			}
		}
	}
	return data, match_state, match_definition.variant, .None
}

@(private)
tlb_write_all :: proc(file: ^os.File, data: []u8) -> bool {
	if file == nil {return false}
	written := 0
	for written < len(data) {
		amount, write_error := os.write(file, data[written:])
		if write_error != nil || amount <= 0 {return false}
		written += amount
	}
	return true
}

@(private)
tlb_read_bounded_regular :: proc(
	path: string,
	allocator: runtime.Allocator,
) -> ([]u8, TLB_File_Identity, TLB_Overlay_Code) {
	path_info, stat_error := os.lstat(path, context.temp_allocator)
	if stat_error != nil {return nil, {}, .Source_Read_Failed}
	defer os.file_info_delete(path_info, context.temp_allocator)
	if path_info.type != .Regular || !tlb_platform_path_is_safe_regular(path) {
		return nil, {}, .Source_Unsafe
	}
	if path_info.size < 0 {return nil, {}, .Source_Read_Failed}
	if u64(path_info.size) > TLB_VMM32_SOURCE_MAX_BYTES {
		return nil, {}, .Source_Too_Large
	}
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return nil, {}, .Source_Read_Failed}
	defer os.close(file)
	identity, identity_ok := tlb_platform_file_identity(file)
	if !identity_ok {return nil, {}, .Source_Unsafe}
	file_info, file_stat_error := os.fstat(file, context.temp_allocator)
	if file_stat_error != nil {return nil, {}, .Source_Read_Failed}
	defer os.file_info_delete(file_info, context.temp_allocator)
	if file_info.size != path_info.size {return nil, {}, .Source_Changed}
	data := make([]u8, int(file_info.size), allocator)
	position := 0
	for position < len(data) {
		amount, read_error := os.read(file, data[position:])
		if read_error != nil && read_error != .EOF || amount <= 0 {
			delete(data, allocator)
			return nil, {}, .Source_Changed
		}
		position += amount
	}
	extra: [1]u8
	amount, read_error := os.read(file, extra[:])
	if amount != 0 || read_error != .EOF {
		delete(data, allocator)
		return nil, {}, .Source_Changed
	}
	return data, identity, .None
}

@(private)
tlb_current_identity :: proc(path: string) -> (TLB_File_Identity, bool) {
	if !tlb_platform_path_is_safe_regular(path) {return {}, false}
	file, open_error := os.open(path, {.Read})
	if open_error != nil {return {}, false}
	defer os.close(file)
	return tlb_platform_file_identity(file)
}

@(private)
tlb_write_adjacent_temp :: proc(
	destination: string,
	data: []u8,
	allocator: runtime.Allocator,
) -> (string, bool) {
	parent := filepath.dir(destination)
	file, create_error := os.create_temp_file(parent, ".retvrn99-vmm32-*.tmp")
	if create_error != nil {return "", false}
	path := ""
	succeeded := false
	defer {
		if file != nil {_ = os.close(file)}
		if !succeeded && path != "" {_ = os.remove(path)}
	}
	info, stat_error := os.fstat(file, allocator)
	if stat_error != nil {return "", false}
	path = info.fullpath
	if !tlb_write_all(file, data) || os.close(file) != nil {
		file = nil
		return "", false
	}
	file = nil
	succeeded = true
	return path, true
}

@(private)
tlb_vacant_adjacent_backup_path :: proc(
	destination: string,
	allocator: runtime.Allocator,
) -> (string, bool) {
	parent := filepath.dir(destination)
	file, create_error := os.create_temp_file(parent, ".retvrn99-vmm32-backup-*.tmp")
	if create_error != nil {return "", false}
	path := ""
	defer if file != nil {_ = os.close(file)}
	info, stat_error := os.fstat(file, allocator)
	if stat_error != nil {return "", false}
	path = info.fullpath
	if os.close(file) != nil {
		file = nil
		_ = os.remove(path)
		delete(path, allocator)
		return "", false
	}
	file = nil
	if os.remove(path) != nil {
		delete(path, allocator)
		return "", false
	}
	return path, true
}

@(private)
tlb_default_publish_no_replace :: proc(
	_: rawptr,
	source, destination: string,
) -> TLB_Publication_Status {
	return tlb_platform_publish_no_replace(source, destination)
}

@(private)
tlb_publish_replace_captured :: proc(
	hook_ctx: rawptr,
	source, destination: string,
	expected: TLB_File_Identity,
	hook: TLB_Captured_Publish_Hook_Proc,
) -> TLB_Publication_Status {
	backup, backup_ok := tlb_vacant_adjacent_backup_path(
		destination,
		context.temp_allocator,
	)
	if !backup_ok {return .Failed}
	captured := false
	preserve_backup := false
	defer {
		if captured && !preserve_backup {_ = os.remove(backup)}
		delete(backup, context.temp_allocator)
	}
	capture_status := tlb_platform_publish_no_replace(destination, backup)
	if capture_status != .Published {return capture_status}
	captured = true
	captured_identity, identity_ok := tlb_current_identity(backup)
	if !identity_ok || captured_identity != expected {
		restore_status := tlb_platform_publish_no_replace(backup, destination)
		if restore_status == .Published {
			captured = false
			return .Conflict
		}
		preserve_backup = true
		return restore_status == .Conflict ? .Conflict : .Failed
	}
	if hook != nil {hook(hook_ctx, source, backup, destination)}
	publish_status := tlb_platform_publish_no_replace(source, destination)
	if publish_status == .Published {return .Published}
	restore_status := tlb_platform_publish_no_replace(backup, destination)
	if restore_status == .Published {
		captured = false
		return publish_status
	}
	preserve_backup = true
	if restore_status == .Conflict {return .Conflict}
	return .Failed
}

@(private)
tlb_default_publish_replace :: proc(
	_: rawptr,
	source, destination: string,
	expected: TLB_File_Identity,
) -> TLB_Publication_Status {
	return tlb_publish_replace_captured(nil, source, destination, expected, nil)
}

@(private)
tlb_default_setup_source_extract :: proc(
	_: rawptr,
	setup_directory, first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	return cabinetextract.setup_source_extract_files(setup_directory, first_cabinet, requests)
}

tlb_overlay_stage :: proc(
	setup_directory, workspace_directory: string,
	overlay: Setup_Source_Overlay = {},
	publication: TLB_Publication_Adapter = {},
) -> TLB_Overlay_Result {
	if setup_directory == "" ||
	   workspace_directory == "" ||
	   !filepath.is_abs(setup_directory) ||
	   !filepath.is_abs(workspace_directory) {
		return {diagnostic = .Invalid_Argument}
	}
	destination, destination_error := filepath.join({setup_directory, TLB_VMM32_NAME})
	if destination_error != nil {
		delete(destination)
		return {diagnostic = .Destination_Write_Failed}
	}
	defer delete(destination)
	publisher := publication
	if publisher.no_replace == nil {publisher.no_replace = tlb_default_publish_no_replace}
	if publisher.replace == nil {publisher.replace = tlb_default_publish_replace}

	_, destination_stat_error := os.lstat(destination, context.temp_allocator)
	destination_exists := destination_stat_error == nil
	if destination_stat_error != nil && destination_stat_error != os.General_Error.Not_Exist {
		return {diagnostic = .Destination_Write_Failed}
	}
	if destination_exists {
		source, identity, read_diagnostic := tlb_read_bounded_regular(
			destination,
			context.temp_allocator,
		)
		if read_diagnostic != .None {return {diagnostic = read_diagnostic}}
		defer delete(source, context.temp_allocator)
		patched, state, variant, patch_diagnostic := tlb_vmm32_transform(
			source,
			context.temp_allocator,
		)
		if patch_diagnostic != .None {return {diagnostic = patch_diagnostic}}
		defer delete(patched, context.temp_allocator)
		if state == .Already_Applied {
			return {state = state, variant = variant}
		}
		temp_path, temp_ok := tlb_write_adjacent_temp(
			destination,
			patched,
			context.temp_allocator,
		)
		if !temp_ok {return {diagnostic = .Destination_Write_Failed}}
		defer {
			_ = os.remove(temp_path)
			delete(temp_path, context.temp_allocator)
		}
		status := publisher.replace(
			publisher.ctx,
			temp_path,
			destination,
			identity,
		)
		switch status {
		case .Published:
			return {state = state, variant = variant}
		case .Conflict:
			return {diagnostic = .Destination_Changed}
		case .Failed:
			return {diagnostic = .Destination_Write_Failed}
		}
	}

	temp_directory, temp_error := filepath.join({workspace_directory, "tlb-overlay"})
	if temp_error != nil {
		delete(temp_directory)
		return {diagnostic = .Destination_Write_Failed}
	}
	defer delete(temp_directory)
	if _, stat_error := os.lstat(temp_directory, context.temp_allocator); stat_error == nil {
		return {diagnostic = .Workspace_Exists}
	} else if stat_error != os.General_Error.Not_Exist || os.make_directory(temp_directory) != nil {
		return {diagnostic = .Destination_Write_Failed}
	}
	defer os.remove_all(temp_directory)
	source_path, source_error := filepath.join({temp_directory, "source.vxd"})
	if source_error != nil {
		delete(source_path)
		return {diagnostic = .Destination_Write_Failed}
	}
	defer delete(source_path)
	requests := [?]cabinetextract.Setup_Source_Extract_Request {
		{
			source_name = TLB_VMM32_NAME,
			destination = source_path,
			max_output_bytes = TLB_VMM32_SOURCE_MAX_BYTES,
		},
	}
	extract := overlay.extract
	if extract == nil {extract = tlb_default_setup_source_extract}
	source_diagnostic := extract(
		overlay.ctx,
		setup_directory,
		TLB_VMM32_FIRST_CABINET,
		requests[:],
	)
	if source_diagnostic.code != .None {
		return {
			diagnostic = .Source_Extraction_Failed,
			source_diagnostic = source_diagnostic,
		}
	}
	source, _, read_diagnostic := tlb_read_bounded_regular(
		source_path,
		context.temp_allocator,
	)
	if read_diagnostic != .None {return {diagnostic = read_diagnostic}}
	defer delete(source, context.temp_allocator)
	patched, state, variant, patch_diagnostic := tlb_vmm32_transform(
		source,
		context.temp_allocator,
	)
	if patch_diagnostic != .None {return {diagnostic = patch_diagnostic}}
	defer delete(patched, context.temp_allocator)
	temp_path, temp_ok := tlb_write_adjacent_temp(
		destination,
		patched,
		context.temp_allocator,
	)
	if !temp_ok {return {diagnostic = .Destination_Write_Failed}}
	defer {
		_ = os.remove(temp_path)
		delete(temp_path, context.temp_allocator)
	}
	status := publisher.no_replace(publisher.ctx, temp_path, destination)
	switch status {
	case .Published:
		return {state = state, variant = variant}
	case .Conflict:
		return {diagnostic = .Destination_Exists}
	case .Failed:
		return {diagnostic = .Destination_Write_Failed}
	}
	return {diagnostic = .Destination_Write_Failed}
}
