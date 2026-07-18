// SPDX-License-Identifier: GPL-3.0-only
package opticaldrive

enumerate :: proc() -> [26]bool {return {}}
open :: proc(_: ^Drive, _: string) -> bool {return false}
close :: proc(drive: ^Drive) {if drive != nil {drive^ = {}}}
is_open :: proc(_: ^Drive) -> bool {return false}
execute :: proc(_: ^Drive, _: []u8, _: []u8, _: bool) -> Command_Result {return {}}
