// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"
import "host"

@(test)
quick_install_test_key_validation_is_syntax_only :: proc(t: ^testing.T) {
	testing.expect(t, quick_install_key_syntax_valid("ABCDE-12345-ABCDE-12345-ABCDE"))
	testing.expect(t, quick_install_key_syntax_valid("abcde-12345-abcde-12345-abcde"))
	testing.expect(t, !quick_install_key_syntax_valid("ABCDE-12345-ABCDE-12345"))
	testing.expect(t, !quick_install_key_syntax_valid("ABCDE-12345-ABCDE-12345-ABCD!"))
}

@(test)
quick_install_test_dialog_request_is_iso_only :: proc(t: ^testing.T) {
	request := quick_install_iso_dialog()
	testing.expect_value(t, request.kind, host.Hard_Drive_Native_Dialog_Kind.Open_File)
	testing.expect_value(t, request.purpose, host.Hard_Drive_Dialog_Purpose.Quick_Install_ISO)
	testing.expect_value(t, request.filter_pattern, "iso")
}
