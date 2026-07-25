// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../../src/fat32session"
import "core:fmt"
import "core:os"

main :: proc() {
	code := gswgfx_offline_stage_main(os.args[1:])
	if code != 0 {os.exit(code)}
}

gswgfx_offline_stage_main :: proc(args: []string) -> int {
	if len(args) != 4 || args[0] != "stage" {
		fmt.eprintln(
			"usage: retvrn99-gswgfx-offline-stage stage IMAGE PACKAGE_DIRECTORY STAGE_MANIFEST",
		)
		return 2
	}
	result := stage_gswgfx_package(args[1], args[2], args[3], .Process)
	if result.diagnostic != .None {
		fmt.eprintfln(
			"GSWGFX offline stage failed: %s",
			gswgfx_stage_diagnostic_text(result.diagnostic),
		)
		if result.session_error.code != .None {
			err := result.session_error
			fmt.eprintfln("FAT32 Edit: %s", fat32session.error_text(&err))
		}
		return 1
	}
	fmt.printfln(
		"GSWGFX offline stage complete: guest=%s files=%d bytes=%d transaction=%d",
		GSWGFX_GUEST_DIRECTORY,
		GSWGFX_FILE_COUNT,
		result.total_bytes,
		result.transaction,
	)
	return 0
}
