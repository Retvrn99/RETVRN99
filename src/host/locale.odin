// SPDX-License-Identifier: GPL-3.0-only
package host

import "core:c"
import "core:strings"
import sdl3 "vendor:sdl3"

Host_Locale :: struct {
	language: string,
	country:  string,
}

host_locale_make :: proc(
	language, country: string,
	allocator := context.allocator,
) -> (
	Host_Locale,
	bool,
) {
	if language == "" {return {}, false}
	return {
			language = strings.clone(language, allocator),
			country = strings.clone(country, allocator),
		},
		true
}

host_locale_destroy :: proc(locale: ^Host_Locale, allocator := context.allocator) {
	if locale == nil {return}
	delete(locale.language, allocator)
	delete(locale.country, allocator)
	locale^ = {}
}

host_preferred_locale :: proc(allocator := context.allocator) -> (Host_Locale, bool) {
	count: c.int
	locales := sdl3.GetPreferredLocales(&count)
	if locales == nil {return {}, false}
	defer sdl3.free(rawptr(locales))
	if count <= 0 {return {}, false}
	for index in 0 ..< int(count) {
		locale := locales[index]
		if locale == nil || locale.language == nil {continue}
		country := ""
		if locale.country != nil {country = string(locale.country)}
		if result, ok := host_locale_make(string(locale.language), country, allocator); ok {
			return result, true
		}
	}
	return {}, false
}
