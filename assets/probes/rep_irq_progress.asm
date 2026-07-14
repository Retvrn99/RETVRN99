; SPDX-License-Identifier: GPL-3.0-only
;
; Protected-mode REP string-I/O interruptibility probe. Descriptor and IRQ-gate
; structure selectively adapted from IzarraVM commit
; d930de57acccbc6a70cda8cc5a603173bf23cd1c:
; crates/izarravm-machine/tests/fixtures/pmirq5.asm.

cpu 386
bits 16
org 0x7C00

%include "common.inc"

%define REP_START  0x00100000
%define REP_COUNT  0x00021000
%define REP_END    (REP_START + REP_COUNT)

start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    mov dword [0x0500], 0
    mov di, idt + 0x20 * 8
    mov eax, irq0_handler
    mov [di], ax
    mov word [di + 2], 0x08
    mov byte [di + 4], 0
    mov byte [di + 5], 0x8E
    shr eax, 16
    mov [di + 6], ax
    lgdt [gdtr]
    lidt [idtr]
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
    INITIALIZE_PIC_IRQ0
    PROGRAM_PIT_1MS
    mov al, 0
    out TEST_INDEX, al
    mov dx, TEST_DATA
    mov edi, REP_START
    mov ecx, REP_COUNT
    sti
    nop
    rep insb
    cli
    mov [0x0504], edi
    mov [0x0508], ecx
    cmp edi, REP_END
    jne fail_progress
    test ecx, ecx
    jne fail_progress
    cmp dword [0x0500], 0
    je fail_irq
    TEST_EXIT 0

fail_progress:
    TEST_EXIT 2

fail_irq:
    TEST_EXIT 3

irq0_handler:
    push eax
    inc dword [0x0500]
    mov al, 0x20
    out PIC_MASTER_CMD, al
    pop eax
    iretd

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

align 8
idt:
    times 0x21 dq 0
idt_end:

idtr:
    dw idt_end - idt - 1
    dd idt
