/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW_GDI_ABI_H
#define RETVRN99_GSW_GDI_ABI_H

#define GSW_VGA_CAP_GDI_ROP3              (1UL << 5)
#define GSW_VGA_CAP_GDI_FAST_DOORBELL     (1UL << 6)
#define GSW_VGA_CAP_GDI_SYNC_COOKIE       (1UL << 7)
#define GSW_VGA_COMMAND_VERSION_4         4
#define GSW_VGA_OPCODE_GDI_BLT            13
#define GSW_GDI_PM16_QUERY                 0x47B0
#define GSW_GDI_PM16_SUBMIT                0x47B1
#define GSW_GDI_SOURCE_VALID               (1UL << 0)
#define GSW_GDI_PATTERN_VALID              (1UL << 1)
#define GSW_GDI_DOORBELL_TAIL_FLAG         0x80000000UL
#define GSW_GDI_DOORBELL_COOKIE_FLAG       0x40000000UL
#define GSW_GDI_COMPLETION_COOKIE           0x4753574FUL
#define GSW_GDI_PATTERN_PIXELS             64
#define GSW_GDI_BLT_COMMAND_BYTES          324UL

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

typedef struct GSWGdiBltCommand {
	GSWCommandHeader header;
	DWORD source_offset;
	DWORD destination_offset;
	DWORD source_pitch;
	DWORD destination_pitch;
	DWORD source_x;
	DWORD source_y;
	DWORD destination_x;
	DWORD destination_y;
	DWORD width;
	DWORD height;
	DWORD format;
	DWORD flags;
	DWORD rop3;
	DWORD pattern[GSW_GDI_PATTERN_PIXELS];
} GSWGdiBltCommand;

#pragma pack(pop)

#endif
