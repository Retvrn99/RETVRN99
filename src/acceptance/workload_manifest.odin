// SPDX-License-Identifier: GPL-3.0-only
package acceptance

import "core:encoding/json"
import "core:strings"

WORKLOAD_MANIFEST_VERSION :: 1
WORKLOAD_MANIFEST_MAX_ENTRIES :: 64
WORKLOAD_MANIFEST_MAX_BYTES :: 256 * 1024
WORKLOAD_ID_MAX_BYTES :: 64
WORKLOAD_EXECUTABLE_MAX_BYTES :: 128
WORKLOAD_ARGUMENT_MAX_BYTES :: 512
WORKLOAD_ARGUMENTS_MAX_BYTES :: 16 * 1024
WORKLOAD_MANIFEST_DATA := #load("../tests/workload-manifest.json")

Workload :: struct {
	id:                string `json:"id"`,
	executable:        string `json:"executable"`,
	arguments:         []string `json:"arguments"`,
	executable_sha256: string `json:"executable_sha256"`,
	metric:            string `json:"metric"`,
	expected:          u64 `json:"expected"`,
	repetitions:       int `json:"repetitions"`,
	semantic_exit:     string `json:"semantic_exit"`,
}

Workload_Manifest :: struct {
	version:   int `json:"version"`,
	workloads: []Workload `json:"workloads"`,
}

Workload_Manifest_Diagnostic :: enum {
	None,
	Malformed,
	Unsupported_Version,
	Invalid_Entry,
}

workload_manifest_destroy :: proc(manifest: ^Workload_Manifest) {
	if manifest == nil {return}
	for &workload in manifest.workloads {
		delete(workload.id)
		delete(workload.executable)
		for argument in workload.arguments {delete(argument)}
		delete(workload.arguments)
		delete(workload.executable_sha256)
		delete(workload.metric)
		delete(workload.semantic_exit)
	}
	delete(manifest.workloads)
	manifest^ = {}
}

@(private = "file")
workload_hash_valid :: proc(value: string) -> bool {
	if value == "" {return true}
	if len(value) != 64 {return false}
	for byte in transmute([]u8)value {
		if !((byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f')) {return false}
	}
	return true
}

@(private = "file")
workload_ascii_equal_fold :: proc(a, b: string) -> bool {
	if len(a) != len(b) {return false}
	for byte, index in transmute([]u8)a {
		other := b[index]
		normalized := byte
		if normalized >= 'a' && normalized <= 'z' {normalized -= 'a' - 'A'}
		if other >= 'a' && other <= 'z' {other -= 'a' - 'A'}
		if normalized != other {return false}
	}
	return true
}

@(private = "file")
workload_reserved_executable :: proc(value: string) -> bool {
	base := value
	for byte, index in transmute([]u8)value {
		if byte == '.' {base = value[:index]; break}
	}
	if workload_ascii_equal_fold(base, "CON") ||
	   workload_ascii_equal_fold(base, "PRN") ||
	   workload_ascii_equal_fold(base, "AUX") ||
	   workload_ascii_equal_fold(base, "NUL") {return true}
	if len(base) == 4 && base[3] >= '1' && base[3] <= '9' {
		return workload_ascii_equal_fold(base[:3], "COM") ||
		       workload_ascii_equal_fold(base[:3], "LPT")
	}
	return false
}

workload_valid :: proc(workload: ^Workload) -> bool {
	if workload == nil || workload.id == "" || workload.executable == "" {return false}
	if len(workload.id) > WORKLOAD_ID_MAX_BYTES ||
	   len(workload.executable) > WORKLOAD_EXECUTABLE_MAX_BYTES {return false}
	if workload.executable == "." || workload.executable == ".." ||
	   workload.executable[len(workload.executable) - 1] == '.' ||
	   workload.executable[len(workload.executable) - 1] == ' ' ||
	   workload_reserved_executable(workload.executable) {return false}
	if strings.contains(workload.executable, "/") ||
	   strings.contains(workload.executable, "\\") ||
	   strings.contains(workload.executable, ":") {return false}
	if len(workload.arguments) > 32 || workload.expected == 0 {return false}
	argument_bytes := 0
	for argument in workload.arguments {
		if len(argument) > WORKLOAD_ARGUMENT_MAX_BYTES || strings.contains(argument, "\x00") {
			return false
		}
		argument_bytes += len(argument)
	}
	if argument_bytes > WORKLOAD_ARGUMENTS_MAX_BYTES {return false}
	if workload.repetitions < 1 || workload.repetitions > 10 {return false}
	if workload.metric != "gametics" && workload.metric != "frames" {return false}
	if workload.semantic_exit != "test_device" {return false}
	return workload_hash_valid(workload.executable_sha256)
}

workload_manifest_parse :: proc(data: []u8) -> (Workload_Manifest, Workload_Manifest_Diagnostic) {
	manifest: Workload_Manifest
	if len(data) == 0 || len(data) > WORKLOAD_MANIFEST_MAX_BYTES {return {}, .Malformed}
	if err := json.unmarshal(data, &manifest); err != nil {
		workload_manifest_destroy(&manifest)
		return {}, .Malformed
	}
	if manifest.version != WORKLOAD_MANIFEST_VERSION {
		workload_manifest_destroy(&manifest)
		return {}, .Unsupported_Version
	}
	if len(manifest.workloads) == 0 || len(manifest.workloads) > WORKLOAD_MANIFEST_MAX_ENTRIES {
		workload_manifest_destroy(&manifest)
		return {}, .Invalid_Entry
	}
	for &workload, index in manifest.workloads {
		if !workload_valid(&workload) {
			workload_manifest_destroy(&manifest)
			return {}, .Invalid_Entry
		}
		for prior in manifest.workloads[:index] {
			if prior.id == workload.id {
				workload_manifest_destroy(&manifest)
				return {}, .Invalid_Entry
			}
		}
	}
	return manifest, .None
}
