; SPDX-License-Identifier: GPL-3.0-only
;
; Probe conventions selectively adapted from IzarraVM commit
; d930de57acccbc6a70cda8cc5a603173bf23cd1c, notably:
; crates/izarravm-firmware/roms/probes/probe-pit.inc and
; crates/izarravm-machine/tests/fixtures/pmirq5.asm.

%define TEST_INDEX       0xE4
%define TEST_DATA        0xE5
%define TEST_COMMAND     0xE6
%define TEST_REG_EXIT    12
%define TEST_COMMAND_EXIT 3

%define PIC_MASTER_CMD   0x20
%define PIC_MASTER_DATA  0x21
%define PIC_SLAVE_CMD    0xA0
%define PIC_SLAVE_DATA   0xA1
%define PIT_CHANNEL_0    0x40
%define PIT_CONTROL      0x43

%macro TEST_EXIT 1
    cli
    mov al, TEST_REG_EXIT
    out TEST_INDEX, al
    mov al, %1
    out TEST_DATA, al
    mov al, TEST_COMMAND_EXIT
    out TEST_COMMAND, al
%%halt:
    hlt
    jmp %%halt
%endmacro
%macro INITIALIZE_PIC_IRQ0 0
    mov al, 0x11
    out PIC_MASTER_CMD, al
    out PIC_SLAVE_CMD, al
    mov al, 0x20
    out PIC_MASTER_DATA, al
    mov al, 0x28
    out PIC_SLAVE_DATA, al
    mov al, 0x04
    out PIC_MASTER_DATA, al
    mov al, 0x02
    out PIC_SLAVE_DATA, al
    mov al, 0x01
    out PIC_MASTER_DATA, al
    out PIC_SLAVE_DATA, al
    mov al, 0xFE
    out PIC_MASTER_DATA, al
    mov al, 0xFF
    out PIC_SLAVE_DATA, al
%endmacro

%macro PROGRAM_PIT_1MS 0
    mov al, 0x34
    out PIT_CONTROL, al
    mov al, 0xA9
    out PIT_CHANNEL_0, al
    mov al, 0x04
    out PIT_CHANNEL_0, al
%endmacro
