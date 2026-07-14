; SPDX-License-Identifier: GPL-3.0-only
;
; PIT delivery during repeated trapped VGA aperture clears. IRQ/PIT conventions
; selectively adapted from IzarraVM commit
; d930de57acccbc6a70cda8cc5a603173bf23cd1c:
; crates/izarravm-firmware/roms/boot-suite/stage2.asm.

cpu 386
bits 16
org 0x7C00

%include "common.inc"

start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7000
    mov word [0x0500], 0
    mov word [0x0080], irq0_handler
    mov word [0x0082], 0
    INITIALIZE_PIC_IRQ0
    PROGRAM_PIT_1MS

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
    mov ax, 0xA000
    mov es, ax

    sti
    xor edi, edi
    mov ecx, 16000
    mov eax, 0x11111111
    a32 rep stosd
    xor edi, edi
    mov ecx, 16000
    mov eax, 0xA5A5A5A5
    a32 rep stosd
    cli
    cmp word [0x0500], 0
    je fail_no_irq
    TEST_EXIT 0

fail_no_irq:
    TEST_EXIT 1

irq0_handler:
    push ax
    inc word [0x0500]
    mov al, 0x20
    out PIC_MASTER_CMD, al
    pop ax
    iret
