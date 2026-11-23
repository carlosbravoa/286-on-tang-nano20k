; A boot sector that looks for an AdLib card the way programs do, then plays a note.
; Prints the two status values: 00 and C0 mean the card is there.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov ax, 0x6004              ; reset both timers
        call opl
        mov ax, 0x8004              ; and their flags
        call opl
        mov dx, 0x388
        in al, dx
        and al, 0xE0
        call hex
        mov ax, 0xFF02              ; timer 1: as short as it goes
        call opl
        mov ax, 0x2104              ; start it
        call opl
        mov cx, 2000
.w:     in al, 0x61                 ; a little longer than 80 microseconds
        loop .w
        mov dx, 0x388
        in al, dx
        and al, 0xE0
        call hex
        mov ax, 0x6004
        call opl
        mov ax, 0x8004
        call opl
        mov si, note                ; a note on channel 0
.n:     lodsw
        or ax, ax
        jz .stop
        call opl
        jmp .n
.stop:  hlt
        jmp .stop

opl:    mov dx, 0x388               ; register AL = AH
        out dx, al
        mov cx, 6
.d1:    in al, dx
        loop .d1
        inc dx
        mov al, ah
        out dx, al
        dec dx
        mov cx, 35
.d2:    in al, dx
        loop .d2
        ret
hex:    push ax
        shr al, 4
        call .n
        pop ax
        call .n
        mov al, ' '
        jmp putc
.n:     and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe putc
        add al, 7
putc:   mov ah, 0x0E
        mov bx, 7
        int 0x10
        ret
note:   dw 0x0120, 0x1040, 0xF060, 0x7780, 0x01A0   ; modulator
        dw 0x0123, 0x0043, 0xF063, 0x7783           ; carrier
        dw 0x98A0, 0x31B0                           ; pitch, key on
        dw 0
