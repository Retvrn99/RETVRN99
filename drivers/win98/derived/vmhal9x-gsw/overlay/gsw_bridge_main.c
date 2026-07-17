/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>

void FBHDA_load(void);
void FBHDA_free(void);
BOOL FBHDA_valid_obj(void);

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID reserved)
{
	(void)reserved;
	if(reason == DLL_PROCESS_ATTACH)
	{
		DisableThreadLibraryCalls(module);
		FBHDA_load();
	}
	else if(reason == DLL_PROCESS_DETACH && FBHDA_valid_obj())
	{
		FBHDA_free();
	}
	return TRUE;
}
