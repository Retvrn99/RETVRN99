; SPDX-License-Identifier: GPL-3.0-only
;
; Bare protected-mode paging accessed/dirty-bit probe. The flat protected-mode
; transition is selectively adapted from IzarraVM commit
; d930de57acccbc6a70cda8cc5a603173bf23cd1c:
; crates/izarravm-machine/tests/fixtures/pmirq5.asm.

cpu 386
bits 16
org 0x7C00

%include "common.inc"

%define PAGE_DIRECTORY 0x00090000
%define PAGE_TABLE     0x00091000
%define READ_PAGE      0x00200000
%define WRITE_PAGE     0x00201000
%define READ_PTE       (PAGE_TABLE + 512 * 4)
%define WRITE_PTE      (PAGE_TABLE + 513 * 4)

start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
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
    mov eax, [READ_PAGE]
    mov dword [WRITE_PAGE], 0xA55A39C3

    test dword [PAGE_DIRECTORY], 0x20
    jz fail_pde_accessed
    mov eax, [READ_PTE]
    test eax, 0x20
    jz fail_read_accessed
    test eax, 0x40
    jnz fail_read_dirty
    mov eax, [WRITE_PTE]
    and eax, 0x60
    cmp eax, 0x60
    jne fail_write_dirty
    TEST_EXIT 0

fail_pde_accessed:
    TEST_EXIT 1
fail_read_accessed:
    TEST_EXIT 2
fail_read_dirty:
    TEST_EXIT 3
fail_write_dirty:
    TEST_EXIT 4

align 8
gdt:
    dq 0
    dw 0xFFFF, 0
    db 0, 0x9A, 0xCF, 0
    dw 0xFFFF, 0
    db 0, 0x92, 0xCF, 0
gdt_end:

gdtr:
    dw gdt_end - gdt - 1
    dd gdt
