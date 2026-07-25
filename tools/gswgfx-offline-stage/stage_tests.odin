// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Gswgfx_Stage_Test_Fixture :: struct {
	package_directory: string,
	manifest_path:     string,
	contents:          [GSWGFX_FILE_COUNT]string,
}

@(private = "file")
gswgfx_stage_test_cleanup_fixture :: proc(fixture: ^Gswgfx_Stage_Test_Fixture) {
	if fixture == nil {return}
	contract := gswgfx_stage_contract_default()
	for file in contract.files {
		path, path_error := filepath.join(
			{fixture.package_directory, file.name},
			context.temp_allocator,
		)
		if path_error == nil {_ = os.remove(path)}
	}
	_ = os.remove(fixture.package_directory)
	_ = os.remove(fixture.manifest_path)
}

@(private = "file")
gswgfx_stage_test_digest :: proc(contents: string) -> [32]u8 {
	digest: [32]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)contents)
	sha2.final(&ctx, digest[:])
	return digest
}

@(private = "file")
gswgfx_stage_test_manifest_text :: proc(
	contents: [GSWGFX_FILE_COUNT]string,
) -> string {
	contract := gswgfx_stage_contract_default()
	builder := strings.builder_make()
	fmt.sbprintf(&builder, "%s\n", GSWGFX_MANIFEST_HEADER)
	for file, index in contract.files {
		digest := gswgfx_stage_test_digest(contents[index])
		fmt.sbprintf(&builder, "%s\t%s\t", GSWGFX_GUEST_DIRECTORY, file.name)
		for byte in digest {fmt.sbprintf(&builder, "%02x", byte)}
		fmt.sbprintf(&builder, "\t%d\n", len(contents[index]))
	}
	return strings.to_string(builder)
}

@(private = "file")
gswgfx_stage_test_fixture :: proc(
	t: ^testing.T,
	root, name: string,
	contents: [GSWGFX_FILE_COUNT]string,
) -> (
	Gswgfx_Stage_Test_Fixture,
	bool,
) {
	fixture := Gswgfx_Stage_Test_Fixture{contents = contents}
	fixture.package_directory, _ = filepath.join({root, name}, context.temp_allocator)
	manifest_name := strings.concatenate({name, "-stage.tsv"}, context.temp_allocator)
	fixture.manifest_path, _ = filepath.join({root, manifest_name}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(fixture.package_directory), os.Error(nil)) {
		return fixture, false
	}
	contract := gswgfx_stage_contract_default()
	for file, index in contract.files {
		path, path_error := filepath.join(
			{fixture.package_directory, file.name},
			context.temp_allocator,
		)
		if !testing.expect(t, path_error == nil) ||
		   !testing.expect_value(t, os.write_entire_file(path, contents[index]), os.Error(nil)) {
			return fixture, false
		}
	}
	manifest := gswgfx_stage_test_manifest_text(contents)
	defer delete(manifest)
	if !testing.expect_value(
		t,
		os.write_entire_file(fixture.manifest_path, manifest),
		os.Error(nil),
	) {
		return fixture, false
	}
	return fixture, true
}

@(private = "file")
gswgfx_stage_test_contract :: proc(
	t: ^testing.T,
	fixture: ^Gswgfx_Stage_Test_Fixture,
) -> (
	Gswgfx_Stage_Contract,
	bool,
) {
	contract := gswgfx_stage_contract_default()
	if fixture == nil ||
	   !testing.expect(t, gswgfx_stage_parse_manifest(fixture.manifest_path, &contract)) {
		return contract, false
	}
	return contract, true
}

@(private = "file")
gswgfx_stage_test_image :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
	path, path_error := filepath.join({root, name}, context.temp_allocator)
	if !testing.expect(t, path_error == nil) {return path, false}
	info, create_error := fat32session.create_image({path = path, capacity_gib = 1}, .In_Process)
	if !testing.expect_value(t, create_error.code, fat32session.Error_Code.None) {
		return path, false
	}
	fat32session.image_info_destroy(&info)
	return path, true
}

@(private = "file")
gswgfx_stage_test_invalid_manifest :: proc(
	t: ^testing.T,
	path, contents: string,
) -> bool {
	if !testing.expect_value(t, os.write_entire_file(path, contents), os.Error(nil)) {
		return false
	}
	contract := gswgfx_stage_contract_default()
	return testing.expect(t, !gswgfx_stage_parse_manifest(path, &contract))
}

@(private = "file")
gswgfx_stage_test_manifest_is_exact_canonical_lf :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-gswgfx-manifest-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	contents := [GSWGFX_FILE_COUNT]string{"fixture-executable\n", "fixture-plan\n"}
	fixture, fixture_ok := gswgfx_stage_test_fixture(t, root, "canonical", contents)
	if !fixture_ok {return}
	contract, contract_ok := gswgfx_stage_test_contract(t, &fixture)
	if !contract_ok {return}
	testing.expect_value(t, contract.total_bytes, u64(len(contents[0]) + len(contents[1])))
	testing.expect_value(t, contract.files[0].bytes, u64(len(contents[0])))
	testing.expect_value(t, contract.files[1].bytes, u64(len(contents[1])))

	canonical, read_error := os.read_entire_file(fixture.manifest_path, context.allocator)
	if !testing.expect_value(t, read_error, os.Error(nil)) {return}
	defer delete(canonical)
	bad_path, _ := filepath.join({root, "bad.tsv"}, context.temp_allocator)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, string(canonical[:len(canonical) - 1])) {
		return
	}
	crlf, crlf_allocated := strings.replace_all(
		string(canonical),
		"\n",
		"\r\n",
		context.allocator,
	)
	defer if crlf_allocated {delete(crlf)}
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, crlf) {return}
	bom := strings.concatenate({"\xef\xbb\xbf", string(canonical)}, context.allocator)
	defer delete(bom)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, bom) {return}
	extra_blank := strings.concatenate({string(canonical), "\n"}, context.allocator)
	defer delete(extra_blank)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, extra_blank) {return}
	commented := strings.concatenate({"#comment\n", string(canonical)}, context.allocator)
	defer delete(commented)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, commented) {return}

	lines := strings.split(string(canonical), "\n", context.temp_allocator)
	defer delete(lines, context.temp_allocator)
	swapped := strings.concatenate(
		{lines[0], "\n", lines[2], "\n", lines[1], "\n"},
		context.allocator,
	)
	defer delete(swapped)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, swapped) {return}
	duplicate := strings.concatenate(
		{lines[0], "\n", lines[1], "\n", lines[1], "\n"},
		context.allocator,
	)
	defer delete(duplicate)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, duplicate) {return}

	fields := strings.split(lines[1], "\t", context.temp_allocator)
	defer delete(fields, context.temp_allocator)
	uppercase_hash := strings.concatenate(
		{
			lines[0], "\n",
			fields[0], "\t", fields[1], "\t",
			"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			"\t", fields[3], "\n", lines[2], "\n",
		},
		context.allocator,
	)
	defer delete(uppercase_hash)
	if !gswgfx_stage_test_invalid_manifest(t, bad_path, uppercase_hash) {return}
	leading_zero := strings.concatenate(
		{
			lines[0], "\n",
			fields[0], "\t", fields[1], "\t", fields[2], "\t0", fields[3], "\n",
			lines[2], "\n",
		},
		context.allocator,
	)
	defer delete(leading_zero)
	gswgfx_stage_test_invalid_manifest(t, bad_path, leading_zero)
	_ = os.remove(bad_path)
	gswgfx_stage_test_cleanup_fixture(&fixture)
	_ = os.remove(root)
}

@(private = "file")
gswgfx_stage_test_host_package_rejects_shape_hash_and_stream_drift :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-gswgfx-host-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	contents := [GSWGFX_FILE_COUNT]string{"executable-one\n", "companion-one\n"}
	fixture, fixture_ok := gswgfx_stage_test_fixture(t, root, "package", contents)
	if !fixture_ok {return}
	contract, contract_ok := gswgfx_stage_test_contract(t, &fixture)
	if !contract_ok {return}
	if !testing.expect_value(
		t,
		gswgfx_stage_validate_host_package(fixture.package_directory, &contract),
		Gswgfx_Stage_Diagnostic.None,
	) {
		return
	}
	extra, _ := filepath.join({fixture.package_directory, "EXTRA.TXT"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(extra, "extra"), os.Error(nil)) {return}
	testing.expect_value(
		t,
		gswgfx_stage_validate_host_package(fixture.package_directory, &contract),
		Gswgfx_Stage_Diagnostic.Package_Shape_Invalid,
	)
	if !testing.expect_value(t, os.remove(extra), os.Error(nil)) {return}
	companion, _ := filepath.join({fixture.package_directory, "GSWVBE.EXE"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(companion, "companion-two\n"), os.Error(nil)) {
		return
	}
	testing.expect_value(
		t,
		gswgfx_stage_validate_host_package(fixture.package_directory, &contract),
		Gswgfx_Stage_Diagnostic.Package_Hash_Mismatch,
	)
	if !testing.expect_value(t, os.write_entire_file(companion, contents[1]), os.Error(nil)) {return}
	when ODIN_OS == .Windows {
		executable, _ := filepath.join(
			{fixture.package_directory, "GSWGFX.EXE"},
			context.temp_allocator,
		)
		stream := strings.concatenate({executable, ":GSWGFX_TEST"}, context.temp_allocator)
		if stream_error := os.write_entire_file(stream, "hidden"); stream_error == nil {
			testing.expect_value(
				t,
				gswgfx_stage_validate_host_package(fixture.package_directory, &contract),
				Gswgfx_Stage_Diagnostic.Package_File_Invalid,
			)
		}
	}
	gswgfx_stage_test_cleanup_fixture(&fixture)
	_ = os.remove(root)
}

@(private = "file")
gswgfx_stage_test_verify_applied :: proc(
	t: ^testing.T,
	image_path: string,
	contract: ^Gswgfx_Stage_Contract,
) -> bool {
	session, open_error := fat32session.open_edit(
		image_path,
		"gswgfx-stage-test-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return false}
	exists, valid, verify_error := gswgfx_stage_verify_guest_directory(session, contract)
	if !testing.expect_value(t, verify_error.code, fat32session.Error_Code.None) ||
	   !testing.expect(t, exists && valid) {
		_ = fat32session.edit_finish(session, false)
		return false
	}
	finish_error := fat32session.edit_finish(session, false)
	return testing.expect_value(t, finish_error.code, fat32session.Error_Code.None)
}

@(test)
gswgfx_stage_test_import_is_exact_and_nonreplacing :: proc(t: ^testing.T) {
	gswgfx_stage_test_manifest_is_exact_canonical_lf(t)
	gswgfx_stage_test_host_package_rejects_shape_hash_and_stream_drift(t)
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-gswgfx-import-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	contents := [GSWGFX_FILE_COUNT]string{"synthetic-exe\n", "synthetic-plan\n"}
	fixture, fixture_ok := gswgfx_stage_test_fixture(t, root, "package", contents)
	image_path, image_ok := gswgfx_stage_test_image(t, root, "stage.img")
	if !fixture_ok || !image_ok {return}
	contract, contract_ok := gswgfx_stage_test_contract(t, &fixture)
	if !contract_ok {return}
	result := stage_gswgfx_package(
		image_path,
		fixture.package_directory,
		fixture.manifest_path,
		.In_Process,
	)
	if !testing.expect_value(t, result.diagnostic, Gswgfx_Stage_Diagnostic.None) ||
	   !testing.expect(t, result.transaction != 0) ||
	   !testing.expect_value(
		   t,
		   result.total_bytes,
		   u64(len(contents[0]) + len(contents[1])),
	   ) ||
	   !gswgfx_stage_test_verify_applied(t, image_path, &contract) {
		return
	}
	collision := stage_gswgfx_package(
		image_path,
		fixture.package_directory,
		fixture.manifest_path,
		.In_Process,
	)
	if !testing.expect_value(
		t,
		collision.diagnostic,
		Gswgfx_Stage_Diagnostic.Destination_Exists,
	) {
		return
	}
	if !gswgfx_stage_test_verify_applied(t, image_path, &contract) {return}
	gswgfx_stage_test_cleanup_fixture(&fixture)
	_ = os.remove(image_path)
	_ = os.remove(root)
}
