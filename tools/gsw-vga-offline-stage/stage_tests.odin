// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:crypto/sha2"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

Stage_Test_Fixture :: struct {
	package_directory:   string,
	manifest_path:       string,
	inventory_path:      string,
	prior_manifest_path: string,
}

@(private = "file")
stage_test_fixture :: proc(
	t: ^testing.T,
	root, name: string,
	contents: [GSW_VGA_FILE_COUNT]string,
) -> (
	Stage_Test_Fixture,
	bool,
) {
	fixture: Stage_Test_Fixture
	fixture.package_directory, _ = filepath.join({root, name}, context.temp_allocator)
	manifest_name := strings.concatenate({name, "-manifest.tsv"}, context.temp_allocator)
	inventory_name := strings.concatenate({name, "-inventory.tsv"}, context.temp_allocator)
	prior_name := strings.concatenate({name, "-prior.tsv"}, context.temp_allocator)
	fixture.manifest_path, _ = filepath.join({root, manifest_name}, context.temp_allocator)
	fixture.inventory_path, _ = filepath.join({root, inventory_name}, context.temp_allocator)
	fixture.prior_manifest_path, _ = filepath.join({root, prior_name}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(fixture.package_directory), os.Error(nil)) {
		return fixture, false
	}
	contract := stage_contract_default()
	manifest := strings.builder_make()
	inventory := strings.builder_make()
	prior := strings.builder_make()
	fmt.sbprintfln(&manifest, "%s", GSW_VGA_MANIFEST_HEADER)
	fmt.sbprintfln(&inventory, "%s", GSW_VGA_INVENTORY_HEADER)
	fmt.sbprintfln(&prior, "%s", GSW_VGA_PRIOR_MANIFEST_HEADER)
	for file, index in contract.files {
		path, path_error := filepath.join(
			{fixture.package_directory, file.name},
			context.temp_allocator,
		)
		if !testing.expect(t, path_error == nil) ||
		   !testing.expect_value(t, os.write_entire_file(path, contents[index]), os.Error(nil)) {
			strings.builder_destroy(&manifest)
			strings.builder_destroy(&inventory)
			strings.builder_destroy(&prior)
			return fixture, false
		}
		digest: [32]u8
		ctx: sha2.Context_256
		sha2.init_256(&ctx)
		sha2.update(&ctx, transmute([]u8)contents[index])
		sha2.final(&ctx, digest[:])
		fmt.sbprintf(
			&manifest,
			"%s\t%s\t%s\t%s\t",
			GSW_VGA_PACKAGE_ID,
			file.source_path,
			file.destination_path,
			stage_file_kind_text(file.kind),
		)
		for byte in digest {fmt.sbprintf(&manifest, "%02x", byte)}
		fmt.sbprintfln(&manifest, "\t%d\t%s\t0", len(contents[index]), GSW_VGA_HARDWARE_ID)
		fmt.sbprintfln(
			&inventory,
			"%s\t%s\t%s\t%s\t0",
			GSW_VGA_PACKAGE_ID,
			file.destination_path,
			stage_file_kind_text(file.kind),
			GSW_VGA_HARDWARE_ID,
		)
	}
	reviewed_prior := stage_reviewed_prior_contract()
	for file in reviewed_prior.files {
		fmt.sbprintf(&prior, "%s\t%s\t", GSW_VGA_PRIOR_PACKAGE_ID, file.destination_path)
		for byte in file.sha256 {fmt.sbprintf(&prior, "%02x", byte)}
		fmt.sbprintfln(&prior, "\t%d", file.bytes)
	}
	manifest_text := strings.to_string(manifest)
	inventory_text := strings.to_string(inventory)
	prior_text := strings.to_string(prior)
	defer delete(manifest_text)
	defer delete(inventory_text)
	defer delete(prior_text)
	if !testing.expect_value(
		   t,
		   os.write_entire_file(fixture.manifest_path, manifest_text),
		   os.Error(nil),
	   ) ||
	   !testing.expect_value(
			   t,
			   os.write_entire_file(fixture.inventory_path, inventory_text),
			   os.Error(nil),
		   ) ||
	   !testing.expect_value(
			   t,
			   os.write_entire_file(fixture.prior_manifest_path, prior_text),
			   os.Error(nil),
		   ) {
		return fixture, false
	}
	return fixture, true
}

@(private = "file")
stage_test_image :: proc(t: ^testing.T, root, name: string) -> (string, bool) {
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
stage_test_contract :: proc(
	t: ^testing.T,
	fixture: ^Stage_Test_Fixture,
) -> (
	Stage_Contract,
	bool,
) {
	contract := stage_contract_default()
	if fixture == nil ||
	   !testing.expect(t, stage_parse_manifest(fixture.manifest_path, &contract)) ||
	   !testing.expect(t, stage_parse_inventory(fixture.inventory_path, &contract)) {
		return contract, false
	}
	return contract, true
}

@(test)
stage_test_exact_package_restage_and_reject_drift :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp(
		"",
		"retvrn99-gsw-vga-stage-*",
		context.temp_allocator,
	)
	if !testing.expect_value(t, root_error, os.Error(nil)) {return}
	defer os.remove_all(root)
	original_contents := [GSW_VGA_FILE_COUNT]string {
		"fixture-inf\n",
		"fixture-drv\n",
		"fixture-vxd\n",
		"fixture-hal\n",
		"fixture-dd32\n",
	}
	replacement_contents := original_contents
	replacement_contents[4] = "different-dd32\n"
	original, original_ok := stage_test_fixture(t, root, "original", original_contents)
	replacement, replacement_ok := stage_test_fixture(t, root, "replacement", replacement_contents)
	image_path, image_ok := stage_test_image(t, root, "stage.img")
	if !original_ok || !replacement_ok || !image_ok {return}
	original_contract, original_contract_ok := stage_test_contract(t, &original)
	replacement_contract, replacement_contract_ok := stage_test_contract(t, &replacement)
	if !original_contract_ok || !replacement_contract_ok {return}
	reviewed_prior := stage_reviewed_prior_contract()

	first := stage_gsw_vga_package_contracts(
		image_path,
		original.package_directory,
		&original_contract,
		&reviewed_prior,
		.In_Process,
	)
	if !testing.expect_value(t, first.diagnostic, Stage_Diagnostic.None) {return}
	testing.expect(t, !first.prior_verified)
	testing.expect_value(t, first.prior_kind, Stage_Prior_Kind.Absent)
	testing.expect_value(t, first.total_bytes, u64(61))

	second := stage_gsw_vga_package_contracts(
		image_path,
		original.package_directory,
		&original_contract,
		&reviewed_prior,
		.In_Process,
	)
	if !testing.expect_value(t, second.diagnostic, Stage_Diagnostic.None) {return}
	testing.expect(t, second.prior_verified)
	testing.expect_value(t, second.prior_kind, Stage_Prior_Kind.Current)

	drift := stage_gsw_vga_package_contracts(
		image_path,
		replacement.package_directory,
		&replacement_contract,
		&reviewed_prior,
		.In_Process,
	)
	testing.expect_value(t, drift.diagnostic, Stage_Diagnostic.Unexpected_Prior_Directory)

	after_rejection := stage_gsw_vga_package_contracts(
		image_path,
		original.package_directory,
		&original_contract,
		&reviewed_prior,
		.In_Process,
	)
	testing.expect_value(t, after_rejection.diagnostic, Stage_Diagnostic.None)
	testing.expect(t, after_rejection.prior_verified)
	stage_test_legacy_replace_apply(t, root)
	stage_test_contract_failures(t, root)
}

@(private = "file")
stage_test_legacy_replace_apply :: proc(t: ^testing.T, root: string) {
	legacy_contents := [GSW_VGA_FILE_COUNT]string {
		"legacy-inf-one\n",
		"legacy-drv-two\n",
		"legacy-vxd-three\n",
		"legacy-hal-four\n",
		"legacy-dd32-five\n",
	}
	current_contents := [GSW_VGA_FILE_COUNT]string {
		"current-inf-six\n",
		"current-drv-seven\n",
		"current-vxd-eight\n",
		"current-hal-nine\n",
		"current-dd32-ten\n",
	}
	legacy, legacy_ok := stage_test_fixture(t, root, "legacy-five", legacy_contents)
	current, current_ok := stage_test_fixture(t, root, "current-five", current_contents)
	image_path, image_ok := stage_test_image(t, root, "legacy-replace.img")
	if !legacy_ok || !current_ok || !image_ok {return}
	legacy_contract, legacy_contract_ok := stage_test_contract(t, &legacy)
	current_contract, current_contract_ok := stage_test_contract(t, &current)
	if !legacy_contract_ok || !current_contract_ok {return}
	for file, index in legacy_contract.files {
		if !testing.expect(
			t,
			file.bytes != current_contract.files[index].bytes ||
			file.sha256 != current_contract.files[index].sha256,
		) {
			return
		}
	}

	seed := stage_gsw_vga_package_contracts(
		image_path,
		legacy.package_directory,
		&legacy_contract,
		&legacy_contract,
		.In_Process,
	)
	if !testing.expect_value(t, seed.diagnostic, Stage_Diagnostic.None) ||
	   !testing.expect_value(t, seed.prior_kind, Stage_Prior_Kind.Absent) {
		return
	}
	replacement := stage_gsw_vga_package_contracts(
		image_path,
		current.package_directory,
		&current_contract,
		&legacy_contract,
		.In_Process,
	)
	if !testing.expect_value(t, replacement.diagnostic, Stage_Diagnostic.None) ||
	   !testing.expect(t, replacement.prior_verified) ||
	   !testing.expect(t, replacement.transaction != 0) ||
	   !testing.expect_value(t, replacement.prior_kind, Stage_Prior_Kind.Reviewed_Legacy) {
		return
	}

	session, open_error := fat32session.open_edit(
		image_path,
		"gsw-vga-legacy-replace-verify",
		0,
		.In_Process,
	)
	if !testing.expect_value(t, open_error.code, fat32session.Error_Code.None) {return}
	current_exists, current_valid, current_error := stage_verify_guest_directory(
		session,
		&current_contract,
	)
	legacy_exists, legacy_valid, legacy_error := stage_verify_guest_directory(
		session,
		&legacy_contract,
	)
	verified_files := 0
	for file in current_contract.files {
		path := strings.concatenate(
			{GSW_VGA_GUEST_DIRECTORY, "/", file.name},
			context.temp_allocator,
		)
		digest, read_error, hash_ok := stage_hash_guest_file(session, path, file.bytes)
		delete(path, context.temp_allocator)
		if !testing.expect_value(t, read_error.code, fat32session.Error_Code.None) ||
		   !testing.expect(t, hash_ok) ||
		   !testing.expect_value(t, digest, file.sha256) {
			_ = fat32session.edit_finish(session, false)
			return
		}
		verified_files += 1
	}
	finish_error := fat32session.edit_finish(session, false)
	testing.expect_value(t, current_error.code, fat32session.Error_Code.None)
	testing.expect(t, current_exists && current_valid)
	testing.expect_value(t, legacy_error.code, fat32session.Error_Code.None)
	testing.expect(t, legacy_exists && !legacy_valid)
	testing.expect_value(t, verified_files, GSW_VGA_FILE_COUNT)
	testing.expect_value(t, finish_error.code, fat32session.Error_Code.None)
}

@(private = "file")
stage_test_contract_failures :: proc(t: ^testing.T, root: string) {
	contents := [GSW_VGA_FILE_COUNT]string{"inf\n", "drv\n", "vxd\n", "hal\n", "dd32\n"}
	fixture, fixture_ok := stage_test_fixture(t, root, "package", contents)
	if !fixture_ok {return}
	fixture_contract, fixture_contract_ok := stage_test_contract(t, &fixture)
	if !fixture_contract_ok {return}
	reviewed_prior := stage_reviewed_prior_contract()
	reviewed_current := stage_reviewed_current_contract()
	testing.expect(t, stage_contract_identity_matches(&reviewed_current, &reviewed_current))
	testing.expect(t, !stage_contract_identity_matches(&fixture_contract, &reviewed_current))
	bad_inventory, _ := filepath.join({root, "bad-inventory.tsv"}, context.temp_allocator)
	if !testing.expect_value(
		t,
		os.write_entire_file(bad_inventory, GSW_VGA_INVENTORY_HEADER + "\n"),
		os.Error(nil),
	) {
		return
	}
	bad_contract := stage_gsw_vga_package(
		"unused.img",
		fixture.package_directory,
		fixture.manifest_path,
		bad_inventory,
		fixture.prior_manifest_path,
		.In_Process,
	)
	testing.expect_value(t, bad_contract.diagnostic, Stage_Diagnostic.Inventory_Invalid)
	unreviewed_current := stage_gsw_vga_package(
		"unused.img",
		fixture.package_directory,
		fixture.manifest_path,
		fixture.inventory_path,
		fixture.prior_manifest_path,
		.In_Process,
	)
	testing.expect_value(
		t,
		unreviewed_current.diagnostic,
		Stage_Diagnostic.Current_Manifest_Unreviewed,
	)

	extra_path, _ := filepath.join(
		{fixture.package_directory, "EXTRA.TXT"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, os.write_entire_file(extra_path, "extra"), os.Error(nil)) {return}
	extra := stage_gsw_vga_package_contracts(
		"unused.img",
		fixture.package_directory,
		&fixture_contract,
		&reviewed_prior,
		.In_Process,
	)
	testing.expect_value(t, extra.diagnostic, Stage_Diagnostic.Package_Shape_Invalid)
	if !testing.expect_value(t, os.remove(extra_path), os.Error(nil)) {return}

	mutated_path, _ := filepath.join(
		{fixture.package_directory, "gswmini.inf"},
		context.temp_allocator,
	)
	if !testing.expect_value(
		t,
		os.write_entire_file(mutated_path, "bad\n"),
		os.Error(nil),
	) {return}
	mutated := stage_gsw_vga_package_contracts(
		"unused.img",
		fixture.package_directory,
		&fixture_contract,
		&reviewed_prior,
		.In_Process,
	)
	testing.expect_value(t, mutated.diagnostic, Stage_Diagnostic.Package_Hash_Mismatch)

	prior_contract := stage_contract_default()
	if !testing.expect(
		t,
		stage_parse_reviewed_prior_manifest(fixture.prior_manifest_path, &prior_contract),
	) {
		return
	}
	prior_data, prior_read_error := os.read_entire_file(
		fixture.prior_manifest_path,
		context.allocator,
	)
	if !testing.expect_value(t, prior_read_error, os.Error(nil)) {return}
	defer delete(prior_data)
	altered := make([]u8, len(prior_data))
	defer delete(altered)
	copy(altered, prior_data)
	hash_offset := strings.index(
		string(altered),
		"952c2a18697a363944879b64031872266505d34ac50fca7080663bfa54783dea",
	)
	if !testing.expect(t, hash_offset >= 0) {return}
	altered[hash_offset] = '8'
	if !testing.expect_value(
		t,
		os.write_entire_file(fixture.prior_manifest_path, altered),
		os.Error(nil),
	) {
		return
	}
	altered_contract := stage_contract_default()
	testing.expect(
		t,
		!stage_parse_reviewed_prior_manifest(fixture.prior_manifest_path, &altered_contract),
	)

	partial_text := GSW_VGA_PRIOR_MANIFEST_HEADER + "\n"
	if !testing.expect_value(
		t,
		os.write_entire_file(fixture.prior_manifest_path, partial_text),
		os.Error(nil),
	) {
		return
	}
	partial_contract := stage_contract_default()
	testing.expect(
		t,
		!stage_parse_reviewed_prior_manifest(fixture.prior_manifest_path, &partial_contract),
	)

	extra_text := strings.concatenate(
		{
			string(prior_data),
			"gsw-vga-prior-only\tGSW-VGA\\gswmini.inf\t952c2a18697a363944879b64031872266505d34ac50fca7080663bfa54783dea\t3188\n",
		},
		context.temp_allocator,
	)
	if !testing.expect_value(
		t,
		os.write_entire_file(fixture.prior_manifest_path, extra_text),
		os.Error(nil),
	) {
		return
	}
	extra_contract := stage_contract_default()
	testing.expect(
		t,
		!stage_parse_reviewed_prior_manifest(fixture.prior_manifest_path, &extra_contract),
	)
}
