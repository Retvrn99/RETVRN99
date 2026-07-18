/* SPDX-License-Identifier: GPL-3.0-only */
#define QEMU
#define GSW
#define mouse_buffer GSW_base_mouse_buffer
#include "pm16_calls.c"
#undef mouse_buffer
#include "gsw_gdi.h"

DWORD GSW_PM16_capabilities(void)
{
	static DWORD capabilities;
	static BYTE failed;
	if(capabilities != 0) return capabilities;
	capabilities = 0;
	failed = 1;
	if(VXD_VM == 0) return 0;
	_asm
	{
		.386
		push eax
		push ecx
		push edx
		xor ecx, ecx
		mov edx, GSW_GDI_PM16_QUERY
		call dword ptr [VXD_VM]
		mov [capabilities], ecx
		setc al
		mov [failed], al
		pop edx
		pop ecx
		pop eax
	}
	return failed ? 0 : capabilities;
}

BOOL GSW_PM16_submit(const GSWGdiBltCommand __far *request)
{
	static DWORD request_linear;
	static DWORD request_base;
	static DWORD result;
	static BYTE failed;
	static WORD request_selector;
	DWORD pointer;
	WORD selector;
	if(VXD_VM == 0 || request == NULL) return FALSE;
	pointer = (DWORD)request;
	selector = (WORD)(pointer >> 16);
	if(request_base == 0 || request_selector != selector)
	{
		request_selector = selector;
		request_base = DPMI_GetSegBase(selector);
	}
	request_linear = request_base + (WORD)pointer;
	result = 0;
	failed = 1;
	_asm
	{
		.386
		push eax
		push ecx
		push edx
		push esi
		mov edx, GSW_GDI_PM16_SUBMIT
		mov ecx, 324
		mov esi, [request_linear]
		call dword ptr [VXD_VM]
		mov [result], ecx
		setc al
		mov [failed], al
		pop esi
		pop edx
		pop ecx
		pop eax
	}
	return !failed && result != 0;
}

void mouse_buffer(void __far* __far* pBuf, DWORD __far* pLinear)
{
	*pBuf = NULL;
	*pLinear = 0;
}
