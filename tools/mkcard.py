#!/usr/bin/env python3
"""Make an SD card image for the 286 machine.
  mkcard.py OUT.img [--floppy FLOPPY.img] [--hd HD.img] [--size-mb N]
Layout: sector 0 = the hard disk's partition table (the hard disk is the whole card),
        sector 64 = a floppy image (drive A:). A hard disk image, if given, is copied
        from sector 0 and must keep its first partition at sector 4032 or later (mkhd.py makes such an image)."""
import os, sys
out = sys.argv[1]; a = sys.argv[2:]
floppy = hd = None; size = 8
while a:
    k = a.pop(0)
    if k == '--floppy': floppy = a.pop(0)
    elif k == '--hd': hd = a.pop(0)
    elif k == '--size-mb': size = int(a.pop(0))
import shutil, subprocess
if hd:
    subprocess.run(['cp', '--sparse=always', hd, out], check=True)      # may be gigabytes, mostly empty
else:
    with open(out, 'wb') as f: f.truncate(size << 20)
if floppy:
    d = open(floppy, 'rb').read()
    with open(out, 'r+b') as f:
        if os.path.getsize(out) < 64 * 512 + len(d): f.truncate(64 * 512 + len(d))
        f.seek(64 * 512); f.write(d)
