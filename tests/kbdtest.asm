; A boot sector that takes the keyboard interrupt the way games do: it reads port 60h itself,
; then lets the BIOS handler run (which reads the port again). Prints every byte it read.
; An arrow key must show as E0 48 E0 C8.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        cli
        mov ax, [0x24]
        mov [old], ax
        mov ax, [0x26]
        mov [old+2], ax
        mov word [0x24], kbd
        mov [0x26], cs
        sti
.loop:  mov bl, [tail]
        cmp bl, [head]
        je .loop
        xor bh, bh
        mov al, [buf+bx]
        inc byte [tail]
        and byte [tail], 31
        call hex
        jmp .loop
kbd:    push ax
        push bx
        push ds
        xor ax, ax
        mov ds, ax
        in al, 0x60
        mov bl, [head]
        xor bh, bh
        mov [buf+bx], al
        inc bl
        and bl, 31
        mov [head], bl
        pop ds
        pop bx
        pop ax
        jmp far [cs:old]
hex:    push ax
        shr al, 4
        call .n
        pop ax
        call .n
        mov al, ' '
        jmp putc
.n:     and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe putc
        add al, 7
putc:   mov ah, 0x0E
        mov bx, 7
        int 0x10
        ret
old:    dd 0
head:   db 0
tail:   db 0
buf:    times 32 db 0
