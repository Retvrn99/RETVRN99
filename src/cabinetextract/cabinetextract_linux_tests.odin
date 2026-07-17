#+build linux

// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

import "core:testing"

@(test)
cabinetextract_linux_test_reports_unsupported :: proc(t: ^testing.T) {
	requests := []Setup_Source_Extract_Request {
		{source_name = "MSHDC.INF", destination = "/tmp/MSHDC.INF", max_output_bytes = 1024},
	}
	diagnostic := setup_source_extract_files("/tmp", "PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Unsupported)
}
