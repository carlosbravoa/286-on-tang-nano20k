; ───────────────────────────── SD card ─────────────────────────────
; one byte out, one byte in (the port makes the CPU wait for the transfer)
spi_xfer:
        out SPI_DATA, al
        in al, SPI_DATA
        ret

; command AH with argument CX:DX; returns the R1 answer in AL (FFh: none). Keeps CX, DX.
sd_cmd: mov al, 0xFF
        call spi_xfer
        mov al, ah
        or al, 0x40
        call spi_xfer
        mov al, ch
        call spi_xfer
        mov al, cl
        call spi_xfer
        mov al, dh
        call spi_xfer
        mov al, dl
        call spi_xfer
        mov al, 0x95
        or ah, ah
        jz .crc
        mov al, 0x87
        cmp ah, 8
        je .crc
        mov al, 0xFF
.crc:   call spi_xfer
        push cx
        mov cx, 16
.wait:  mov al, 0xFF
        call spi_xfer
        test al, 0x80
        jz .got
        loop .wait
.got:   pop cx
        ret

sd_deselect:
        push ax
        xor al, al
        out SPI_CTRL, al
        mov al, 0xFF
        call spi_xfer
        pop ax
        ret

%ifdef SD_DEBUG
; debugging on the serial port (port E9h): a character, or AX in hexadecimal
%macro DBGC 1
        push ax
        mov al, %1
        out 0xE9, al
        pop ax
%endmacro
%define sdbg_hex call sd_dbg_hex
sd_dbg_hex:
        push ax
        push cx
        call dbg_hex
        pop cx
        pop ax
        ret
%endif

; start the card; sets E_SDOK and E_SDHC
sd_init:
        push ds
        mov ax, EBDA_SEG
        mov ds, ax
        mov byte [E_SDOK], 0
        mov byte [E_SDHC], 0
        mov al, SPI_SLOW
        out SPI_CTRL, al
        mov cx, 10                  ; 80 clocks with the card not selected
.wake:  mov al, 0xFF
        call spi_xfer
        loop .wake
        mov al, SPI_SLOW | SPI_CS
        out SPI_CTRL, al
        mov bx, 20
.idle:  mov ah, 0                   ; CMD0: go idle
        xor cx, cx
        xor dx, dx
        call sd_cmd
        cmp al, 1
        je .v
        dec bx
        jnz .idle
        jmp .fail
.v:     mov ah, 8                   ; CMD8: version 2 cards answer
        mov dx, 0x01AA
        call sd_cmd
        mov bl, al
%ifdef SD_DEBUG
        DBGC 'V'
        sdbg_hex
%endif
        test al, 4
        jnz .op
        mov cx, 4
.r7:    mov al, 0xFF
        call spi_xfer
        loop .r7
.op:    mov si, 20000               ; ACMD41 until the card is ready
.op1:   mov ah, 55
        xor cx, cx
        xor dx, dx
        call sd_cmd
        mov ah, 41
        xor cx, cx
        test bl, 4
        jnz .op2
        mov cx, 0x4000              ; we can do high capacity
.op2:   call sd_cmd
        or al, al
        jz .ready
        dec si
        jnz .op1
        jmp .fail
.ready: mov ah, 58                  ; CMD58: OCR, bit 30 = addressed in sectors
        xor cx, cx
        xor dx, dx
        call sd_cmd
        mov al, 0xFF
        call spi_xfer
%ifdef SD_DEBUG
        DBGC 'O'
        sdbg_hex
        DBGC 13
        DBGC 10
%endif
        and al, 0x40
        mov [E_SDHC], al
        mov cx, 3
.ocr:   mov al, 0xFF
        call spi_xfer
        loop .ocr
        mov ah, 16                  ; CMD16: 512-byte blocks
        xor cx, cx
        mov dx, 512
        call sd_cmd
        mov byte [E_SDOK], 1
        call sd_deselect
        pop ds
        ret
.fail:  call sd_deselect
        pop ds
        mov si, msg_nocard
        jmp puts

; DX:AX = sector -> CX:DX = the card's address of it. DS = EBDA.
sd_addr:
        cmp byte [E_SDHC], 0
        jne .hc
        mov ch, dl                  ; times 512
        mov cl, ah
        mov dh, al
        xor dl, dl
        shl dh, 1
        rcl cx, 1
        ret
.hc:    mov cx, dx
        mov dx, ax
        ret

; read sector DX:AX to ES:DI (DI moves on). DS = EBDA. Carry on error.
sd_read:
        cmp byte [E_SDOK], 0
        je .bad
%ifdef SD_DEBUG
        DBGC 'R'
        xchg ax, dx
        sdbg_hex
        xchg ax, dx
        sdbg_hex
%endif
        call sd_addr
%ifdef SD_DEBUG
        DBGC 'A'
        mov ax, cx
        sdbg_hex
        mov ax, dx
        sdbg_hex
%endif
        mov al, SPI_CS
        out SPI_CTRL, al
        mov ah, 17
        call sd_cmd
%ifdef SD_DEBUG
        DBGC 'S'
        sdbg_hex
%endif
        or al, al
        jnz .err
        mov cx, 0xFFFF
.tok:   mov al, 0xFF
        call spi_xfer
        cmp al, 0xFE
        je .data
        loop .tok
        jmp .err
.data:  mov al, SPI_CS | SPI_AUTO
        out SPI_CTRL, al
        in al, SPI_DATA             ; starts the first byte
        mov cx, 512
        mov dx, SPI_DATA
        rep insb
        mov al, SPI_CS
        out SPI_CTRL, al
        in al, SPI_DATA             ; the two CRC bytes
        mov al, 0xFF
        call spi_xfer
        call sd_deselect
%ifdef SD_DEBUG
        DBGC 'D'
        mov ax, [es:di-512]
        sdbg_hex
        mov ax, [es:di-510]
        sdbg_hex
        mov ax, [es:di-2]
        sdbg_hex
        DBGC 13
        DBGC 10
%endif
        clc
        ret
.err:   call sd_deselect
%ifdef SD_DEBUG
        DBGC '!'
        DBGC 13
        DBGC 10
%endif
.bad:   stc
        ret

; write sector DX:AX from ES:SI (SI moves on). DS = EBDA. Carry on error.
sd_write:
        cmp byte [E_SDOK], 0
        je .bad
        call sd_addr
        mov al, SPI_CS
        out SPI_CTRL, al
        mov ah, 24
        call sd_cmd
        or al, al
        jnz .err
        mov al, 0xFF
        call spi_xfer
        mov al, 0xFE
        out SPI_DATA, al
        mov cx, 512
        mov dx, SPI_DATA
        push ds
        push es
        pop ds
        rep outsb
        pop ds
        mov al, 0xFF
        call spi_xfer
        mov al, 0xFF
        call spi_xfer
        mov al, 0xFF
        call spi_xfer               ; data response
        and al, 0x1F
        cmp al, 0x05
        jne .err
        mov cx, 0xFFFF
.busy:  mov al, 0xFF
        call spi_xfer
        cmp al, 0xFF
        je .done
        loop .busy
        jmp .err
.done:  call sd_deselect
        clc
        ret
.err:   call sd_deselect
.bad:   stc
        ret

; find the floppy image and the hard disk on the card
drives_init:
        push ds
        push es
        mov ax, EBDA_SEG
        mov ds, ax
        xor ax, ax
        mov es, ax
        ; drive B: is on another computer, if one serves it; until it says what, 1.44 MB
        mov word [E_REMOTE+DRV.present], 0x1201
        mov word [E_REMOTE+DRV.heads], 0x0402
        mov word [E_REMOTE+DRV.cyls], 80
        xor ax, ax
        mov [E_REMOTE+DRV.base], ax
        mov [E_REMOTE+DRV.base+2], ax
        mov [E_RSERVE], al
        mov [E_RSTATE], al
        push ds
        mov ax, 0x40
        mov ds, ax
        or word [BD_EQUIP], 0x0041  ; two floppy drives
        pop ds
        ; floppy image: a boot sector with a FAT12 parameter block
        mov ax, FLOPPY_LBA
        xor dx, dx
        mov di, 0x7C00
        call sd_read
        jc .hd
        cmp word [es:0x7DFE], 0xAA55
        jne .hd
        mov ax, [es:0x7C13]         ; sectors
        mov bl, [es:0x7C18]         ; per track
        mov bh, [es:0x7C1A]         ; heads
        or ax, ax
        jz .hd
        or bl, bl
        jz .hd
        cmp bl, 63
        ja .hd
        or bh, bh
        jz .hd
        cmp bh, 2
        ja .hd
        mov [E_FLOPPY+DRV.spt], bl
        mov [E_FLOPPY+DRV.heads], bh
        mov [E_FLOPPY+DRV.total], ax
        mov word [E_FLOPPY+DRV.base], FLOPPY_LBA
        push ax
        mov al, bl
        mul bh
        mov cx, ax
        pop ax
        xor dx, dx
        div cx
        mov [E_FLOPPY+DRV.cyls], ax
        mov al, 4                   ; 1.44 MB
        cmp bl, 18
        je .ft
        mov al, 2                   ; 1.2 MB
        cmp bl, 15
        je .ft
        mov al, 3                   ; 720 KB
        cmp word [E_FLOPPY+DRV.cyls], 80
        je .ft
        mov al, 1                   ; 360 KB
.ft:    mov [E_FLOPPY+DRV.type], al
        mov byte [E_FLOPPY+DRV.present], 1
        push ds
        mov ax, 0x40
        mov ds, ax
        or word [BD_EQUIP], 0x0001
        pop ds
        mov si, msg_floppy
        call puts
        ; hard disk: the card itself, if it has a partition table
.hd:    xor ax, ax
        xor dx, dx
        mov di, 0x7C00
        call sd_read
        jc .done
        cmp word [es:0x7DFE], 0xAA55
        jne .done
        mov bl, 63                  ; geometry: as the first partition's end says, else 16 x 63
        mov bh, 16
        cmp byte [es:0x7DBE+4], 0
        je .geo
        mov al, [es:0x7DBE+6]
        and al, 0x3F
        jz .geo
        mov bl, al
        mov bh, [es:0x7DBE+5]
        inc bh
        jz .hd255
        jmp .geo
.hd255: mov bh, 255
.geo:   mov [E_HD+DRV.spt], bl
        mov [E_HD+DRV.heads], bh
        mov word [E_HD+DRV.cyls], 1024
        mov byte [E_HD+DRV.present], 1
        mov word [E_HDPARM], 1024
        mov [E_HDPARM+2], bh
        mov word [E_HDPARM+5], 0xFFFF
        mov byte [E_HDPARM+8], 8
        mov word [E_HDPARM+12], 1024
        mov [E_HDPARM+14], bl
        push ds
        mov ax, 0x40
        mov ds, ax
        mov byte [BD_HDCOUNT], 1
        xor ax, ax
        mov ds, ax
        mov word [0x41*4], E_HDPARM
        mov word [0x41*4+2], EBDA_SEG
        pop ds
        mov si, msg_hd
        call puts
.done:  pop es
        pop ds
        ret

msg_nocard:     db "SD card: not found", 13, 10, 0
msg_floppy:     db "Drive A: floppy image on the card", 13, 10, 0
msg_hd:         db "Drive C: the card", 13, 10, 0

; ───────────────────────────── INT 13h: disks ─────────────────────────────
; Frame from BP: +0 ES +2 DS +4 DI +6 SI +8 BP +10 SP +12 BX +14 DX +16 CX +18 AX +20 IP +22 CS +24 flags
int13:  sti
        cld
        pusha
        push ds
        push es
        mov bp, sp
        mov si, EBDA_SEG
        mov ds, si
        mov si, E_FLOPPY
        or dl, dl
        jz .drv
        mov si, E_REMOTE
        cmp dl, 1
        je .drv
        mov si, E_HD
        cmp dl, 0x80
        jne .nodrive
.drv:   cmp byte [si+DRV.present], 0
        je .nodrive
        cmp ah, 0x02
        je d_read
        cmp ah, 0x03
        je d_write
        cmp ah, 0x08
        je d_parms
        cmp ah, 0x15
        je d_type
        cmp ah, 0x01
        je d_status
        cmp ah, 0x18
        ja d_bad
        cmp ah, 0x06
        je d_bad
        cmp ah, 0x07
        je d_bad
        jmp d_ok                    ; reset, verify, seek, ...: nothing to do
.nodrive:
        cmp ah, 0x08
        jne .nd1
        cmp dl, 0x80
        jae d_bad
        xor ax, ax                  ; no such floppy: all zero
        mov F_BX, ax
        mov F_CX, ax
        mov F_DX, ax
        mov [bp+4], ax
        mov [bp+0], ax
        jmp d_ok
.nd1:   cmp ah, 0x15
        jne .nd2
        mov byte [bp+19], 0         ; no drive
        jmp d_ret_nc
.nd2:   or ah, ah
        jz d_ok                     ; a reset of everything
d_bad:  mov ah, 0x01                ; bad command
d_fail: mov [bp+19], ah
        call d_setstatus
        or byte [bp+24], 1
        jmp d_ret
d_ok:   xor ah, ah
        mov [bp+19], ah
        call d_setstatus
d_ret_nc:
        and byte [bp+24], 0xFE
d_ret:  pop es
        pop ds
        popa
        iret

d_setstatus:                        ; AH = status of drive DL
        push ds
        push bx
        mov bx, 0x40
        mov ds, bx
        mov bx, BD_FDSTATUS
        test byte [bp+14], 0x80
        jz .s
        mov bx, BD_HDSTATUS
.s:     mov [bx], ah
        pop bx
        pop ds
        ret

d_status:
        push ds
        mov bx, 0x40
        mov ds, bx
        mov bx, BD_FDSTATUS
        test dl, 0x80
        jz .s
        mov bx, BD_HDSTATUS
.s:     mov ah, [bx]
        pop ds
        mov [bp+19], ah
        or ah, ah
        jz d_ret_nc
        or byte [bp+24], 1
        jmp d_ret

; CHS in CX, DH of drive SI -> sector on the card in DX:AX. Carry: out of range.
d_lba:  mov ax, cx
        xchg al, ah
        shr ah, 6                   ; AX = cylinder
        mov bl, cl
        and bx, 0x3F                ; BX = sector
        jz .bad
        cmp bl, [si+DRV.spt]
        ja .bad
        cmp dh, [si+DRV.heads]
        jae .bad
        cmp ax, [si+DRV.cyls]
        jae .bad
        mov cl, dh
        xor ch, ch
        xor dx, dx
        mov dl, [si+DRV.heads]
        mul dx                      ; cylinder * heads (fits 16 bits... or 32 with 255 heads)
        add ax, cx
        adc dx, 0
        push bx
        mov bx, dx                  ; (DX:AX) * spt
        mov cl, [si+DRV.spt]
        xor ch, ch
        mul cx
        push ax
        push dx
        mov ax, bx
        mul cx
        pop dx
        add dx, ax
        pop ax
        pop bx
        dec bx
        add ax, bx
        adc dx, 0
        add ax, [si+DRV.base]
        adc dx, [si+DRV.base+2]
        clc
        ret
.bad:   stc
        ret

d_read: mov byte [bp+18], 0         ; sectors done
        mov bl, al
        or bl, bl
        jz d_bad
        push bx
        call d_lba
        pop bx
        jnc .found
        mov ah, 0x04                ; sector not found
        jmp d_fail
.found:
        mov bh, 2
        cmp si, E_REMOTE
        je d_remote
        mov di, F_BX
        mov es, F_ES
.l:     push ax
        push dx
        push bx
        call sd_read
        pop bx
        pop dx
        pop ax
        jnc .good
        mov ah, 0x20                ; controller failure
        jmp d_fail
.good:
        inc byte [bp+18]
        add ax, 1
        adc dx, 0
        dec bl
        jnz .l
        xor ah, ah
        call d_setstatus
        mov byte [bp+19], 0
        jmp d_ret_nc

d_write:
        mov byte [bp+18], 0
        mov bl, al
        or bl, bl
        jz d_bad
        push bx
        call d_lba
        pop bx
        jnc .found
        mov ah, 0x04
        jmp d_fail
.found: mov bh, 3
        cmp si, E_REMOTE
        je d_remote
        mov di, si
        mov si, F_BX
        mov es, F_ES
.l:     push ax
        push dx
        push bx
        call sd_write
        pop bx
        pop dx
        pop ax
        jnc .good
        mov ah, 0x20
        jmp d_fail
.good:
        inc byte [bp+18]
        add ax, 1
        adc dx, 0
        dec bl
        jnz .l
        xor ah, ah
        call d_setstatus
        mov byte [bp+19], 0
        jmp d_ret_nc

; Drive B: is on another computer, which looks into this machine's memory through the
; monitor (tools/pc286ctl.py serve): we leave the request in the EBDA and wait until it says
; done; it reads or writes the caller's memory itself.
; BH = 2 read, 3 write; BL = sectors; DX:AX = the first one.
d_remote:
        cmp byte [E_RSERVE], 0
        jne .on
.gone:  mov ah, 0x80                ; nobody there: not ready
        jmp d_fail
.on:    mov [E_RLBA], ax
        mov [E_RLBA+2], dx
        mov [E_ROP], bh
        mov [E_RCOUNT], bl
        mov ax, F_ES                ; where the caller's memory is
        mov dx, ax
        shl ax, 4
        shr dx, 12
        add ax, F_BX
        adc dx, 0
        mov [E_RBUF], ax
        mov [E_RBUF+2], dx
        mov byte [E_RSTATE], 1
        mov ax, 0x40
        mov es, ax
        mov cx, [es:BD_TICKS]
.wait:  test byte [E_RSTATE], 0x80
        jnz .done
        mov ax, [es:BD_TICKS]
        sub ax, cx
        cmp ax, 18 * 20             ; 20 seconds
        jb .wait
        mov byte [E_RSTATE], 0
        jmp .gone
.done:  mov ah, [E_RSTATE]
        mov byte [E_RSTATE], 0
        and ah, 0x7F
        jnz d_fail
        mov [bp+18], bl
        call d_setstatus
        mov byte [bp+19], 0
        jmp d_ret_nc

d_parms:
        mov ax, [si+DRV.cyls]
        dec ax                      ; highest cylinder
        mov ch, al
        mov cl, ah
        shl cl, 6
        or cl, [si+DRV.spt]
        mov F_CX, cx
        mov ah, [si+DRV.heads]
        dec ah
        mov al, 1                   ; one hard disk
        mov F_DX, ax
        cmp dl, 0x80
        jae d_ok
        mov byte [bp+14], 2         ; two floppy drives
        mov al, [si+DRV.type]
        xor ah, ah
        mov F_BX, ax
        mov word [bp+4], diskette_parms
        mov [bp+0], cs
        jmp d_ok

d_type: cmp dl, 0x80
        jae .hd
        mov byte [bp+19], 1         ; a floppy drive without change line
        jmp d_ret_nc
.hd:    mov ax, [si+DRV.cyls]       ; sectors = cylinders * heads * spt
        xor bh, bh
        mov bl, [si+DRV.heads]
        mul bx
        mov bl, [si+DRV.spt]
        mov cx, dx
        mul bx
        xchg ax, cx
        push dx
        mul bx
        pop dx
        add dx, ax
        mov F_DX, cx
        mov F_CX, dx
        mov byte [bp+19], 3
        jmp d_ret_nc
