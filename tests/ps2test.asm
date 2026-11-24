; A boot sector that uses the mouse as Windows does: through the BIOS interface of a PS/2
; mouse (INT 15h AH=C2h). It sets a handler and prints what each call brings: status, x, y.
; In the simulator --type '\m\l\u' moves the mouse and presses and releases the left button.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ax, 0xC205              ; 3-byte packets
        mov bh, 3
        int 0x15
        mov ax, 0xC207
        mov bx, handler
        int 0x15
        mov ax, 0xC200
        mov bh, 1
        int 0x15
        mov al, 'G'
        call putc
        mov al, 'O'
        call putc
        sti
.l:     hlt
        jmp .l
handler:                            ; far call; on the stack: status, x, y, 0
        push bp
        mov bp, sp
        pusha
        mov al, [bp+12]
        call hex
        mov al, [bp+10]
        call hex
        mov al, [bp+8]
        call hex
        mov al, ' '
        call putc
        popa
        pop bp
        retf
hex:    push ax
        shr al, 4
        call .n
        pop ax
.n:     and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe putc
        add al, 7
putc:   mov ah, 0x0E
        mov bx, 7
        int 0x10
        ret
