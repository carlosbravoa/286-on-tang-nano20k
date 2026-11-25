; A boot sector that uses drive B:, which another computer serves through the monitor
; (tools/pc286ctl.py serve): it reads the first sector until that works, prints the name in
; it, changes it and writes it to sector 6 (cylinder 0, head 0, sector 7).
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
.read:  mov ax, 0x0201
        mov bx, 0x7E00
        mov cx, 0x0001
        mov dx, 0x0001
        int 0x13
        jc .read
        mov si, 0x7E03
        mov cx, 8
.name:  lodsb
        mov ah, 0x0E
        int 0x10
        loop .name
        mov word [0x7E00], 0x3832    ; "286" at the start
        mov byte [0x7E02], 0x36
        mov ax, 0x0301
        mov bx, 0x7E00
        mov cx, 0x0007
        mov dx, 0x0001
        int 0x13
        mov al, 'W'
        jnc .say
        mov al, 'E'
.say:   mov ah, 0x0E
        int 0x10
        mov ah, 0x08                ; and what the BIOS says of the drive
        mov dl, 1
        int 0x13
        mov al, cl
        add al, '0'
        mov ah, 0x0E
        int 0x10
        mov al, dl
        add al, '0'
        mov ah, 0x0E
        int 0x10
.stop:  jmp .stop
