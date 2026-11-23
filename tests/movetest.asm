; A boot sector that tests INT 15h AH=87h: a text goes above 1 MB and comes back.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ah, 0x88
        int 0x15
        call hex                    ; KB of extended memory
        mov word [gdt+0x12], text   ; from 0:text
        mov byte [gdt+0x14], 0
        mov word [gdt+0x1A], 0x3FFA ; to 123FFAh: across two pages of the window
        mov byte [gdt+0x1C], 0x12
        call move
        mov word [gdt+0x12], 0x3FFA
        mov byte [gdt+0x14], 0x12
        mov word [gdt+0x1A], 0x8000 ; back to 0:8000
        mov byte [gdt+0x1C], 0
        call move
        mov si, 0x8000
.p:     lodsb
        or al, al
        jz .stop
        call putc
        jmp .p
.stop:  hlt
        jmp .stop
move:   mov si, gdt
        mov cx, 12
        mov ah, 0x87
        int 0x15
        pushf
        pop ax
        and ax, 0x0041              ; carry and zero: 0040 is right
        or ah, ah
hex:    push ax
        mov al, ah
        call .b
        pop ax
        call .b
        mov al, ' '
        jmp putc
.b:     push ax
        shr al, 4
        call .n
        pop ax
.n:     and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe putc
        add al, 7
putc:   push bx
        mov ah, 0x0E
        mov bx, 7
        int 0x10
        pop bx
        ret
text:   db "back from above 1 MB", 13, 10, 0, 0, 0
gdt:    times 0x30 db 0
