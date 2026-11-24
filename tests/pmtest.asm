; A boot sector that goes into protected mode and comes back the way a 286 has to: by a
; CPU reset, with CMOS byte 0Fh = 0Ah and the return address in 0040:0067.
; In protected mode it writes a word at 110000h (above 1 MB) through a descriptor and takes
; a software interrupt through an interrupt gate. Back in real mode it reads the word with
; INT 15h AH=87h. Prints: P (before), then R (back), then the word (BEEF) and the value the
; interrupt handler left (55). With -DFAULT the reset is a triple fault, not the keyboard
; controller's reset line.
        cpu 286
        org 0x7C3E
start:  xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        mov al, 'P'
        call putc
        cli
        mov al, 2                   ; A20 on
        out 0x92, al
        mov word [0x467], back
        mov [0x469], cs
        mov al, 0x0F
        out 0x70, al
        mov al, 0x0A
        out 0x71, al
        mov [save_sp], sp
        lgdt [gdtr]
        lidt [idtr]
        smsw ax
        or al, 1
        lmsw ax
        jmp 0x08:pm
pm:     mov ax, 0x10                ; data: base 0
        mov ds, ax
        mov ss, ax
        mov ax, 0x18                ; data: base 110000h
        mov es, ax
        mov word [es:0], 0xBEEF
        int 1                       ; through the gate
%ifdef FAULT
        lidt [noidt]
        int 3
%else
        mov al, 0xFE
        out 0x64, al
%endif
.h:     hlt
        jmp .h
isr:    mov byte [mark], 0x55
        iret
back:   xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, [save_sp]
        sti
        mov al, 'R'
        call putc
        mov si, mv                  ; INT 15h AH=87h: 2 bytes from 110000h to 'got'
        mov cx, 1
        mov ah, 0x87
        int 0x15
        mov al, [got+1]
        call hex
        mov al, [got]
        call hex
        mov al, [mark]
        call hex
.h:     hlt
        jmp .h
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
        align 2
gdt:    dw 0, 0, 0, 0
        dw 0xFFFF, 0, 0x9A00, 0     ; 08: code, base 0
        dw 0xFFFF, 0, 0x9200, 0     ; 10: data, base 0
        dw 0xFFFF, 0, 0x9211, 0     ; 18: data, base 110000h
gdtr:   dw 31, gdt, 0
idt:    dw 0, 0, 0, 0
        dw isr, 0x08, 0x8600, 0     ; 1: interrupt gate
idtr:   dw 2*8-1, idt, 0
noidt:  dw 0, 0, 0
mv:     times 16 db 0
        dw 0xFFFF, 0x0000, 0x9311, 0   ; source: 110000h
        dw 0xFFFF, got, 0x9300, 0      ; destination
        times 16 db 0
save_sp: dw 0
got:    dw 0
mark:   db 0
