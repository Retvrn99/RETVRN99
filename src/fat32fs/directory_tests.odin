// SPDX-License-Identifier: GPL-3.0-only
package fat32fs

import "core:testing"

@(test)
entry_copy_test_short_name_owns_independent_strings :: proc(t: ^testing.T) {
	raw: Raw_Entry
	copy(raw.short[:], "README  TXT")
	raw.modified_date = 0x58AF
	raw.modified_time = 0x7C00
	entry := entry_copy(&raw)
	defer entry_destroy(&entry)
	testing.expect_value(t, entry.name, "README.TXT")
	testing.expect_value(t, entry.short_name, "README.TXT")
	testing.expect_value(t, entry.modified_date, raw.modified_date)
	testing.expect_value(t, entry.modified_time, raw.modified_time)
	testing.expect(t, raw_data(entry.name) != raw_data(entry.short_name))
}
