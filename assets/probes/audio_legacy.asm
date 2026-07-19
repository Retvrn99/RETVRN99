; SPDX-License-Identifier: GPL-3.0-only
;
; Bare real-mode GSW-Sound probe. This is guest-I/O evidence only; cold DOS
; and Windows 98 SE Restart-in-MS-DOS-mode remain separate licensed gates.

cpu 386
bits 16
org 0x7C00

%include "common.inc"

%define SB_BASE          0x220
%define SB_MIXER_INDEX   0x224
%define SB_MIXER_DATA    0x225
%define SB_RESET         0x226
%define SB_READ          0x22A
%define SB_WRITE         0x22C
%define SB_READ_STATUS   0x22E
%define SB_ACK_DMA16     0x22F
%define OPL_INDEX        0x388
%define OPL_DATA         0x389
%define PIT_CHANNEL_2    0x42
%define SPEAKER_CONTROL  0x61

start:
    cli
    cld
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7000
    mov dword [0x0500], 0
    mov dword [0x0504], 0
    mov word [0x0094], irq5_handler
    mov word [0x0096], 0
    mov word [0x0080], irq0_handler
    mov word [0x0082], 0
    call initialize_pic_irq5

    ; A restrained 1 kHz PIT channel-2 tone supplies PC-Speaker evidence.
    mov dx, PIT_CONTROL
    mov al, 0xB6
    out dx, al
    mov dx, PIT_CHANNEL_2
    mov al, 0xA9
    out dx, al
    mov al, 0x04
    out dx, al
    mov dx, SPEAKER_CONTROL
    in al, dx
    or al, 0x03
    out dx, al

    ; Standard AdLib timer detection, followed by a keyed melodic tone.
    mov al, 0x04
    mov ah, 0x60
    call opl_write
    mov al, 0x04
    mov ah, 0x80
    call opl_write
    mov dx, OPL_INDEX
    in al, dx
    mov [0x0506], al
    test al, 0xE0
    jnz fail_opl
    mov al, 0x02
    mov ah, 0xFF
    call opl_write
    mov al, 0x04
    mov ah, 0x21
    call opl_write
    PROGRAM_PIT_1MS
    sti
    hlt
    cli
    mov dx, PIC_MASTER_DATA
    mov al, 0xDF
    out dx, al
    mov dx, OPL_INDEX
    in al, dx
    mov [0x0507], al
    and al, 0xE0
    cmp al, 0xC0
    jne fail_opl
    mov byte [0x0501], al
    mov al, 0x04
    mov ah, 0x60
    call opl_write
    mov al, 0x04
    mov ah, 0x80
    call opl_write
    mov al, 0x43
    mov ah, 0x00
    call opl_write
    mov al, 0x60
    mov ah, 0xF0
    call opl_write
    mov al, 0x63
    mov ah, 0xF0
    call opl_write
    mov al, 0xC0
    mov ah, 0x00
    call opl_write
    mov al, 0xA0
    mov ah, 0x80
    call opl_write
    mov al, 0xB0
    mov ah, 0x31
    call opl_write

    ; DSP reset and version.
    mov dx, SB_RESET
    mov al, 1
    out dx, al
    xor al, al
    out dx, al
    call sb_read_byte
    cmp al, 0xAA
    jne fail_reset
    mov al, 0xE1
    call sb_write_byte
    call sb_read_byte
    mov [0x0502], al
    cmp al, 4
    jne fail_version
    call sb_read_byte
    mov [0x0503], al
    cmp al, 5
    jne fail_version
    mov al, 0xD1
    call sb_write_byte
    mov al, 0x41
    call sb_write_byte
    mov al, 0x1F
    call sb_write_byte
    mov al, 0x40
    call sb_write_byte

    ; Enable the AT cascade channel used by the primary DMA controller.
    mov dx, 0xD6
    mov al, 0xC0
    out dx, al
    mov dx, 0xD4
    xor al, al
    out dx, al

    mov byte [0x1000], 0x00
    mov byte [0x1001], 0x40
    mov byte [0x1002], 0xC0
    mov byte [0x1003], 0xFF
    call program_dma1
    mov al, 0xC0
    call sb_write_byte
    xor al, al
    call sb_write_byte
    mov al, 3
    call sb_write_byte
    xor al, al
    call sb_write_byte
    sti
    hlt
    cli
    cmp byte [0x0504], 1
    jb fail_dma8

    mov word [0x1100], 0x8000
    mov word [0x1102], 0xC000
    mov word [0x1104], 0x4000
    mov word [0x1106], 0x7FFF
    call program_dma5
    mov al, 0xB0
    call sb_write_byte
    xor al, al
    call sb_write_byte
    mov al, 3
    call sb_write_byte
    xor al, al
    call sb_write_byte
    sti
    hlt
    cli
    cmp byte [0x0505], 1
    jb fail_dma16

    mov byte [0x0500], 0xA5
    TEST_EXIT 0

fail_reset:
    TEST_EXIT 1
fail_version:
    TEST_EXIT 2
fail_opl:
    TEST_EXIT 3
fail_dma8:
    TEST_EXIT 4
fail_dma16:
    TEST_EXIT 5

initialize_pic_irq5:
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
    mov al, 0xDE
    out PIC_MASTER_DATA, al
    mov al, 0xFF
    out PIC_SLAVE_DATA, al
    ret

opl_write:
    push dx
    push ax
    mov dx, OPL_INDEX
    out dx, al
    mov al, ah
    mov dx, OPL_DATA
    out dx, al
    pop ax
    pop dx
    ret

sb_write_byte:
    push dx
    push ax
.wait:
    mov dx, SB_WRITE
    in al, dx
    test al, 0x80
    jnz .wait
    pop ax
    out dx, al
    pop dx
    ret

sb_read_byte:
    push dx
.wait:
    mov dx, SB_READ_STATUS
    in al, dx
    test al, 0x80
    jz .wait
    mov dx, SB_READ
    in al, dx
    pop dx
    ret

program_dma1:
    mov dx, 0x0A
    mov al, 0x05
    out dx, al
    mov dx, 0x0C
    out dx, al
    mov dx, 0x02
    xor al, al
    out dx, al
    mov al, 0x10
    out dx, al
    mov dx, 0x03
    mov al, 3
    out dx, al
    xor al, al
    out dx, al
    mov dx, 0x83
    out dx, al
    mov dx, 0x0B
    mov al, 0x49
    out dx, al
    mov dx, 0x0A
    mov al, 0x01
    out dx, al
    ret

program_dma5:
    mov dx, 0xD4
    mov al, 0x05
    out dx, al
    mov dx, 0xD8
    out dx, al
    mov dx, 0xC4
    mov al, 0x80
    out dx, al
    mov al, 0x08
    out dx, al
    mov dx, 0xC6
    mov al, 3
    out dx, al
    xor al, al
    out dx, al
    mov dx, 0x8B
    out dx, al
    mov dx, 0xD6
    mov al, 0x49
    out dx, al
    mov dx, 0xD4
    mov al, 0x01
    out dx, al
    ret

irq5_handler:
    push ax
    push dx
    mov dx, SB_MIXER_INDEX
    mov al, 0x82
    out dx, al
    mov dx, SB_MIXER_DATA
    in al, dx
    test al, 0x02
    jnz .dma16
    mov dx, SB_READ_STATUS
    in al, dx
    inc byte [0x0504]
    jmp .eoi
.dma16:
    mov dx, SB_ACK_DMA16
    in al, dx
    inc byte [0x0505]
.eoi:
    mov al, 0x20
    out PIC_MASTER_CMD, al
    pop dx
    pop ax
    iret

irq0_handler:
    push ax
    mov al, 0x20
    out PIC_MASTER_CMD, al
    pop ax
    iret
