// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:fmt"
import "core:os"

main :: proc() {
	code := offline_stage_main(os.args[1:])
	if code != 0 {os.exit(code)}
}

offline_stage_main :: proc(args: []string) -> int {
	if len(args) != 6 || args[0] != "stage" {
		fmt.eprintln(
			"usage: retvrn99-gsw-vga-offline-stage stage IMAGE PACKAGE_DIRECTORY PAYLOAD_MANIFEST PAYLOAD_INVENTORY PRIOR_ONLY_MANIFEST",
		)
		return 2
	}
	result := stage_gsw_vga_package(args[1], args[2], args[3], args[4], args[5], .Process)
	if result.diagnostic != .None {
		fmt.eprintfln("GSW-VGA offline stage failed: %s", stage_diagnostic_text(result.diagnostic))
		if result.session_error.code != .None {
			err := result.session_error
			fmt.eprintfln("FAT32 Edit: %s", fat32session.error_text(&err))
		}
		return 1
	}
	fmt.printfln(
		"GSW-VGA offline stage complete: guest=%s files=%d bytes=%d transaction=%d prior_verified=%v prior=%s",
		GSW_VGA_GUEST_DIRECTORY,
		GSW_VGA_FILE_COUNT,
		result.total_bytes,
		result.transaction,
		result.prior_verified,
		stage_prior_kind_text(result.prior_kind),
	)
	return 0
}
