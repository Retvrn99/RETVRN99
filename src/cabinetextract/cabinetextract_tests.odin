#+build windows

// SPDX-License-Identifier: GPL-3.0-only
package cabinetextract

import "core:testing"

@(test)
cabinetextract_test_rejects_traversal_before_platform_dispatch :: proc(t: ^testing.T) {
	requests := []Setup_Source_Extract_Request {
		{
			source_name = "../MSHDC.INF",
			destination = "C:\\scratch\\MSHDC.INF",
			max_output_bytes = 1024,
		},
	}
	diagnostic := setup_source_extract_files("C:\\setup", "PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Unsafe_Source_Name)
	testing.expect_value(t, diagnostic.request_index, i32(0))

	requests[0].source_name = "MSHDC.INF"
	requests[0].destination = "C:\\scratch\\..\\MSHDC.INF"
	diagnostic = setup_source_extract_files("C:\\setup", "PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Unsafe_Destination)

	requests[0].destination = "C:\\scratch\\MSHDC.INF:stream"
	diagnostic = setup_source_extract_files("C:\\setup", "PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Unsafe_Destination)

	requests[0].destination = "C:\\scratch\\MSHDC.INF"
	diagnostic = setup_source_extract_files("C:\\setup", "..\\PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Unsafe_Cabinet_Name)
}

@(test)
cabinetextract_test_rejects_unbounded_and_duplicate_targets :: proc(t: ^testing.T) {
	requests := []Setup_Source_Extract_Request {
		{source_name = "MSHDC.INF", destination = "C:\\scratch\\MSHDC.INF", max_output_bytes = 0},
	}
	diagnostic := setup_source_extract_files("C:\\setup", "PRECOPY1.CAB", requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Invalid_Output_Limit)

	duplicate_requests := []Setup_Source_Extract_Request {
		{
			source_name = "MSHDC.INF",
			destination = "C:\\scratch\\MSHDC.INF",
			max_output_bytes = 1024,
		},
		{
			source_name = "mshdc.inf",
			destination = "C:\\scratch\\OTHER.INF",
			max_output_bytes = 1024,
		},
	}
	diagnostic = setup_source_extract_files("C:\\setup", "PRECOPY1.CAB", duplicate_requests)
	testing.expect_value(t, diagnostic.code, Setup_Source_Extract_Code.Duplicate_Target_Request)
	testing.expect_value(t, diagnostic.request_index, i32(1))
}
