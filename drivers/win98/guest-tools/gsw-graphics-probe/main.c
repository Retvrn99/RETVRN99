/* SPDX-License-Identifier: GPL-3.0-only */

#include "gswgfx.h"

void mainCRTStartup(void)
{
	ExitProcess(gsw_run());
}
