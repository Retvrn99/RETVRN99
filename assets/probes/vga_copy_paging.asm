; SPDX-License-Identifier: GPL-3.0-only

cpu 386
bits 16
org 0x7C00

%include "common.inc"

%define PAGE_DIRECTORY 0x00090000
%define PAGE_TABLE     0x00091000
%define SOURCE_BUFFER  0x00020000
%define READBACK_BUFFER 0x00030000

; Exercise a wrapped selector and a 320x200 scanline copy.

start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000

    mov dx, 0x03CE
    mov ax, 0x0506
    out dx, ax
    mov ax, 0x0005
    out dx, ax
    mov ax, 0xFF08
    out dx, ax
    mov dx, 0x03C4
    mov ax, 0x0F02
    out dx, ax
    ; Sequencer 04h. Odd/even would pair the planes by A0 and this probe wants
    ; the map mask to decide, so disable it rather than inherit a reset value.
    mov ax, 0x0604
    out dx, ax

    lgdt [gdtr]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x08:protected_entry

bits 32
protected_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x00080000

    mov edi, PAGE_DIRECTORY
    xor eax, eax
    mov ecx, 2048
    rep stosd
    mov dword [PAGE_DIRECTORY], PAGE_TABLE | 0x03
    mov edi, PAGE_TABLE
    mov eax, 0x03
    mov ecx, 1024
.fill_page_table:
    stosd
    add eax, 0x1000
    loop .fill_page_table

    mov eax, PAGE_DIRECTORY
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    jmp short .paging_active
.paging_active:
    mov edi, SOURCE_BUFFER
    mov eax, 0xA5A5A5A5
    mov ecx, 80
    rep stosd

    mov esi, SOURCE_BUFFER
    mov ax, 0x18
    mov es, ax
    mov edi, 0x7D109000
    mov ebx, 80
    mov ebp, 200
    xor eax, eax
.copy_scanline:
    mov esi, SOURCE_BUFFER
    mov ecx, ebx
    rep movsd
    dec ebp
    jnz .copy_scanline
    test ecx, ecx
    jnz fail_copy
    cmp esi, SOURCE_BUFFER + 320
    jne fail_copy
    cmp edi, 0x7D109000 + 64000
    jne fail_copy

    mov ax, 0x18
    mov ds, ax
    mov esi, 0x7D109128
    mov ax, 0x10
    mov es, ax
    mov edi, READBACK_BUFFER
    mov ecx, 80
    xor eax, eax
    call copy_from_vga
    mov ax, 0x10
    mov ds, ax
    mov esi, READBACK_BUFFER
    mov ecx, 320
.verify_readback:
    cmp byte [esi], 0xA5
    jne fail_copy
    inc esi
    loop .verify_readback
    TEST_EXIT 0

fail_copy:
    TEST_EXIT 1

copy_from_vga:
    rep movsd
    mov cl, al
    rep movsb
    ret

align 8
gdt:
    dq 0
    dw 0xFFFF, 0
    db 0, 0x9A, 0xCF, 0
    dw 0xFFFF, 0
    db 0, 0x92, 0xCF, 0
    dw 0xFFFF, 0x7000
    db 0xF9, 0x92, 0xCF, 0x82
gdt_end:

gdtr:
    dw gdt_end - gdt - 1
    dd gdt
