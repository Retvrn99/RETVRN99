// SPDX-License-Identifier: GPL-3.0-only
package main

import fat32session "../fat32session"
import "core:os"

main :: proc() {
	if len(os.args) != 2 && len(os.args) != 4 || os.args[1] != "--pipe" {
		os.exit(2)
	}
	if len(os.args) == 4 &&
	   (os.args[2] != "--crash-phase" ||
	    !fat32session.enable_process_crash_injection(os.args[3])) {
		os.exit(2)
	}
	os.exit(fat32session.serve(os.stdin, os.stdout))
}
