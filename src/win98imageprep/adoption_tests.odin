// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import fat32image "../fat32image"
import "core:os"
import "core:slice"
import "core:testing"

@(private = "file")
prep_adoption_test_io :: proc(file: ^os.File, data: []u8, offset: i64, write: bool) -> bool {
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
prep_adoption_test_make_standard :: proc(
	t: ^testing.T,
	environment: ^Prep_Test_Environment,
) -> (original_vbr: [fat32image.SECTOR_BYTES]u8, ok: bool) {
	info := &environment.created_info
	file, open_error := os.open(environment.image_path, {.Read, .Write})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	primary_offset := i64(u64(info.partition_lba) * fat32image.SECTOR_BYTES)
	if !prep_adoption_test_io(file, original_vbr[:], primary_offset, false) {
		_ = os.close(file)
		return
	}
	backup_lba := u64(info.partition_lba) + u64(u16(original_vbr[50]) | u16(original_vbr[51]) << 8)
	copy(original_vbr[3:11], "MSDOS5.0")
	copy(original_vbr[71:82], "NO NAME    ")
	for &octet in original_vbr[90:510] {octet = 0}
	original_vbr[90], original_vbr[91] = 0xfa, 0xf4
	marker: [fat32image.SECTOR_BYTES]u8
	ok =
		prep_adoption_test_io(file, original_vbr[:], primary_offset, true) &&
		prep_adoption_test_io(
			file,
			original_vbr[:],
			i64(backup_lba * fat32image.SECTOR_BYTES),
			true,
		) &&
		prep_adoption_test_io(
			file,
			marker[:],
			i64(u64(info.marker_sector) * fat32image.SECTOR_BYTES),
			true,
		) &&
		os.sync(file) == nil
	close_error := os.close(file)
	ok = testing.expect(t, ok) && testing.expect_value(t, close_error, os.Error(nil))
	return
}

@(test)
prepare_test_standard_external_image_is_inspected_then_adopted_transactionally :: proc(t: ^testing.T) {
	environment, environment_ok := prep_test_environment(
		t,
		{embedded_boot = true, setup_name = "INSTALAR"},
	)
	if !environment_ok {return}
	defer prep_test_environment_destroy(&environment)
	external_vbr, external_ok := prep_adoption_test_make_standard(t, &environment)
	if !external_ok {return}
	inspection, inspect_error := inspect(
		{
			image_path      = environment.image_path,
			iso_path        = environment.iso_path,
			edit_session_id = "standard-image-inspection",
		},
		.In_Process,
	)
	inspection_destroy(&inspection)
	if !testing.expect_value(t, inspect_error.code, Error_Code.None) {return}
	still_standard, validation_error := fat32image.validate(environment.image_path)
	if !testing.expect_value(t, validation_error.code, fat32image.Error_Code.None) {return}
	testing.expect(t, !still_standard.enrolled && !still_standard.retvrn99_format && !still_standard.dirty)
	fat32image.info_destroy(&still_standard)
	request := prep_test_prepare_request(&environment)
	prepared, prepare_error := prepare(request, .In_Process)
	defer prepare_result_destroy(&prepared)
	if !testing.expect_value(t, prepare_error.code, Error_Code.None) {return}
	validated, final_error := fat32image.validate(environment.image_path)
	if !testing.expect_value(t, final_error.code, fat32image.Error_Code.None) {return}
	defer fat32image.info_destroy(&validated)
	testing.expect(t, validated.enrolled && validated.retvrn99_format && !validated.dirty)
	testing.expect_value(t, validated.image_id, prepared.image_identity)
	file, open_error := os.open(environment.image_path, {.Read})
	if !testing.expect_value(t, open_error, os.Error(nil)) {return}
	adopted_vbr: [fat32image.SECTOR_BYTES]u8
	read_ok := prep_adoption_test_io(
		file,
		adopted_vbr[:],
		i64(u64(validated.partition_lba) * fat32image.SECTOR_BYTES),
		false,
	)
	close_error := os.close(file)
	if !testing.expect(t, read_ok) || !testing.expect_value(t, close_error, os.Error(nil)) {return}
	testing.expect(t, slice.equal(adopted_vbr[11:67], external_vbr[11:67]))
}
