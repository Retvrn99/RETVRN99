// SPDX-License-Identifier: GPL-3.0-only
#+build linux
package host

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import sdl3 "vendor:sdl3"

host_file_url :: proc(path: string, allocator := context.temp_allocator) -> string {
	if len(path) == 0 {return ""}
	builder: strings.Builder
	strings.builder_init(&builder, allocator = allocator)
	strings.write_string(&builder, "file://")
	for byte in transmute([]u8)path {
		switch byte {
		case '/', ':', '-', '_', '.', '~':
			strings.write_byte(&builder, byte)
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
			strings.write_byte(&builder, byte)
		case:
			strings.write_string(&builder, fmt.tprintf("%%%02X", byte))
		}
	}
	return strings.to_string(builder)
}

host_reveal_path :: proc(path: string) -> bool {
	if len(path) == 0 {return false}
	directory := filepath.dir(path)
	if len(directory) == 0 {return false}
	url := host_file_url(directory)
	if len(url) == 0 {return false}
	return sdl3.OpenURL(fmt.ctprintf("%s", url))
}
