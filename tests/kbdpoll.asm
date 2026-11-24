; A boot sector that reads the keyboard the way some small games do: the BIOS keeps its
; interrupt handler, and the program reads port 60h again and again to see the last key.
; It prints every new value it sees there. Type "ab": 1E 9E 30 B0 must appear.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov al, 'G'
        call putc
        mov al, 'O'
        call putc
        sti
        xor bl, bl
.l:     in al, 0x60
        cmp al, bl
        je .l
        mov bl, al
        push bx
        call hex
        pop bx
        jmp .l
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
