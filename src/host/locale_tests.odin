// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:testing"

@(test)
host_locale_test_make_owns_language_and_country :: proc(t: ^testing.T) {
	language := []u8{'e', 's'}
	country := []u8{'E', 'S'}
	locale, ok := host_locale_make(string(language), string(country))
	defer host_locale_destroy(&locale)
	language[0] = 'x'
	country[0] = 'X'
	testing.expect(t, ok)
	testing.expect_value(t, locale.language, "es")
	testing.expect_value(t, locale.country, "ES")
}

@(test)
host_locale_test_make_rejects_missing_language :: proc(t: ^testing.T) {
	locale, ok := host_locale_make("", "ES")
	defer host_locale_destroy(&locale)
	testing.expect(t, !ok)
	testing.expect_value(t, locale, Host_Locale{})
}
