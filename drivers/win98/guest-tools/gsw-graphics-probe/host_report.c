/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

#define GSW_PORT_INDEX 0xE4
#define GSW_PORT_DATA 0xE5
#define GSW_PORT_COMMAND 0xE6
#define GSW_REPORT_BEGIN 4
#define GSW_REPORT_APPEND 5
#define GSW_REPORT_COMMIT 6
#define GSW_REPORT_ABORT 7
#define GSW_HOST_OK 1
#define GSW_COMPOSED_SNAPSHOT 8
#define GSW_REG_SNAPSHOT 29

static void gsw_out8(WORD port, BYTE value)
{
#if defined(__GNUC__) && defined(__i386__)
	__asm__ __volatile__("outb %0, %1" : : "a"(value), "Nd"(port));
#else
	(void)port; (void)value;
#endif
}

static BYTE gsw_in8(WORD port)
{
#if defined(__GNUC__) && defined(__i386__)
	BYTE value;
	__asm__ __volatile__("inb %1, %0" : "=a"(value) : "Nd"(port));
	return value;
#else
	(void)port;
	return 0;
#endif
}

static void gsw_register_write(BYTE index, BYTE value)
{
	gsw_out8(GSW_PORT_INDEX, index);
	gsw_out8(GSW_PORT_DATA, value);
}

static BYTE gsw_register_read(BYTE index)
{
	gsw_out8(GSW_PORT_INDEX, index);
	return gsw_in8(GSW_PORT_DATA);
}

static BOOL gsw_command(BYTE command)
{
	DWORD poll;
	gsw_register_write(31, 0);
	gsw_out8(GSW_PORT_COMMAND, command);
	for(poll = 0; poll < 2000; poll++)
	{
		BYTE status = gsw_register_read(31);
		if(status != 0) return status == GSW_HOST_OK;
	}
	return FALSE;
}

BOOL gsw_host_publish(const GSW_REPORT *report)
{
	DWORD offset = 0;
	if(report == NULL || report->bytes == NULL || report->length == 0 ||
	   report->length > GSW_REPORT_CAP) return FALSE;
	if(!gsw_command(GSW_REPORT_BEGIN)) return FALSE;
	while(offset < report->length)
	{
		DWORD length = report->length - offset;
		DWORD index;
		if(length > 30) length = 30;
		for(index = 0; index < length; index++)
			gsw_register_write((BYTE)index, report->bytes[offset + index]);
		gsw_register_write(30, (BYTE)length);
		if(!gsw_command(GSW_REPORT_APPEND))
		{
			gsw_command(GSW_REPORT_ABORT);
			return FALSE;
		}
		offset += length;
	}
	if(!gsw_command(GSW_REPORT_COMMIT))
	{
		gsw_command(GSW_REPORT_ABORT);
		return FALSE;
	}
	return TRUE;
}

/* Asks the host to write what the window would be showing right now, under the
 * given label, and waits for it. Waiting is the point: the host samples the
 * display when it services the command, so a caller that returned immediately
 * would race its own next mode change and capture whatever came after. */
BOOL gsw_host_capture(BYTE label)
{
	gsw_register_write(GSW_REG_SNAPSHOT, label);
	return gsw_command(GSW_COMPOSED_SNAPSHOT);
}

void gsw_host_exit(DWORD code)
{
	gsw_register_write(12, (BYTE)code);
	gsw_register_write(13, (BYTE)(code >> 8));
	gsw_register_write(14, (BYTE)(code >> 16));
	gsw_register_write(15, (BYTE)(code >> 24));
	gsw_out8(GSW_PORT_COMMAND, 3);
}
