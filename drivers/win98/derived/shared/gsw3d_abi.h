/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW3D_ABI_H
#define RETVRN99_GSW3D_ABI_H

#define GSW3D_ABI_VERSION                 1UL
#define GSW3D_PACKET_SVGA9                1UL
#define GSW3D_COMMAND_VERSION             1

#define GSW3D_REG_PACKET_FORMAT           0x100UL
#define GSW3D_REG_CAPABILITIES            0x104UL
#define GSW3D_REG_RING_GPA_LOW            0x108UL
#define GSW3D_REG_RING_GPA_HIGH           0x10CUL
#define GSW3D_REG_RING_SIZE               0x110UL
#define GSW3D_REG_RING_HEAD               0x114UL
#define GSW3D_REG_RING_TAIL               0x118UL
#define GSW3D_REG_DOORBELL                0x11CUL
#define GSW3D_REG_STATUS                  0x120UL
#define GSW3D_REG_FENCE_LOW               0x124UL
#define GSW3D_REG_FENCE_HIGH              0x128UL
#define GSW3D_REG_ERROR                   0x12CUL
#define GSW3D_REG_PRESENT_INTERVALS       0x130UL

#define GSW3D_OPCODE_REGISTER_REGION      1
#define GSW3D_OPCODE_UNREGISTER_REGION    2
#define GSW3D_OPCODE_CREATE_CONTEXT       3
#define GSW3D_OPCODE_DESTROY_CONTEXT      4
#define GSW3D_OPCODE_SUBMIT               5
#define GSW3D_OPCODE_DIRECT_PRESENT       6
#define GSW3D_OPCODE_RESOURCE_UPLOAD      7

#define GSW3D_CAP_SVGA9                   (1UL << 0)
#define GSW3D_CAP_DIRECT_PRESENT          (1UL << 1)
#define GSW3D_CAP_RESOURCE_UPLOAD         (1UL << 2)
#define GSW3D_CAP_ASYNC_COMPLETION        (1UL << 3)

#define GSW3D_STATUS_READY                (1UL << 0)
#define GSW3D_STATUS_BUSY                 (1UL << 1)
#define GSW3D_STATUS_ERROR                (1UL << 2)
#define GSW3D_STATUS_QUEUE_FULL           (1UL << 3)
#define GSW3D_STATUS_RESET                (1UL << 31)

#define GSW3D_ERROR_NONE                  0UL
#define GSW3D_ERROR_QUEUE_FULL            7UL

#define GSW3D_IOCTL_QUERY                 0x47530100UL
#define GSW3D_IOCTL_CONTEXT_CREATE        0x47530101UL
#define GSW3D_IOCTL_CONTEXT_DESTROY       0x47530102UL
#define GSW3D_IOCTL_SUBMIT                 0x47530103UL
#define GSW3D_IOCTL_UPLOAD                 0x47530104UL
#define GSW3D_IOCTL_PRESENT                0x47530105UL
#define GSW3D_IOCTL_FENCE_POLL             0x47530106UL

#define GSW3D_IOCTL_FIRST                 GSW3D_IOCTL_QUERY
#define GSW3D_IOCTL_LAST                  GSW3D_IOCTL_FENCE_POLL
#define GSW3D_STAGING_BYTES               (64UL * 1024UL)
#define GSW3D_MAX_BATCH_BYTES             GSW3D_STAGING_BYTES

#pragma pack(push, 1)

typedef struct GSW3DCommandHeader {
	WORD opcode;
	WORD version;
	DWORD length;
	DWORD fence_low;
	DWORD fence_high;
} GSW3DCommandHeader;

typedef struct GSW3DRegionCommand {
	GSW3DCommandHeader header;
	DWORD region_id;
	DWORD reserved0;
	DWORD gpa_low;
	DWORD gpa_high;
	DWORD size_low;
	DWORD size_high;
} GSW3DRegionCommand;

typedef struct GSW3DIdCommand {
	GSW3DCommandHeader header;
	DWORD id;
	DWORD reserved0;
} GSW3DIdCommand;

typedef struct GSW3DSubmitCommand {
	GSW3DCommandHeader header;
	DWORD context_id;
	DWORD region_id;
	DWORD offset_low;
	DWORD offset_high;
	DWORD byte_count;
	DWORD packet_format;
} GSW3DSubmitCommand;

typedef struct GSW3DUploadCommand {
	GSW3DCommandHeader header;
	DWORD resource_id;
	DWORD region_id;
	DWORD source_offset_low;
	DWORD source_offset_high;
	DWORD destination_offset_low;
	DWORD destination_offset_high;
	DWORD byte_count;
	DWORD reserved0;
} GSW3DUploadCommand;

typedef struct GSW3DPresentCommand {
	GSW3DCommandHeader header;
	DWORD context_id;
	DWORD surface_id;
	DWORD source_x;
	DWORD source_y;
	DWORD source_width;
	DWORD source_height;
	DWORD destination_x;
	DWORD destination_y;
	DWORD destination_width;
	DWORD destination_height;
	DWORD interval;
	DWORD reserved0;
} GSW3DPresentCommand;

typedef struct GSW3DQuery {
	DWORD cb;
	DWORD version;
	DWORD available;
	DWORD capabilities;
	DWORD packet_format;
	DWORD present_intervals;
	DWORD staging_bytes;
	DWORD maximum_batch_bytes;
} GSW3DQuery;

typedef struct GSW3DContextRequest {
	DWORD cb;
	DWORD context_id;
} GSW3DContextRequest;

/* Batch bytes immediately follow this fixed header in the DIOC input buffer. */
typedef struct GSW3DSubmitRequest {
	DWORD cb;
	DWORD context_id;
	DWORD byte_count;
} GSW3DSubmitRequest;

/* Upload bytes immediately follow this fixed header in the DIOC input buffer. */
typedef struct GSW3DUploadRequest {
	DWORD cb;
	DWORD resource_id;
	DWORD destination_offset_low;
	DWORD destination_offset_high;
	DWORD byte_count;
} GSW3DUploadRequest;

typedef struct GSW3DPresentRequest {
	DWORD cb;
	DWORD context_id;
	DWORD surface_id;
	DWORD source_x;
	DWORD source_y;
	DWORD source_width;
	DWORD source_height;
	DWORD destination_x;
	DWORD destination_y;
	DWORD destination_width;
	DWORD destination_height;
	DWORD interval;
} GSW3DPresentRequest;

typedef struct GSW3DFencePollRequest {
	DWORD cb;
	DWORD fence_low;
	DWORD fence_high;
} GSW3DFencePollRequest;

typedef struct GSW3DResult {
	DWORD cb;
	DWORD success;
	DWORD fence_low;
	DWORD fence_high;
	DWORD completed_low;
	DWORD completed_high;
	DWORD status;
	DWORD error;
} GSW3DResult;

#pragma pack(pop)

#endif
