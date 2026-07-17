// SPDX-License-Identifier: GPL-3.0-only
package win98media

import "core:os"

EL_TORITO_SYSTEM_ID :: "EL TORITO SPECIFICATION"
EL_TORITO_CATALOG_ENTRY_BYTES :: 32
EL_TORITO_BOOTABLE :: u8(0x88)
EL_TORITO_MEDIA_1440K :: u8(2)
EL_TORITO_FLOPPY_BYTES :: 1440 * 1024

Boot_Floppy_Diagnostic :: enum {
	None,
	Absent,
	Unsupported,
	Malformed,
	Image_Read_Failed,
	Destination_Exists,
	Create_File_Failed,
	Write_Failed,
}

Boot_Floppy :: struct {
	image_lba: u32,
	size:      u32,
}

@(private = "file")
eltorito_system_id :: proc(data: []u8) -> bool {
	if len(data) != 32 {return false}
	length := len(data)
	for length > 0 && (data[length - 1] == 0 || data[length - 1] == ' ') {length -= 1}
	return string(data[:length]) == EL_TORITO_SYSTEM_ID
}

@(private = "file")
eltorito_catalog_checksum_valid :: proc(entry: []u8) -> bool {
	if len(entry) != EL_TORITO_CATALOG_ENTRY_BYTES ||
	   entry[0] != 1 ||
	   entry[30] != 0x55 ||
	   entry[31] != 0xAA {
		return false
	}
	sum: u16
	for offset in 0 ..< EL_TORITO_CATALOG_ENTRY_BYTES / 2 {
		sum += iso_u16_le(entry[offset * 2:])
	}
	return sum == 0
}

iso_boot_floppy_find :: proc(image: ^Iso_Image) -> (Boot_Floppy, Boot_Floppy_Diagnostic) {
	if image == nil || image.file == nil {return {}, .Image_Read_Failed}
	descriptor: [ISO_BLOCK_SIZE]u8
	catalog_lba: u32
	for sector in 16 ..< 80 {
		if !iso_read_exact(image.file, descriptor[:], u64(sector * ISO_BLOCK_SIZE)) {
			return {}, .Image_Read_Failed
		}
		if string(descriptor[1:6]) != "CD001" || descriptor[6] != 1 {
			return {}, .Malformed
		}
		if descriptor[0] == 0 && eltorito_system_id(descriptor[7:39]) {
			catalog_lba = iso_u32_le(descriptor[71:75])
			break
		}
		if descriptor[0] == 255 {break}
	}
	if catalog_lba == 0 {return {}, .Absent}
	catalog_offset := u64(catalog_lba) * ISO_BLOCK_SIZE
	if catalog_offset + ISO_BLOCK_SIZE > image.file_bytes {return {}, .Malformed}
	catalog: [ISO_BLOCK_SIZE]u8
	if !iso_read_exact(image.file, catalog[:], catalog_offset) {
		return {}, .Image_Read_Failed
	}
	if !eltorito_catalog_checksum_valid(catalog[:EL_TORITO_CATALOG_ENTRY_BYTES]) {
		return {}, .Malformed
	}
	entry := catalog[EL_TORITO_CATALOG_ENTRY_BYTES:2 * EL_TORITO_CATALOG_ENTRY_BYTES]
	if entry[0] != EL_TORITO_BOOTABLE || entry[1] != EL_TORITO_MEDIA_1440K {
		return {}, .Unsupported
	}
	image_lba := iso_u32_le(entry[8:12])
	start := u64(image_lba) * ISO_BLOCK_SIZE
	end := start + EL_TORITO_FLOPPY_BYTES
	volume_bytes := u64(image.volume_blocks) * u64(image.block_size)
	if image_lba == 0 || end < start || end > image.file_bytes || end > volume_bytes {
		return {}, .Malformed
	}
	return Boot_Floppy{image_lba = image_lba, size = EL_TORITO_FLOPPY_BYTES}, .None
}

read_boot_floppy :: proc(
	iso_path: string,
	allocator := context.allocator,
) -> (
	[]u8,
	Boot_Floppy_Diagnostic,
) {
	image, diagnostic := iso_open(iso_path)
	if diagnostic != .None {
		if diagnostic == .Image_Read_Failed {return nil, .Image_Read_Failed}
		return nil, .Malformed
	}
	defer iso_image_close(&image)
	boot, boot_diagnostic := iso_boot_floppy_find(&image)
	if boot_diagnostic != .None {return nil, boot_diagnostic}
	data := make([]u8, int(boot.size), allocator)
	if !iso_read_exact(image.file, data, u64(boot.image_lba) * ISO_BLOCK_SIZE) {
		delete(data, allocator)
		return nil, .Image_Read_Failed
	}
	return data, .None
}

extract_boot_floppy :: proc(iso_path, destination: string) -> Boot_Floppy_Diagnostic {
	image, diagnostic := iso_open(iso_path)
	if diagnostic != .None {
		#partial switch diagnostic {
		case .Image_Read_Failed:
			return .Image_Read_Failed
		case:
			return .Malformed
		}
	}
	defer iso_image_close(&image)
	boot, boot_diagnostic := iso_boot_floppy_find(&image)
	if boot_diagnostic != .None {return boot_diagnostic}
	out, create_error := os.open(destination, {.Write, .Create, .Excl})
	if create_error != nil {
		return create_error == os.General_Error.Exist ? .Destination_Exists : .Create_File_Failed
	}
	remove_on_failure := true
	defer {
		if out != nil {_ = os.close(out)}
		if remove_on_failure {_ = os.remove(destination)}
	}
	buffer: [64 * 1024]u8
	offset := u64(boot.image_lba) * ISO_BLOCK_SIZE
	remaining := u64(boot.size)
	for remaining > 0 {
		amount := int(min(remaining, u64(len(buffer))))
		if !iso_read_exact(image.file, buffer[:amount], offset) {return .Image_Read_Failed}
		written, write_error := os.write(out, buffer[:amount])
		if write_error != nil || written != amount {return .Write_Failed}
		offset += u64(amount)
		remaining -= u64(amount)
	}
	if os.sync(out) != nil || os.close(out) != nil {
		out = nil
		return .Write_Failed
	}
	out = nil
	remove_on_failure = false
	return .None
}
