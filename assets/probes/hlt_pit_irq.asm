; SPDX-License-Identifier: GPL-3.0-only
;
; HLT/PIT/IRQ/IRET acceptance probe. Conventions selectively adapted from
; IzarraVM d930de57acccbc6a70cda8cc5a603173bf23cd1c:
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
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    mov word [0x0500], 0
    mov word [0x0080], irq0_handler
    mov word [0x0082], 0
    INITIALIZE_PIC_IRQ0
    PROGRAM_PIT_1MS
    sti
    hlt
    cli
    mov byte [0x0502], 0xA5
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
