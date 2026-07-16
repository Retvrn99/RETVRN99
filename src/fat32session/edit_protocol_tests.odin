// SPDX-License-Identifier: GPL-3.0-only
package fat32session

import fat32fs "../fat32fs"
import "core:strings"
import "core:testing"

@(test)
edit_protocol_test_korean_page_preserves_metadata :: proc(t: ^testing.T) {
	page := Edit_Page {
		entries     = make([dynamic]fat32fs.Entry, 0, 1),
		next_cursor = 7,
		has_more    = true,
	}
	append(
		&page.entries,
		fat32fs.Entry {
			name = strings.clone("안녕하세요.txt"),
			short_name = strings.clone("______~1.TXT"),
			first_cluster = 42,
			size = 1234,
			modified_date = 0x58AF,
			modified_time = 0x7C00,
		},
	)
	defer edit_page_destroy(&page)
	payload, encoded := protocol_edit_page_encode(&page, context.allocator)
	if !testing.expect(t, encoded) {return}
	defer delete(payload)
	decoded, decoded_ok := protocol_edit_page_decode(payload, context.allocator)
	if !testing.expect(t, decoded_ok) {return}
	defer edit_page_destroy(&decoded)
	testing.expect_value(t, decoded.next_cursor, page.next_cursor)
	testing.expect_value(t, decoded.has_more, page.has_more)
	if !testing.expect_value(t, len(decoded.entries), 1) {return}
	testing.expect_value(t, decoded.entries[0].name, page.entries[0].name)
	testing.expect_value(t, decoded.entries[0].short_name, page.entries[0].short_name)
	testing.expect_value(t, decoded.entries[0].modified_date, page.entries[0].modified_date)
	testing.expect_value(t, decoded.entries[0].modified_time, page.entries[0].modified_time)
}

@(test)
edit_protocol_test_stat_preserves_metadata_and_rejects_truncation :: proc(t: ^testing.T) {
	info := Edit_Stat {
		exists        = true,
		first_cluster = 17,
		size          = 0x1234,
		modified_date = 0x58AF,
		modified_time = 0x7C00,
	}
	payload := protocol_edit_stat_encode(info)
	decoded, ok := protocol_edit_stat_decode(payload[:])
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, decoded, info)
	_, truncated_ok := protocol_edit_stat_decode(payload[:len(payload) - 1])
	testing.expect(t, !truncated_ok)
}

@(test)
edit_protocol_test_apply_progress_round_trip_and_validation :: proc(t: ^testing.T) {
	want := Edit_Apply_Progress {
		state = .Applying,
		completed_units = 1024,
		total_units = 4096,
		applied_sectors = 17,
		total_sectors = 31,
	}
	payload := protocol_edit_apply_encode(want)
	got, decoded := protocol_edit_apply_decode(payload[:])
	if !testing.expect(t, decoded) {return}
	testing.expect_value(t, got, want)
	payload[1] = 2
	_, decoded = protocol_edit_apply_decode(payload[:])
	testing.expect(t, !decoded)
	payload[1] = 0
	payload[0] = u8(Edit_Apply_State.Failed) + 1
	_, decoded = protocol_edit_apply_decode(payload[:])
	testing.expect(t, !decoded)
	_, decoded = protocol_edit_apply_decode(payload[:len(payload) - 1])
	testing.expect(t, !decoded)
}
