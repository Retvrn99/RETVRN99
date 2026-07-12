// SPDX-License-Identifier: GPL-3.0-only
package profile

import "core:fmt"
import "core:os"
import "core:path/filepath"

Atomic_Write_Diagnostic :: enum {
	None,
	Create_Directory_Failed,
	Temporary_Path_Failed,
	Write_Failed,
	Replace_Failed,
}

@(private)
atomic_replace :: proc(path: string, payload: []u8, stem: string) -> Atomic_Write_Diagnostic {
	dir := filepath.dir(path)
	if merr := os.make_directory_all(dir); merr != nil { return .Create_Directory_Failed }
	temp_name := fmt.tprintf(".%s.%d.tmp", stem, os.get_pid())
	temporary, terr := filepath.join({dir, temp_name})
	if terr != nil { return .Temporary_Path_Failed }
	defer delete(temporary)
	defer _ = os.remove(temporary)
	if werr := os.write_entire_file(temporary, payload); werr != nil { return .Write_Failed }
	if rerr := os.rename(temporary, path); rerr != nil { return .Replace_Failed }
	return .None
}
