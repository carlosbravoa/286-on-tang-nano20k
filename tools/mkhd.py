#!/usr/bin/env python3
"""Make a hard disk image for the 286 machine: one FAT16 partition that boots FreeDOS.

  mkhd.py OUT.img [--size-mb N] [--from FLOPPY.img]... [--dir HOSTDIR[=DOSDIR]]...

  --size-mb N      size of the disk (default 64, at most 2016: C: is one FAT16 partition)
  --from IMG       copy everything on a floppy image (the first one must have KERNEL.SYS)
  --dir DIR[=NAME] copy a directory of this computer to C:\\NAME (default: its own name)
  --root DIR       copy everything in a directory of this computer to C:\\ (its
                   subdirectories become C:\\GAME1, C:\\GAME2, ...)
  --xms FILE       an XMS driver for a 286 (FDXMS286.SYS): DOS then loads itself high and
                   programs get about 100 KB more

The partition starts at sector 4032, which leaves room for the floppy image that
mkcard.py puts at sector 64. Then:  mkcard.py CARD.img --hd OUT.img [--floppy A.img]
Files can be added later:  fatimg.py CARD.img@4032 put FILE
Needs nasm and mkfs.fat (dosfstools).
"""
import os, struct, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
from fatimg import Fat

START, SPT = 4032, 63
HEADS = 16                         # 32 or 64 for disks over 504 MB; the BIOS reads it from the partition table
XMS = b"DEVICE=C:\\FREEDOS\\BIN\\%s\r\nDOS=HIGH\r\n"
CONFIG = b"LASTDRIVE=Z\r\nBUFFERS=20\r\nFILES=40\r\nSHELL=C:\\FREEDOS\\BIN\\COMMAND.COM C:\\FREEDOS\\BIN /E:512 /P=C:\\FDAUTO.BAT\r\n"
AUTO = b"@echo off\r\npath C:\\FREEDOS\\BIN\r\nprompt $p$g\r\n"

def chs(lba):
    c, r = divmod(lba, HEADS * SPT); h, s = divmod(r, SPT)
    if c > 1023: c, h, s = 1023, HEADS - 1, SPT - 1
    return bytes([h, (s + 1) | (c >> 8) << 6, c & 0xFF])

def asm(name, tmp):
    out = os.path.join(tmp, name + '.bin')
    subprocess.run(['nasm', '-f', 'bin', os.path.join(here, '..', 'bios', name + '.asm'), '-o', out], check=True)
    return open(out, 'rb').read()

def main():
    a = sys.argv[1:]
    if not a or a[0].startswith('-'): raise SystemExit(__doc__)
    out = a.pop(0); size = 64; floppies = []; dirs = []; roots = []; xms = None
    while a:
        k = a.pop(0)
        if k == '--size-mb': size = int(a.pop(0))
        elif k == '--from': floppies.append(a.pop(0))
        elif k == '--dir': dirs.append(a.pop(0))
        elif k == '--xms': xms = a.pop(0)
        elif k == '--root': roots.append(a.pop(0))
        else: raise SystemExit(__doc__)
    global HEADS
    while HEADS < 64 and size * 2048 > 1024 * HEADS * SPT: HEADS *= 2
    cyls = min(size * 2048 // (HEADS * SPT), 1024)
    total = cyls * HEADS * SPT
    psecs = total - START
    with tempfile.TemporaryDirectory() as tmp:
        part = out + '.part'
        if os.path.exists(part): os.remove(part)
        mkfs = '/usr/sbin/mkfs.fat' if os.path.exists('/usr/sbin/mkfs.fat') else 'mkfs.fat'
        subprocess.run([mkfs, '-F', '16', '-n', 'DOS286', '-g', '%d/%d' % (HEADS, SPT), '-h', str(START),
                        '-D', '0x80', '--invariant', '-C', part, str(psecs // 2)], check=True, stdout=subprocess.DEVNULL)
        boot = asm('bootfat16', tmp)
        if len(boot) > 0x1FE - 0x3E: raise SystemExit('boot sector code too long')
        with open(part, 'r+b') as f:
            f.write(b'\xEB\x3C\x90'); f.seek(0x3E); f.write(boot)
        fs = Fat(part)
        for i, fl in enumerate(floppies):
            fs.copy_from(Fat(fl))
        fs.remove('SETUP.BAT')                      # the floppy's installer: of no use here
        config = CONFIG
        if xms:
            name = os.path.basename(xms).upper()
            fs.mkdir('FREEDOS'); fs.mkdir('FREEDOS/BIN')
            fs.write('FREEDOS/BIN/' + name, open(xms, 'rb').read())
            config = XMS % name.encode() + CONFIG
        fs.write('FDCONFIG.SYS', config); fs.write('FDAUTO.BAT', AUTO)
        for r in roots: fs.copy_host(r)
        for d in dirs:
            src, _, name = d.partition('=')
            name = name or os.path.basename(os.path.normpath(src))
            fs.mkdir(name); fs.copy_host(src, name + '/')
        mbr = bytearray(512); code = asm('mbr', tmp); mbr[:len(code)] = code
        ptype = 0x06 if psecs >= 65536 else 0x04
        mbr[0x1BE:0x1CE] = bytes([0x80]) + chs(START) + bytes([ptype]) + chs(total - 1) + struct.pack('<II', START, psecs)
        mbr[510:512] = b'\x55\xAA'
        fs.save(); csize = fs.csize; fs.d.close(); fs.f.close()
        with open(out, 'wb') as f:
            f.write(mbr); f.truncate(START * 512)
        # the partition goes after it, holes kept as holes
        subprocess.run(['dd', 'if=' + part, 'of=' + out, 'bs=4096', 'seek=%d' % (START * 512 // 4096), 'conv=sparse,notrunc', 'status=none'], check=True)
        os.truncate(out, total * 512)
        os.remove(part)
    print('%s: %d MB disk, C: is FAT16 with %d KB clusters' % (out, total // 2048, csize // 1024))

main()
