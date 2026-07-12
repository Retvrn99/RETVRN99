; SPDX-License-Identifier: GPL-3.0-only
; retvrn99 clean-room FAT32 VBR: read the first 4 sectors of IO.SYS (absolute
; LBA patched by the synthesizer at offset 0x1F0) to 0000:0700 via INT 13h
; AH=42h, then enter MSLOAD per the MS-DOS 7 boot protocol as consumed by
; MSLOAD's own entry code (first 4 sectors of IO.SYS, entry 0070:0200):
;   BP=7C00 (our BPB), DL=80h, DS=0, and a stack frame under 7C00:
;     0:7BFC dword  absolute LBA of the first data sector (patch 0x1E0)
;     0:7BFA word   original INT 1Eh vector segment (restored on boot fail)
;     0:7BF8 word   original INT 1Eh vector offset
;     0:7BF4 two scratch words that MSLOAD pops and discards
;   SI:DI = first cluster of IO.SYS, high:low (patch 0x1E4)
; MSLOAD walks the FAT itself using the BPB fields at BP (hidden sectors,
; reserved count, FAT size) and reads via INT 13h CHS with the BPB geometry.
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
        push    word [data_lba + 2]     ; -> 0:7BFE
        push    word [data_lba]         ; -> 0:7BFC
        push    word [0x7A]             ; INT 1Eh segment -> 0:7BFA
        push    word [0x78]             ; INT 1Eh offset  -> 0:7BF8
        push    ax                      ; scratch -> 0:7BF6
        push    ax                      ; scratch -> 0:7BF4
        mov     dl, 0x80
        mov     ah, 0x42
        mov     si, dap
        int     0x13
        jc      fail
        mov     di, [first_cluster]     ; cluster low word
        mov     si, [first_cluster + 2] ; cluster high word
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

        times 0x1E0 - ($ - $$) db 0
data_lba:                               ; offset 0x1E0, patched by make_vbr
        dd 0
first_cluster:                          ; offset 0x1E4, patched by make_vbr
        dd 0
dap:                                    ; offset 0x1E8
        db 0x10, 0
        dw 4                            ; sector count
        dw 0x0700                       ; buffer offset
        dw 0x0000                       ; buffer segment
io_sys_lba:                             ; offset 0x1F0, patched by make_vbr
        dq 0

        times 0x1FE - ($ - $$) db 0
        dw 0xAA55
