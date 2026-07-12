; SPDX-License-Identifier: GPL-3.0-only
; retvrn99 clean-room FAT32 VBR: read the first 4 sectors of IO.SYS (absolute
; LBA patched by the synthesizer at offset 0x1F0) to 0000:0700 via INT 13h
; AH=42h, then enter MSLOAD per the MS-DOS 7 boot protocol:
; DL=80h, BP=7C00h (our BPB), SS:SP=0000:7C00, DS=0, far jump 0070:0200.
; Build (NASM 3.01): nasm -f bin vbr.asm -o vbr.bin

BITS 16
ORG 0x7C00

        jmp     short code
        nop
        times 0x5A - ($ - $$) db 0      ; BPB hole, filled by the synthesizer

code:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        cld
        mov     bp, 0x7C00
        mov     dl, 0x80
        mov     ah, 0x42
        mov     si, dap
        int     0x13
        jc      fail
        jmp     0x0070:0x0200           ; IO.SYS MSLOAD entry

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

        times 0x1E8 - ($ - $$) db 0
dap:
        db 0x10, 0
        dw 4                            ; sector count
        dw 0x0700                       ; buffer offset
        dw 0x0000                       ; buffer segment
io_sys_lba:                             ; offset 0x1F0, patched by make_vbr
        dq 0

        times 0x1FE - ($ - $$) db 0
        dw 0xAA55
