// SPDX-License-Identifier: GPL-3.0-only
package opticaldrive

import "core:fmt"
import "core:strings"

PATH_PREFIX :: "hostcd://"

Drive :: struct {
	handle: uintptr,
	letter: u8,
}

Command_Result :: struct {
	ok:           bool,
	transferred:  int,
	scsi_status:  u8,
	sense:        [32]u8,
	sense_length: int,
}

path :: proc(letter: u8) -> string {
	upper := letter
	if upper >= 'a' && upper <= 'z' {upper -= 'a' - 'A'}
	if upper < 'A' || upper > 'Z' {return ""}
	return fmt.tprintf("%s%c:", PATH_PREFIX, upper)
}

path_letter :: proc(value: string) -> (u8, bool) {
	if len(value) != len(PATH_PREFIX) + 2 ||
	   !strings.equal_fold(value[:len(PATH_PREFIX)], PATH_PREFIX) ||
	   value[len(value) - 1] != ':' {
		return 0, false
	}
	letter := value[len(PATH_PREFIX)]
	if letter >= 'a' && letter <= 'z' {letter -= 'a' - 'A'}
	return letter, letter >= 'A' && letter <= 'Z'
}

is_path :: proc(value: string) -> bool {
	_, ok := path_letter(value)
	return ok
}
