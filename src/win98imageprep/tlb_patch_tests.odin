// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import cabinetextract "../cabinetextract"
import "core:bytes"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

TLB_TEST_PE_OFFSET :: 128
TLB_TEST_SIGNATURE_OFFSET :: 512

tlb_test_put_u16 :: proc(data: []u8, offset: int, value: u16) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
}

tlb_test_put_u32 :: proc(data: []u8, offset: int, value: u32) {
	data[offset] = u8(value)
	data[offset + 1] = u8(value >> 8)
	data[offset + 2] = u8(value >> 16)
	data[offset + 3] = u8(value >> 24)
}

tlb_test_definition :: proc(variant: TLB_Patch_Variant) -> TLB_Patch_Definition {
	for definition in tlb_patch_definitions() {
		if definition.variant == variant {return definition}
	}
	return {}
}

tlb_test_w3_with_signature :: proc(signature: []u8, size := 4096) -> []u8 {
	data := make([]u8, size, context.temp_allocator)
	data[0], data[1] = 'M', 'Z'
	tlb_test_put_u32(data, 60, TLB_TEST_PE_OFFSET)
	data[TLB_TEST_PE_OFFSET], data[TLB_TEST_PE_OFFSET + 1] = 'W', '3'
	tlb_test_put_u16(data, TLB_TEST_PE_OFFSET + 4, 1)
	copy(
		data[TLB_TEST_SIGNATURE_OFFSET:TLB_TEST_SIGNATURE_OFFSET + len(signature)],
		signature,
	)
	return data
}

tlb_test_variant_source :: proc(
	variant: TLB_Patch_Variant,
	patched: bool,
) -> []u8 {
	definition := tlb_test_definition(variant)
	signature := definition.original
	if patched {signature = definition.patched}
	data := tlb_test_w3_with_signature(signature)
	if variant == .Simple_V1 || variant == .Simple_V2 {
		data[TLB_TEST_SIGNATURE_OFFSET + 56] =
			data[TLB_TEST_SIGNATURE_OFFSET + 56] ~ 0x5a
	}
	return data
}

tlb_test_expected_patch :: proc(
	source: []u8,
	definition: TLB_Patch_Definition,
) -> []u8 {
	expected := make([]u8, len(source), context.temp_allocator)
	copy(expected, source)
	for index in 0 ..< len(definition.patched) {
		if tlb_signature_checked(definition.modify_mask, index) {
			expected[TLB_TEST_SIGNATURE_OFFSET + index] = definition.patched[index]
		}
	}
	return expected
}

@(test)
test_tlb_patch_applies_all_six_pristine_variants_exactly :: proc(t: ^testing.T) {
	for variant in TLB_Patch_Variant {
		definition := tlb_test_definition(variant)
		source := tlb_test_variant_source(variant, false)
		expected := tlb_test_expected_patch(source, definition)
		actual, state, actual_variant, diagnostic := tlb_vmm32_transform(
			source,
			context.temp_allocator,
		)
		testing.expect_value(t, diagnostic, TLB_Overlay_Code.None)
		testing.expect_value(t, state, TLB_Patch_State.Applied)
		testing.expect_value(t, actual_variant, variant)
		testing.expect(t, bytes.equal(actual, expected))
	}
}

@(test)
test_tlb_patch_accepts_all_six_patched_forms_idempotently :: proc(t: ^testing.T) {
	for variant in TLB_Patch_Variant {
		source := tlb_test_variant_source(variant, true)
		actual, state, _, diagnostic := tlb_vmm32_transform(
			source,
			context.temp_allocator,
		)
		testing.expect_value(t, diagnostic, TLB_Overlay_Code.None)
		testing.expect_value(t, state, TLB_Patch_State.Already_Applied)
		testing.expect(t, bytes.equal(actual, source))
	}
}

@(test)
test_tlb_patch_uses_upstream_precedence_at_one_physical_match :: proc(t: ^testing.T) {
	source := tlb_test_w3_with_signature(TLB_UPDATED_V1_ORIGINAL[:])
	actual, state, variant, diagnostic := tlb_vmm32_transform(
		source,
		context.temp_allocator,
	)
	testing.expect_value(t, diagnostic, TLB_Overlay_Code.None)
	testing.expect_value(t, state, TLB_Patch_State.Applied)
	testing.expect_value(t, variant, TLB_Patch_Variant.Updated_V1)
	testing.expect(t, actual != nil)
}

@(test)
test_tlb_patch_rejects_missing_and_distinct_physical_matches :: proc(t: ^testing.T) {
	mismatch := tlb_test_w3_with_signature(TLB_UPDATED_V1_ORIGINAL[:])
	mismatch[TLB_TEST_SIGNATURE_OFFSET] = mismatch[TLB_TEST_SIGNATURE_OFFSET] ~ 1
	mismatch_result, _, _, mismatch_diagnostic := tlb_vmm32_transform(
		mismatch,
		context.temp_allocator,
	)
	testing.expect_value(t, mismatch_diagnostic, TLB_Overlay_Code.Signature_Missing)
	testing.expect(t, mismatch_result == nil)

	ambiguous := tlb_test_w3_with_signature(TLB_UPDATED_V1_ORIGINAL[:])
	second_offset := 2048
	copy(
		ambiguous[second_offset:second_offset + len(TLB_SIMPLE_V2_ORIGINAL)],
		TLB_SIMPLE_V2_ORIGINAL[:],
	)
	ambiguous[second_offset + 56] = ambiguous[second_offset + 56] ~ 0x5a
	ambiguous_result, _, _, ambiguous_diagnostic := tlb_vmm32_transform(
		ambiguous,
		context.temp_allocator,
	)
	testing.expect_value(t, ambiguous_diagnostic, TLB_Overlay_Code.Signature_Ambiguous)
	testing.expect(t, ambiguous_result == nil)
}

@(test)
test_tlb_patch_accepts_embedded_w3_behind_le_without_rewriting_pointer :: proc(t: ^testing.T) {
	source := tlb_test_w3_with_signature(TLB_UPDATED_V1_ORIGINAL[:])
	le_offset := TLB_TEST_PE_OFFSET + 0x400
	tlb_test_put_u32(source, 60, u32(le_offset))
	source[le_offset], source[le_offset + 1] = 'L', 'E'
	original_pointer := source[60:64]
	actual, state, variant, diagnostic := tlb_vmm32_transform(
		source,
		context.temp_allocator,
	)
	testing.expect_value(t, diagnostic, TLB_Overlay_Code.None)
	testing.expect_value(t, state, TLB_Patch_State.Applied)
	testing.expect_value(t, variant, TLB_Patch_Variant.Updated_V1)
	testing.expect(t, bytes.equal(actual[60:64], original_pointer))
	testing.expect_value(t, actual[le_offset], u8('L'))
	testing.expect_value(t, actual[le_offset + 1], u8('E'))
}

@(test)
test_tlb_patch_enforces_source_and_decompressed_size_bounds :: proc(t: ^testing.T) {
	too_large := make([]u8, int(TLB_VMM32_SOURCE_MAX_BYTES) + 1, context.temp_allocator)
	source_result, _, _, source_diagnostic := tlb_vmm32_transform(
		too_large,
		context.temp_allocator,
	)
	testing.expect_value(t, source_diagnostic, TLB_Overlay_Code.Source_Too_Large)
	testing.expect(t, source_result == nil)

	chunk_count := int(TLB_VMM32_OUTPUT_MAX_BYTES / TLB_W4_CHUNK_BYTES)
	w4 := make([]u8, TLB_TEST_PE_OFFSET + TLB_WX_HEADER_BYTES + chunk_count * 4, context.temp_allocator)
	w4[0], w4[1] = 'M', 'Z'
	tlb_test_put_u32(w4, 60, TLB_TEST_PE_OFFSET)
	w4[TLB_TEST_PE_OFFSET], w4[TLB_TEST_PE_OFFSET + 1] = 'W', '4'
	tlb_test_put_u16(w4, TLB_TEST_PE_OFFSET + 4, TLB_W4_CHUNK_BYTES)
	tlb_test_put_u16(w4, TLB_TEST_PE_OFFSET + 6, u16(chunk_count))
	w4[TLB_TEST_PE_OFFSET + 8], w4[TLB_TEST_PE_OFFSET + 9] = 'D', 'S'
	output_result, _, _, output_diagnostic := tlb_vmm32_transform(w4, context.temp_allocator)
	testing.expect_value(t, output_diagnostic, TLB_Overlay_Code.Output_Too_Large)
	testing.expect(t, output_result == nil)
}

tlb_test_write_bits :: proc(output: ^[dynamic]u8, bit_position: ^int, value: u32, count: int) {
	for index in 0 ..< count {
		byte_index := bit_position^ / 8
		if byte_index == len(output^) {append(output, 0)}
		output^[byte_index] =
			output^[byte_index] | u8(value >> u32(index) & 1) << u8(bit_position^ & 7)
		bit_position^ += 1
	}
}

tlb_test_ds_literals :: proc(data: []u8) -> []u8 {
	result := make([dynamic]u8, context.temp_allocator)
	bit_position := 0
	for value in data {
		token := u32(value & 0x7f) << 2
		if value & 0x80 == 0 {token |= 2} else {token |= 1}
		tlb_test_write_bits(&result, &bit_position, token, 9)
	}
	tlb_test_write_bits(&result, &bit_position, 0, 8 + 32)
	return result[:]
}

tlb_test_w4_from_w3 :: proc(w3: []u8) -> []u8 {
	payload := tlb_test_ds_literals(w3[TLB_TEST_PE_OFFSET:])
	chunk_offset := TLB_TEST_PE_OFFSET + TLB_WX_HEADER_BYTES + 4
	result := make([]u8, chunk_offset + len(payload), context.temp_allocator)
	copy(result[:TLB_TEST_PE_OFFSET], w3[:TLB_TEST_PE_OFFSET])
	result[TLB_TEST_PE_OFFSET], result[TLB_TEST_PE_OFFSET + 1] = 'W', '4'
	tlb_test_put_u16(result, TLB_TEST_PE_OFFSET + 4, TLB_W4_CHUNK_BYTES)
	tlb_test_put_u16(result, TLB_TEST_PE_OFFSET + 6, 1)
	result[TLB_TEST_PE_OFFSET + 8], result[TLB_TEST_PE_OFFSET + 9] = 'D', 'S'
	tlb_test_put_u32(result, TLB_TEST_PE_OFFSET + TLB_WX_HEADER_BYTES, u32(chunk_offset))
	copy(result[chunk_offset:], payload)
	return result
}

@(test)
test_tlb_patch_decompresses_w4_before_patching :: proc(t: ^testing.T) {
	w3 := tlb_test_variant_source(.Updated_V1, false)
	w4 := tlb_test_w4_from_w3(w3)
	from_w3, w3_state, w3_variant, w3_diagnostic := tlb_vmm32_transform(
		w3,
		context.temp_allocator,
	)
	from_w4, w4_state, w4_variant, w4_diagnostic := tlb_vmm32_transform(
		w4,
		context.temp_allocator,
	)
	testing.expect_value(t, w3_diagnostic, TLB_Overlay_Code.None)
	testing.expect_value(t, w4_diagnostic, TLB_Overlay_Code.None)
	testing.expect_value(t, w4_state, w3_state)
	testing.expect_value(t, w4_variant, w3_variant)
	testing.expect(t, bytes.equal(from_w4, from_w3))
}

TLB_Test_Extract_Context :: struct {
	source:           []u8,
	fail:             bool,
	oversize:         bool,
	calls:            int,
	race_destination: string,
	race_contents:    string,
}

tlb_test_extract :: proc(
	ctx: rawptr,
	_: string,
	first_cabinet: string,
	requests: []cabinetextract.Setup_Source_Extract_Request,
) -> cabinetextract.Setup_Source_Extract_Diagnostic {
	state := (^TLB_Test_Extract_Context)(ctx)
	if state == nil || first_cabinet != TLB_VMM32_FIRST_CABINET || len(requests) != 1 {
		return {code = .Invalid_Argument, request_index = -1}
	}
	state.calls += 1
	request := requests[0]
	if request.source_name != TLB_VMM32_NAME {
		return {code = .Target_Missing, request_index = 0}
	}
	if state.oversize {
		file, open_error := os.open(request.destination, {.Write, .Create, .Excl})
		if open_error != nil {return {code = .Output_Write_Failed, request_index = 0}}
		truncate_error := os.truncate(file, i64(TLB_VMM32_SOURCE_MAX_BYTES + 1))
		close_error := os.close(file)
		if truncate_error != nil || close_error != nil {
			return {code = .Output_Write_Failed, request_index = 0}
		}
	} else if u64(len(state.source)) > request.max_output_bytes ||
	          os.write_entire_file(request.destination, state.source) != nil {
		return {code = .Output_Write_Failed, request_index = 0}
	}
	if state.race_destination != "" {
		if os.write_entire_file(state.race_destination, state.race_contents) != nil {
			return {code = .Output_Write_Failed, request_index = 0}
		}
	}
	if state.fail {return {code = .Cabinet_Corrupt, request_index = 0}}
	return {extracted_count = 1, request_index = -1}
}

tlb_test_stage_root :: proc(t: ^testing.T) -> (string, string, bool) {
	root, root_error := os.make_directory_temp("", "retvrn99-tlb-overlay-*", context.allocator)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return "", "", false}
	setup, setup_error := filepath.join({root, "setup"}, context.allocator)
	if !testing.expect(t, setup_error == nil && os.make_directory(setup) == nil) {
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
		return "", "", false
	}
	return root, setup, true
}

tlb_test_destination :: proc(setup: string) -> string {
	result, _ := filepath.join({setup, TLB_VMM32_NAME}, context.temp_allocator)
	return result
}

tlb_test_expect_setup_entries :: proc(t: ^testing.T, setup: string, expected: int) {
	directory, open_error := os.open(setup, {.Read})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	defer os.close(directory)
	entries, read_error := os.read_directory(directory, -1, context.temp_allocator)
	if !testing.expect_value(t, read_error, os.Error(nil)) {return}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	testing.expect_value(t, len(entries), expected)
}

tlb_test_backup_contents :: proc(setup: string) -> ([]u8, bool) {
	directory, open_error := os.open(setup, {.Read})
	if open_error != nil {return nil, false}
	defer os.close(directory)
	entries, read_error := os.read_directory(directory, -1, context.temp_allocator)
	if read_error != nil {return nil, false}
	defer os.file_info_slice_delete(entries, context.temp_allocator)
	for entry in entries {
		if strings.has_prefix(entry.name, ".retvrn99-vmm32-backup-") {
			contents, contents_error := os.read_entire_file(
				entry.fullpath,
				context.temp_allocator,
			)
			return contents, contents_error == nil
		}
	}
	return nil, false
}

@(test)
test_tlb_overlay_extracts_and_atomically_publishes_loose_vmm32 :: proc(t: ^testing.T) {
	root, setup, ready := tlb_test_stage_root(t)
	if !ready {return}
	defer {
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
	ctx := TLB_Test_Extract_Context {source = tlb_test_variant_source(.Updated_V1, false)}
	result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.None)
	testing.expect_value(t, result.state, TLB_Patch_State.Applied)
	testing.expect_value(t, result.variant, TLB_Patch_Variant.Updated_V1)
	testing.expect_value(t, ctx.calls, 1)
	destination := tlb_test_destination(setup)
	actual, read_error := os.read_entire_file(destination, context.temp_allocator)
	expected, _, _, expected_diagnostic := tlb_vmm32_transform(
		ctx.source,
		context.temp_allocator,
	)
	testing.expect_value(t, read_error, os.Error(nil))
	testing.expect_value(t, expected_diagnostic, TLB_Overlay_Code.None)
	testing.expect(t, bytes.equal(actual, expected))
	tlb_test_expect_setup_entries(t, setup, 1)
	workspace, _ := filepath.join({root, "tlb-overlay"}, context.temp_allocator)
	_, workspace_error := os.lstat(workspace, context.temp_allocator)
	testing.expect_value(t, workspace_error, os.General_Error.Not_Exist)
}

@(test)
test_tlb_overlay_uses_existing_pristine_and_patched_loose_files :: proc(t: ^testing.T) {
	cases := [?]bool {false, true}
	for already_patched in cases {
		root, setup, ready := tlb_test_stage_root(t)
		if !ready {return}
		destination := tlb_test_destination(setup)
		source := tlb_test_variant_source(.Updated_V1, false)
		if already_patched {
			source, _, _, _ = tlb_vmm32_transform(source, context.temp_allocator)
		}
		testing.expect(t, os.write_entire_file(destination, source) == nil)
		ctx := TLB_Test_Extract_Context {source = tlb_test_variant_source(.Updated_V1, false)}
		result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
		testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.None)
		testing.expect_value(t, ctx.calls, 0)
		actual, read_error := os.read_entire_file(destination, context.temp_allocator)
		testing.expect_value(t, read_error, os.Error(nil))
		if already_patched {
			testing.expect_value(t, result.state, TLB_Patch_State.Already_Applied)
			testing.expect(t, bytes.equal(actual, source))
		} else {
			expected, _, _, _ := tlb_vmm32_transform(source, context.temp_allocator)
			testing.expect_value(t, result.state, TLB_Patch_State.Applied)
			testing.expect(t, bytes.equal(actual, expected))
		}
		tlb_test_expect_setup_entries(t, setup, 1)
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
}

@(test)
test_tlb_overlay_rejects_unsupported_or_unsafe_existing_loose_file_without_extracting :: proc(t: ^testing.T) {
	root, setup, ready := tlb_test_stage_root(t)
	if !ready {return}
	defer {
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
	destination := tlb_test_destination(setup)
	testing.expect(t, os.write_entire_file(destination, "sentinel") == nil)
	ctx := TLB_Test_Extract_Context {source = tlb_test_variant_source(.Updated_V1, false)}
	result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Unsupported_Container)
	testing.expect_value(t, ctx.calls, 0)
	actual, _ := os.read_entire_file(destination, context.temp_allocator)
	testing.expect_value(t, string(actual), "sentinel")

	_ = os.remove(destination)
	testing.expect(t, os.make_directory(destination) == nil)
	result = tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Source_Unsafe)
	testing.expect_value(t, ctx.calls, 0)
}

tlb_test_publish_failure :: proc(
	_: rawptr,
	_, _: string,
	_: TLB_File_Identity,
) -> TLB_Publication_Status {
	return .Failed
}

TLB_Test_Race_Context :: struct {
	contents: string,
}

tlb_test_publish_identity_race :: proc(
	ctx: rawptr,
	source, destination: string,
	expected: TLB_File_Identity,
) -> TLB_Publication_Status {
	state := (^TLB_Test_Race_Context)(ctx)
	_ = os.remove(destination)
	if state == nil || os.write_entire_file(destination, state.contents) != nil {return .Failed}
	return tlb_default_publish_replace(nil, source, destination, expected)
}

TLB_Test_Window_Action :: enum u8 {
	Race_Destination,
	Remove_Source,
}

TLB_Test_Window_Context :: struct {
	action:    TLB_Test_Window_Action,
	contents:  string,
	succeeded: bool,
}

tlb_test_publication_window_hook :: proc(
	ctx: rawptr,
	source, _, destination: string,
) {
	state := (^TLB_Test_Window_Context)(ctx)
	if state == nil {return}
	switch state.action {
	case .Race_Destination:
		state.succeeded = os.write_entire_file(destination, state.contents) == nil
	case .Remove_Source:
		state.succeeded = os.remove(source) == nil
	}
}

@(test)
test_tlb_publication_window_never_overwrites_race_and_restores_on_failure :: proc(
	t: ^testing.T,
) {
	for action in TLB_Test_Window_Action {
		root, setup, ready := tlb_test_stage_root(t)
		if !ready {return}
		destination := tlb_test_destination(setup)
		original := "original"
		testing.expect(t, os.write_entire_file(destination, original) == nil)
		identity, identity_ok := tlb_current_identity(destination)
		testing.expect(t, identity_ok)
		patched := [?]u8 {'p', 'a', 't', 'c', 'h', 'e', 'd'}
		temp_path, temp_ok := tlb_write_adjacent_temp(
			destination,
			patched[:],
			context.temp_allocator,
		)
		testing.expect(t, temp_ok)
		window := TLB_Test_Window_Context {
			action = action,
			contents = "raced",
		}
		status := tlb_publish_replace_captured(
			&window,
			temp_path,
			destination,
			identity,
			tlb_test_publication_window_hook,
		)
		testing.expect(t, window.succeeded)
		actual, read_error := os.read_entire_file(destination, context.temp_allocator)
		testing.expect_value(t, read_error, os.Error(nil))
		if action == .Race_Destination {
			testing.expect_value(t, status, TLB_Publication_Status.Conflict)
			testing.expect_value(t, string(actual), "raced")
			backup, backup_ok := tlb_test_backup_contents(setup)
			testing.expect(t, backup_ok)
			testing.expect_value(t, string(backup), original)
		} else {
			testing.expect_value(t, status, TLB_Publication_Status.Failed)
			testing.expect_value(t, string(actual), original)
			_, backup_ok := tlb_test_backup_contents(setup)
			testing.expect(t, !backup_ok)
			tlb_test_expect_setup_entries(t, setup, 1)
		}
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
}

@(test)
test_tlb_overlay_existing_replace_failure_and_identity_race_roll_back :: proc(t: ^testing.T) {
	cases := [?]bool {false, true}
	for identity_race in cases {
		root, setup, ready := tlb_test_stage_root(t)
		if !ready {return}
		destination := tlb_test_destination(setup)
		original := tlb_test_variant_source(.Updated_V1, false)
		testing.expect(t, os.write_entire_file(destination, original) == nil)
		race := TLB_Test_Race_Context {contents = "raced"}
		publisher := TLB_Publication_Adapter {
			ctx = &race,
			replace = tlb_test_publish_failure,
		}
		if identity_race {publisher.replace = tlb_test_publish_identity_race}
		result := tlb_overlay_stage(setup, root, {}, publisher)
		actual, read_error := os.read_entire_file(destination, context.temp_allocator)
		testing.expect_value(t, read_error, os.Error(nil))
		if identity_race {
			testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Destination_Changed)
			testing.expect_value(t, string(actual), "raced")
		} else {
			testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Destination_Write_Failed)
			testing.expect(t, bytes.equal(actual, original))
		}
		tlb_test_expect_setup_entries(t, setup, 1)
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
}

@(test)
test_tlb_overlay_no_replace_race_preserves_raced_destination :: proc(t: ^testing.T) {
	root, setup, ready := tlb_test_stage_root(t)
	if !ready {return}
	defer {
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
	destination := tlb_test_destination(setup)
	ctx := TLB_Test_Extract_Context {
		source = tlb_test_variant_source(.Updated_V1, false),
		race_destination = destination,
		race_contents = "raced",
	}
	result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Destination_Exists)
	actual, read_error := os.read_entire_file(destination, context.temp_allocator)
	testing.expect_value(t, read_error, os.Error(nil))
	testing.expect_value(t, string(actual), "raced")
	tlb_test_expect_setup_entries(t, setup, 1)
}

@(test)
test_tlb_overlay_bounds_existing_and_extracted_files_before_allocation :: proc(t: ^testing.T) {
	cases := [?]bool {true, false}
	for existing in cases {
		root, setup, ready := tlb_test_stage_root(t)
		if !ready {return}
		destination := tlb_test_destination(setup)
		ctx := TLB_Test_Extract_Context {oversize = true}
		if existing {
			file, open_error := os.open(destination, {.Write, .Create, .Excl})
			testing.expect_value(t, open_error, os.Error(nil))
			if file != nil {
				testing.expect(t, os.truncate(file, i64(TLB_VMM32_SOURCE_MAX_BYTES + 1)) == nil)
				_ = os.close(file)
			}
		}
		result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
		testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Source_Too_Large)
		if existing {testing.expect_value(t, ctx.calls, 0)} else {testing.expect_value(t, ctx.calls, 1)}
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
}

@(test)
test_tlb_overlay_extraction_and_patch_failures_leave_setup_unchanged :: proc(t: ^testing.T) {
	root, setup, ready := tlb_test_stage_root(t)
	if !ready {return}
	defer {
		_ = os.remove_all(root)
		delete(root)
		delete(setup)
	}
	ctx := TLB_Test_Extract_Context {
		source = tlb_test_variant_source(.Updated_V1, false),
		fail = true,
	}
	result := tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Source_Extraction_Failed)
	tlb_test_expect_setup_entries(t, setup, 0)
	ctx.fail = false
	ctx.source[TLB_TEST_SIGNATURE_OFFSET] = ctx.source[TLB_TEST_SIGNATURE_OFFSET] ~ 1
	result = tlb_overlay_stage(setup, root, {ctx = &ctx, extract = tlb_test_extract})
	testing.expect_value(t, result.diagnostic, TLB_Overlay_Code.Signature_Missing)
	tlb_test_expect_setup_entries(t, setup, 0)
}
