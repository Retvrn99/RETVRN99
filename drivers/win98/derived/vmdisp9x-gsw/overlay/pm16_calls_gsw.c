/* SPDX-License-Identifier: GPL-3.0-only */
#define QEMU
#define GSW
#define mouse_buffer GSW_base_mouse_buffer
#include "pm16_calls.c"
#undef mouse_buffer

void mouse_buffer(void __far* __far* pBuf, DWORD __far* pLinear)
{
	*pBuf = NULL;
	*pLinear = 0;
}
