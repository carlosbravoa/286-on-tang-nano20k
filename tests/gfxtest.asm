; A boot sector that shows a test picture in one video mode:
;   nasm -DMODE=0x13 -f bin tests/gfxtest.asm -o build/gfx13.bin
; It goes over the code of a floppy image's boot sector, from offset 3Eh (after the BPB).
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ax, MODE
        int 0x10
        cld
%if MODE == 0x13
        mov ax, 0xA000              ; 16 x 16 squares of the 256 colours, 20 x 10 pixels each
        mov es, ax
        xor di, di
        xor dx, dx                  ; DX = line
.row:   mov ax, dx
        mov bl, 10
        div bl
        cmp al, 16
        jb .in
        mov al, 15
.in:    shl al, 4
        mov bh, al
        xor bl, bl
        mov cx, 16
.sq:    push cx
        mov al, bh
        or al, bl
        mov cx, 20
        rep stosb
        inc bl
        pop cx
        loop .sq
        inc dx
        cmp dx, 160
        jb .row
%elif MODE == 6
        mov ax, 0xB800              ; stripes of 1, 2 and 4 pixels
        mov es, ax
        xor di, di
        mov al, 0xAA
        mov cx, 80*20
        rep stosb
        mov al, 0xCC
        mov cx, 80*20
        rep stosb
        mov di, 0x2000
        mov al, 0xAA
        mov cx, 80*20
        rep stosb
        mov al, 0xF0
        mov cx, 80*20
        rep stosb
%elif MODE == 4 || MODE == 5
        mov ax, 0xB800              ; the four colours side by side, twice
        mov es, ax
        xor di, di
        call bands
        mov di, 0x2000
        call bands
%endif
        mov ah, 2                   ; text at row 21
        xor bh, bh
        mov dx, 0x1502
        int 0x10
        mov si, msg
.t:     lodsb
        or al, al
        jz .line
        mov ah, 0x0E
        mov bx, 0x000F
%if MODE == 4 || MODE == 5
        mov bl, 2
%endif
        int 0x10
        jmp .t
.line:
%if MODE >= 4
        mov cx, 10                  ; a diagonal with the pixel function
        mov dx, 185
.d:     mov ax, 0x0C0F
        xor bh, bh
        int 0x10
        add cx, 2
        dec dx
        cmp dx, 165
        ja .d
%endif
.stop:  hlt
        jmp .stop

%if MODE == 4 || MODE == 5
bands:  mov bx, 40
.l:     mov al, 0x00
        mov cx, 20
        rep stosb
        mov al, 0x55
        mov cx, 20
        rep stosb
        mov al, 0xAA
        mov cx, 20
        rep stosb
        mov al, 0xFF
        mov cx, 20
        rep stosb
        dec bx
        jnz .l
        ret
%endif
msg:    db "Mode ", '0' + MODE / 16, '0' + MODE % 16, "h: 286 on Tang Nano 20K", 13, 10
        db "  second line of text", 0
