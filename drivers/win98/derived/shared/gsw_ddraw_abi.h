/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW_DDRAW_ABI_H
#define RETVRN99_GSW_DDRAW_ABI_H

#define GSW_DD_ABI_VERSION                1UL
#define GSW_DD_CAP_SURFACE_IDS            (1UL << 0)
#define GSW_DD_CAP_FILL                   (1UL << 1)
#define GSW_DD_CAP_BLT                    (1UL << 2)
#define GSW_DD_CAP_PRESENT                (1UL << 3)
#define GSW_DD_CAP_DIRTY_RECT             (1UL << 4)
#define GSW_DD_CAP_DST_COLOR_KEY          (1UL << 5)

#define GSW_VGA_CAP_SURFACE_IDS           (1UL << 4)
#define GSW_VGA_COMMAND_VERSION_3         3
#define GSW_VGA_OPCODE_REGISTER_SURFACE   7
#define GSW_VGA_OPCODE_UNREGISTER_SURFACE 8
#define GSW_VGA_OPCODE_SURFACE_FILL       9
#define GSW_VGA_OPCODE_SURFACE_BLT        10
#define GSW_VGA_OPCODE_SURFACE_PRESENT    11
#define GSW_VGA_OPCODE_SURFACE_DIRTY      12

#define GSW_DD_SURFACE_PRESENTABLE        (1UL << 0)
#define GSW_DD_BLT_SRC_COLOR_KEY          (1UL << 0)
#define GSW_DD_BLT_DST_COLOR_KEY          (1UL << 1)

#define GSW_DD_IOCTL_QUERY                0x47530001UL
#define GSW_DD_IOCTL_REGISTER             0x47530002UL
#define GSW_DD_IOCTL_UNREGISTER           0x47530003UL
#define GSW_DD_IOCTL_FILL                 0x47530004UL
#define GSW_DD_IOCTL_BLT                  0x47530005UL
#define GSW_DD_IOCTL_PRESENT              0x47530006UL
#define GSW_DD_IOCTL_DIRTY                0x47530007UL

#pragma pack(push, 1)

#ifndef RETVRN99_GSW_COMMAND_HEADER_DEFINED
#define RETVRN99_GSW_COMMAND_HEADER_DEFINED
typedef struct GSWCommandHeader {
	WORD opcode;
	WORD version;
	DWORD length;
	DWORD fence_low;
	DWORD fence_high;
} GSWCommandHeader;
#endif

typedef struct GSWRegisterSurfaceCommand {
	GSWCommandHeader header;
	DWORD surface_id;
	DWORD offset;
	DWORD byte_size;
	DWORD width;
	DWORD height;
	DWORD pitch;
	DWORD format;
	DWORD flags;
} GSWRegisterSurfaceCommand;

typedef struct GSWUnregisterSurfaceCommand {
	GSWCommandHeader header;
	DWORD surface_id;
} GSWUnregisterSurfaceCommand;

typedef struct GSWSurfaceFillCommand {
	GSWCommandHeader header;
	DWORD surface_id;
	DWORD x;
	DWORD y;
	DWORD width;
	DWORD height;
	DWORD color;
} GSWSurfaceFillCommand;

typedef struct GSWSurfaceBltCommand {
	GSWCommandHeader header;
	DWORD source_id;
	DWORD destination_id;
	DWORD source_x;
	DWORD source_y;
	DWORD source_width;
	DWORD source_height;
	DWORD destination_x;
	DWORD destination_y;
	DWORD destination_width;
	DWORD destination_height;
	DWORD flags;
	DWORD source_color_key;
	DWORD destination_color_key;
	DWORD pattern;
	DWORD rop3;
} GSWSurfaceBltCommand;

typedef struct GSWSurfacePresentCommand {
	GSWCommandHeader header;
	DWORD surface_id;
} GSWSurfacePresentCommand;

typedef struct GSWSurfaceDirtyCommand {
	GSWCommandHeader header;
	DWORD surface_id;
	DWORD x;
	DWORD y;
	DWORD width;
	DWORD height;
} GSWSurfaceDirtyCommand;

typedef struct GSWDDQuery {
	DWORD cb;
	DWORD version;
	DWORD capabilities;
	DWORD framebuffer_linear;
	DWORD framebuffer_bytes;
} GSWDDQuery;

typedef struct GSWDDRegister {
	DWORD cb;
	DWORD offset;
	DWORD byte_size;
	DWORD width;
	DWORD height;
	DWORD pitch;
	DWORD bpp;
	DWORD flags;
	DWORD surface_id;
} GSWDDRegister;

typedef struct GSWDDUnregister {
	DWORD cb;
	DWORD surface_id;
} GSWDDUnregister;

typedef struct GSWDDFill {
	DWORD cb;
	DWORD surface_id;
	DWORD x;
	DWORD y;
	DWORD width;
	DWORD height;
	DWORD color;
} GSWDDFill;

typedef struct GSWDDBlt {
	DWORD cb;
	DWORD source_id;
	DWORD destination_id;
	DWORD source_x;
	DWORD source_y;
	DWORD source_width;
	DWORD source_height;
	DWORD destination_x;
	DWORD destination_y;
	DWORD destination_width;
	DWORD destination_height;
	DWORD flags;
	DWORD source_color_key;
	DWORD destination_color_key;
	DWORD pattern;
	DWORD rop3;
} GSWDDBlt;

typedef struct GSWDDPresent {
	DWORD cb;
	DWORD surface_id;
} GSWDDPresent;

typedef struct GSWDDDirty {
	DWORD cb;
	DWORD surface_id;
	DWORD x;
	DWORD y;
	DWORD width;
	DWORD height;
} GSWDDDirty;

#pragma pack(pop)

#endif
