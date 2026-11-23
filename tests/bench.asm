; A boot sector that works the way a mode 13h game does, a fixed number of frames, then says
; DONE on the debug port: clear the picture, draw 40 sprites with transparency from a far
; buffer, some arithmetic through calls. The simulator's cycle count at DONE is the result.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ax, 0x0013
        int 0x10
        mov ax, 0x3000              ; sprite data: a pattern with holes at 3000:0
        mov es, ax
        xor di, di
        mov cx, 0x4000
.mk:    mov al, cl
        and al, 0x1F
        stosb
        loop .mk
        mov word [frames], 40
frame:  mov ax, 0xA000
        mov es, ax
        xor di, di
        mov ax, 0x0101
        mov cx, 32000
        rep stosw                   ; clear
        mov bp, 40                  ; sprites
.spr:   mov ax, bp
        call place                  ; di = where
        push ds
        mov ax, 0x3000
        mov ds, ax
        mov si, bp
        shl si, 6
        mov dx, 16                  ; 16 x 16, transparent where 0
.row:   mov cx, 16
.px:    lodsb
        or al, al
        jz .skip
        mov [es:di], al
.skip:  inc di
        loop .px
        add di, 320 - 16
        dec dx
        jnz .row
        pop ds
        dec bp
        jnz .spr
        dec word [frames]
        jnz frame
        mov si, done
.say:   lodsb
        or al, al
        jz .halt
        mov dx, 0xE9
        out dx, al
        jmp .say
.halt:  hlt
        jmp .halt
place:  push bx                     ; di = (ax * 37 mod 180) * 320 + ax * 7
        push dx
        mov bx, ax
        mov cx, 37
        mul cx
        mov cx, 180
        xor dx, dx
        div cx
        mov ax, dx
        mov cx, 320
        mul cx
        mov di, ax
        mov ax, bx
        mov cx, 7
        mul cx
        add di, ax
        pop dx
        pop bx
        ret
frames: dw 0
done:   db 'DONE', 0
