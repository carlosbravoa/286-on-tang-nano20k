; BIOS of the 286 machine on the Tang Nano 20K. 16 KB ROM at F000:C000.
; Written for this machine: the disk is an SD card on an SPI port, the keyboard controller
; delivers set 1 scancodes, video is CGA-style text at B800.
;
; SD card layout:  sector 0        partition table of the hard disk (drive 80h is the whole card)
;                  sector 64...    one floppy image (drive 00h), if a boot sector is there
bits 16
cpu 286
org 0xC000

SPI_DATA        equ 0xE0
SPI_CTRL        equ 0xE1
SPI_CS          equ 1
SPI_SLOW        equ 2
SPI_AUTO        equ 4
FLOPPY_LBA      equ 64
EBDA_SEG        equ 0x9FC0          ; the last kilobyte of the 640 KB

; BIOS data area (segment 40h)
BD_EBDA         equ 0x0E
BD_EQUIP        equ 0x10
BD_MEMSIZE      equ 0x13
BD_KFLAGS       equ 0x17            ; 0 RShift 1 LShift 2 Ctrl 3 Alt 4 Scroll 5 Num 6 Caps 7 Ins
BD_KFLAGS2      equ 0x18            ; 0 LCtrl 1 LAlt 4 Scroll held 5 Num held 6 Caps held 7 Ins held
BD_KHEAD        equ 0x1A
BD_KTAIL        equ 0x1C
BD_KBUF         equ 0x1E
BD_FDSTATUS     equ 0x41
BD_VMODE        equ 0x49
BD_VCOLS        equ 0x4A
BD_VPAGESIZE    equ 0x4C
BD_VPAGESTART   equ 0x4E
BD_VCURSOR      equ 0x50            ; 8 words: column, row of each page
BD_VCURTYPE     equ 0x60
BD_VPAGE        equ 0x62
BD_VCRTC        equ 0x63
BD_VMODEREG     equ 0x65
BD_VPALETTE     equ 0x66
BD_TICKS        equ 0x6C
BD_MIDNIGHT     equ 0x70
BD_BREAK        equ 0x71
BD_RESETFLAG    equ 0x72
BD_HDSTATUS     equ 0x74
BD_HDCOUNT      equ 0x75
BD_KBUFSTART    equ 0x80
BD_KBUFEND      equ 0x82
BD_VROWS        equ 0x84
BD_VCHARH       equ 0x85
BD_KFLAGS3      equ 0x96            ; 0 E1 seen 1 E0 seen 2 RCtrl 3 RAlt 4 101-key keyboard

; our own data, in the EBDA
struc DRV
    .present    resb 1
    .spt        resb 1
    .heads      resb 1
    .type       resb 1              ; floppy type for INT 13h AH=08h
    .cyls       resw 1
    .base       resd 1              ; first sector on the card
    .total      resd 1              ; sectors
endstruc
E_SDHC          equ 0x10            ; 1 = the card is addressed in sectors
E_SDOK          equ 0x11
E_FLOPPY        equ 0x20
E_HD            equ 0x30
E_HDPARM        equ 0x40            ; the table INT 41h points to

; ───────────────────────────── reset ─────────────────────────────
cmos_table:                         ; register, value; ends with FFh
        db 0x0A, 0x26, 0x0B, 0x02, 0x0C, 0x00, 0x0D, 0x80, 0x0E, 0x00
        db 0x10, 0x40               ; drive A: 1.44 MB
        db 0x12, 0xF0, 0x14, 0x21, 0x19, 0x2F
        db 0x15, 0x80, 0x16, 0x02   ; 640 KB
        db 0x17, 0x00, 0x18, 0x1B   ; 6912 KB above 1 MB
        db 0x30, 0x00, 0x31, 0x1B
        db 0x32, 0x19               ; century
        db 0xFF
post:   cli
        cld
        mov ax, 0x0030
        mov ss, ax
        mov sp, 0x0100
        ; Was the CPU reset by a program to come back from protected mode? Then CMOS byte 0Fh
        ; says so: 05h or 0Ah = go on at the address in 0040:0067 (05h: after an end-of-interrupt).
        mov al, 0x0F
        out 0x70, al
        in al, 0x71
        or al, al
        jz .cold
        mov ah, al
        mov al, 0x0F
        out 0x70, al
        xor al, al
        out 0x71, al
        cmp ah, 0x0A
        je .back
        cmp ah, 0x05
        jne .cold
        mov al, 0x20
        out 0x20, al
.back:  mov ax, 0x0040
        mov ds, ax
        jmp far [0x0067]
.cold:  mov si, cmos_table           ; what programs look up in the CMOS memory
.cm:    mov al, [cs:si]
        cmp al, 0xFF
        je .cmd
        out 0x70, al
        mov al, [cs:si+1]
        out 0x71, al
        add si, 2
        jmp .cm
.cmd:
        mov cx, 4                   ; the memory window: off
.win:   mov al, cl
        dec al
        out 0xEC, al
        xor al, al
        out 0xEE, al
        loop .win
        mov al, 2                   ; The SDRAM keeps what it had through a reset. A DOS that was
        out 0x92, al                ; loaded high leaves the mark "VDISK" at the start of the
        mov ax, 0xFFFF              ; memory above 1 MB, and the XMS driver of the next boot
        mov es, ax                  ; refuses to start when it finds it: wipe it.
        mov di, 0x0010
        xor ax, ax
        mov cx, 16
        cld
        rep stosw
        out 0x92, al
        ; interrupt controllers: IRQ0-7 at 08h, IRQ8-15 at 70h
        mov al, 0x11
        out 0x20, al
        out 0xA0, al
        mov al, 0x08
        out 0x21, al
        mov al, 0x70
        out 0xA1, al
        mov al, 0x04
        out 0x21, al
        mov al, 0x02
        out 0xA1, al
        mov al, 0x01
        out 0x21, al
        out 0xA1, al
        mov al, 0xF8                ; timer, keyboard, cascade
        out 0x21, al
        mov al, 0xEF                ; mouse
        out 0xA1, al
        ; timer 0: 18.2 Hz
        mov al, 0x36
        out 0x43, al
        xor al, al
        out 0x40, al
        out 0x40, al
        out 0x61, al                ; speaker off
        ; vectors and the BIOS data area
        xor ax, ax
        mov es, ax
        mov ds, ax
        xor di, di
        mov cx, 256
.vec:   mov ax, int_dummy
        stosw
        mov ax, cs
        stosw
        loop .vec
        xor ax, ax
        mov cx, 0x80                ; 0400-04FF
        rep stosw
        mov si, vector_table
.set:   cs lodsb
        or al, al
        jz .setdone
        xor ah, ah
        shl ax, 2
        mov di, ax
        cs lodsw
        stosw
        jmp .set
.setdone:
        mov ax, EBDA_SEG
        mov es, ax
        xor di, di
        xor ax, ax
        mov cx, 0x200
        rep stosw                   ; clear the EBDA
        mov word [es:0], 1          ; its size in KB
        push es
        pop ds
        call mouse_reset
        mov ax, 0x40
        mov ds, ax
        mov word [BD_EBDA], EBDA_SEG
        mov word [BD_MEMSIZE], 639
        mov word [BD_EQUIP], 0x0024 ; 80x25 colour, a mouse
        mov word [BD_KHEAD], BD_KBUF
        mov word [BD_KTAIL], BD_KBUF
        mov word [BD_KBUFSTART], BD_KBUF
        mov word [BD_KBUFEND], BD_KBUF + 32
        mov byte [BD_KFLAGS3], 0x10
        mov ax, 0x0003
        int 0x10
        sti
        mov si, msg_banner
        call puts
        call speed
        call sd_init
        call drives_init
        int 0x19

; Say how fast the machine is: turns of a small loop (its code, a memory read, a memory
; write) in two ticks of the timer (110 ms), divided by 8. To compare one build with another.
speed:  push ds
        mov ax, 0x40
        mov ds, ax
        xor cx, cx
        mov ax, [BD_TICKS]
.w:     cmp ax, [BD_TICKS]
        je .w
        mov ax, [BD_TICKS]
        add ax, 2
        xor dx, dx
.l:     add cx, 1
        adc dx, 0
        mov [0xF0], cx
        cmp ax, [BD_TICKS]
        jne .l
        pop ds
        mov si, msg_speed
        call puts
        mov ax, cx                  ; shown: turns / 8
        mov cx, 3
.s:     shr dx, 1
        rcr ax, 1
        loop .s
        xor cx, cx
        mov bx, 10
.d:     xor dx, dx
        div bx
        push dx
        inc cx
        or ax, ax
        jnz .d
.p:     pop ax
        add al, '0'
        mov ah, 0x0E
        mov bx, 7
        int 0x10
        loop .p
        mov si, msg_crlf
        jmp puts

; ───────────────────────────── boot ─────────────────────────────
int19:  sti
        xor ax, ax
        mov ds, ax
        mov es, ax
        xor dx, dx                  ; the floppy first
        call .try
        mov dl, 0x80
        call .try
        int 0x18
.try:   mov ax, 0x0201
        mov bx, 0x7C00
        mov cx, 0x0001
        mov dh, 0
        push dx
        int 0x13
        pop dx
        jc .no
        cmp word [0x7DFE], 0xAA55
        jne .no
        mov si, msg_boot_a
        or dl, dl
        jz .go
        mov si, msg_boot_c
.go:    call puts
        jmp 0x0000:0x7C00
.no:    ret

int18:  mov si, msg_noboot
        call puts
        xor ax, ax
        int 0x16
        int 0x19

; ───────────────────────────── small things ─────────────────────────────
puts:   cs lodsb                    ; CS:SI, zero terminated
        or al, al
        jz .done
        mov ah, 0x0E
        mov bx, 0x0007
        int 0x10
        jmp puts
.done:  ret

int_hw_dummy:                       ; an interrupt nobody handles: acknowledge it
        push ax
        mov al, 0x20
        out 0x20, al
        pop ax
int_dummy:
        iret

int06:  push bp                     ; invalid opcode: say where and stop
        mov bp, sp
        mov al, '#'
        out 0xE9, al
        mov al, 'U'
        out 0xE9, al
        mov ax, [bp+4]
        call dbg_hex
        mov ax, [bp+2]
        call dbg_hex
.stop:  hlt
        jmp .stop
dbg_hex:
        mov cx, 4
.d:     rol ax, 4
        push ax
        and al, 0x0F
        add al, '0'
        cmp al, '9'
        jbe .p
        add al, 7
.p:     out 0xE9, al
        pop ax
        loop .d
        mov al, ' '
        out 0xE9, al
        ret

int11:  push ds
        mov ax, 0x40
        mov ds, ax
        mov ax, [BD_EQUIP]
        pop ds
        iret
int12:  push ds
        mov ax, 0x40
        mov ds, ax
        mov ax, [BD_MEMSIZE]
        pop ds
        iret
int14:  mov ah, 0x80                ; no serial ports
        iret
int17:  mov ah, 0x01                ; no printer
        iret

; ───────────────────────────── INT 08h: timer tick ─────────────────────────────
int08:  push ax
        push ds
        mov ax, 0x40
        mov ds, ax
        add word [BD_TICKS], 1
        adc word [BD_TICKS+2], 0
        cmp word [BD_TICKS+2], 0x18
        jne .n
        cmp word [BD_TICKS], 0xB0
        jne .n
        mov word [BD_TICKS], 0
        mov word [BD_TICKS+2], 0
        mov byte [BD_MIDNIGHT], 1
.n:     int 0x1C
        mov al, 0x20
        out 0x20, al
        pop ds
        pop ax
        iret

; ───────────────────────────── INT 1Ah: time ─────────────────────────────
int1a:  sti
        push ds
        push ax
        mov ax, 0x40
        mov ds, ax
        pop ax
        or ah, ah
        jz .get
        cmp ah, 1
        je .set
        pop ds
        stc                         ; no real-time clock
        retf 2
.get:   cli
        mov cx, [BD_TICKS+2]
        mov dx, [BD_TICKS]
        mov al, [BD_MIDNIGHT]
        mov byte [BD_MIDNIGHT], 0
        sti
        pop ds
        iret
.set:   cli
        mov [BD_TICKS+2], cx
        mov [BD_TICKS], dx
        mov byte [BD_MIDNIGHT], 0
        sti
        pop ds
        iret

; ───────────────────────────── INT 15h: system ─────────────────────────────
int15:  sti
        cmp ah, 0x4F                ; keyboard intercept: carry on with the key
        je .cy
        cmp ax, 0xC2FF              ; ours: put the mouse driver's vectors back (DOS takes them)
        je .mouse
        cmp ah, 0x88
        je .ext
        cmp ah, 0x87
        je int15_move
        cmp ah, 0x90
        je .ok
        cmp ah, 0x91
        je .ok
        cmp ah, 0x86
        je .wait
        cmp ah, 0x24
        je .a20
        cmp ah, 0xC1
        je .ebda
        mov ah, 0x86                ; not supported
.cy:    stc
        retf 2
.ext:   mov ax, 6912                ; extended memory: 8 MB less the first, less the EGA planes (top 256 KB)
.okax:  clc
        retf 2
.ok:    xor ah, ah
        clc
        retf 2
.mouse: push ds
        push ax
        xor ax, ax
        mov ds, ax
        cli
        mov word [0x33*4], int33
        mov [0x33*4+2], cs
        mov word [0x74*4], int74
        mov [0x74*4+2], cs
        in al, 0xA1                 ; IRQ 12 open
        and al, 0xEF
        out 0xA1, al
        in al, 0x21                 ; and the second interrupt controller's line
        and al, 0xFB
        out 0x21, al
        sti
        pop ax
        pop ds
        jmp .ok
.ebda:  mov ax, EBDA_SEG
        mov es, ax
        jmp .ok
.wait:  push cx                     ; CX:DX microseconds, to the nearest timer tick (55 ms)
        push dx
        push ds
        mov ax, 0x40
        mov ds, ax
        mov ax, cx                  ; ticks = CX * 1.19 + 1
        shr cx, 2
        add ax, cx
        inc ax
        add ax, [BD_TICKS]
.w:     hlt
        cmp ax, [BD_TICKS]
        jne .w
        pop ds
        pop dx
        pop cx
        jmp .ok
.a20:   cmp al, 1
        ja .a20q
        push ax
        shl al, 1
        out 0x92, al
        pop ax
        jmp .ok
.a20q:  cmp al, 2
        jne .a20s
        in al, 0x92
        shr al, 1
        and al, 1
        jmp .ok
.a20s:  mov bx, 3                   ; AL=3: both methods work
        jmp .ok

; AH = 87h: copy CX words between any two places of memory. ES:SI = a table with the
; source address at +12h (24 bits) and the destination at +1Ah. No protected mode: the two
; places are shown in the window at D0000 (source in its first half, destination in the
; second), 16 KB at a time. The window is left as it was.
int15_move:
        cli
        cld
        pusha
        push ds
        push es
        mov bp, sp
        xor bx, bx
.sv:    mov al, bl
        out 0xEC, al
        in al, 0xEE
        mov ah, al
        in al, 0xED
        push ax                     ; bp-2..-8: the window
        inc bx
        cmp bx, 4
        jb .sv
        push word [es:si+0x12]      ; bp-10, -12: source
        mov al, [es:si+0x14]
        xor ah, ah
        push ax
        push word [es:si+0x1A]      ; bp-14, -16: destination
        mov al, [es:si+0x1C]
        push ax
        push cx                     ; bp-18: words left
        mov ax, 0xD000
        mov ds, ax
        mov es, ax
.chunk: cmp word [bp-18], 0
        je .done
        mov ax, [bp-10]
        mov dx, [bp-12]
        xor bl, bl
        call .map2
        mov si, ax
        mov ax, [bp-14]
        mov dx, [bp-16]
        mov bl, 2
        call .map2
        mov di, ax
        or di, 0x8000
        mov cx, [bp-18]
        cmp cx, 0x2000
        jbe .n
        mov cx, 0x2000
.n:     sub [bp-18], cx
        mov ax, cx
        shl ax, 1
        add [bp-10], ax
        adc word [bp-12], 0
        add [bp-14], ax
        adc word [bp-16], 0
        rep movsw
        jmp .chunk
.done:  add sp, 10
        mov bx, 3
.rs:    mov al, bl
        out 0xEC, al
        pop ax
        out 0xED, al
        mov al, ah
        out 0xEE, al
        dec bx
        jns .rs
        pop es
        pop ds
        popa
        sti
        xor ah, ah
        retf 2
; show the 16 KB page of address DX:AX and the next one in quarters BL and BL+1 of the
; window; AX = where the address is in the first
.map2:  push cx
        mov cx, ax
        and cx, 0x3FFF
        shl ax, 1
        rcl dx, 1
        shl ax, 1
        rcl dx, 1
        call .map1
        inc bl
        inc dx
        call .map1
        mov ax, cx
        pop cx
        ret
.map1:  mov al, bl
        out 0xEC, al
        mov al, dl
        out 0xED, al
        mov al, dh
        and al, 1
        or al, 0x80
        out 0xEE, al
        ret

%include "bios/video.asm"
%include "bios/mouse.asm"
%include "bios/keyboard.asm"
%include "bios/disk.asm"

; ───────────────────────────── tables ─────────────────────────────
vector_table:                       ; vector, handler
%macro VEC 2
        db %1
        dw %2
%endmacro
        VEC 0x06, int06
        VEC 0x08, int08
        VEC 0x09, int09
        VEC 0x0A, int_hw_dummy
        VEC 0x0B, int_hw_dummy
        VEC 0x0C, int_hw_dummy
        VEC 0x0D, int_hw_dummy
        VEC 0x0E, int_hw_dummy
        VEC 0x0F, int_hw_dummy
        VEC 0x10, int10
        VEC 0x11, int11
        VEC 0x12, int12
        VEC 0x13, int13
        VEC 0x14, int14
        VEC 0x15, int15
        VEC 0x16, int16
        VEC 0x17, int17
        VEC 0x18, int18
        VEC 0x19, int19
        VEC 0x1A, int1a
        VEC 0x1D, video_parms
        VEC 0x33, int33
        VEC 0x74, int74
        VEC 0x1F, font8x8+1024
        VEC 0x43, font8x8
        VEC 0x1E, diskette_parms
        db 0

video_parms:    times 16 db 0
diskette_parms: db 0xDF, 0x02, 0x25, 0x02, 0x12, 0x1B, 0xFF, 0x6C, 0xF6, 0x0F, 0x08

msg_banner:     db "286 on Tang Nano 20K - BIOS 0.1", 13, 10
                db "640 KB base memory", 13, 10, 0
msg_speed:      db "Speed ", 0
msg_crlf:       db 13, 10, 0
msg_boot_a:     db "Booting from A:", 13, 10, 0
msg_boot_c:     db "Booting from C:", 13, 10, 0
msg_noboot:     db "No boot disk. Insert a card and press a key.", 13, 10, 0

; ───────────────────────────── fixed places ─────────────────────────────
        times 0xFA6E-0xC000-($-$$) db 0xFF
        incbin "fonts/vga8x8.bin", 0, 1024      ; FFA6E: characters 0-127, 8x8, where programs look for them
        times 0xFFF0-0xC000-($-$$) db 0xFF
        jmp 0xF000:post             ; FFFF0: reset
        db "11/23/26"               ; FFFF5: date
        db 0xFF
        db 0xFC                     ; FFFFE: model (AT)
        db 0x00
