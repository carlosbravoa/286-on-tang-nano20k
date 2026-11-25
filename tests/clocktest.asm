; A boot sector for the clock (INT 1Ah): no date at first (N), then sets 2023-12-31 23:59:59,
; reads both back, goes to just before midnight, waits and reads them again: the year must have turned.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ah, 4
        int 0x1A
        mov al, 'N'
        jc .n
        mov al, 'Y'
.n:     call putc
        mov ah, 5
        mov cx, 0x2023
        mov dx, 0x1231
        int 0x1A
        mov ah, 3
        mov cx, 0x2359
        mov dx, 0x5900
        int 0x1A
        call show
        mov ah, 1                   ; a few ticks before midnight
        mov cx, 0x18
        mov dx, 0xA8
        int 0x1A
.w:     mov ah, 0
        int 0x1A
        or cx, cx
        jnz .w
        cmp dx, 2
        jb .w
.go:    call show
.stop:  jmp .stop
show:   mov ah, 4
        int 0x1A
        mov ax, cx
        call hex4
        mov ax, dx
        call hex4
        mov al, ' '
        call putc
        mov ah, 2
        int 0x1A
        mov ax, cx
        call hex4
        mov al, ' '
        jmp putc
hex4:   push ax
        mov al, ah
        call hex2
        pop ax
hex2:   push ax
        shr al, 4
        call hex1
        pop ax
hex1:   and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe putc
        add al, 7
putc:   mov ah, 0x0E
        int 0x10
        ret
