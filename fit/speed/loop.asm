bits 16
cpu 286
org 0x100
start:  xor ax,ax
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov sp,0x8000
        mov si,0x2000
        mov di,0x3000
        mov bx,3
        mov dx,0x1234
        mov cx,1000
L:      mov ax,[si]
        add ax,bx
        mov [di],ax
        inc si
        inc si
        inc di
        inc di
        cmp ax,dx
        jne N
N:      push ax
        pop bx
        call F
        loop L
        hlt
F:      ret
        times 0xFFF0-0x100-($-$$) db 0xF4
        jmp start
        times 0x10000-0x100-($-$$) db 0xF4
