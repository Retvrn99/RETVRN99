; SPDX-License-Identifier: GPL-3.0-only
; retvrn99 clean-room MBR: relocate 0000:7C00 -> 0000:0600, read the active
; partition's first sector via INT 13h AH=42h (EDD) and jump to it.
; Build (NASM 3.01): nasm -f bin mbr.asm -o mbr.bin

BITS 16
ORG 0x0600

start:
        cli
        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     ss, ax
        mov     sp, 0x7C00
        sti
        cld
        mov     si, 0x7C00
        mov     di, 0x0600
        mov     cx, 256
        rep     movsw
        jmp     0x0000:main

main:
        mov     si, ptable
        mov     cx, 4
.scan:
        cmp     byte [si], 0x80
        je      .boot
        add     si, 16
        loop    .scan
        jmp     fail

.boot:
        mov     eax, [si + 8]           ; partition start LBA
        mov     [dap.lba], eax
        push    si                      ; DS:SI = partition entry for the VBR
        mov     ah, 0x42                ; DL = boot drive, untouched from BIOS
        mov     si, dap
        int     0x13
        pop     si
        jc      fail
        cmp     word [0x7DFE], 0xAA55
        jne     fail
        jmp     0x0000:0x7C00

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

dap:
        db 0x10, 0
        dw 1                            ; sector count
        dw 0x7C00                       ; buffer offset
        dw 0x0000                       ; buffer segment
.lba:
        dq 0

        times 446 - ($ - $$) db 0
ptable: times 64 db 0                   ; filled by the synthesizer
        dw 0xAA55
