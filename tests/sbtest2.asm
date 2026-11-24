; A boot sector that plays sounds the way SkyRoads does: no interrupt, DMA channel 1 in
; auto-init mode (59h) with single-block play (14h), "pause" (D0h) before every sound.
; Three sounds one after another with rates 131, 6 and 131; after each it waits and prints
; the DMA address reached (low word). Each must have moved on from 0000.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov dx, 0x226
        mov al, 1
        out dx, al
        mov cx, 100
.d:     loop .d
        xor al, al
        out dx, al
        mov cx, 1000
.d2:    loop .d2
        mov dx, 0x22A
        in al, dx
        call hex
        mov al, 0xD1
        call wr
        mov bl, 131
        call play
        mov bl, 6
        call play
        mov bl, 131
        call play
.halt:  hlt
        jmp .halt
play:   mov al, 0xD0                ; stop what plays
        call wr
        mov al, 5
        out 0x0A, al
        mov al, 5                   ; then as the game does
        out 0x0A, al
        mov al, 0x59
        out 0x0B, al
        xor al, al
        out 0x0C, al
        out 0x02, al
        out 0x02, al
        mov al, (3000-1) & 0xFF
        out 0x03, al
        mov al, (3000-1) >> 8
        out 0x03, al
        mov al, 2
        out 0x83, al
        mov al, 1
        out 0x0A, al
        mov al, 0x40
        call wr
        mov al, bl
        call wr
        mov al, 0x14
        call wr
        mov al, (3000-1) & 0xFF
        call wr
        mov al, (3000-1) >> 8
        call wr
        mov cx, 0
.w:     loop .w                     ; some tens of milliseconds
        out 0x0C, al
        in al, 0x02
        mov ah, al
        in al, 0x02
        push ax
        call hex
        pop ax
        mov al, ah
        call hex
        mov al, ' '
        jmp putc
wr:     push ax
        mov dx, 0x22C
.w:     in al, dx
        shl al, 1
        jc .w
        pop ax
        out dx, al
        ret
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
