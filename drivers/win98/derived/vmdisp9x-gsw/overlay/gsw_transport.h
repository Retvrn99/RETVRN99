/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef RETVRN99_GSW_TRANSPORT_H
#define RETVRN99_GSW_TRANSPORT_H

#include "winhack.h"

#define GSW_PCI_VENDOR_ID                 0xFFFE
#define GSW_PCI_DEVICE_ID                 0x0002
#define GSW_PCI_CAPABILITY_OFFSET         0x40
#define GSW_PCI_CAPABILITY_SIGNATURE      0x56575347UL
#define GSW_PCI_CAPABILITY_VERSION        2
#define GSW_PCI_CAPABILITY_LENGTH         0x14

#define GSW_VGA_CONTROL_BYTES             0x1000UL
#define GSW_VGA_RING_BYTES                0x1000UL
#define GSW_VGA_INTERFACE_VERSION         2
#define GSW_VGA_ID                        0x56475347UL

#define GSW_VGA_REG_ID                    0x00
#define GSW_VGA_REG_VERSION               0x04
#define GSW_VGA_REG_CAPABILITIES          0x08
#define GSW_VGA_REG_STATUS                0x0C
#define GSW_VGA_REG_RING_GPA_LOW          0x10
#define GSW_VGA_REG_RING_GPA_HIGH         0x14
#define GSW_VGA_REG_RING_SIZE             0x18
#define GSW_VGA_REG_RING_HEAD             0x1C
#define GSW_VGA_REG_RING_TAIL             0x20
#define GSW_VGA_REG_DOORBELL              0x24
#define GSW_VGA_REG_IRQ_ENABLE            0x28
#define GSW_VGA_REG_IRQ_STATUS            0x2C
#define GSW_VGA_REG_FENCE_LOW             0x30
#define GSW_VGA_REG_FENCE_HIGH            0x34

#define GSW_VGA_CAP_2D                    (1UL << 0)
#define GSW_VGA_CAP_FENCE_IRQ             (1UL << 1)
#define GSW_VGA_CAP_SURFACE_OFFSET        (1UL << 2)
#define GSW_VGA_CAP_BLT_V2                (1UL << 3)
#define GSW_VGA_CAP_SURFACE_IDS           (1UL << 4)

#define GSW_VGA_STATUS_READY              (1UL << 0)
#define GSW_VGA_STATUS_ERROR              (1UL << 1)
#define GSW_VGA_IRQ_2D                    (1UL << 0)

#define GSW_VGA_COMMAND_VERSION_2         2
#define GSW_VGA_OPCODE_SET_MODE           1
#define GSW_VGA_OPCODE_PRESENT            2
#define GSW_VGA_OPCODE_FILL               3
#define GSW_VGA_OPCODE_COPY               4

#define GSW_PIXEL_FORMAT_INDEXED_8        1
#define GSW_PIXEL_FORMAT_RGB_555          2
#define GSW_PIXEL_FORMAT_RGB_565          3
#define GSW_PIXEL_FORMAT_RGB_888          4
#define GSW_PIXEL_FORMAT_XRGB_8888        5

#define GSW_VGA_MAX_WIDTH                 2560UL
#define GSW_VGA_MAX_HEIGHT                1600UL
#define GSW_VGA_MAX_SOFTWARE_PIXELS       (4096UL * 2160UL)

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

typedef struct GSWSetModeCommand {
	GSWCommandHeader header;
	DWORD width;
	DWORD height;
	DWORD pitch;
	DWORD format;
} GSWSetModeCommand;

typedef struct GSWPresentCommand {
	GSWCommandHeader header;
	DWORD offset;
	DWORD width;
	DWORD height;
	DWORD pitch;
	DWORD format;
	DWORD reserved0;
} GSWPresentCommand;

typedef struct GSWFillCommand {
	GSWCommandHeader header;
	DWORD offset;
	DWORD pitch;
	DWORD width;
	DWORD height;
	DWORD color;
	DWORD format;
} GSWFillCommand;

typedef struct GSWCopyCommand {
	GSWCommandHeader header;
	DWORD source;
	DWORD destination;
	DWORD source_pitch;
	DWORD destination_pitch;
	DWORD width;
	DWORD height;
	DWORD format;
} GSWCopyCommand;

#include "gsw_ddraw_abi.h"

#pragma pack(pop)

BOOL GSW_transport_init(void);
void GSW_transport_shutdown(void);
void GSW_transport_release(void);
BOOL GSW_transport_ready(void);
void *GSW_transport_framebuffer(void);
DWORD GSW_transport_framebuffer_bytes(void);
DWORD GSW_transport_capabilities(void);

BOOL GSW_transport_mode_valid(DWORD width, DWORD height, DWORD pitch, DWORD bpp);
BOOL GSW_transport_set_mode(DWORD width, DWORD height, DWORD pitch, DWORD bpp);
BOOL GSW_transport_present(
	DWORD offset,
	DWORD width,
	DWORD height,
	DWORD pitch,
	DWORD bpp
);
BOOL GSW_transport_fill(
	DWORD offset,
	DWORD pitch,
	DWORD width,
	DWORD height,
	DWORD color,
	DWORD bpp
);
BOOL GSW_transport_copy(
	DWORD source,
	DWORD destination,
	DWORD source_pitch,
	DWORD destination_pitch,
	DWORD width,
	DWORD height,
	DWORD bpp
);
BOOL GSW_transport_surface_register(GSWDDRegister *request);
BOOL GSW_transport_surface_unregister(DWORD surface_id);
BOOL GSW_transport_surface_fill(const GSWDDFill *request);
BOOL GSW_transport_surface_blt(const GSWDDBlt *request);
BOOL GSW_transport_surface_present(DWORD surface_id);
BOOL GSW_transport_surface_dirty(const GSWDDDirty *request);
BOOL GSW_DD_ioctl(struct DIOCParams *params, DWORD *result);

#endif
