// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import win98media "../win98media"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

Host_Staging :: struct {
	root:                string,
	setup:               string,
	dos:                 [3]string,
	launcher:            string,
	autoexec:            string,
	owner:               string,
	seeded_dos:          bool,
	system_fingerprints: [3]File_Fingerprint,
}

staging_destroy :: proc(staging: ^Host_Staging) {
	if staging == nil {return}
	if staging.root != "" {_ = os.remove_all(staging.root)}
	delete(staging.root)
	delete(staging.setup)
	for &path in staging.dos {delete(path)}
	delete(staging.launcher)
	delete(staging.autoexec)
	delete(staging.owner)
	staging^ = {}
}

staging_open :: proc(parent: string) -> (Host_Staging, Error) {
	if parent != "" && os.make_directory_all(parent) != nil {
		return {}, error_make(.Scratch_Failed, "cannot create the Windows 98 preparation workspace parent")
	}
	root, root_error := os.make_directory_temp(parent, "retvrn99-win98-image-*", context.allocator)
	if root_error !=
	   nil {return {}, error_make(.Scratch_Failed, "cannot create an owned Windows 98 preparation workspace")}
	staging := Host_Staging {
		root = root,
	}
	join_error: runtime.Allocator_Error
	staging.setup, join_error = filepath.join({root, "setup"})
	if join_error == nil {staging.launcher, join_error = filepath.join({root, "GSWSETUP.BAT"})}
	if join_error == nil {staging.autoexec, join_error = filepath.join({root, "AUTOEXEC.BAT"})}
	if join_error == nil {staging.owner, join_error = filepath.join({root, OWNER_FILE_NAME})}
	for name, index in BOOTSTRAP_SYSTEM_NAMES {
		if join_error == nil {staging.dos[index], join_error = filepath.join({root, name})}
	}
	if join_error != nil {
		staging_destroy(&staging)
		return {}, error_make(.Scratch_Failed, "cannot resolve Windows 98 preparation workspace paths")
	}
	return staging, {}
}

staging_boot_seed :: proc(
	staging: ^Host_Staging,
	iso_path, provided_boot_path: string,
	boot_source: Boot_Source,
) -> Error {
	if staging ==
	   nil {return error_make(.Internal, "Windows 98 preparation workspace is unavailable")}
	boot_path := provided_boot_path
	embedded_path := ""
	if boot_source == .Embedded {
		path, path_error := filepath.join(
			{staging.root, "embedded-boot.img"},
			context.temp_allocator,
		)
		if path_error !=
		   nil {return error_make(.Scratch_Failed, "cannot resolve the embedded boot-floppy workspace path")}
		embedded_path = path
		boot_path = embedded_path
		boot_diagnostic := win98media.extract_boot_floppy(iso_path, boot_path)
		if boot_diagnostic != .None {
			err := error_make(.Boot_Floppy_Invalid, "embedded El Torito boot floppy is unusable")
			return err
		}
	}
	seed, boot_diagnostic := image_boot_seed_extract(boot_path)
	if boot_diagnostic != .None {
		err := error_make(.Boot_Floppy_Invalid, "Windows 98 boot-floppy extraction failed")
		err.boot_diagnostic = boot_diagnostic
		return err
	}
	defer image_boot_seed_destroy(&seed)
	for data, index in seed.data {
		if os.write_entire_file(staging.dos[index], data) != nil {
			return error_make(.Scratch_Failed, "cannot stage a DOS boot-seed file")
		}
		staging.system_fingerprints[index] = fingerprint_bytes(data)
	}
	staging.seeded_dos = true
	return {}
}

staging_setup_source :: proc(
	staging: ^Host_Staging,
	iso_path: string,
	media_info: ^win98media.Media_Info,
	options: Prepare_Options,
) -> Error {
	if extraction := win98media.extract_win98(iso_path, staging.setup); extraction != .None {
		err := error_make(.Extraction_Failed, "cannot extract the Windows 98 Setup source")
		err.media_diagnostic = extraction
		return err
	}
	driver_result := driver_bundle_stage_early_setup(
		staging.setup,
		staging.root,
		options.setup_source_overlay,
	)
	if driver_result.diagnostic != .None {
		err := error_make(
			.Extraction_Failed,
			"cannot stage the localized Windows 98 IDE policy overlay",
		)
		err.driver_diagnostic = driver_result.diagnostic
		return err
	}
	tlb_result := tlb_overlay_stage(staging.setup, staging.root, options.setup_source_overlay)
	if tlb_result.diagnostic != .None {
		err := error_make(
			.Extraction_Failed,
			"cannot stage the Windows 98 TLB compatibility overlay",
		)
		err.tlb_diagnostic = tlb_result
		return err
	}
	template_path, template_path_error := filepath.join(
		{staging.root, "MSBATCH.INF"},
		context.temp_allocator,
	)
	if template_path_error !=
	   nil {return error_make(.Scratch_Failed, "cannot resolve MSBATCH.INF in the preparation workspace")}
	if media_info.has_msbatch_template {
		if extraction := win98media.extract_msbatch_template(iso_path, template_path);
		   extraction != .None {
			err := error_make(
				.Extraction_Failed,
				"cannot extract the Windows 98 Setup answer template",
			)
			err.media_diagnostic = extraction
			return err
		}
	} else if os.write_entire_file(template_path, fallback_msbatch()) != nil {
		return error_make(
			.Scratch_Failed,
			"cannot stage the fallback Windows 98 Setup answer file",
		)
	}
	if !normalize_msbatch_file(template_path, options.desktop_probe, options.host_locale) {
		return error_make(.Extraction_Failed, "cannot normalize the Windows 98 Setup answer file")
	}
	destination, destination_error := filepath.join(
		{staging.setup, "MSBATCH.INF"},
		context.temp_allocator,
	)
	if destination_error !=
	   nil {return error_make(.Scratch_Failed, "cannot resolve the staged Setup answer-file destination")}
	data, read_error := os.read_entire_file(template_path, context.temp_allocator)
	if read_error != nil || os.write_entire_file(destination, data) != nil {
		return error_make(.Scratch_Failed, "cannot place the staged Windows 98 Setup answer file")
	}
	marker, marker_error := filepath.join(
		{staging.setup, PAYLOAD_MARKER_NAME},
		context.temp_allocator,
	)
	if marker_error != nil || os.write_entire_file(marker, PAYLOAD_MARKER) != nil {
		return error_make(
			.Scratch_Failed,
			"cannot mark the staged Windows 98 Setup tree as RETVRN99-owned",
		)
	}
	if !post_setup_write(staging.setup, options.desktop_probe) {
		return error_make(.Scratch_Failed, "cannot stage Windows 98 post-Setup activation")
	}
	return {}
}

staging_launchers :: proc(
	staging: ^Host_Staging,
	setup_executable: string,
	enable_boot_gui: bool,
	options: Prepare_Options,
) -> Error {
	launcher := image_launcher_text(
		setup_executable,
		enable_boot_gui,
		true,
		options.hardware_diagnostics,
	)
	defer delete(launcher)
	if !strings.has_prefix(launcher, LAUNCHER_MARKER) ||
	   os.write_entire_file(staging.launcher, launcher) != nil ||
	   os.write_entire_file(staging.autoexec, BOOTSTRAP_AUTOEXEC) != nil {
		return error_make(.Scratch_Failed, "cannot stage the Windows 98 Setup launcher")
	}
	return {}
}

staging_owner_write :: proc(staging: ^Host_Staging, owner: Preparation_Owner) -> Error {
	data := owner_encode(owner)
	if os.write_entire_file(staging.owner, data[:]) != nil {
		return error_make(.Scratch_Failed, "cannot stage the Windows 98 ownership marker")
	}
	return {}
}
