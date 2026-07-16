// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "core:strings"

DRIVER_PACKAGE_MAX_FILES :: 32
DRIVER_PACKAGE_MAX_HARDWARE_IDS :: 16
DRIVER_INF_MAX_BYTES :: u64(1024 * 1024)
DRIVER_CATALOG_MAX_BYTES :: u64(16 * 1024 * 1024)
DRIVER_BINARY_MAX_BYTES :: u64(128 * 1024 * 1024)
STOCK_DMA_PACKAGE_ID :: "stock-win98-ide-dma"
STOCK_DMA_FIRST_CABINET :: "PRECOPY2.CAB"

Driver_Package_Mode :: enum u8 {
	Stock_Overlay,
	PnP_Driver,
	Early_Setup,
	Post_Setup_Component,
}

Driver_File_Kind :: enum u8 {
	Invalid,
	INF,
	Catalog,
	Binary,
}

Driver_Device_Class :: enum u8 {
	None,
	Display,
	Media,
	System,
}

Driver_Package_File :: struct {
	source_name:      string,
	destination_name: string,
	kind:             Driver_File_Kind,
	max_output_bytes: u64,
	patch_section:    string,
}

Driver_Package_Manifest :: struct {
	package_id:      string,
	mode:            Driver_Package_Mode,
	first_cabinet:   string,
	device_class:    Driver_Device_Class,
	hardware_ids:    []string,
	files:           []Driver_Package_File,
	install_section: string,
}

Driver_Package_Diagnostic :: enum u16 {
	None,
	Invalid_Manifest,
	Unsupported_Mode,
	Package_Content_Unavailable,
	Source_Extraction_Failed,
	INF_Patch_Failed,
	Destination_Exists,
	Destination_Write_Failed,
}

STOCK_DMA_FILES := [?]Driver_Package_File {
	{
		source_name = "MSHDC.INF",
		destination_name = "MSHDC.INF",
		kind = .INF,
		max_output_bytes = DRIVER_INF_MAX_BYTES,
		patch_section = "ESDI_AddReg",
	},
	{
		source_name = "DISKDRV.INF",
		destination_name = "DISKDRV.INF",
		kind = .INF,
		max_output_bytes = DRIVER_INF_MAX_BYTES,
		patch_section = "DiskReg",
	},
}

stock_dma_driver_manifest :: proc() -> Driver_Package_Manifest {
	return {
		package_id = STOCK_DMA_PACKAGE_ID,
		mode = .Stock_Overlay,
		first_cabinet = STOCK_DMA_FIRST_CABINET,
		files = STOCK_DMA_FILES[:],
	}
}

driver_manifest_validate :: proc(manifest: Driver_Package_Manifest) -> Driver_Package_Diagnostic {
	if !driver_package_id_valid(manifest.package_id) ||
	   len(manifest.files) == 0 ||
	   len(manifest.files) > DRIVER_PACKAGE_MAX_FILES {
		return .Invalid_Manifest
	}
	for file, index in manifest.files {
		if !driver_manifest_file_valid(file) {return .Invalid_Manifest}
		for prior in 0 ..< index {
			if strings.equal_fold(file.source_name, manifest.files[prior].source_name) ||
			   strings.equal_fold(file.destination_name, manifest.files[prior].destination_name) {
				return .Invalid_Manifest
			}
			if driver_destination_alias(file.destination_name) ==
			   driver_destination_alias(manifest.files[prior].destination_name) {
				return .Invalid_Manifest
			}
		}
	}

	switch manifest.mode {
	case .Stock_Overlay:
		return driver_stock_manifest_validate(manifest)
	case .PnP_Driver:
		return driver_oem_manifest_validate(manifest)
	case .Early_Setup:
		return .Unsupported_Mode
	case .Post_Setup_Component:
		if len(manifest.hardware_ids) != 0 ||
		   !driver_install_section_valid(manifest.install_section) {
			return .Invalid_Manifest
		}
		return .Unsupported_Mode
	}
	return .Unsupported_Mode
}

@(private)
driver_stock_manifest_validate :: proc(
	manifest: Driver_Package_Manifest,
) -> Driver_Package_Diagnostic {
	if manifest.package_id != STOCK_DMA_PACKAGE_ID ||
	   manifest.first_cabinet != STOCK_DMA_FIRST_CABINET ||
	   manifest.device_class != .None ||
	   len(manifest.hardware_ids) != 0 ||
	   manifest.install_section != "" ||
	   len(manifest.files) != len(STOCK_DMA_FILES) {
		return .Invalid_Manifest
	}
	for expected, index in STOCK_DMA_FILES {
		actual := manifest.files[index]
		if actual.source_name != expected.source_name ||
		   actual.destination_name != expected.destination_name ||
		   actual.kind != expected.kind ||
		   actual.max_output_bytes != expected.max_output_bytes ||
		   actual.patch_section != expected.patch_section {
			return .Invalid_Manifest
		}
	}
	return .None
}

@(private)
driver_oem_manifest_validate :: proc(
	manifest: Driver_Package_Manifest,
) -> Driver_Package_Diagnostic {
	if manifest.first_cabinet != "" ||
	   manifest.device_class == .None ||
	   manifest.install_section != "" ||
	   len(manifest.hardware_ids) == 0 ||
	   len(manifest.hardware_ids) > DRIVER_PACKAGE_MAX_HARDWARE_IDS {
		return .Invalid_Manifest
	}
	for hardware_id, index in manifest.hardware_ids {
		if !driver_hardware_id_valid(hardware_id) {return .Invalid_Manifest}
		for prior in 0 ..< index {
			if strings.equal_fold(hardware_id, manifest.hardware_ids[prior]) {
				return .Invalid_Manifest
			}
		}
	}
	inf_count := 0
	binary_count := 0
	catalog_count := 0
	for file, index in manifest.files {
		if file.patch_section != "" {return .Invalid_Manifest}
		if index > 0 &&
		   !driver_ascii_less_fold(
				   manifest.files[index - 1].destination_name,
				   file.destination_name,
			   ) {
			return .Invalid_Manifest
		}
		switch file.kind {
		case .INF:
			inf_count += 1
		case .Catalog:
			catalog_count += 1
		case .Binary:
			binary_count += 1
		case .Invalid:
			return .Invalid_Manifest
		}
	}
	if inf_count != 1 || binary_count == 0 || catalog_count > 1 {
		return .Invalid_Manifest
	}
	return .None
}

@(private)
driver_manifest_file_valid :: proc(file: Driver_Package_File) -> bool {
	if !driver_package_component_valid(file.source_name) ||
	   !driver_package_component_valid(file.destination_name) ||
	   file.max_output_bytes == 0 {
		return false
	}
	switch file.kind {
	case .INF:
		return(
			driver_extension_equal(file.source_name, ".INF") &&
			driver_extension_equal(file.destination_name, ".INF") &&
			file.max_output_bytes <= DRIVER_INF_MAX_BYTES \
		)
	case .Catalog:
		return(
			driver_extension_equal(file.source_name, ".CAT") &&
			driver_extension_equal(file.destination_name, ".CAT") &&
			file.max_output_bytes <= DRIVER_CATALOG_MAX_BYTES \
		)
	case .Binary:
		return(
			driver_binary_extension_valid(file.source_name) &&
			driver_binary_extension_valid(file.destination_name) &&
			file.max_output_bytes <= DRIVER_BINARY_MAX_BYTES \
		)
	case .Invalid:
		return false
	}
	return false
}

@(private)
driver_package_id_valid :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > 64 || value[0] == '-' || value[len(value) - 1] == '-' {
		return false
	}
	for index in 0 ..< len(value) {
		byte := value[index]
		if (byte < 'a' || byte > 'z') && (byte < '0' || byte > '9') && byte != '-' {
			return false
		}
	}
	return true
}

@(private)
driver_hardware_id_valid :: proc(value: string) -> bool {
	if len(value) < 5 ||
	   len(value) > 128 ||
	   strings.index_byte(value, '\\') <= 0 ||
	   strings.contains(value, "..") {
		return false
	}
	for index in 0 ..< len(value) {
		byte := value[index]
		if byte < 0x21 || byte >= 0x7F || byte == '/' || byte == ':' || byte == '"' {
			return false
		}
	}
	return true
}

@(private)
driver_package_component_valid :: proc(value: string) -> bool {
	if len(value) == 0 ||
	   len(value) > 128 ||
	   value == "." ||
	   value == ".." ||
	   value[len(value) - 1] == '.' ||
	   value[len(value) - 1] == ' ' {
		return false
	}
	for index in 0 ..< len(value) {
		byte := value[index]
		if byte < 0x21 || byte >= 0x7F || strings.index_byte(`/\:*?"<>|`, byte) >= 0 {
			return false
		}
	}
	base_end := strings.index_byte(value, '.')
	if base_end < 0 {base_end = len(value)}
	base := value[:base_end]
	reserved := [?]string {
		"CON",
		"PRN",
		"AUX",
		"NUL",
		"COM1",
		"COM2",
		"COM3",
		"COM4",
		"COM5",
		"COM6",
		"COM7",
		"COM8",
		"COM9",
		"LPT1",
		"LPT2",
		"LPT3",
		"LPT4",
		"LPT5",
		"LPT6",
		"LPT7",
		"LPT8",
		"LPT9",
	}
	for item in reserved {
		if strings.equal_fold(base, item) {return false}
	}
	return true
}

@(private)
driver_extension_equal :: proc(value, extension: string) -> bool {
	return(
		len(value) > len(extension) &&
		strings.equal_fold(value[len(value) - len(extension):], extension) \
	)
}

@(private)
driver_binary_extension_valid :: proc(value: string) -> bool {
	extensions := [?]string{".VXD", ".DRV", ".MPD", ".SYS", ".DLL", ".EXE"}
	for extension in extensions {
		if driver_extension_equal(value, extension) {return true}
	}
	return false
}

@(private)
driver_ascii_less_fold :: proc(left, right: string) -> bool {
	count := min(len(left), len(right))
	for index in 0 ..< count {
		l := left[index]
		r := right[index]
		if l >= 'a' && l <= 'z' {l -= 'a' - 'A'}
		if r >= 'a' && r <= 'z' {r -= 'a' - 'A'}
		if l < r {return true}
		if l > r {return false}
	}
	return len(left) < len(right)
}

@(private)
driver_install_section_valid :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > 64 {return false}
	for index in 0 ..< len(value) {
		byte := value[index]
		if (byte < 'A' || byte > 'Z') &&
		   (byte < 'a' || byte > 'z') &&
		   (byte < '0' || byte > '9') &&
		   byte != '_' &&
		   byte != '-' &&
		   byte != '.' {
			return false
		}
	}
	return true
}

@(private)
driver_destination_alias :: proc(name: string) -> [11]u8 {
	result: [11]u8
	for index in 0 ..< len(result) {result[index] = ' '}
	base := name
	extension := ""
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		base = name[:dot]
		extension = name[dot + 1:]
	}
	direct :=
		len(base) > 0 && len(base) <= 8 && len(extension) <= 3 && strings.index_byte(base, '.') < 0
	if direct {
		for index in 0 ..< len(base) {
			upper, ok := driver_short_character(base[index])
			if !ok {
				direct = false
				break
			}
			result[index] = upper
		}
		if direct {
			for index in 0 ..< len(extension) {
				upper, ok := driver_short_character(extension[index])
				if !ok {
					direct = false
					break
				}
				result[8 + index] = upper
			}
		}
		if direct {return result}
	}
	for index in 0 ..< len(result) {result[index] = ' '}
	written := 0
	for index in 0 ..< len(base) {
		if written >= 6 {break}
		upper, _ := driver_short_character(base[index])
		result[written] = upper
		written += 1
	}
	if written == 0 {
		result[0] = '_'
		written = 1
	}
	result[written] = '~'
	result[written + 1] = '1'
	for index in 0 ..< min(len(extension), 3) {
		upper, _ := driver_short_character(extension[index])
		result[8 + index] = upper
	}
	return result
}

@(private)
driver_short_character :: proc(value: u8) -> (u8, bool) {
	upper := value
	if upper >= 'a' && upper <= 'z' {upper -= 'a' - 'A'}
	if upper >= 'A' && upper <= 'Z' || upper >= '0' && upper <= '9' {
		return upper, true
	}
	switch upper {
	case '!', '#', '$', '%', '&', '\'', '(', ')', '-', '@', '^', '_', '`', '{', '}', '~':
		return upper, true
	case:
		return '_', false
	}
}
