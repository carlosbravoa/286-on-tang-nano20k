; A boot sector that tests the BIOS mouse driver: prints what INT 33h says after each key.
;   nasm -f bin tests/mousetest.asm -o build/mouse.bin     (see tests/mkgfxcard.sh for the rest)
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        xor ax, ax
        int 0x33
        call hex                    ; FFFF: there is a mouse
        mov ax, bx
        call hex                    ; buttons
        mov ax, 1
        int 0x33
        mov si, ready
.p:     lodsb
        or al, al
        jz .loop
        call putc
        jmp .p
.loop:  xor ax, ax
        int 0x16
        mov ax, 3
        int 0x33
        mov ax, bx
        call hex
        mov ax, cx
        call hex
        mov ax, dx
        call hex
        mov ax, 5
        xor bx, bx
        int 0x33
        mov ax, bx                  ; times the left button went down
        call hex
        mov al, 13
        call putc
        mov al, 10
        call putc
        jmp .loop

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
ready:  db "ready", 13, 10, 0
