; ───────────────────────────── INT 10h: video ─────────────────────────────
; Modes: 0-3 text (40 or 80 columns), 4-5 320x200 in 4 colours, 6 640x200 in 2,
; 13h 320x200 in 256. The card says it is a VGA.
; Stack frame after the pushes, from BP:
;   +0 ES  +2 DS  +4 DI  +6 SI  +8 BP  +10 SP  +12 BX  +14 DX  +16 CX  +18 AX
; Locals below BP: -1 lines  -2 rows  -3 columns  -4 attribute  -6 row  -7 step  -8 use attribute  -9 attribute
;   graphics scroll: -11 fill byte  -14 height  -16 distance  -18 width  -20 left  -22 signed distance
%define F_ES [bp+0]
%define F_BP [bp+8]
%define F_BX [bp+12]
%define F_DX [bp+14]
%define F_CX [bp+16]
%define F_AX [bp+18]

int10:  sti
        cld
        pusha
        push ds
        push es
        mov bp, sp
        sub sp, 24
        mov si, 0x40
        mov ds, si
        mov si, 0xB800
        mov es, si
        cmp ah, 0x1A
        ja v_exit
        mov si, ax
        shr si, 8
        shl si, 1
        jmp [cs:si+v_table]
v_exit: mov sp, bp
        pop es
        pop ds
        popa
        iret

v_table: dw v_setmode, v_curtype, v_setpos, v_getpos, v_exit, v_page, v_up, v_down
         dw v_read, v_write, v_writec, v_palette, v_wpixel, v_rpixel, v_tty, v_getmode
         dw v_dac, v_font, v_alt, v_string, v_exit, v_exit, v_exit, v_exit
         dw v_exit, v_exit, v_dcc

; per mode: port 3D8h, columns, port 3D9h, mode number
mode_table:
        db 0x2C, 40, 0x30, 0x00
        db 0x28, 40, 0x30, 0x01
        db 0x2D, 80, 0x30, 0x02
        db 0x29, 80, 0x30, 0x03
        db 0x2A, 40, 0x30, 0x04
        db 0x2E, 40, 0x30, 0x05
        db 0x1E, 80, 0x3F, 0x06
        db 0x0A, 40, 0x30, 0x13
        db 0x0A, 40, 0x30, 0x0D     ; 16 colours in four planes: 320x200
        db 0x0A, 80, 0x30, 0x0E     ; 640x200
        db 0x0A, 80, 0x30, 0x10     ; 640x350
        db 0x0A, 80, 0x30, 0x12     ; 640x480

; DI = address of the cell at page BH, row DH, column DL
cell_addr:
        push ax
        mov al, dh
        mul byte [BD_VCOLS]
        push dx
        xor dh, dh
        add ax, dx
        shl ax, 1
        mov di, ax
        mov al, bh
        and ax, 7
        mul word [BD_VPAGESIZE]
        add di, ax
        pop dx
        pop ax
        ret

; put the hardware cursor where the active page's cursor is
hw_cursor:
        push ax
        push bx
        push dx
        mov bl, [BD_VPAGE]
        xor bh, bh
        shl bx, 1
        mov dx, [bx+BD_VCURSOR]
        mov al, dh
        mul byte [BD_VCOLS]
        xor dh, dh
        add ax, dx
        mov bx, [BD_VPAGESTART]
        shr bx, 1
        add bx, ax
        mov dx, 0x3D4
        mov al, 0x0E
        mov ah, bh
        out dx, ax
        mov al, 0x0F
        mov ah, bl
        out dx, ax
        pop dx
        pop bx
        pop ax
        ret

; cursor shape CH = first line, CL = last line; CGA values (0-7) are doubled for the 16-line cell
set_curtype:
        mov [BD_VCURTYPE], cx
        mov ax, cx
        test ah, 0x20
        jnz .set
        and ax, 0x1F1F
        cmp al, 7
        ja .set
        shl ah, 1
        shl al, 1
        inc al
.set:   push ax
        mov dx, 0x3D4
        mov al, 0x0A
        out dx, ax
        pop ax
        mov ah, al
        mov al, 0x0B
        out dx, ax
        ret

v_setmode:
        and al, 0x7F
        cmp al, 6
        jbe .ok
        mov ah, al                  ; the others: their place in the table
        mov al, 7
        cmp ah, 0x13
        je .ok
        inc al
        cmp ah, 0x0D
        je .ok
        inc al
        cmp ah, 0x0E
        je .ok
        inc al
        cmp ah, 0x10
        je .ok
        inc al
        cmp ah, 0x12
        jne v_exit                  ; a mode we do not have: nothing changes
.ok:    xor ah, ah
        mov si, ax
        shl si, 2
        add si, mode_table
        mov al, [cs:si+3]
        mov [BD_VMODE], al
        mov al, [cs:si+1]
        xor ah, ah
        mov [BD_VCOLS], ax
        mov word [BD_VPAGESIZE], 0x1000
        cmp al, 40
        jne .p
        mov word [BD_VPAGESIZE], 0x0800
.p:     mov word [BD_VPAGESTART], 0
        mov byte [BD_VPAGE], 0
        mov word [BD_VCRTC], 0x3D4
        mov byte [BD_VROWS], 24
        mov word [BD_VCHARH], 16
        cmp byte [BD_VMODE], 4
        jb .h
        mov word [BD_VCHARH], 8
.h:     push es
        push ds
        pop es
        mov di, BD_VCURSOR
        xor ax, ax
        mov cx, 8
        rep stosw
        pop es
        mov dx, 0x3D8
        out dx, al                  ; no picture while things change
        mov bx, ea_table - 1        ; which picture the video hardware makes
.ea:    inc bx
        mov ah, [cs:bx]
        inc bx
        or ah, ah
        jz .v
        cmp ah, [BD_VMODE]
        jne .ea
        mov al, [cs:bx]
.v:     out 0xEA, al
        call pl_defaults
        push ax
        mov dx, 0x3D4               ; no split screen, the picture not moved
        mov ax, 0xFF18
        out dx, ax
        mov ax, 0x1007
        out dx, ax
        mov ax, 0x4009
        out dx, ax
        mov ax, 0x1413              ; line length: 40 bytes, or 80
        cmp byte [BD_VCOLS], 80
        jne .ll
        mov ah, 0x28
.ll:    out dx, ax
        mov dx, 0x3DA
        in al, dx
        mov dx, 0x3C0
        mov al, 0x13
        out dx, al
        xor al, al
        out dx, al
        mov al, 0x20
        out dx, al
        pop ax
        test byte F_AX, 0x80
        jnz .keep
        xor di, di
        cmp byte [BD_VMODE], 4
        jae .g
        mov ax, 0x0720
        mov cx, 0x4000
        rep stosw
        jmp .keep
.g:     xor ax, ax
        mov cx, 0x2000
        cmp byte [BD_VMODE], 7
        jb .c
        push es
        push 0xA000
        pop es
        mov cx, 0x8000
        rep stosw
        pop es
        jmp .keep
.c:     rep stosw
.keep:  push si                     ; the default palette
        mov dx, 0x3C8
        xor al, al
        out dx, al
        inc dx
        mov si, vga_palette
        mov cx, 768
.pl:    cs lodsb
        out dx, al
        loop .pl
        pop si
        call is_planar
        jne .np
        call pl_palette
.np:
        mov dx, 0x3D4
        mov ax, 0x000C
        out dx, ax
        mov ax, 0x000D
        out dx, ax
        mov al, [cs:si+2]
        mov [BD_VPALETTE], al
        mov dx, 0x3D9
        out dx, al
        mov al, [cs:si]
        mov [BD_VMODEREG], al
        dec dx
        out dx, al
        mov cx, 0x0607
        call set_curtype
        call hw_cursor
        jmp v_exit

v_curtype:
        call set_curtype
        jmp v_exit

v_setpos:
        mov bl, bh
        and bx, 7
        mov al, bl
        shl bx, 1
        mov [bx+BD_VCURSOR], dx
        cmp al, [BD_VPAGE]
        jne v_exit
        call hw_cursor
        jmp v_exit

v_getpos:
        mov bl, bh
        and bx, 7
        shl bx, 1
        mov ax, [bx+BD_VCURSOR]
        mov F_DX, ax
        mov ax, [BD_VCURTYPE]
        mov F_CX, ax
        jmp v_exit

v_page: cmp byte [BD_VMODE], 4
        jae v_exit
        and ax, 7
        mov [BD_VPAGE], al
        mul word [BD_VPAGESIZE]
        mov bx, ax
        mov [BD_VPAGESTART], bx
        shr bx, 1
        mov dx, 0x3D4
        mov al, 0x0C
        mov ah, bh
        out dx, ax
        mov al, 0x0D
        mov ah, bl
        out dx, ax
        call hw_cursor
        jmp v_exit

v_up:   mov bl, 0
        jmp scroll
v_down: mov bl, 1
scroll: cmp dh, 24
        jbe .r
        mov dh, 24
.r:     mov ah, [BD_VCOLS]
        dec ah
        cmp dl, ah
        jbe .c
        mov dl, ah
.c:     cmp ch, dh
        ja v_exit
        cmp cl, dl
        ja v_exit
        cmp byte [BD_VMODE], 4
        jb .text
        call gfx_scroll
        jmp v_exit
.text:  mov [bp-4], bh
        mov byte [bp-7], 1
        mov [bp-6], ch
        or bl, bl
        jz .dir
        mov byte [bp-7], -1
        mov [bp-6], dh
.dir:   mov ah, dh
        sub ah, ch
        inc ah
        mov [bp-2], ah
        mov ah, dl
        sub ah, cl
        inc ah
        mov [bp-3], ah
        or al, al
        jz .all
        cmp al, [bp-2]
        jb .n
.all:   mov al, [bp-2]
.n:     mov [bp-1], al
        mov bh, [BD_VPAGE]
        mov dl, cl
        mov bl, [bp-2]
        sub bl, [bp-1]
.copy:  or bl, bl
        jz .fill
        mov dh, [bp-6]
        call cell_addr
        push di
        mov al, [bp-1]
        imul byte [bp-7]
        add dh, al
        call cell_addr
        mov si, di
        pop di
        mov cl, [bp-3]
        xor ch, ch
        push ds
        push es
        pop ds
        rep movsw
        pop ds
        mov al, [bp-7]
        add [bp-6], al
        dec bl
        jmp .copy
.fill:  mov bl, [bp-1]
.f:     or bl, bl
        jz v_exit
        mov dh, [bp-6]
        call cell_addr
        mov ah, [bp-4]
        mov al, ' '
        mov cl, [bp-3]
        xor ch, ch
        rep stosw
        mov al, [bp-7]
        add [bp-6], al
        dec bl
        jmp .f

; DI = cell under the cursor of page BH
cursor_cell:
        push bx
        mov bl, bh
        and bx, 7
        shl bx, 1
        mov dx, [bx+BD_VCURSOR]
        pop bx
        jmp cell_addr

v_read: xor ax, ax
        cmp byte [BD_VMODE], 4
        jae .g
        call cursor_cell
        mov ax, [es:di]
.g:     mov F_AX, ax
        jmp v_exit

v_write:
        mov byte [bp-8], 1
        jmp wr
v_writec:
        mov byte [bp-8], 0
wr:     jcxz .x
        cmp byte [BD_VMODE], 4
        jae .g
        push ax
        call cursor_cell
        pop ax
        mov ah, bl
        cmp byte [bp-8], 0
        je .l
        rep stosw
        jmp v_exit
.l:     stosb
        inc di
        loop .l
.x:     jmp v_exit
.g:     mov dx, [BD_VCURSOR]
.gl:    call gfx_glyph
        inc dl
        loop .gl
        jmp v_exit

v_palette:
        mov al, [BD_VPALETTE]
        or bh, bh
        jnz .p
        and al, 0xE0                ; BH = 0: background and border colour
        and bl, 0x1F
        or al, bl
        jmp .o
.p:     and al, 0xDF                ; BH = 1: which palette
        test bl, 1
        jz .o
        or al, 0x20
.o:     mov [BD_VPALETTE], al
        mov dx, 0x3D9
        out dx, al
        jmp v_exit

; pixel AL at column CX, line DX; bit 7 of AL: exclusive or (not in mode 13h)
v_wpixel:
        cmp byte [BD_VMODE], 4
        jb v_exit
        call is_planar
        je pl_wpixel
        call pix_addr
        or ah, ah
        jnz .c
        stosb
        jmp v_exit
.c:     mov bl, al
        and al, ah
        shl al, cl
        shl ah, cl
        test bl, 0x80
        jnz .xor
        not ah
        and [es:di], ah
        or [es:di], al
        jmp v_exit
.xor:   xor [es:di], al
        jmp v_exit

v_rpixel:
        cmp byte [BD_VMODE], 4
        jb v_exit
        call is_planar
        je pl_rpixel
        call pix_addr
        mov al, [es:di]
        or ah, ah
        jz .s
        shr al, cl
        and al, ah
.s:     mov F_AX, al
        jmp v_exit

; the byte of the pixel at column CX, line DX: ES:DI, CL = shift, AH = mask (0: the whole byte)
pix_addr:
        push ax
        mov ax, dx
        call gline_addr
        pop ax
        cmp byte [BD_VMODE], 6
        je .m6
        jb .m4
        add di, cx
        push 0xA000
        pop es
        xor ah, ah
        ret
.m4:    mov bx, cx
        shr bx, 2
        add di, bx
        not cl
        and cl, 3
        shl cl, 1
        mov ah, 3
        ret
.m6:    mov bx, cx
        shr bx, 3
        add di, bx
        not cl
        and cl, 7
        mov ah, 1
        ret

; DI = offset of graphics line AX in its segment
gline_addr:
        call is_planar
        jne .np
        push dx
        push ax
        mul word [BD_VCOLS]
        mov di, ax
        pop ax
        pop dx
        ret
.np:    cmp byte [BD_VMODE], 0x13
        jne .c
        imul di, ax, 320
        ret
.c:     mov di, ax
        shr di, 1
        imul di, di, 80
        test al, 1
        jz .e
        add di, 0x2000
.e:     ret

; draw character AL in colour BL at row DH, column DL of a graphics mode (8x8 cells)
gfx_glyph:
        call is_planar
        je pl_glyph
        pusha
        push es
        xor ah, ah
        mov si, ax
        shl si, 3
        add si, font8x8
        mov al, dh
        shl ax, 3                   ; the top line
        mov cx, 8
        cmp byte [BD_VMODE], 0x13
        jne .line
        push 0xA000
        pop es
.line:  push ax
        push cx
        call gline_addr
        mov al, [cs:si]
        inc si
        mov cl, dl
        xor ch, ch
        cmp byte [BD_VMODE], 6
        je .m6
        ja .m13
        shl cx, 1                   ; 4 colours: two bytes a cell, two bits a pixel
        add di, cx
        push dx
        xor dx, dx
        mov ch, 8
.x:     shl dx, 2
        shl al, 1
        jnc .z
        mov ah, bl
        and ah, 3
        or dl, ah
.z:     dec ch
        jnz .x
        mov ax, dx
        pop dx
        xchg al, ah
        test bl, 0x80
        jz .st
        xor ax, [es:di]
.st:    mov [es:di], ax
        jmp .next
.m6:    add di, cx
        test bl, 0x80
        jz .s6
        xor al, [es:di]
.s6:    mov [es:di], al
        jmp .next
.m13:   shl cx, 3
        add di, cx
        mov ah, al
        mov cx, 8
.b:     xor al, al
        shl ah, 1
        jnc .w
        mov al, bl
.w:     stosb
        loop .b
.next:  pop cx
        pop ax
        inc ax
        loop .line
        pop es
        popa
        ret

; scroll a window of a graphics mode: AL lines (0 = clear), BL 0 up / 1 down, BH fill colour,
; CH,CL the top left cell, DH,DL the bottom right one
gfx_scroll:
        pusha
        push es
        mov si, 1                   ; SI = log2 of the bytes in a cell's width
        cmp byte [BD_VMODE], 6
        jb .s
        mov si, 0
        je .s
        push 0xA000
        pop es
        call is_planar
        je .s
        mov si, 3
        push 0xA000
        pop es
.s:     mov ah, bh                  ; the fill byte
        cmp byte [BD_VMODE], 6
        ja .f
        je .f6
        and ah, 3
        mov bh, ah
        shl ah, 2
        or ah, bh
        mov bh, ah
        shl ah, 4
        or ah, bh
        jmp .f
.f6:    and ah, 1
        neg ah
.f:     mov [bp-11], ah
        mov ah, dh
        sub ah, ch
        inc ah                      ; rows of the window
        or al, al
        jz .all
        cmp al, ah
        jb .n
.all:   mov al, ah
.n:     push ax
        mov al, ah
        xor ah, ah
        shl ax, 3
        mov [bp-14], ax
        pop ax
        xor ah, ah
        shl ax, 3
        mov [bp-16], ax
        mov [bp-22], ax
        mov al, dl
        sub al, cl
        inc al
        xor ah, ah
        xchg cx, si                 ; CL = the shift, SI = the top left cell
        shl ax, cl
        mov [bp-18], ax
        mov ax, si
        xor ah, ah
        shl ax, cl
        mov [bp-20], ax
        mov ax, si
        mov al, ah
        xor ah, ah
        shl ax, 3
        mov dx, ax                  ; DX = the line being written
        mov si, 1                   ; SI = +1 going down the window, -1 going up
        or bl, bl
        jz .up
        add dx, [bp-14]
        dec dx
        neg si
        neg word [bp-22]
.up:    mov bx, [bp-14]
        sub bx, [bp-16]
        push ax
        mov ax, 0x0105              ; planes: a copy moves all four (write mode 1)
        call gc_out
        pop ax
.copy:  or bx, bx
        jz .fill
        mov ax, dx
        add ax, [bp-22]
        call gline_addr
        add di, [bp-20]
        push di
        mov ax, dx
        call gline_addr
        add di, [bp-20]
        pop ax
        push si
        mov si, ax
        mov cx, [bp-18]
        push ds
        push es
        pop ds
        rep movsb
        pop ds
        pop si
        add dx, si
        dec bx
        jmp .copy
.fill:  mov bx, [bp-16]
        mov ax, 0x0205              ; planes: the byte written is the colour (write mode 2)
        call gc_out
.fl:    or bx, bx
        jz .done
        mov ax, dx
        call gline_addr
        add di, [bp-20]
        mov al, [bp-11]
        mov cx, [bp-18]
        rep stosb
        add dx, si
        dec bx
        jmp .fl
.done:  call pl_defaults
        pop es
        popa
        ret

; ── the 16-colour modes (four planes at A000) ──
; ZF set if the mode is one of them
is_planar:
        cmp byte [BD_VMODE], 0x0D
        je .y
        cmp byte [BD_VMODE], 0x0E
        je .y
        cmp byte [BD_VMODE], 0x10
        je .y
        cmp byte [BD_VMODE], 0x12
.y:     ret

ea_table:                           ; mode, value for port EAh; ends with 0
        db 0x13, 0x01, 0x0D, 0x02, 0x0E, 0x06, 0x10, 0x0E, 0x12, 0x16, 0

; AL to graphics controller register AH... as a word: AX = value * 256 + register
gc_out: push dx
        mov dx, 0x3CE
        out dx, ax
        pop dx
        ret

; the graphics controller and the plane mask as programs expect to find them
pl_defaults:
        push ax
        push dx
        mov ax, 0x0005
        call gc_out
        mov ax, 0xFF08
        call gc_out
        mov ax, 0x0003
        call gc_out
        mov ax, 0x0001
        call gc_out
        mov ax, 0x0004
        call gc_out
        mov ax, 0x0F07
        call gc_out
        mov dx, 0x3C4
        mov ax, 0x0F02
        out dx, ax
        pop dx
        pop ax
        ret

; ES:DI = the byte of the pixel at column CX, line DX; CH = its bit
pl_addr:
        mov ax, [BD_VCOLS]
        mul dx
        mov di, cx
        shr di, 3
        add di, ax
        push 0xA000
        pop es
        and cl, 7
        mov ch, 0x80
        shr ch, cl
        ret

pl_wpixel:
        mov bl, al
        call pl_addr
        mov ah, ch
        mov al, 8
        call gc_out                 ; only this bit
        mov ax, 0x0205
        call gc_out
        test bl, 0x80
        jz .w
        mov ax, 0x1803              ; exclusive or
        call gc_out
.w:     mov al, [es:di]
        mov [es:di], bl
        call pl_defaults
        jmp v_exit

pl_rpixel:
        call pl_addr
        xor bl, bl
        mov ah, 3
.p:     mov al, 4                   ; plane by plane
        call gc_out
        shl bl, 1
        test [es:di], ch
        jz .n
        or bl, 1
.n:     dec ah
        jns .p
        call pl_defaults
        mov F_AX, bl
        jmp v_exit

; character AL in colour BL at row DH, column DL (8x8 cells)
pl_glyph:
        pusha
        push es
        push 0xA000
        pop es
        xor ah, ah
        mov si, ax
        shl si, 3
        add si, font8x8
        mov cl, dl
        xor ch, ch
        mov al, dh
        xor ah, ah
        shl ax, 3
        mul word [BD_VCOLS]
        mov di, ax
        add di, cx
        mov ax, 0x0205
        call gc_out
        test bl, 0x80
        jz .n
        mov ax, 0x1803
        call gc_out
.n:     mov cx, 8
.row:   mov ah, [cs:si]
        inc si
        mov al, 8
        call gc_out                 ; the dots of the character: the colour
        mov al, [es:di]
        mov [es:di], bl
        test bl, 0x80
        jnz .x
        not ah
        mov al, 8
        call gc_out                 ; the others: black
        mov al, [es:di]
        mov byte [es:di], 0
.x:     add di, [BD_VCOLS]
        loop .row
        call pl_defaults
        pop es
        popa
        ret

; the colours of a 16-colour mode: 64 DAC entries as an EGA monitor shows them, and the 16
; palette registers. With 200 lines bit 4 is "bright"; with more, bits 5-3 are the dim thirds.
pl_palette:
        pusha
        mov dx, 0x3C8
        xor al, al
        out dx, al
        inc dx
        xor bx, bx
.l:     mov si, 2                   ; red, green, blue
.c:     xor al, al
        test bl, [cs:.prim+si]
        jz .1
        add al, 0x2A
.1:     mov ah, [cs:.sec+si]
        cmp byte [BD_VMODE], 0x10
        jae .2
        mov ah, 0x10
.2:     test bl, ah
        jz .3
        add al, 0x15
.3:     cmp byte [BD_VMODE], 0x10   ; 200 lines: colour 6 is brown
        jae .4
        cmp si, 1
        jne .4
        mov ah, bl
        and ah, 0x17
        cmp ah, 6
        jne .4
        mov al, 0x15
.4:     out dx, al
        dec si
        jns .c
        inc bl
        cmp bl, 64
        jb .l
        mov dx, 0x3DA
        in al, dx
        mov dx, 0x3C0
        xor bl, bl
.a:     mov al, bl
        out dx, al
        cmp bl, 8
        jb .lo
        add al, 8                   ; 200 lines: 10h-17h
        cmp byte [BD_VMODE], 0x10
        jb .o
        add al, 0x28                ; more: 38h-3Fh
        jmp .o
.lo:    cmp bl, 6
        jne .o
        cmp byte [BD_VMODE], 0x10
        jb .o
        mov al, 0x14
.o:     out dx, al
        inc bl
        cmp bl, 16
        jb .a
        mov al, 0x20
        out dx, al
        popa
        ret
.prim:  db 1, 2, 4
.sec:   db 0x08, 0x10, 0x20

v_getmode:
        mov al, [BD_VMODE]
        mov ah, [BD_VCOLS]
        mov F_AX, ax
        mov al, [BD_VPAGE]
        mov [bp+13], al
        jmp v_exit

; the palette: AL = 10h set colour BX to DH,CH,CL; 12h set CX colours from BX with ES:DX;
; 15h and 17h read them back
v_dac:  or al, al                   ; AL = 0: palette register BL = BH
        jnz .r2
        cmp bl, 16
        jae .x
        mov dx, 0x3DA
        in al, dx
        mov dx, 0x3C0
        mov al, bl
        out dx, al
        mov al, bh
        out dx, al
        mov al, 0x20
        out dx, al
        jmp v_exit
.r2:    cmp al, 2                   ; AL = 2: all 16 from ES:DX
        jne .r7
        mov si, dx
        mov ds, F_ES
        mov dx, 0x3DA
        in al, dx
        mov dx, 0x3C0
        xor bl, bl
.ra:    mov al, bl
        out dx, al
        lodsb
        out dx, al
        inc bl
        cmp bl, 16
        jb .ra
        mov al, 0x20
        out dx, al
        jmp v_exit
.r7:    cmp al, 7                   ; AL = 7: read palette register BL into BH
        jne .r10
        mov dx, 0x3DA
        in al, dx
        mov dx, 0x3C0
        mov al, bl
        out dx, al
        inc dx
        in al, dx
        mov [bp+13], al
        dec dx
        mov al, 0x20                ; (the value write that 3C0 waits for goes nowhere)
        out dx, al
        mov dx, 0x3DA
        in al, dx
        jmp v_exit
.r10:   cmp al, 0x10
        jne .1
        mov ah, dh
        mov dx, 0x3C8
        mov al, bl
        out dx, al
        inc dx
        mov al, ah
        out dx, al
        mov al, ch
        out dx, al
        mov al, cl
        out dx, al
        jmp v_exit
.1:     cmp al, 0x12
        jne .2
        jcxz .x
        mov si, dx
        mov dx, 0x3C8
        mov al, bl
        out dx, al
        inc dx
        mov ax, cx
        shl cx, 1
        add cx, ax
        mov ds, F_ES
.l:     lodsb
        out dx, al
        loop .l
.x:     jmp v_exit
.2:     cmp al, 0x15
        jne .3
        mov dx, 0x3C7
        mov al, bl
        out dx, al
        add dx, 2
        in al, dx
        mov [bp+15], al
        in al, dx
        mov ah, al
        in al, dx
        mov F_CX, ax
        jmp v_exit
.3:     cmp al, 0x17
        jne .x
        jcxz .x
        mov di, dx
        mov dx, 0x3C7
        mov al, bl
        out dx, al
        add dx, 2
        mov ax, cx
        shl cx, 1
        add cx, ax
        mov es, F_ES
.r:     in al, dx
        stosb
        loop .r
        jmp v_exit

; AL = 30h: where the fonts are. BH = 3 the 8x8 font, 4 its upper half
v_font: cmp al, 0x30
        jne v_exit
        mov ax, font8x8
        cmp bh, 4
        jne .a
        add ax, 1024
.a:     mov F_BP, ax
        mov word F_ES, 0xF000
        mov ax, [BD_VCHARH]
        mov F_CX, ax
        mov al, [BD_VROWS]
        mov [bp+14], al
        jmp v_exit

; BL = 10h: what the card is. Colour, 256 KB.
v_alt:  cmp bl, 0x10
        jne v_exit
        mov word F_BX, 0x0003
        mov word F_CX, 0x0009
        jmp v_exit

; AL = 0: the display is a VGA with a colour monitor
v_dcc:  or al, al
        jnz v_exit
        mov byte F_AX, 0x1A
        mov word F_BX, 0x0008
        jmp v_exit

v_tty:  mov [bp-9], bl
        mov byte [bp-8], 0
        call tty_char
        jmp v_exit

v_string:
        jcxz .x
        mov bl, [BD_VPAGE]
        xor bh, bh
        shl bx, 1
        push word [bx+BD_VCURSOR]
        mov [bx+BD_VCURSOR], dx
        mov al, F_BX
        mov [bp-9], al
        mov byte [bp-8], 1
        mov si, F_BP
.l:     push es
        mov es, F_ES
        mov al, [es:si]
        inc si
        test byte F_AX, 2
        jz .c
        mov ah, [es:si]
        inc si
        mov [bp-9], ah
.c:     pop es
        push cx
        push si
        call tty_char
        pop si
        pop cx
        loop .l
        pop dx
        test byte F_AX, 1
        jnz .x
        mov bl, [BD_VPAGE]
        xor bh, bh
        shl bx, 1
        mov [bx+BD_VCURSOR], dx
        call hw_cursor
.x:     jmp v_exit

; write AL at the cursor of the active page and move on. Text: [bp-8] != 0 gives it attribute
; [bp-9]. Graphics: its colour is [bp-9].
tty_char:
        out 0xE9, al                ; a copy for the simulation log
        mov bl, [BD_VPAGE]
        xor bh, bh
        shl bx, 1
        mov dx, [bx+BD_VCURSOR]
        mov bh, [BD_VPAGE]
        cmp al, 0x0D
        jne .1
        mov dl, 0
        jmp .store
.1:     cmp al, 0x0A
        jne .2
        inc dh
        jmp .chk
.2:     cmp al, 0x08
        jne .3
        or dl, dl
        jz .store
        dec dl
        jmp .store
.3:     cmp al, 0x07
        je .ret
        cmp byte [BD_VMODE], 4
        jb .t
        mov bl, [bp-9]
        call gfx_glyph
        jmp .adv
.t:     call cell_addr
        cmp byte [bp-8], 0
        je .keep
        mov ah, [bp-9]
        stosw
        jmp .adv
.keep:  stosb
.adv:   inc dl
        cmp dl, [BD_VCOLS]
        jb .store
        mov dl, 0
        inc dh
.chk:   cmp dh, 25
        jb .store
        mov dh, 24
        cmp byte [BD_VMODE], 4
        jb .ts
        push dx
        mov al, 1
        xor bx, bx
        xor cx, cx
        mov dl, [BD_VCOLS]
        dec dl
        call gfx_scroll
        pop dx
        jmp .store
.ts:    call cell_addr
        mov ah, [es:di+1]           ; the new line takes the attribute found there
        push dx
        xor dx, dx
        call cell_addr              ; start of the page
        mov cx, [BD_VCOLS]
        mov si, cx
        shl si, 1
        add si, di
        imul cx, cx, 24
        push ds
        push es
        pop ds
        rep movsw
        pop ds
        mov al, ' '
        mov cx, [BD_VCOLS]
        rep stosw
        pop dx
.store: mov bl, [BD_VPAGE]
        xor bh, bh
        shl bx, 1
        mov [bx+BD_VCURSOR], dx
        call hw_cursor
.ret:   ret

vga_palette:
%include "bios/vgapal.inc"
font8x8: incbin "fonts/vga8x8.bin"
