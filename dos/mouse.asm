; MOUSE.COM: the mouse driver is in the BIOS (INT 33h), but DOS takes its interrupt vectors
; when it starts. This asks the BIOS to put them back. It does not stay in memory.
        cpu 286
        org 0x100
        mov ax, 0xC2FF
        int 0x15
        jc .no
        xor ax, ax                  ; is the driver there now?
        int 0x33
        cmp ax, 0xFFFF
        jne .no
        mov dx, yes
        jmp .say
.no:    mov dx, no
.say:   mov ah, 9
        int 0x21
        mov ax, 0x4C00
        int 0x21
yes:    db 'Mouse driver ready (BIOS, INT 33h)', 13, 10, '$'
no:     db 'No mouse driver in this BIOS', 13, 10, '$'
