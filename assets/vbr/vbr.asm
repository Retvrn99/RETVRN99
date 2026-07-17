; SPDX-License-Identifier: GPL-3.0-only
; retvrn99 clean-room FAT32 VBR: find IO.SYS in the first root-directory
; cluster, read its first 4 sectors to 0000:0700 via INT 13h AH=42h, then
; enter MSLOAD per the MS-DOS 7 boot protocol as consumed by MSLOAD's own
; entry code (first 4 sectors of IO.SYS, entry 0070:0200):
;   BP=7C00 (our BPB), DL=80h, DS=0, and a stack frame under 7C00:
;     0:7BFC dword  absolute LBA of the first data sector (patch 0x1E0)
;     0:7BFA word   original INT 1Eh vector segment (restored on boot fail)
;     0:7BF8 word   original INT 1Eh vector offset
;     0:7BF4 two scratch words that MSLOAD pops and discards
;   SI:DI = first cluster of IO.SYS, high:low
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
        mov     es, ax
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

        mov     eax, [bp + 44]          ; BPB root cluster
        sub     eax, 2
        movzx   ecx, byte [bp + 13]     ; sectors per cluster
        imul    eax, ecx
        xor     edx, edx
        add     eax, [data_lba]
        adc     edx, 0
        mov     [io_sys_lba], eax       ; DAP starts at the root directory
        mov     [io_sys_lba + 4], edx
        mov     al, [bp + 13]
        mov     [root_left], al
        mov     word [dap + 2], 1
        mov     word [dap + 4], 0x0500

.read_root:
        mov     dl, 0x80
        mov     ah, 0x42
        mov     si, dap
        push    bp
        int     0x13
        pop     bp
        jc      fail

        xor     ax, ax
        mov     ds, ax
        mov     es, ax
        mov     bx, 0x0500
.scan_entry:
        cmp     byte [bx], 0
        je      fail
        cmp     byte [bx], 0xE5
        je      .next_entry
        mov     al, [bx + 11]
        cmp     al, 0x0F                ; long-file-name slot
        je      .next_entry
        test    al, 0x18                ; volume label or directory
        jnz     .next_entry
        push    bx
        mov     si, io_name
        mov     di, bx
        mov     cx, 11
        repe    cmpsb
        pop     bx
        je      .found
.next_entry:
        add     bx, 32
        cmp     bx, 0x0700
        jb      .scan_entry
        add     dword [io_sys_lba], 1
        adc     dword [io_sys_lba + 4], 0
        dec     byte [root_left]
        jnz     .read_root
        jmp     fail

.found:
        mov     ax, [bx + 26]
        mov     [first_cluster], ax
        mov     ax, [bx + 20]
        mov     [first_cluster + 2], ax
        mov     eax, [first_cluster]
        sub     eax, 2
        movzx   ecx, byte [bp + 13]
        imul    eax, ecx
        xor     edx, edx
        add     eax, [data_lba]
        adc     edx, 0
        mov     [io_sys_lba], eax
        mov     [io_sys_lba + 4], edx
        mov     word [dap + 2], 4
        mov     word [dap + 4], 0x0700
        mov     dl, 0x80
        mov     ah, 0x42
        mov     si, dap
        push    bp
        int     0x13
        pop     bp
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
io_name db 'IO      SYS'
root_left db 0

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
