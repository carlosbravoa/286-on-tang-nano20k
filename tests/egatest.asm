; A boot sector that shows a test picture in a 16-colour mode (0Dh, 0Eh, 10h or 12h):
;   nasm -DMODE=0x12 -DCOLS=80 -DLINES=480 -f bin tests/egatest.asm -o build/ega12.bin
; 16 colour bars drawn the way programs do it (set/reset), a line of dots through the BIOS,
; text in colours, and the colour of one dot read back (it prints 0C).
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ax, MODE
        int 0x10
        cld
        mov ax, 0xA000
        mov es, ax
        mov dx, 0x3CE
        mov ax, 0x0F01              ; all planes from set/reset
        out dx, ax
        xor bx, bx                  ; BL = colour
.bar:   mov ah, bl
        xor al, al
        out dx, ax                  ; set/reset = the colour
        mov ax, COLS/16
        mul bl
        mov di, ax
        add di, COLS*40             ; from line 40
        mov si, LINES-80            ; to 40 above the end
.ln:    mov cx, COLS/16
        rep stosb
        add di, COLS - COLS/16
        dec si
        jnz .ln
        inc bl
        cmp bl, 16
        jb .bar
        mov ax, 0x0001
        out dx, ax
        xor cx, cx                  ; dots: a diagonal in colour 12
.dot:   mov ax, 0x0C0C
        mov dx, cx
        add dx, 4
        xor bh, bh
        int 0x10
        inc cx
        cmp cx, 30
        jb .dot
        mov si, text
        mov bl, 9
.t:     lodsb
        or al, al
        jz .rd
        mov ah, 0x0E
        xor bh, bh
        int 0x10
        inc bl
        jmp .t
.rd:    mov ah, 0x0D                ; read a dot of the diagonal back
        mov cx, 10
        mov dx, 14
        int 0x10
        push ax
        shr al, 4
        call nib
        pop ax
        call nib
.halt:  hlt
        jmp .halt
nib:    and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe .p
        add al, 7
.p:     mov ah, 0x0E
        mov bx, 0x000F
        int 0x10
        ret
text:   db '    16 colours ', 0
