// SPDX-License-Identifier: GPL-3.0-only
package fat32edit

import fat32fs "../fat32fs"

boot_entry_in_first_root_cluster :: proc(
	session: ^Edit_Session,
	short_name: [11]u8,
	expected_first_cluster: u32,
) -> (
	bool,
	Edit_Error,
) {
	if session == nil || session.impl == nil || session.impl.closed {
		return false, error_make(.Invalid_State, "FAT32 edit session is closed")
	}
	present, fat_error := fat32fs.root_short_entry_in_first_cluster(
		&session.impl.volume,
		short_name,
		expected_first_cluster,
	)
	return present, error_from_fat32(fat_error)
}
