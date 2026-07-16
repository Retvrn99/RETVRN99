// SPDX-License-Identifier: GPL-3.0-only
package main

import "core:testing"

@(test)
workload_image_test_capacity_parser_bounds :: proc(t: ^testing.T) {
	cases := []struct {
		text:     string,
		expected: u32,
		valid:    bool,
	} {
		{"1", 1, true},
		{"20", 20, true},
		{"127", 127, true},
		{"", 0, false},
		{"0", 0, false},
		{"128", 0, false},
		{"20.0", 0, false},
		{"-1", 0, false},
	}
	for sample in cases {
		actual, ok := parse_capacity_gib(sample.text)
		testing.expect_value(t, ok, sample.valid)
		if sample.valid {testing.expect_value(t, actual, sample.expected)}
	}
}
