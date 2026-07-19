// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:strings"
import "core:testing"

driver_test_pnp_manifest :: proc(
	package_id: string,
	device_class: Driver_Device_Class,
	hardware_ids: []string,
	files: []Driver_Package_File,
) -> Driver_Package_Manifest {
	return {
		package_id = package_id,
		mode = .PnP_Driver,
		device_class = device_class,
		hardware_ids = hardware_ids,
		files = files,
	}
}

@(test)
test_custom_inf_merge_new_multiple_pnp_is_sorted_idempotent_and_skips_load_inf :: proc(
	t: ^testing.T,
) {
	sound_ids := [?]string{"PCI\\VEN_FFFE&DEV_0003"}
	sound_files := [?]Driver_Package_File {
		{
			source_name = "GSWSOUND.DRV",
			destination_name = "GSWSOUND.DRV",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
		{
			source_name = "GSWSOUND.INF",
			destination_name = "GSWSOUND.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWSOUND.VXD",
			destination_name = "GSWSOUND.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	vga_ids := [?]string{"PCI\\VEN_FFFE&DEV_0002"}
	vga_files := [?]Driver_Package_File {
		{
			source_name = "GSWVGA.DRV",
			destination_name = "GSWVGA.DRV",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
		{
			source_name = "GSWVGA.INF",
			destination_name = "GSWVGA.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
	}
	manifests := [?]Driver_Package_Manifest {
		driver_test_pnp_manifest("gsw-vga", .Display, vga_ids[:], vga_files[:]),
		driver_test_pnp_manifest("gsw-sound", .Media, sound_ids[:], sound_files[:]),
	}
	merged, diagnostic := driver_custom_inf_merge("", manifests[:])
	defer delete(merged)
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect(t, strings.contains(merged, "SetupClass=BASE\r\n"))
	testing.expect(
		t,
		strings.contains(merged, "LayoutFile=layout.inf,layout1.inf,layout2.inf\r\n"),
	)
	testing.expect(t, strings.contains(merged, `[SourceDisksNames]` + "\r\n"))
	testing.expect(t, strings.contains(merged, `101="Custom INF Precopy files",,0`))
	testing.expect(t, strings.contains(merged, "[SourceDisksFiles]\r\n"))
	testing.expect(t, strings.contains(merged, "[DestinationDirs]\r\n"))
	testing.expect(t, strings.contains(merged, "[CUSTOM_PRECOPY]\r\n"))
	testing.expect(t, strings.contains(merged, "[BaseWinOptions]\r\n"))
	testing.expect(t, strings.contains(merged, "CopyFiles=RETVRN99.gsw-sound.PreCopy\r\n"))
	testing.expect(t, strings.contains(merged, "RETVRN99.gsw-vga.Install\r\n"))
	testing.expect(t, strings.contains(merged, "RETVRN99.gsw-sound.PreCopy=2\r\n"))
	testing.expect(t, strings.contains(merged, "RETVRN99.gsw-sound.INF.Files=17\r\n"))
	testing.expect(t, !strings.contains(merged, "GSWSOUND.DRV"))
	testing.expect(t, !strings.contains(merged, "GSWSOUND.VXD"))
	testing.expect(t, !strings.contains(merged, "GSWVGA.DRV"))
	testing.expect(t, !driver_ascii_contains_fold(merged, "[load_inf]"))
	sound_position := strings.index(merged, "[RETVRN99.gsw-sound.PreCopy]")
	vga_position := strings.index(merged, "[RETVRN99.gsw-vga.PreCopy]")
	testing.expect(t, sound_position >= 0 && vga_position > sound_position)

	second, second_diagnostic := driver_custom_inf_merge(merged, manifests[:])
	defer delete(second)
	testing.expect_value(t, second_diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect_value(t, second, merged)
}

@(test)
test_custom_inf_merge_preserves_existing_oem_sections_bytes_and_eof :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_FFFE&DEV_0001"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWCHIP.INF",
			destination_name = "GSWCHIP.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWCHIP.VXD",
			destination_name = "GSWCHIP.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := driver_test_pnp_manifest("gsw-chipset", .System, hardware_ids[:], files[:])
	existing :=
		"; OEM localized \x80\x81\r\n" +
		"[CUSTOM_PRECOPY]\r\nCopyFiles=OEM.Temp.Files\r\n\r\n" +
		"[OEM.Temp.Files]\r\nOEMNIC.INF\r\n\r\n" +
		"[BaseWinOptions]\r\nOEM.Install\r\n\r\n" +
		"[OEM.Install]\r\nCopyFiles=OEM.INF.Files\r\n\r\n" +
		"[Strings]\r\nOEMName=\"Localized \x80\"\r\n" +
		"\x1aOEM TRAILER \x81"
	merged, diagnostic := driver_custom_inf_merge(existing, []Driver_Package_Manifest{manifest})
	defer delete(merged)
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect(t, strings.has_prefix(merged, "; OEM localized \x80\x81\r\n"))
	testing.expect(t, strings.contains(merged, "CopyFiles=OEM.Temp.Files\r\n"))
	testing.expect(t, strings.contains(merged, "OEMName=\"Localized \x80\"\r\n"))
	testing.expect(t, strings.has_suffix(merged, "\x1aOEM TRAILER \x81"))
}

@(test)
test_custom_inf_merge_separates_appended_lines_after_unterminated_oem_line :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_FFFE&DEV_0001"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWCHIP.INF",
			destination_name = "GSWCHIP.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWCHIP.VXD",
			destination_name = "GSWCHIP.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := driver_test_pnp_manifest("gsw-chipset", .System, hardware_ids[:], files[:])
	existing := "[Version]\r\nSignature=\"$CHICAGO$\""
	merged, diagnostic := driver_custom_inf_merge(existing, []Driver_Package_Manifest{manifest})
	defer delete(merged)
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect(
		t,
		strings.contains(merged, "Signature=\"$CHICAGO$\"\r\nSetupClass=BASE\r\n"),
	)
	testing.expect(t, !strings.contains(merged, "Signature=\"$CHICAGO$\"SetupClass"))
}

@(test)
test_custom_inf_merge_repairs_foundation_before_accepting_owned_sections :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_FFFE&DEV_0001"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWCHIP.INF",
			destination_name = "GSWCHIP.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWCHIP.VXD",
			destination_name = "GSWCHIP.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := driver_test_pnp_manifest("gsw-chipset", .System, hardware_ids[:], files[:])
	complete, complete_diagnostic := driver_custom_inf_merge(
		"",
		[]Driver_Package_Manifest{manifest},
	)
	defer delete(complete)
	testing.expect_value(t, complete_diagnostic, Driver_Custom_INF_Diagnostic.None)
	missing, allocated := strings.replace_all(complete, "SetupClass=BASE\r\n", "")
	defer if allocated {delete(missing)}
	testing.expect(t, allocated)
	repaired, diagnostic := driver_custom_inf_merge(missing, []Driver_Package_Manifest{manifest})
	defer delete(repaired)
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect(t, strings.contains(repaired, "SetupClass=BASE\r\n"))
	second, second_diagnostic := driver_custom_inf_merge(
		repaired,
		[]Driver_Package_Manifest{manifest},
	)
	defer delete(second)
	testing.expect_value(t, second_diagnostic, Driver_Custom_INF_Diagnostic.None)
	testing.expect_value(t, second, repaired)
}

@(test)
test_custom_inf_merge_rejects_duplicate_section_and_owned_reference :: proc(t: ^testing.T) {
	hardware_ids := [?]string{"PCI\\VEN_FFFE&DEV_0001"}
	files := [?]Driver_Package_File {
		{
			source_name = "GSWCHIP.INF",
			destination_name = "GSWCHIP.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
		{
			source_name = "GSWCHIP.VXD",
			destination_name = "GSWCHIP.VXD",
			kind = .Binary,
			max_output_bytes = 4 * 1024 * 1024,
		},
	}
	manifest := driver_test_pnp_manifest("gsw-chipset", .System, hardware_ids[:], files[:])
	duplicate_sections :=
		"[CUSTOM_PRECOPY]\r\nCopyFiles=OEM.Temp\r\n" +
		"[custom_precopy]\r\nCopyFiles=OEM.Other\r\n"
	merged, diagnostic := driver_custom_inf_merge(
		duplicate_sections,
		[]Driver_Package_Manifest{manifest},
	)
	testing.expect_value(t, merged, "")
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.Duplicate_Section)

	duplicate_reference :=
		"[CUSTOM_PRECOPY]\r\n" +
		"CopyFiles=RETVRN99.gsw-chipset.PreCopy\r\n" +
		"CopyFiles=RETVRN99.gsw-chipset.PreCopy\r\n"
	merged, diagnostic = driver_custom_inf_merge(
		duplicate_reference,
		[]Driver_Package_Manifest{manifest},
	)
	testing.expect_value(t, merged, "")
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.Owned_Content_Collision)
}

@(test)
test_custom_inf_merge_rejects_cross_package_pnp_filename_alias_collision :: proc(t: ^testing.T) {
	one_ids := [?]string{"PCI\\VEN_1111&DEV_0001"}
	one_files := [?]Driver_Package_File {
		{
			source_name = "AONE.VXD",
			destination_name = "AONE.VXD",
			kind = .Binary,
			max_output_bytes = 1024 * 1024,
		},
		{
			source_name = "LONGFILEONE.INF",
			destination_name = "LONGFILEONE.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
	}
	two_ids := [?]string{"PCI\\VEN_2222&DEV_0002"}
	two_files := [?]Driver_Package_File {
		{
			source_name = "ATWO.VXD",
			destination_name = "ATWO.VXD",
			kind = .Binary,
			max_output_bytes = 1024 * 1024,
		},
		{
			source_name = "LONGFILETWO.INF",
			destination_name = "LONGFILETWO.INF",
			kind = .INF,
			max_output_bytes = 64 * 1024,
		},
	}
	manifests := [?]Driver_Package_Manifest {
		driver_test_pnp_manifest("one", .Display, one_ids[:], one_files[:]),
		driver_test_pnp_manifest("two", .Media, two_ids[:], two_files[:]),
	}
	merged, diagnostic := driver_custom_inf_merge("", manifests[:])
	testing.expect_value(t, merged, "")
	testing.expect_value(t, diagnostic, Driver_Custom_INF_Diagnostic.Filename_Collision)
}
