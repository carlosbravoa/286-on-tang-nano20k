; A boot sector that uses the Sound Blaster the way a game does: reset (AA), version (0201),
; then plays 2000 bytes of a sawtooth through DMA channel 1 and waits for the interrupt.
; Prints: AA 02 01, then I when the interrupt came, then the DMA count left (FFFF = all done).
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov dx, 0x226               ; reset
        mov al, 1
        out dx, al
        mov cx, 100
.d:     loop .d
        xor al, al
        out dx, al
        call rd
        call hex
        mov al, 0xE1                ; version
        call wr
        call rd
        call hex
        call rd
        call hex
        mov ax, 0x2000              ; the sound: at 2000:0
        mov es, ax
        xor di, di
        mov cx, 2000
.fill:  mov al, cl
        shl al, 3
        stosb
        loop .fill
        cli
        mov word [0x0F*4], isr      ; IRQ 7
        mov [0x0F*4+2], cs
        in al, 0x21
        and al, 0x7F
        out 0x21, al
        sti
        mov al, 5                   ; DMA channel 1: masked, single, read from memory
        out 0x0A, al
        xor al, al
        out 0x0C, al
        mov al, 0x49
        out 0x0B, al
        xor al, al                  ; address 20000h
        out 0x02, al
        out 0x02, al
        mov al, 2
        out 0x83, al
        mov al, (2000-1) & 0xFF
        out 0x03, al
        mov al, (2000-1) >> 8
        out 0x03, al
        mov al, 1
        out 0x0A, al
        mov al, 0xD1                ; speaker on
        call wr
        mov al, 0x40                ; 22050 Hz
        call wr
        mov al, 211
        call wr
        mov al, 0x14                ; play 2000 bytes
        call wr
        mov al, (2000-1) & 0xFF
        call wr
        mov al, (2000-1) >> 8
        call wr
.wait:  cmp byte [got], 0
        je .wait
        mov al, 'I'
        call putc
        mov al, ' '
        call putc
        out 0x0C, al
        in al, 0x03
        mov ah, al
        in al, 0x03
        push ax
        call hex
        pop ax
        mov al, ah
        call hex
.halt:  hlt
        jmp .halt
isr:    push ax
        push dx
        mov dx, 0x22E
        in al, dx
        mov byte [cs:got], 1
        mov al, 0x20
        out 0x20, al
        pop dx
        pop ax
        iret
wr:     push ax                     ; a byte to the DSP
        mov dx, 0x22C
.w:     in al, dx
        test al, 0x80
        jnz .w
        pop ax
        out dx, al
        ret
rd:     mov dx, 0x22E               ; a byte from the DSP
.w:     in al, dx
        test al, 0x80
        jz .w
        mov dx, 0x22A
        in al, dx
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
got:    db 0
