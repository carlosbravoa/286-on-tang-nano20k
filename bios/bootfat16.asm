; Boot sector of a FAT16 partition: load KERNEL.SYS (FreeDOS) at 0060:0000 and start it.
; Goes after the BPB that the formatter wrote, from offset 3Eh. 512-byte sectors.
        cpu 286
        org 0x7C3E
start:  cli                         ; first move out of the kernel's way, to 1FE0:7C00
        cld
        xor ax, ax
        mov ds, ax
        mov ax, 0x1FE0
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        mov bp, sp                  ; BP = the BPB: +0Dh sectors per cluster, +0Eh reserved,
        mov si, sp                  ; +10h FATs, +11h root entries, +16h sectors per FAT,
        mov di, sp                  ; +18h sectors per track, +1Ah heads, +1Ch hidden, +24h drive
        mov cx, 256
        rep movsw
        jmp 0x1FE0:.go
.go:    mov ds, ax
        sti
        mov [bp+0x24], dl
        mov si, [bp+0x1C]
        mov di, [bp+0x1E]
        add si, [bp+0x0E]
        adc di, 0
        mov [fat_lo], si
        mov [fat_hi], di
        mov al, [bp+0x10]
        cbw
        mul word [bp+0x16]
        add ax, si
        adc dx, di                  ; DX:AX = the root directory
        mov cx, [bp+0x11]
        shr cx, 4                   ; CX = its sectors
        mov si, ax
        mov di, dx
        add si, cx
        adc di, 0
        mov [data_lo], si
        mov [data_hi], di
.rs:    mov bx, 0x7E00
        call readsec
        mov di, bx
.ent:   push cx
        push di
        mov si, kname
        mov cx, 11
        repe cmpsb
        pop di
        pop cx
        je found
        add di, 32
        cmp di, 0x8000
        jb .ent
        add ax, 1
        adc dx, 0
        loop .rs
error:  mov si, emsg
.p:     lodsb
        or al, al
        jz .k
        mov ah, 0x0E
        mov bx, 7
        int 0x10
        jmp .p
.k:     xor ax, ax
        int 0x16
        int 0x19

found:  mov si, [di+26]             ; SI = cluster
        mov ax, 0x0060
        mov es, ax
.clus:  mov ax, si
        dec ax
        dec ax
        mov cl, [bp+0x0D]
        xor ch, ch
        mul cx
        add ax, [data_lo]
        adc dx, [data_hi]
.sec:   xor bx, bx
        call readsec
        mov bx, es
        add bx, 0x20
        mov es, bx
        add ax, 1
        adc dx, 0
        loop .sec
        push es                     ; the next cluster, from the FAT
        push ds
        pop es
        mov ax, si
        mov al, ah
        xor ah, ah
        xor dx, dx
        add ax, [fat_lo]
        adc dx, [fat_hi]
        mov bx, 0x7E00
        call readsec
        pop es
        and si, 0x00FF
        shl si, 1
        mov si, [si+0x7E00]
        cmp si, 0xFFF8
        jb .clus
        mov bl, [bp+0x24]           ; FreeDOS takes its drive in BL
        mov dl, bl
        jmp 0x0060:0x0000

; read sector DX:AX to ES:BX
readsec:
        pusha
        div word [bp+0x18]
        mov cx, dx
        inc cx
        xor dx, dx
        div word [bp+0x1A]
        mov dh, dl
        mov ch, al
        shl ah, 6
        or cl, ah
        mov dl, [bp+0x24]
        mov ax, 0x0201
        int 0x13
        jc error
        popa
        ret

kname:  db "KERNEL  SYS"
emsg:   db "No KERNEL.SYS", 0
fat_lo: dw 0
fat_hi: dw 0
data_lo: dw 0
data_hi: dw 0
