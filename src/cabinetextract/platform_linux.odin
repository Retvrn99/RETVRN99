// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

platform_setup_source_extract_files :: proc(
	setup_directory, first_cabinet: string,
	requests: []Setup_Source_Extract_Request,
) -> Setup_Source_Extract_Diagnostic {
	_ = setup_directory
	_ = first_cabinet
	_ = requests
	return setup_source_diagnostic(.Unsupported)
}
