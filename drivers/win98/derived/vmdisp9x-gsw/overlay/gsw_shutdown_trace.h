/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef GSW_SHUTDOWN_TRACE_H
#define GSW_SHUTDOWN_TRACE_H

static void GSW_shutdown_marker(unsigned char code);
#pragma aux GSW_shutdown_marker = \
	".386" \
	"mov dx,80h" \
	"out dx,al" \
	parm [al] modify [dx];

#define GSW_MARK_INT10_MODE13          0xD0
#define GSW_MARK_PRE_HIRES_TO_VGA      0xD1
#define GSW_MARK_POST_HIRES_TO_VGA     0xD2
#define GSW_MARK_PRE_VGA_TO_HIRES      0xD3
#define GSW_MARK_POST_VGA_TO_HIRES     0xD4
#define GSW_MARK_DRIVER_DISABLING      0xD5
#define GSW_MARK_SYSTEM_EXIT           0xD6
#define GSW_MARK_DEVICE_EXIT_ENTER     0xD7
#define GSW_MARK_TRANSPORT_WAIT        0xD8
#define GSW_MARK_TRANSPORT_ACQUIRED    0xD9
#define GSW_MARK_3D_WAIT               0xDA
#define GSW_MARK_3D_ACQUIRED           0xDB
#define GSW_MARK_DEVICE_EXIT_DONE      0xDC
#define GSW_MARK_DESTROY_PROCESS       0xDD
#define GSW_MARK_PROCESS_CLEANUP_DONE  0xDE

#endif
