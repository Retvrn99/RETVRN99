; SPDX-License-Identifier: GPL-3.0-only

bits 16
org 0x100

%define KATEA_INDEX_PORT 0xE4
%define KATEA_DATA_PORT 0xE5
%define KATEA_COMMAND_PORT 0xE6
%define KATEA_STATUS_REGISTER 31
%define KATEA_CAPTURE_REGISTER 29
%define KATEA_REPORT_LENGTH_REGISTER 30
%define KATEA_STATUS_OK 1
%define KATEA_REPORT_BEGIN 4
%define KATEA_REPORT_APPEND 5
%define KATEA_REPORT_COMMIT 6
%define KATEA_REPORT_ABORT 7
%define KATEA_CRC 1
%define KATEA_CANVAS_CAPTURE 2
%define KATEA_COMPOSED_CAPTURE 8
%define KATEA_PRE_CAPTURE 224
%define KATEA_POST_CAPTURE 225
%define KATEA_FAILURE_CAPTURE 239

start:
    push cs
    pop ds
    xor ch, ch
    mov cl, [0x80]
    jcxz argument_missing
    mov si, 0x81
    jmp skip_spaces

argument_missing:
    jmp exit_failure

skip_spaces:
    lodsb
    cmp al, ' '
    jne dispatch
    loop skip_spaces
    jmp exit_failure

dispatch:
    and al, 0xDF
    cmp al, 'P'
    je phase_pre
    cmp al, 'O'
    je phase_post
    cmp al, 'Q'
    je phase_quake_failure
    cmp al, 'R'
    je phase_report_failure
    jmp exit_failure

phase_pre:
    mov al, KATEA_REPORT_BEGIN
    call katea_command
    jc exit_failure
    mov si, pre_payload
    mov cx, pre_payload_end - pre_payload
    call append_payload
    jc exit_failure
    mov al, KATEA_PRE_CAPTURE
    call capture_pair
    jc exit_failure
    call verify_sentinel
    jc phase_sentinel_failure
    jmp exit_success

phase_post:
    mov al, KATEA_POST_CAPTURE
    call capture_pair
    jc exit_failure
    call verify_sentinel
    jc phase_sentinel_failure
    mov si, post_payload
    mov cx, post_payload_end - post_payload
    call append_payload
    jc exit_failure
    mov al, KATEA_REPORT_COMMIT
    call katea_command
    jc exit_failure
    jmp exit_success

phase_sentinel_failure:
    mov si, sentinel_failure_payload
    mov cx, sentinel_failure_payload_end - sentinel_failure_payload
    call append_payload
    jc exit_failure
    mov al, KATEA_FAILURE_CAPTURE
    call capture_pair
    jc exit_failure
    mov al, KATEA_REPORT_COMMIT
    call katea_command
    jc exit_failure
    jmp exit_sentinel_failure

phase_quake_failure:
    mov si, quake_failure_payload
    mov cx, quake_failure_payload_end - quake_failure_payload
    call append_payload
    jc exit_failure
    mov al, KATEA_FAILURE_CAPTURE
    call capture_pair
    jc exit_failure
    mov al, KATEA_REPORT_COMMIT
    call katea_command
    jc exit_failure
    jmp exit_success

phase_report_failure:
    mov al, KATEA_REPORT_ABORT
    call katea_command
    mov al, KATEA_REPORT_BEGIN
    call katea_command
    jc exit_failure
    mov si, report_failure_payload
    mov cx, report_failure_payload_end - report_failure_payload
    call append_payload
    jc exit_failure
    mov al, KATEA_FAILURE_CAPTURE
    call capture_pair
    jc exit_failure
    mov al, KATEA_REPORT_COMMIT
    call katea_command
    jc exit_failure
    jmp exit_success

append_payload:
    push ax
    push bx
    push dx
    push si
    push di
    push bp

.next_chunk:
    test cx, cx
    jz .success
    mov bp, cx
    cmp bp, 30
    jbe .size_ready
    mov bp, 30

.size_ready:
    xor di, di

.copy_byte:
    mov dx, KATEA_INDEX_PORT
    mov ax, di
    out dx, al
    inc dx
    lodsb
    out dx, al
    inc di
    cmp di, bp
    jb .copy_byte

    mov dx, KATEA_INDEX_PORT
    mov al, KATEA_REPORT_LENGTH_REGISTER
    out dx, al
    inc dx
    mov ax, bp
    out dx, al
    mov al, KATEA_REPORT_APPEND
    call katea_command
    jc .failure
    sub cx, bp
    jmp .next_chunk

.success:
    clc
    jmp .done

.failure:
    stc

.done:
    pop bp
    pop di
    pop si
    pop dx
    pop bx
    pop ax
    ret

capture_pair:
    push ax
    push dx
    mov ah, al
    mov dx, KATEA_INDEX_PORT
    mov al, KATEA_CAPTURE_REGISTER
    out dx, al
    inc dx
    mov al, ah
    out dx, al
    mov al, KATEA_CANVAS_CAPTURE
    call katea_command
    jc .failure
    mov dx, KATEA_INDEX_PORT
    mov al, KATEA_CAPTURE_REGISTER
    out dx, al
    inc dx
    mov al, ah
    out dx, al
    mov al, KATEA_COMPOSED_CAPTURE
    call katea_command
    jc .failure
    clc
    jmp .done

.failure:
    stc

.done:
    pop dx
    pop ax
    ret

verify_sentinel:
    push ax
    push dx
    push si
    push di
    mov si, sentinel_config
    xor di, di

.write_rectangle:
    mov dx, KATEA_INDEX_PORT
    mov ax, di
    out dx, al
    inc dx
    lodsb
    out dx, al
    inc di
    cmp di, 8
    jb .write_rectangle

    mov al, KATEA_CRC
    call katea_command
    jc .failure
    mov si, sentinel_config + 8
    mov di, 8

.compare_crc:
    mov dx, KATEA_INDEX_PORT
    mov ax, di
    out dx, al
    inc dx
    in al, dx
    cmp al, [si]
    jne .failure
    inc si
    inc di
    cmp di, 12
    jb .compare_crc
    clc
    jmp .done

.failure:
    stc

.done:
    pop di
    pop si
    pop dx
    pop ax
    ret

katea_command:
    push ax
    push bx
    push dx
    mov bl, al
    mov dx, KATEA_INDEX_PORT
    mov al, KATEA_STATUS_REGISTER
    out dx, al
    inc dx
    xor al, al
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    mov bx, 2000

.poll:
    mov dx, KATEA_INDEX_PORT
    mov al, KATEA_STATUS_REGISTER
    out dx, al
    inc dx
    in al, dx
    test al, al
    jnz .completed
    dec bx
    jnz .poll
    stc
    jmp .done

.completed:
    cmp al, KATEA_STATUS_OK
    jne .rejected
    clc
    jmp .done

.rejected:
    stc

.done:
    pop dx
    pop bx
    pop ax
    ret

exit_success:
    mov ax, 0x4C00
    int 0x21

exit_failure:
    mov ax, 0x4C01
    int 0x21

exit_sentinel_failure:
    mov ax, 0x4C02
    int 0x21

pre_payload:
    incbin "legacy-vga-evidence-pre.tsv"
pre_payload_end:

post_payload:
    incbin "legacy-vga-evidence-post.tsv"
post_payload_end:

quake_failure_payload:
    incbin "legacy-vga-evidence-quake-failure.tsv"
quake_failure_payload_end:

sentinel_failure_payload:
    incbin "legacy-vga-evidence-sentinel-failure.tsv"
sentinel_failure_payload_end:

report_failure_payload:
    incbin "legacy-vga-evidence-report-failure.tsv"
report_failure_payload_end:

sentinel_config:
    incbin "legacy-vga-evidence-sentinel.bin"
