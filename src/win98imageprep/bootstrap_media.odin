// SPDX-License-Identifier: GPL-3.0-only
package win98imageprep

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

BOOTSTRAP_AUTOEXEC :: "@REM RETVRN99 WINDOWS 98 BOOTSTRAP V1\r\n@ECHO OFF\r\nC:\\GSWSETUP.BAT\r\n"
BOOTSTRAP_SYSTEM_NAMES :: [3]string{"IO.SYS", "MSDOS.SYS", "COMMAND.COM"}
BOOTSTRAP_IMAGE_MAX_BYTES :: 4 * 1024 * 1024
PAYLOAD_MARKER_NAME :: "RETVRN99.OWN"
PAYLOAD_MARKER :: "RETVRN99 WINDOWS 98 SETUP PAYLOAD V1\r\n"
LAUNCHER_MARKER :: "@REM RETVRN99 WINDOWS 98 SETUP LAUNCHER V1\r\n"

BOOTSTRAP_FAT_NAMES :: [3]string{"IO      SYS", "MSDOS   SYS", "COMMAND COM"}
BOOTSTRAP_MSDOS_SYS :: "[Options]\r\nLogo=0\r\nBootGUI=0\r\n"

Bootstrap_Diagnostic :: enum {
	None,
	Existing_DOS,
	Partial_DOS,
	Boot_Image_Required,
	Boot_Image_Open_Failed,
	Boot_Image_Invalid,
	Path_Failed,
	Staging_Collision,
	Autoexec_Backup_Collision,
	Recovery_Failed,
	Stage_Write_Failed,
	Commit_Failed,
	Rollback_Failed,
}

Image_Boot_Seed :: struct {
	data:      [3][]u8,
	allocator: runtime.Allocator,
}

image_boot_seed_destroy :: proc(seed: ^Image_Boot_Seed) {
	if seed == nil {return}
	for &data in seed.data {delete(data, seed.allocator)}
	seed^ = {}
}

image_boot_seed_parse :: proc(
	image: []u8,
	allocator := context.allocator,
) -> (
	Image_Boot_Seed,
	Bootstrap_Diagnostic,
) {
	seed := Image_Boot_Seed {
		allocator = allocator,
	}
	if len(image) < 512 || len(image) > BOOTSTRAP_IMAGE_MAX_BYTES {return {}, .Boot_Image_Invalid}
	bps := int(boot_seed_rd16(image, 11))
	sectors_per_cluster := int(image[13])
	reserved := int(boot_seed_rd16(image, 14))
	fat_count := int(image[16])
	root_entries := int(boot_seed_rd16(image, 17))
	total_sectors := int(boot_seed_rd16(image, 19))
	if total_sectors == 0 {total_sectors = int(boot_seed_rd32(image, 32))}
	sectors_per_fat := int(boot_seed_rd16(image, 22))
	if bps != 512 ||
	   sectors_per_cluster <= 0 ||
	   (sectors_per_cluster & (sectors_per_cluster - 1)) != 0 ||
	   reserved <= 0 ||
	   fat_count <= 0 ||
	   root_entries <= 0 ||
	   total_sectors <= 0 ||
	   sectors_per_fat <= 0 ||
	   image[510] != 0x55 ||
	   image[511] != 0xaa {
		return {}, .Boot_Image_Invalid
	}
	image_bytes := u64(total_sectors) * u64(bps)
	if image_bytes > u64(len(image)) {return {}, .Boot_Image_Invalid}
	root_sectors := (root_entries * 32 + bps - 1) / bps
	first_root_sector := reserved + fat_count * sectors_per_fat
	first_data_sector := first_root_sector + root_sectors
	if first_data_sector >= total_sectors {return {}, .Boot_Image_Invalid}
	cluster_count := (total_sectors - first_data_sector) / sectors_per_cluster
	if cluster_count <= 0 || cluster_count >= 4085 {return {}, .Boot_Image_Invalid}
	fat_offset := reserved * bps
	fat_bytes := sectors_per_fat * bps
	if fat_offset + fat_bytes > len(image) ||
	   fat_bytes < 3 ||
	   image[fat_offset] != image[21] ||
	   image[fat_offset + 1] != 0xff ||
	   image[fat_offset + 2] != 0xff {
		return {}, .Boot_Image_Invalid
	}
	root_offset := first_root_sector * bps
	root_bytes := root_entries * 32
	if root_offset + root_bytes > len(image) {return {}, .Boot_Image_Invalid}
	found: [3]bool
	for entry_index in 0 ..< root_entries {
		offset := root_offset + entry_index * 32
		first := image[offset]
		if first == 0 {break}
		if first == 0xe5 {continue}
		attributes := image[offset + 11]
		if (attributes & 0x0f) == 0x0f || (attributes & 0x18) != 0 {continue}
		name := string(image[offset:offset + 11])
		for wanted, file_index in BOOTSTRAP_FAT_NAMES {
			if name != wanted {continue}
			if found[file_index] {
				image_boot_seed_destroy(&seed)
				return {}, .Boot_Image_Invalid
			}
			first_cluster := int(boot_seed_rd16(image, offset + 26))
			size := int(boot_seed_rd32(image, offset + 28))
			data, ok := boot_seed_fat12_file(
				image,
				fat_offset,
				fat_bytes,
				first_data_sector,
				sectors_per_cluster,
				cluster_count,
				first_cluster,
				size,
				allocator,
			)
			if !ok {
				image_boot_seed_destroy(&seed)
				return {}, .Boot_Image_Invalid
			}
			if file_index == 1 && boot_seed_msdos_placeholder(data) {
				delete(data, allocator)
				managed: string = BOOTSTRAP_MSDOS_SYS
				data = make([]u8, len(managed), allocator)
				copy(data, managed)
			}
			seed.data[file_index] = data
			found[file_index] = true
		}
	}
	for present in found {
		if !present {
			image_boot_seed_destroy(&seed)
			return {}, .Boot_Image_Invalid
		}
	}
	return seed, .None
}

image_boot_seed_extract :: proc(
	boot_image_path: string,
	allocator := context.allocator,
) -> (
	Image_Boot_Seed,
	Bootstrap_Diagnostic,
) {
	info, stat_error := os.stat(boot_image_path, context.temp_allocator)
	if stat_error != nil {return {}, .Boot_Image_Open_Failed}
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular || info.size < 512 || info.size > BOOTSTRAP_IMAGE_MAX_BYTES {
		return {}, .Boot_Image_Invalid
	}
	image, read_error := os.read_entire_file(boot_image_path, context.temp_allocator)
	if read_error != nil {return {}, .Boot_Image_Open_Failed}
	defer delete(image, context.temp_allocator)
	return image_boot_seed_parse(image, allocator)
}

image_launcher_text :: proc(
	setup_executable: string,
	enable_boot_gui: bool,
	restore_autoexec := true,
	hardware_diagnostics := false,
	allocator := context.allocator,
) -> string {
	text := bootstrap_launcher_text(
		setup_executable,
		enable_boot_gui,
		restore_autoexec,
		hardware_diagnostics,
	)
	return strings.clone(text, allocator)
}

fallback_msbatch :: proc() -> string {
	return(
		`[BatchSetup]
Version=3.0 (32-bit)

[Version]
Signature="$CHICAGO$"
LayoutFile=layout.inf

[Setup]
Express=1
InstallDir="C:\WINDOWS"
InstallType=3
EBD=0
ShowEula=0
ChangeDir=0
Uninstall=0
NoPrompt2Boot=1
OptionalComponents=0
PenWinWarning=0

[NameAndOrg]
Name="RET VRN 99 User"
Org="RET VRN 99"
Display=0

[Network]
ComputerName="RETVRN99"
Workgroup="WORKGROUP"
Description="RET VRN 99"
Display=0
ValidateNetCardResources=0
` \
	)
}

@(private = "file")
bootstrap_launcher_text :: proc(
	setup_executable: string,
	enable_boot_gui: bool,
	restore_autoexec := false,
	hardware_diagnostics := false,
) -> string {
	boot_options := ""
	if enable_boot_gui {
		boot_options = "ECHO [Options]>C:\\MSDOS.SYS\r\nECHO Logo=0>>C:\\MSDOS.SYS\r\nECHO BootGUI=1>>C:\\MSDOS.SYS\r\n"
	}
	autoexec_restore := ""
	if restore_autoexec {
		autoexec_restore =
			"IF EXIST C:\\GSWAUTO.PRV GOTO GSWAR\r\n" +
			"DEL C:\\AUTOEXEC.BAT >NUL\r\n" +
			"IF EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"GOTO GSWAGO\r\n" +
			":GSWAR\r\n" +
			"DEL C:\\AUTOEXEC.BAT >NUL\r\n" +
			"IF EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"REN C:\\GSWAUTO.PRV AUTOEXEC.BAT\r\n" +
			"IF EXIST C:\\GSWAUTO.PRV GOTO GSWAE\r\n" +
			"IF NOT EXIST C:\\AUTOEXEC.BAT GOTO GSWAE\r\n" +
			"GOTO GSWAGO\r\n" +
			":GSWAE\r\n" +
			"ECHO Cannot restore C:\\AUTOEXEC.BAT; Setup was not started.\r\n" +
			"GOTO GSWEND\r\n" +
			":GSWAGO\r\n"
	}
	detection_options := hardware_diagnostics ? " /P G=3;L=3;P" : ""
	return fmt.tprintf(
		"%s@ECHO OFF\r\n%s%sC:\r\nCD \\GSWSETUP\r\n%s MSBATCH.INF /C /IS /IQ /IM /IV%s\r\n:GSWEND\r\n",
		LAUNCHER_MARKER,
		autoexec_restore,
		boot_options,
		setup_executable,
		detection_options,
	)
}

@(private)
boot_seed_msdos_placeholder :: proc(data: []u8) -> bool {
	switch string(data) {
	case "; \r\n", ";\r\n", "; \n", ";\n", ";FORMAT", ";FORMAT\r\n", ";FORMAT\n":
		return true
	}
	return false
}

@(private = "file")
boot_seed_fat12_file :: proc(
	image: []u8,
	fat_offset, fat_bytes, first_data_sector, sectors_per_cluster, cluster_count: int,
	first_cluster, size: int,
	allocator: runtime.Allocator,
) -> (
	[]u8,
	bool,
) {
	if size <= 0 || first_cluster < 2 || first_cluster >= cluster_count + 2 {return nil, false}
	data := make([]u8, size, allocator)
	visited := make([]bool, cluster_count + 2, context.temp_allocator)
	defer delete(visited, context.temp_allocator)
	cluster := first_cluster
	written := 0
	cluster_bytes := sectors_per_cluster * 512
	for written < size {
		if cluster < 2 || cluster >= cluster_count + 2 || visited[cluster] {
			delete(data, allocator)
			return nil, false
		}
		visited[cluster] = true
		data_sector := first_data_sector + (cluster - 2) * sectors_per_cluster
		offset := data_sector * 512
		amount := min(cluster_bytes, size - written)
		if offset < 0 || offset + amount > len(image) {
			delete(data, allocator)
			return nil, false
		}
		copy(data[written:written + amount], image[offset:offset + amount])
		written += amount
		next, ok := boot_seed_fat12_next(image, fat_offset, fat_bytes, cluster)
		if !ok {
			delete(data, allocator)
			return nil, false
		}
		if written == size {
			if next < 0xff8 {
				delete(data, allocator)
				return nil, false
			}
			break
		}
		if next >= 0xff8 {
			delete(data, allocator)
			return nil, false
		}
		cluster = next
	}
	return data, true
}

@(private = "file")
boot_seed_fat12_next :: proc(image: []u8, fat_offset, fat_bytes, cluster: int) -> (int, bool) {
	entry_offset := cluster + cluster / 2
	if entry_offset < 0 ||
	   entry_offset + 1 >= fat_bytes ||
	   fat_offset + entry_offset + 1 >= len(image) {
		return 0, false
	}
	value := int(boot_seed_rd16(image, fat_offset + entry_offset))
	if (cluster & 1) != 0 {value >>= 4} else {value &= 0x0fff}
	if value == 0 || value == 1 || value == 0xff7 {return 0, false}
	return value, true
}

@(private = "file")
boot_seed_rd16 :: proc(data: []u8, offset: int) -> u16 {
	if offset < 0 || offset + 2 > len(data) {return 0}
	return u16(data[offset]) | u16(data[offset + 1]) << 8
}

@(private = "file")
boot_seed_rd32 :: proc(data: []u8, offset: int) -> u32 {
	if offset < 0 || offset + 4 > len(data) {return 0}
	return(
		u32(data[offset]) |
		u32(data[offset + 1]) << 8 |
		u32(data[offset + 2]) << 16 |
		u32(data[offset + 3]) << 24 \
	)
}
