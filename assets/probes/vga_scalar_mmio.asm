; SPDX-License-Identifier: GPL-3.0-only

cpu 486
bits 16
org 0x7C00

%include "common.inc"

%define PAGE_DIRECTORY 0x00090000
%define PAGE_TABLE     0x00091000
%define SOURCE_BUFFER  0x00020000
%define FAULT_COUNT    0x00000500

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
    lidt [idtr]

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
    xor eax, eax
    mov esi, 0x000A0000
    mov ecx, 0x44332211
    db 0x89, 0x0C, 0x86
    cmp dword [0x000A0000], 0x44332211
    jne fail

    mov ax, 0x18
    mov ds, ax
    xor eax, eax
    mov esi, 0x7D109010
    mov ecx, 0x88776655
    db 0x89, 0x0C, 0x86
    mov ax, 0x10
    mov ds, ax
    cmp dword [0x000A0010], 0x88776655
    jne fail

    mov eax, 2
    mov esi, 0x000A0018
    mov ecx, 0xCCBBAA99
    db 0x89, 0x0C, 0x86
    cmp dword [0x000A0020], 0xCCBBAA99
    jne fail

    xor eax, eax
    mov esi, 0x000A0030
    mov ecx, 0x1234BEEF
    db 0x66, 0x89, 0x0C, 0x86
    cmp word [0x000A0030], 0xBEEF
    jne fail

    xor eax, eax
    mov esi, 0x000A0010
    xor ecx, ecx
    db 0x8B, 0x0C, 0x86
    cmp ecx, 0x88776655
    jne fail

    mov eax, 1
    mov esi, 0x000A0FFB
    mov ecx, 0xD4C3B2A1
    db 0x89, 0x0C, 0x86
    cmp dword [0x000A0FFF], 0xD4C3B2A1
    jne fail

    mov dword [SOURCE_BUFFER], 0x04030201
    mov dword [SOURCE_BUFFER + 4], 0x08070605
    mov esi, SOURCE_BUFFER
    mov edi, 0x000A0100
    mov ecx, 2
    rep movsd
    std
    mov esi, SOURCE_BUFFER + 4
    mov edi, 0x000A0114
    mov ecx, 2
    rep movsd
    cld
    cmp dword [0x000A0100], 0x04030201
    jne fail
    cmp dword [0x000A0104], 0x08070605
    jne fail
    cmp dword [0x000A0110], 0x04030201
    jne fail
    cmp dword [0x000A0114], 0x08070605
    jne fail

    mov dword [FAULT_COUNT], 0
    and dword [PAGE_TABLE + 0xA2 * 4], byte ~1
    invlpg [0x000A2000]
    xor eax, eax
    mov esi, 0x000A2000
    mov ecx, 0x5AA55AA5
    db 0x89, 0x0C, 0x86
    cmp dword [FAULT_COUNT], 1
    jne fail
    cmp dword [0x000A2000], 0x5AA55AA5
    jne fail
    TEST_EXIT 0

fail:
    TEST_EXIT 1

page_fault:
    push eax
    or dword [PAGE_TABLE + 0xA2 * 4], byte 1
    invlpg [0x000A2000]
    inc dword [FAULT_COUNT]
    pop eax
    add esp, 4
    iretd

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

align 8
idt:
    times 14 dq 0
    dw (page_fault - $$ + 0x7C00) & 0xFFFF
    dw 0x08
    db 0
    db 0x8E
    dw (page_fault - $$ + 0x7C00) >> 16
idt_end:

idtr:
    dw idt_end - idt - 1
    dd idt
