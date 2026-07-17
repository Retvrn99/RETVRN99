; SPDX-License-Identifier: GPL-3.0-only
; Historical RETVRN99 fixed-target VBR retained only as a migration fixture.
; Build: nasm -f bin legacy_fixed_vbr.asm -o legacy_fixed_vbr.bin

BITS 16
ORG 0x7C00

        jmp     short code
        nop
        times 0x5A - ($ - $$) db 0

code:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        cld
        mov     bp, 0x7C00
        push    word [data_lba + 2]
        push    word [data_lba]
        push    word [0x7A]
        push    word [0x78]
        push    ax
        push    ax
        mov     dl, 0x80
        mov     ah, 0x42
        mov     si, dap
        int     0x13
        jc      fail
        mov     di, [first_cluster]
        mov     si, [first_cluster + 2]
        jmp     0x0070:0x0200

fail:
        mov     si, msg
.next:
        lodsb
        test    al, al
        jz      .stop
        mov     ah, 0x0E
        mov     bx, 0x0007
        int     0x10
        jmp     .next
.stop:
        int     0x18
.hang:
        hlt
        jmp     .hang

msg     db 'Err', 0

        times 0x1E0 - ($ - $$) db 0
data_lba:
        dd 0
first_cluster:
        dd 0
dap:
        db 0x10, 0
        dw 4
        dw 0x0700
        dw 0x0000
io_sys_lba:
        dq 0

        times 0x1FE - ($ - $$) db 0
        dw 0xAA55
