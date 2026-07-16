// SPDX-License-Identifier: GPL-3.0-only
package fat32image

import disk "../disk"
import "base:runtime"
import "core:os"

SECTOR_BYTES :: 512
MAX_BLOCK_BYTES :: 128 * 1024
MIN_CAPACITY_GIB :: 1
MAX_CAPACITY_GIB :: 127
LBA28_SECTOR_LIMIT :: u64(1 << 28)

Image_Id :: [16]u8

Image_Info :: struct {
	path:                string,
	image_id:            Image_Id,
	sector_count:        u64,
	partition_lba:       u32,
	partition_sectors:   u32,
	sectors_per_cluster: u8,
	reserved_sectors:    u16,
	marker_sector:       u32, // absolute LBA
	sparse:              bool,
	enrolled:            bool,
	retvrn99_format:     bool,
	dirty:               bool, // state observed before validate/open returned
}

Create_Request :: struct {
	path:                  string,
	capacity_gib:          u32,
	allow_full_allocation: bool,
}

Open_Mode :: enum u8 {
	Read_Only,
	Read_Write,
}

Close_Mode :: enum u8 {
	Clean,
	Clean_Compatible,
	Retain,
}

Error_Code :: enum u16 {
	None,
	Invalid_Argument,
	Capacity_Out_Of_Range,
	Already_Exists,
	Not_Found,
	Path_Unsupported,
	Open_Failed,
	Sparse_Unsupported,
	Resize_Failed,
	Publish_Failed,
	Locked,
	Invalid_Size,
	Invalid_MBR,
	Partition_Unsupported,
	Invalid_VBR,
	Invalid_FAT32,
	Marker_Unavailable,
	Marker_Invalid,
	Boot_Code_Unsupported,
	Invalid_Boot_Target,
	Read_Only,
	Out_Of_Range,
	Protected_Write,
	Closed,
	IO,
	Sync_Failed,
	Internal,
}

MAX_ERROR_TEXT_BYTES :: 384

Image_Error :: struct {
	code:              Error_Code,
	retryable:         bool,
	diagnostic:        [MAX_ERROR_TEXT_BYTES]u8,
	diagnostic_length: u16,
}

Image :: struct {
	allocator:      runtime.Allocator,
	file:           ^os.File,
	info:           Image_Info,
	geometry:       Geometry,
	mode:           Open_Mode,
	write_started:  bool,
	recovery_grade: bool,
	locked:         bool,
	closed:         bool,
}

error_ok :: proc(err: ^Image_Error) -> bool {
	return err == nil || err.code == .None
}

error_text :: proc(err: ^Image_Error) -> string {
	if err == nil || err.diagnostic_length == 0 {return ""}
	return string(err.diagnostic[:int(err.diagnostic_length)])
}

info_destroy :: proc(info: ^Image_Info, allocator := context.allocator) {
	if info == nil {return}
	delete(info.path, allocator)
	info^ = {}
}

block_device :: proc(image: ^Image) -> disk.Block_Device {
	if image == nil || image.closed || image.file == nil {return {}}
	return {
		ctx = image,
		sector_count = image.info.sector_count,
		read = image_device_read,
		write = image_device_write,
		flush = image_device_flush,
	}
}

edit_block_device :: proc(image: ^Image) -> disk.Block_Device {
	if image == nil || image.closed || image.file == nil {return {}}
	return {
		ctx = image,
		sector_count = image.info.sector_count,
		read = image_device_read,
		write = image_edit_device_write,
		flush = image_device_flush,
	}
}
