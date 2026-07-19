/* SPDX-License-Identifier: GPL-3.0-only */
#include <windows.h>

#include "gswsound_pm16.h"

static void (__far *gsw_vxd_entry)(void);
static char gsw_vxd_name[8] = {'G', 'S', 'W', 'S', 'O', 'U', 'N', 'D'};

static int gsw_selector_base(gsw_u16 selector, gsw_u32 *base)
{
    gsw_u16 high = 0;
    gsw_u16 low = 0;
    gsw_u8 failed = 1;
    if (base == 0 || selector == 0) return 0;
    _asm {
        mov ax, 0006h
        mov bx, selector
        int 31h
        setc failed
        mov high, cx
        mov low, dx
    }
    if (failed) return 0;
    *base = ((gsw_u32)high << 16) | low;
    return 1;
}
gsw_u32 gsw_sound_pm_linear(const void __far *pointer, int *valid)
{
    gsw_u32 packed = (gsw_u32)pointer;
    gsw_u32 base = 0;
    gsw_u16 selector = (gsw_u16)(packed >> 16);
    gsw_u16 offset = (gsw_u16)packed;
    if (valid != 0) *valid = 0;
    if (pointer == 0 || !gsw_selector_base(selector, &base) || base > 0xFFFFFFFFUL - offset)
        return 0;
    if (valid != 0) *valid = 1;
    return base + offset;
}

int gsw_sound_pm_connect(void)
{
    gsw_u16 entry_offset = 0;
    gsw_u16 entry_selector = 0;
    if (gsw_vxd_entry != 0) return 1;
    _asm {
        push es
        push ds
        pop es
        lea di, gsw_vxd_name
        xor bx, bx
        mov ax, 1684h
        int 2Fh
        mov entry_offset, di
        mov entry_selector, es
        pop es
    }
    if (entry_offset == 0 && entry_selector == 0) return 0;
    *(gsw_u16 *)&gsw_vxd_entry = entry_offset;
    *(((gsw_u16 *)&gsw_vxd_entry) + 1) = entry_selector;
    return 1;
}

GSW_SOUND_RESULT gsw_sound_pm_call(GSW_SOUND_PM_REQUEST __far *request)
{
    gsw_u32 request_linear;
    gsw_u32 result = GSW_SOUND_UNAVAILABLE;
    gsw_u8 failed = 1;
    int valid = 0;
    if (request == 0 || !gsw_sound_pm_connect()) return GSW_SOUND_UNAVAILABLE;
    request_linear = gsw_sound_pm_linear(request, &valid);
    if (!valid) return GSW_SOUND_INVALID;
    _asm {
        .386
        push eax
        push ecx
        push esi
        mov esi, request_linear
        mov ecx, 64
        call dword ptr [gsw_vxd_entry]
        mov result, eax
        setc failed
        pop esi
        pop ecx
        pop eax
    }
    if (failed) return (GSW_SOUND_RESULT)result;
    return (GSW_SOUND_RESULT)request->result;
}
