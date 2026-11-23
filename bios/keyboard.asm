; ───────────────────────────── INT 16h: keyboard ─────────────────────────────
int16:  sti
        push ds
        push bx
        mov bx, 0x40
        mov ds, bx
        mov bl, ah
        and bl, 0xEF                ; 10h-12h are 00h-02h for the 101-key keyboard
        jz .get
        dec bl
        jz .peek
        dec bl
        jz .flags
        cmp ah, 0x05
        je .stuff
        pop bx
        pop ds
        iret
.get:   cli
        mov bx, [BD_KHEAD]
        cmp bx, [BD_KTAIL]
        jne .have
        sti
        hlt
        jmp .get
.have:  push ax
        mov ax, [bx]
        add bx, 2
        cmp bx, [BD_KBUFEND]
        jb .nowrap
        mov bx, [BD_KBUFSTART]
.nowrap: mov [BD_KHEAD], bx
        pop bx                      ; the caller's AX: AH tells which function
        sti
        call .old
        pop bx
        pop ds
        iret
.peek:  cli
        mov bx, [BD_KHEAD]
        cmp bx, [BD_KTAIL]
        je .none
        push ax
        mov ax, [bx]
        pop bx
        call .old
        sti
        pop bx
        pop ds
        push bp
        mov bp, sp
        and byte [bp+6], 0xBF       ; ZF = 0: a key is waiting
        pop bp
        iret
.none:  sti
        pop bx
        pop ds
        push bp
        mov bp, sp
        or byte [bp+6], 0x40        ; ZF = 1
        pop bp
        iret
.flags: mov al, [BD_KFLAGS]
        test ah, 0x10
        jz .f1
        mov ah, [BD_KFLAGS2]
.f1:    pop bx
        pop ds
        iret
.stuff: push ax
        mov ax, cx
        call key_put
        pop ax
        mov al, 0
        jnc .s1
        mov al, 1
.s1:    pop bx
        pop ds
        iret
; the old functions (BH = 00h/01h) do not know the E0 marker
.old:   test bh, 0x10
        jnz .o2
        cmp al, 0xE0
        jne .o1
        or ah, ah
        jz .o1
        xor al, al
.o1:    cmp ah, 0xE0                ; keypad Enter and /
        jne .o2
        mov ah, 0x1C
        cmp al, 0x0D
        je .o2
        mov ah, 0x35
.o2:    ret

; put AX in the keyboard buffer; carry if it is full. DS = 40h.
key_put:
        push bx
        push si
        mov bx, [BD_KTAIL]
        mov si, bx
        add bx, 2
        cmp bx, [BD_KBUFEND]
        jb .1
        mov bx, [BD_KBUFSTART]
.1:     cmp bx, [BD_KHEAD]
        stc
        je .full
        mov [si], ax
        mov [BD_KTAIL], bx
        clc
.full:  pop si
        pop bx
        ret

; ───────────────────────────── INT 09h: a scancode arrived ─────────────────────────────
int09:  push ax
        push bx
        push cx
        push dx
        push ds
        mov ax, 0x40
        mov ds, ax
        in al, 0x60
        mov ah, 0x4F                ; let a program look at it first
        stc
        int 0x15
        jnc k_done
        cmp al, 0xE0
        jne .1
        or byte [BD_KFLAGS3], 2
        jmp k_eoi
.1:     cmp al, 0xE1
        jne .2
        or byte [BD_KFLAGS3], 1
        jmp k_eoi
.2:     mov bl, al
        and bl, 0x7F                ; BL = key
        mov bh, [BD_KFLAGS3]
        and bh, 2                   ; BH = 2: it came after E0
        ; shift keys
        mov cx, 0x0200              ; CH = bit in KFLAGS, CL = bit in KFLAGS2, DL = bit in KFLAGS3
        xor dl, dl
        cmp bl, 0x2A
        je .shift
        mov ch, 0x01
        cmp bl, 0x36
        je .shift
        mov cx, 0x0401
        cmp bl, 0x1D
        je .ctlalt
        mov cx, 0x0802
        cmp bl, 0x38
        je .ctlalt
        mov cx, 0x4040
        cmp bl, 0x3A
        je .toggle
        mov cx, 0x2020
        cmp bl, 0x45
        je .toggle
        mov cx, 0x1010
        cmp bl, 0x46
        je .scroll
        jmp .key
.shift: or bh, bh                   ; E0 2A / E0 36 are fake shifts of the 101-key keyboard
        jnz k_done
        test al, 0x80
        jnz .shoff
        or [BD_KFLAGS], ch
        jmp k_done
.shoff: not ch
        and [BD_KFLAGS], ch
        jmp k_done
.ctlalt:                            ; left and right are kept apart; KFLAGS has "either"
        or bh, bh
        jz .left
        mov dl, cl
        shl dl, 2                   ; RCtrl = 4, RAlt = 8 in KFLAGS3
        xor cl, cl
.left:  test al, 0x80
        jnz .caoff
        or [BD_KFLAGS2], cl
        or [BD_KFLAGS3], dl
        or [BD_KFLAGS], ch
        jmp k_done
.caoff: not cl
        not dl
        and [BD_KFLAGS2], cl
        and [BD_KFLAGS3], dl
        mov al, [BD_KFLAGS2]        ; still held on the other side?
        mov ah, [BD_KFLAGS3]
        shr ah, 2
        or al, ah
        mov ah, ch
        shr ah, 2                   ; 4 -> 1 (Ctrl), 8 -> 2 (Alt)
        test al, ah
        jnz k_done
        not ch
        and [BD_KFLAGS], ch
        jmp k_done
.scroll: or bh, bh                  ; E0 46 is Ctrl-Break
        jz .toggle
        test al, 0x80
        jnz k_done
        mov ax, [BD_KBUFSTART]
        mov [BD_KHEAD], ax
        mov [BD_KTAIL], ax
        mov byte [BD_BREAK], 0x80
        int 0x1B
        xor ax, ax
        call key_put
        jmp k_done
.toggle: test al, 0x80
        jnz .tgoff
        test [BD_KFLAGS2], cl
        jnz k_done                  ; held down: no repeat
        or [BD_KFLAGS2], cl
        xor [BD_KFLAGS], ch
        jmp k_done
.tgoff: not cl
        and [BD_KFLAGS2], cl
        jmp k_done

.key:   test al, 0x80
        jnz k_done                  ; releases of ordinary keys mean nothing here
        cmp bl, 0x58
        ja k_done
        mov dl, [BD_KFLAGS]
        cmp bl, 0x53                ; Ctrl-Alt-Del
        jne .k1
        mov al, dl
        and al, 0x0C
        cmp al, 0x0C
        jne .k1
        mov word [BD_RESETFLAG], 0x1234
        jmp 0xFFFF:0x0000
.k1:    mov ah, bl                  ; AH = scan code, to start with
        xor bh, bh
        mov al, [cs:bx+key_plain]   ; AL = character without shifts
        test dl, 0x08
        jnz .alt
        test dl, 0x04
        jnz .ctrl
        ; function keys
        cmp bl, 0x3B
        jb .k2
        cmp bl, 0x44
        ja .k2
        test dl, 0x03
        jz .put0
        add ah, 0x19                ; Shift-F1..F10: 54h-5Dh
        jmp .put0
.k2:    cmp bl, 0x57
        jb .k3
        add ah, 0x2E                ; F11, F12: 85h, 86h
        test dl, 0x03
        jz .put0
        add ah, 2
        jmp .put0
.k3:    cmp bl, 0x47                ; keypad / cursor block
        jb .k4
        cmp bl, 0x53
        ja .k5
        test byte [BD_KFLAGS3], 2
        jz .pad
        mov al, 0xE0                ; the grey keys
        jmp .put
.pad:   cmp bl, 0x4A                ; - and + are always characters
        je .put
        cmp bl, 0x4E
        je .put
        mov cl, dl                  ; digits if NumLock xor Shift
        shr cl, 5
        and cl, 1
        test dl, 0x03
        jz .pad1
        xor cl, 1
.pad1:  or cl, cl
        jnz .put
        cmp bl, 0x52                ; Ins: the flag in KFLAGS
        jne .put0
        xor byte [BD_KFLAGS], 0x80
        jmp .put0
.k4:    test byte [BD_KFLAGS3], 2   ; keypad Enter and / carry E0 in AH
        jz .k5
        mov ah, 0xE0
        jmp .put
.k5:    or al, al
        jz k_done                   ; no character: not a key for the buffer
        xor cl, cl
        test dl, 0x03
        jz .k6
        inc cl
.k6:    cmp al, 'a'
        jb .k7
        cmp al, 'z'
        ja .k7
        test dl, 0x40               ; letters: Caps Lock turns Shift round
        jz .k7
        xor cl, 1
.k7:    or cl, cl
        jz .put
        mov al, [cs:bx+key_shift]
        jmp .put

.ctrl:  cmp al, 'a'
        jb .c1
        cmp al, 'z'
        ja .c1
        and al, 0x1F
        jmp .put
.c1:    push si                     ; look the key up: scan, new scan, character
        mov si, key_ctrl
.c2:    mov cx, [cs:si]
        or cl, cl
        jz .c3
        cmp cl, bl
        je .c4
        add si, 3
        jmp .c2
.c3:    pop si
        jmp .cf
.c4:    mov ah, ch
        mov al, [cs:si+2]
        pop si
        jmp .put
.cf:    cmp bl, 0x3B                ; Ctrl-F1..F10: 5Eh-67h
        jb k_done
        cmp bl, 0x44
        ja .cf2
        add ah, 0x23
        jmp .put0
.cf2:   cmp bl, 0x57
        jb k_done
        add ah, 0x32                ; Ctrl-F11, F12: 89h, 8Ah
        jmp .put0

.alt:   cmp bl, 0x39
        jne .a1
        mov al, ' '
        jmp .put
.a1:    cmp bl, 0x02                ; Alt-1 .. Alt-=: 78h-83h
        jb k_done
        cmp bl, 0x0D
        ja .a2
        add ah, 0x76
        jmp .put0
.a2:    cmp bl, 0x3B
        jb .a4
        cmp bl, 0x44
        ja .a3
        add ah, 0x2D                ; Alt-F1..F10: 68h-71h
        jmp .put0
.a3:    cmp bl, 0x57
        jb .a5
        add ah, 0x34                ; Alt-F11, F12: 8Bh, 8Ch
        jmp .put0
.a4:    or al, al                   ; letters and signs: the scan code alone
        jz k_done
        jmp .put0
.a5:    test byte [BD_KFLAGS3], 2   ; Alt with the grey cursor keys: 97h-A3h
        jz k_done
        add ah, 0x50
.put0:  xor al, al
.put:   call key_put
k_done: and byte [BD_KFLAGS3], 0xFC
k_eoi:  mov al, 0x20
        out 0x20, al
        pop ds
        pop dx
        pop cx
        pop bx
        pop ax
        iret

; characters of scan codes 00h-58h, without and with Shift
key_plain:
        db 0, 27, "1234567890-=", 8, 9
        db "qwertyuiop[]", 13, 0, "as"
        db "dfghjkl;'`", 0, "\zxcv"
        db "bnm,./", 0, "*", 0, " ", 0, 0, 0, 0, 0, 0
        db 0, 0, 0, 0, 0, 0, 0, "789-456+1"
        db "230.", 0, 0, "\", 0, 0
key_shift:
        db 0, 27, "!@#$%^&*()_+", 8, 0
        db "QWERTYUIOP{}", 13, 0, "AS"
        db 'DFGHJKL:"~', 0, "|ZXCV"
        db "BNM<>?", 0, "*", 0, " ", 0, 0, 0, 0, 0, 0
        db 0, 0, 0, 0, 0, 0, 0, "789-456+1"
        db "230.", 0, 0, "|", 0, 0
; with Ctrl: scan, scan to report, character
key_ctrl:
        db 0x01, 0x01, 0x1B,  0x03, 0x03, 0x00,  0x07, 0x07, 0x1E,  0x0C, 0x0C, 0x1F
        db 0x0E, 0x0E, 0x7F,  0x0F, 0x94, 0x00,  0x1A, 0x1A, 0x1B,  0x1B, 0x1B, 0x1D
        db 0x1C, 0x1C, 0x0A,  0x2B, 0x2B, 0x1C,  0x39, 0x39, 0x20
        db 0x47, 0x77, 0x00,  0x48, 0x8D, 0x00,  0x49, 0x84, 0x00,  0x4B, 0x73, 0x00
        db 0x4D, 0x74, 0x00,  0x4F, 0x75, 0x00,  0x50, 0x91, 0x00,  0x51, 0x76, 0x00
        db 0x52, 0x92, 0x00,  0x53, 0x93, 0x00
        db 0
