; ───────────────────────────── INT 33h: mouse ─────────────────────────────
; The mouse driver is part of the BIOS. The hardware adds up what the mouse reports and raises
; IRQ 12; reading port E4h gives the buttons and latches the movement for ports E5h (x) and
; E6h (y). Positions are in the usual 640 x 200 grid whatever the video mode.
; The pointer is drawn in text modes only (the cell under it is shown inverted).
struc MS
    .x          resw 1
    .y          resw 1
    .minx       resw 1
    .maxx       resw 1
    .miny       resw 1
    .maxy       resw 1
    .micx       resw 1              ; movement since function 0Bh was last called
    .micy       resw 1
    .mask       resw 1              ; events the program's handler wants
    .hoff       resw 1
    .hseg       resw 1
    .press      resw 9              ; per button: count, x, y
    .rel        resw 9
    .save       resw 1              ; where the pointer was drawn
    .btn        resb 1
    .shown      resb 1              ; 0 = shown, negative = hidden
    .drawn      resb 1
    .yrem       resb 1
endstruc
E_MOUSE         equ 0x60
E_PS2           equ 0xB0            ; INT 15h AH=C2h: the program's handler (offset, segment), then 1 = enabled
%define M(f) [E_MOUSE+MS. %+ f]

int33:  cld
        pusha
        push ds
        push es
        mov bp, sp
        mov si, EBDA_SEG
        mov ds, si
        cmp ax, 0x24
        ja m_exit
        mov si, ax
        shl si, 1
        jmp [cs:si+m_table]
m_exit: pop es
        pop ds
        popa
        iret

m_table: dw m_reset, m_show, m_hide, m_get, m_setpos, m_press, m_release, m_rangex
         dw m_rangey, m_exit, m_exit, m_motion, m_handler, m_exit, m_exit, m_exit
         dw m_exit, m_exit, m_exit, m_exit, m_swap, m_size, m_save, m_restore
         dw m_exit, m_exit, m_exit, m_sens, m_exit, m_exit, m_exit, m_exit
         dw m_exit, m_reset, m_exit, m_exit, m_ver

m_reset:
        call mouse_reset
        mov word F_AX, 0xFFFF
        mov word F_BX, 3
        jmp m_exit

m_show: cmp byte M(shown), 0
        jge m_exit
        inc byte M(shown)
        call mcur_draw
        jmp m_exit

m_hide: call mcur_erase
        cmp byte M(shown), -100
        jl m_exit
        dec byte M(shown)
        jmp m_exit

m_get:  mov al, M(btn)
        xor ah, ah
        mov F_BX, ax
        mov ax, M(x)
        mov F_CX, ax
        mov ax, M(y)
        mov F_DX, ax
        jmp m_exit

m_setpos:
        mov M(x), cx
        mov M(y), dx
m_moved:
        call m_clamp
        call mcur_erase
        call mcur_draw
        jmp m_exit

m_press:
        mov si, E_MOUSE+MS.press
        jmp m_info
m_release:
        mov si, E_MOUSE+MS.rel
m_info: cmp bx, 2
        ja m_exit
        mov ax, bx
        shl bx, 1
        add bx, ax
        shl bx, 1
        add si, bx
        mov al, M(btn)
        xor ah, ah
        mov F_AX, ax
        xor ax, ax
        xchg ax, [si]
        mov F_BX, ax
        mov ax, [si+2]
        mov F_CX, ax
        mov ax, [si+4]
        mov F_DX, ax
        jmp m_exit

m_rangex:
        cmp cx, dx
        jle .o
        xchg cx, dx
.o:     mov M(minx), cx
        mov M(maxx), dx
        jmp m_moved
m_rangey:
        cmp cx, dx
        jle .o
        xchg cx, dx
.o:     mov M(miny), cx
        mov M(maxy), dx
        jmp m_moved

m_motion:
        xor ax, ax
        xchg ax, M(micx)
        mov F_CX, ax
        xor ax, ax
        xchg ax, M(micy)
        mov F_DX, ax
        jmp m_exit

m_swap: mov ax, M(mask)
        mov F_CX, ax
        mov ax, M(hoff)
        mov F_DX, ax
        mov ax, M(hseg)
        mov F_ES, ax
m_handler:
        mov M(mask), cx
        mov M(hoff), dx
        mov M(hseg), es
        jmp m_exit

m_size: mov word F_BX, MS_size
        jmp m_exit

m_save: mov si, E_MOUSE
        mov di, dx
        mov cx, MS_size
        rep movsb
        jmp m_exit

m_restore:
        call mcur_erase
        mov ax, es
        push ds
        pop es
        mov ds, ax
        mov si, dx
        mov di, E_MOUSE
        mov cx, MS_size
        rep movsb
        mov byte [es:E_MOUSE+MS.drawn], 0
        jmp m_exit

m_sens: mov word F_BX, 50
        mov word F_CX, 50
        mov word F_DX, 50
        jmp m_exit

m_ver:  mov word F_BX, 0x0626
        mov word F_CX, 0x0400
        jmp m_exit

; everything as after power-on: the pointer hidden in the middle of the screen. DS = the EBDA
mouse_reset:
        cld
        call mcur_erase
        push es
        push ds
        pop es
        mov di, E_MOUSE
        mov cx, MS_size
        xor al, al
        rep stosb
        pop es
        mov word M(x), 320
        mov word M(y), 100
        mov word M(maxx), 639
        mov word M(maxy), 199
        mov byte M(shown), -1
        ret

m_clamp:
        mov ax, M(x)
        cmp ax, M(minx)
        jge .1
        mov ax, M(minx)
.1:     cmp ax, M(maxx)
        jle .2
        mov ax, M(maxx)
.2:     mov M(x), ax
        mov ax, M(y)
        cmp ax, M(miny)
        jge .3
        mov ax, M(miny)
.3:     cmp ax, M(maxy)
        jle .4
        mov ax, M(maxy)
.4:     mov M(y), ax
        ret

mcur_erase:
        cmp byte M(drawn), 0
        je .x
        push es
        push bx
        mov bx, 0xB800
        mov es, bx
        mov bx, M(save)
        xor byte [es:bx], 0x77
        mov byte M(drawn), 0
        pop bx
        pop es
.x:     ret

mcur_draw:
        cmp byte M(shown), 0
        jne .x
        cmp byte M(drawn), 0
        jne .x
        pusha
        push es
        mov ax, 0x40
        mov es, ax
        cmp byte [es:BD_VMODE], 4
        jae .no
        mov cx, [es:BD_VCOLS]
        mov bx, [es:BD_VPAGESTART]
        mov ax, M(y)
        shr ax, 3
        mul cl
        mov dx, M(x)
        shr dx, 3
        cmp cl, 40
        jne .c
        shr dx, 1
.c:     add ax, dx
        shl ax, 1
        inc ax
        add bx, ax
        mov M(save), bx
        mov ax, 0xB800
        mov es, ax
        xor byte [es:bx], 0x77
        mov byte M(drawn), 1
.no:    pop es
        popa
.x:     ret

; IRQ 12: the mouse moved or a button changed
int74:  cld
        pusha
        push ds
        push es
        mov ax, EBDA_SEG
        mov ds, ax
        in al, 0xE4
        and al, 7
        mov bl, al                  ; BL = the buttons
        in al, 0xE5
        cbw
        mov cx, ax
        in al, 0xE6
        cbw
        mov dx, ax
        mov al, 0x20
        out 0xA0, al
        out 0x20, al
        test byte [E_PS2+4], 1      ; a program that asked through INT 15h AH=C2h (Windows)
        jz .own                     ; gets what a PS/2 mouse sends: status, x, y (up is positive)
        mov ax, [E_PS2]
        or ax, [E_PS2+2]
        jz .own
        and bl, 7
        or bl, 8
        or cx, cx
        jns .xp
        or bl, 0x10
.xp:    neg dx
        jns .yp
        or bl, 0x20
.yp:    xor bh, bh
        xor ch, ch
        xor dh, dh
        push bx
        push cx
        push dx
        push 0
        call far [E_PS2]
        add sp, 8
        jmp .done
.own:   xor di, di                  ; DI = what happened, as the handler's AX
        mov ax, cx
        or ax, dx
        jz .still
        or di, 1
        add M(micx), cx
        add M(micy), dx
        add M(x), cx
        mov al, M(yrem)             ; two units of the mouse make one line
        xor ah, ah
        add dx, ax
        mov al, dl
        and al, 1
        mov M(yrem), al
        sar dx, 1
        add M(y), dx
        call m_clamp
        call mcur_erase
        call mcur_draw
.still: mov al, M(btn)
        mov M(btn), bl
        xor al, bl                  ; AL = buttons that changed, AH = buttons now
        mov ah, bl
        mov si, E_MOUSE+MS.press
        mov dx, 2                   ; this button's "pressed" event; "released" is the next bit
        mov cx, 3
.b:     shr al, 1
        jnc .nb
        mov bx, si
        test ah, 1
        jnz .pr
        add bx, MS.rel-MS.press
        shl dx, 1
        or di, dx
        shr dx, 1
        jmp .rec
.pr:    or di, dx
.rec:   inc word [bx]
        push ax
        mov ax, M(x)
        mov [bx+2], ax
        mov ax, M(y)
        mov [bx+4], ax
        pop ax
.nb:    shr ah, 1
        add si, 6
        shl dx, 2
        loop .b
        mov ax, di
        and ax, M(mask)
        jz .done
        mov bl, M(btn)
        xor bh, bh
        mov cx, M(x)
        mov dx, M(y)
        mov si, M(micx)
        mov di, M(micy)
        call far [E_MOUSE+MS.hoff]
.done:  pop es
        pop ds
        popa
        iret

; ── INT 15h AH=C2h: the BIOS interface of a PS/2 mouse (AL = function), from int15 ──
int15_ps2:
        push ds
        push ax
        mov ax, EBDA_SEG
        mov ds, ax
        pop ax
        cmp al, 7
        ja .bad
        je .f7
        or al, al
        jz .f0
        cmp al, 1
        je .f1
        cmp al, 5
        je .f5
        cmp al, 4
        je .f4
        cmp al, 6
        jne .ok                     ; 2 rate, 3 resolution: nothing to do
        or bh, bh
        jnz .ok
        mov bl, [E_PS2+4]           ; status: bit 5 = enabled
        shl bl, 5
        mov cl, 2
        mov dl, 100
        jmp .ok
.f0:    and bh, 1                   ; BH = 1: on
        mov [E_PS2+4], bh
        jz .ok
        push ax
        push ds
        xor ax, ax
        mov ds, ax
        cli
        mov word [0x74*4], int74
        mov [0x74*4+2], cs
        in al, 0xA1                 ; IRQ 12 open, and the second controller's line
        and al, 0xEF
        out 0xA1, al
        in al, 0x21
        and al, 0xFB
        out 0x21, al
        pop ds
        pop ax
        jmp .ok
.f1:    mov bx, 0x00AA              ; reset: "passed", device 0
.f5:    mov byte [E_PS2+4], 0
        jmp .ok
.f4:    xor bh, bh                  ; device 0: a plain mouse
        jmp .ok
.f7:    mov [E_PS2], bx
        mov [E_PS2+2], es
.ok:    pop ds
        xor ah, ah
        clc
        sti
        retf 2
.bad:   pop ds
        mov ah, 1
        stc
        retf 2
