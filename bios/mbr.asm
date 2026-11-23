; Master boot record of the hard disk (the SD card): start the active partition.
        cpu 286
        org 0x0600
        cli
        xor ax, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ds, ax
        mov es, ax
        sti
        cld
        mov si, 0x7C00
        mov di, 0x0600
        mov cx, 256
        rep movsw
        jmp 0x0000:next
next:   mov si, 0x07BE
        mov cx, 4
.l:     test byte [si], 0x80
        jnz .boot
        add si, 16
        loop .l
.fail:  int 0x18
.boot:  mov dh, [si+1]              ; DL is still the drive the BIOS gave
        mov cx, [si+2]
        mov bx, 0x7C00
        mov ax, 0x0201
        int 0x13
        jc .fail
        cmp word [0x7DFE], 0xAA55
        jne .fail
        jmp 0x0000:0x7C00
